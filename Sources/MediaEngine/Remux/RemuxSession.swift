internal import FFmpegLGPL
import Foundation
import Synchronization

/// Turns one file into an HLS presentation of fragmented MP4: a video playlist plus one audio playlist per
/// track, produced on demand. All demuxer access is serialized on one queue.
///
/// Segments are cut at video keyframes (from the file's index) and built with ``FragmentWriter``, so any
/// segment can be requested at any time, in any order.
final class RemuxSession: @unchecked Sendable, ResourceProvider {
    struct Resource: Sendable {
        var data: Data
        var contentType: String
    }

    private struct Output {
        var streamIndex: Int
        var kind: Track.Kind
        var track: Track
        var initSegment: InitSegment
        var writer: FragmentWriter
        var codecs: String
        /// Present for audio that is decoded and re-encoded to ALAC; packets then use the transcoder's time base.
        var transcoder: AudioTranscoder?
    }

    private struct CacheKey: Hashable { var stream: Int; var segment: Int }

    let info: MediaInfo
    let plan: SegmentPlan

    private let reader: PacketReader
    private let cancellation: CancellationFlag
    private let queue = DispatchQueue(label: "dev.mediaengine.remux", qos: .userInitiated)
    private var outputs: [Int: Output] = [:]
    private let videoIndex: Int?
    private let audioIndices: [Int]
    private var cache: [CacheKey: Data] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cacheBytes = 0
    /// Source packets of audio that still has to be transcoded; done only if the player asks for that track.
    private var pendingTranscodes: [CacheKey: [MediaPacket]] = [:]
    /// How many (track, segment) transcodes have run (diagnostics and tests).
    private(set) var transcodeCount = 0
    private let cacheBudget: Int
    private let requestEpoch = Mutex(0)
    /// Test hook: rewrites the master playlist before it is served.
    nonisolated(unsafe) var masterTransform: ((String) -> String)?

    // MARK: Opening

    /// Blocking: reads the start of the file, builds the segment plan and the initialization segments.
    init(source: any ByteSource, info: MediaInfo, cancellation: CancellationFlag, cacheBudget: Int = 128 * 1024 * 1024) throws {
        self.info = info
        self.cancellation = cancellation
        self.cacheBudget = cacheBudget
        reader = try PacketReader(source: source, cancellation: cancellation)

        let treatments = Dictionary(uniqueKeysWithValues: info.playbackPlan.tracks.map { ($0.trackID, $0.treatment) })
        videoIndex = info.videoTracks.first { treatments[$0.id] == .passthrough }?.id
        audioIndices = info.audioTracks.filter { track in
            switch treatments[track.id] {
            case .passthrough: true
            case .transcodeAudio(.alac): AudioTranscoder.canTranscodeStatelessly(track.codec.name)
            default: false
            }
        }.map(\.id)
        let wanted = (videoIndex.map { [$0] } ?? []) + audioIndices
        guard !wanted.isEmpty else { throw MediaError.unsupported(detail: "no playable video or audio track") }

        // First packets of every wanted stream: used to describe AC-3 streams and to measure the timestamp shift.
        let first = try Self.readStart(reader, streams: wanted, video: videoIndex)
        var earliest = 0.0
        for (stream, packets) in first {
            if let packet = packets.first { earliest = min(earliest, reader.timeBase(stream).seconds(packet.dts)) }
        }
        let shiftSeconds = -earliest

        // Segment plan from the video index; a scan covers files that lack one.
        var keyframes: [Double] = []
        var duration = info.duration
        if let videoIndex {
            let videoBase = reader.timeBase(videoIndex)
            keyframes = reader.keyframeTimestamps(stream: videoIndex).map { videoBase.seconds($0) }
        }
        if (videoIndex != nil && keyframes.isEmpty) || duration == nil {
            let scan = try Self.scan(reader, video: videoIndex, fallbackStream: wanted[0])
            if keyframes.isEmpty { keyframes = scan.keyframes }
            if duration == nil { duration = scan.duration }
        }
        guard let totalDuration = duration, totalDuration > 0 else { throw MediaError.unsupported(detail: "unknown duration") }
        plan = SegmentPlan.make(keyframes: keyframes, duration: totalDuration)

        for stream in wanted {
            guard let track = info.tracks.first(where: { $0.id == stream }) else { continue }
            let isVideo = stream == videoIndex
            let sourceBase = reader.timeBase(stream)
            let treatment = treatments[stream]

            if case .transcodeAudio = treatment {
                // Decoded and re-encoded to ALAC: the packets, the init segment and the fragments all use 1/sample-rate.
                let transcoder = try AudioTranscoder(parameters: reader.parameters(stream), sourceTimeBase: sourceBase)
                let timeBase = transcoder.outputTimeBase
                let shift = timeBase.ticks(seconds: shiftSeconds)
                let encodedParameters = try transcoder.makeEncodedParameters()
                defer { var pointer: UnsafeMutablePointer<AVCodecParameters>? = encodedParameters; avcodec_parameters_free(&pointer) }
                let sample = try transcoder.transcode(first[stream] ?? [], stream: stream)
                let initSegment = try InitSegmentBuilder.build(
                    parameters: encodedParameters, timeBase: timeBase, sampleAspect: AVRational(num: 0, den: 1),
                    samples: sample, shift: shift)
                outputs[stream] = Output(
                    streamIndex: stream, kind: .audio, track: track, initSegment: initSegment,
                    writer: FragmentWriter(trackID: initSegment.trackID, timescale: initSegment.timescale, timeBase: timeBase,
                                           hasCompositionOffsets: false, shift: shift),
                    codecs: "alac", transcoder: transcoder)
                continue
            }

            let shift = sourceBase.ticks(seconds: shiftSeconds)
            let st = reader.stream(stream)
            let initSegment = try InitSegmentBuilder.build(
                parameters: reader.parameters(stream), timeBase: sourceBase,
                sampleAspect: isVideo ? st.pointee.sample_aspect_ratio : AVRational(num: 0, den: 1),
                samples: first[stream] ?? [], shift: shift)
            outputs[stream] = Output(
                streamIndex: stream, kind: isVideo ? .video : .audio, track: track, initSegment: initSegment,
                writer: FragmentWriter(trackID: initSegment.trackID, timescale: initSegment.timescale, timeBase: sourceBase,
                                       hasCompositionOffsets: isVideo, shift: shift),
                codecs: HLSPlaylists.codecString(for: reader.parameters(stream)))
        }
    }

    /// Whether the session serves this stream (used by tests and the player item builder).
    func hasOutput(_ stream: Int) -> Bool { outputs[stream] != nil }
    /// Media timescale of a served stream.
    func timescale(_ stream: Int) -> Int32 { outputs[stream]?.initSegment.timescale ?? 1 }

    func close() {
        cancellation.cancel()
        queue.sync { cache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0 }
    }

    /// Reads packets from the start of the file until every stream has a handful (video starts at a keyframe).
    private static func readStart(_ reader: PacketReader, streams: [Int], video: Int?) throws -> [Int: [MediaPacket]] {
        var result: [Int: [MediaPacket]] = [:]               // a freshly opened file is already at its first packet
        var inspected = 0
        while inspected < 2_000, let packet = try reader.next() {
            inspected += 1
            guard streams.contains(packet.stream) else { continue }
            if packet.stream == video, result[packet.stream] == nil, !packet.isKeyframe { continue }
            if (result[packet.stream]?.count ?? 0) < 8 { result[packet.stream, default: []].append(packet) }
            if streams.allSatisfy({ (result[$0]?.count ?? 0) >= 8 }) { break }
        }
        guard streams.allSatisfy({ result[$0] != nil }) else { throw MediaError.corrupt(detail: "stream without packets near the start") }
        return result
    }

    /// Reads the whole file once to find keyframes and the true duration.
    private static func scan(_ reader: PacketReader, video: Int?, fallbackStream: Int) throws -> (keyframes: [Double], duration: Double) {
        try reader.rewind()
        var keyframes: [Double] = []
        var end = 0.0
        while let packet = try reader.next() {
            let timeBase = reader.timeBase(packet.stream)
            end = max(end, timeBase.seconds(packet.pts + packet.duration))
            if packet.stream == video, packet.isKeyframe { keyframes.append(timeBase.seconds(packet.pts)) }
        }
        return (keyframes, end)
    }

    // MARK: Serving

    /// Everything the server hands out, by path. Returns `nil` for unknown paths.
    func resource(path: String) throws -> Resource? {
        requestEpoch.withLock { $0 += 1 }
        switch path {
        case "master.m3u8": return text(masterTransform.map { $0(master()) } ?? master())
        case "video.m3u8": return videoIndex.map { text(mediaPlaylist(stream: $0)) }
        case "video-init.mp4": return videoIndex.flatMap { outputs[$0] }.map { Resource(data: $0.initSegment.data, contentType: "video/mp4") }
        default: break
        }
        if path.hasPrefix("video-"), let stream = videoIndex, let number = Self.segmentNumber(path, prefix: "video-") {
            return try segment(stream: stream, number: number)
        }
        if path.hasPrefix("audio-") {
            if path.hasSuffix(".m3u8"), let id = Int(path.dropFirst("audio-".count).dropLast(".m3u8".count)),
               outputs[id]?.kind == .audio {
                return text(mediaPlaylist(stream: id))
            }
            let parts = path.dropFirst("audio-".count).split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let id = Int(parts[0]), let output = outputs[id], output.kind == .audio else { return nil }
            let tail = String(parts[1])
            if tail == "init.mp4" { return Resource(data: output.initSegment.data, contentType: "audio/mp4") }
            if let number = Self.segmentNumber(tail, prefix: "") { return try segment(stream: id, number: number) }
        }
        return nil
    }

    private static func segmentNumber(_ path: String, prefix: String) -> Int? {
        guard path.hasSuffix(".m4s") else { return nil }
        return Int(path.dropFirst(prefix.count).dropLast(4))
    }

    private func text(_ playlist: String) -> Resource {
        Resource(data: Data(playlist.utf8), contentType: "application/vnd.apple.mpegurl")
    }

    private func segment(stream: Int, number: Int) throws -> Resource? {
        guard plan.segments.indices.contains(number), let output = outputs[stream] else { return nil }
        let epoch = requestEpoch.withLock { $0 }
        let data: Data? = try queue.sync {
            if cancellation.isCancelled { throw MediaError.cancelled }
            let key = CacheKey(stream: stream, segment: number)
            if let hit = try fragment(for: key) { return hit }
            try buildWindow(number)
            return try fragment(for: key)
        }
        // Read ahead: build the next window while the player consumes this one, unless a newer request arrived.
        if number + 1 < plan.segments.count {
            queue.async { [self] in
                guard requestEpoch.withLock({ $0 }) == epoch, !cancellation.isCancelled,
                      cache[CacheKey(stream: stream, segment: number + 1)] == nil,
                      pendingTranscodes[CacheKey(stream: stream, segment: number + 1)] == nil else { return }
                try? buildWindow(number + 1)
            }
        }
        return data.map { Resource(data: $0, contentType: output.kind == .video ? "video/mp4" : "audio/mp4") }
    }

    // MARK: Windows

    /// Reads the packets of one segment for every output and stores the finished fragments. Call on `queue`.
    private func buildWindow(_ number: Int) throws {
        let segment = plan.segments[number]
        let seekStream = videoIndex ?? audioIndices[0]
        let seekBase = reader.timeBase(seekStream)
        if number == 0 {
            try reader.rewind()
        } else {
            try reader.seek(stream: seekStream, to: seekBase.ticks(seconds: segment.start))
        }

        var packets: [Int: [MediaPacket]] = [:]
        var videoStarted = videoIndex == nil
        var videoDone = videoIndex == nil
        var audioDone = Set<Int>()
        let videoStartTicks = videoIndex.map { reader.timeBase($0).ticks(seconds: segment.start) }
        let isLast = number == plan.segments.count - 1

        while !(videoDone && audioDone.count == audioIndices.count) {
            if cancellation.isCancelled { throw MediaError.cancelled }
            guard let packet = try reader.next() else { break }
            guard outputs[packet.stream] != nil else { continue }
            let seconds = reader.timeBase(packet.stream).seconds(packet.pts)

            if packet.stream == videoIndex {
                if !videoStarted {
                    guard packet.isKeyframe, packet.pts >= (number == 0 ? Int64.min : videoStartTicks! - 1) else { continue }
                    videoStarted = true
                } else if packet.isKeyframe, !isLast, seconds >= segment.end - 0.0005 {
                    videoDone = true
                    continue
                }
                if !videoDone { packets[packet.stream, default: []].append(packet) }
            } else {
                if seconds < segment.start && number > 0 { continue }
                if seconds >= segment.end && !isLast { audioDone.insert(packet.stream); continue }
                if !audioDone.contains(packet.stream) { packets[packet.stream, default: []].append(packet) }
            }
        }

        pendingTranscodes = pendingTranscodes.filter { abs($0.key.segment - number) <= 2 }      // keep only nearby windows
        for (stream, output) in outputs {
            let list = packets[stream] ?? []
            let key = CacheKey(stream: stream, segment: number)
            if output.transcoder != nil, !list.isEmpty {
                pendingTranscodes[key] = list
                continue
            }
            let data = output.writer.fragment(sequence: UInt32(number + 1), packets: list)
                ?? output.writer.emptyFragment(sequence: UInt32(number + 1), atSeconds: segment.start)
            store(key, data)
        }
    }

    /// The finished fragment for a track and segment: from the cache, or transcoded now from the stored packets.
    private func fragment(for key: CacheKey) throws -> Data? {
        if let hit = touch(key) { return hit }
        guard let list = pendingTranscodes.removeValue(forKey: key), let output = outputs[key.stream],
              let transcoder = output.transcoder else { return nil }
        let encoded = try transcoder.transcode(list, stream: key.stream)
        transcodeCount += 1
        let data = output.writer.fragment(sequence: UInt32(key.segment + 1), packets: encoded)
            ?? output.writer.emptyFragment(sequence: UInt32(key.segment + 1), atSeconds: plan.segments[key.segment].start)
        store(key, data)
        return data
    }

    private func touch(_ key: CacheKey) -> Data? {
        guard let data = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return data
    }

    private func store(_ key: CacheKey, _ data: Data) {
        if let old = cache[key] { cacheBytes -= old.count }
        cache[key] = data
        cacheBytes += data.count
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        // Evict least recently used entries, but never the window just built.
        while cacheBytes > cacheBudget, let oldest = cacheOrder.first, oldest.segment != key.segment {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.count }
        }
    }

    // MARK: Playlists

    private func master() -> String {
        let video = videoIndex.flatMap { outputs[$0] }.flatMap { output -> HLSPlaylists.VideoRendition? in
            guard let details = output.track.video else { return nil }
            let range: String? = switch details.hdr {
            case .hdr10: "PQ"
            case .hlg: "HLG"
            case .dolbyVision: nil
            case .sdr: nil
            }
            let fileBits = info.fileSize.map { Double($0) * 8 / max(plan.totalDuration, 1) }
            let bandwidth = Int(output.track.bitrate.map(Double.init) ?? info.bitrate.map(Double.init) ?? fileBits ?? 4_000_000)
            return HLSPlaylists.VideoRendition(codecs: output.codecs, width: details.width, height: details.height,
                                               frameRate: details.frameRate, range: range, bandwidth: max(bandwidth, 1))
        }
        let defaultID = audioIndices.first { outputs[$0]?.track.isDefault == true } ?? audioIndices.first
        let audio = audioIndices.compactMap { id -> HLSPlaylists.AudioRendition? in
            guard let output = outputs[id] else { return nil }
            let language = output.track.language?.maximalIdentifier.split(separator: "-").first.map(String.init)
            let name = output.track.title ?? output.track.language.flatMap { Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) }
                ?? "Audio \(id)"
            return HLSPlaylists.AudioRendition(id: id, name: name, language: output.track.language?.minimalIdentifier ?? language,
                                               channels: output.track.audio?.channels ?? 2, codecs: output.codecs, isDefault: id == defaultID)
        }
        return HLSPlaylists.master(video: video, audio: audio, videoPlaylist: "video.m3u8", audioPlaylist: { "audio-\($0).m3u8" })
    }

    private func mediaPlaylist(stream: Int) -> String {
        if stream == videoIndex {
            return HLSPlaylists.media(plan: plan, initURI: "video-init.mp4", segmentURI: { "video-\($0).m4s" })
        }
        return HLSPlaylists.media(plan: plan, initURI: "audio-\(stream)-init.mp4", segmentURI: { "audio-\(stream)-\($0).m4s" })
    }
}

extension FragmentWriter {
    /// A valid fragment with no samples, for a time range in which the track has none.
    func emptyFragment(sequence: UInt32, atSeconds seconds: Double) -> Data {
        var writer = ByteWriter()
        let decodeTime = UInt64(max(seconds, 0) * Double(timescale))
        writer.box("moof") { moof in
            moof.box("mfhd") { box in box.u32(0); box.u32(sequence) }
            moof.box("traf") { traf in
                traf.box("tfhd") { box in box.u32(0x0002_0000); box.u32(trackID) }
                traf.box("tfdt") { box in box.u32(0x0100_0000); box.u64(decodeTime) }
            }
        }
        writer.u32(8)
        writer.fourCC("mdat")
        return writer.data
    }
}
