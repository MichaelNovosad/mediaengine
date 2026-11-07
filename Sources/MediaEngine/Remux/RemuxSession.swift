internal import FFmpegLGPL
import Foundation
import os
import Synchronization

/// Turns one file into an HLS presentation of fragmented MP4: a video playlist plus one audio playlist per
/// track, produced on demand. All demuxer access is serialized on one queue.
///
/// Segments are cut at video keyframes (from the file's index) and built with ``FragmentWriter``, so any
/// segment can be requested at any time, in any order.
final class RemuxSession: @unchecked Sendable, ResourceProvider {
    private static let logger = Logger(subsystem: "dev.mediaengine", category: "index")
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
        /// Seconds of audio before a segment that the transcoder's decoder needs as warm-up.
        var prerollSeconds: Double = 0
    }

    /// Source packets of a transcoded track waiting for the player to ask for them.
    private struct PendingTranscode {
        var packets: [MediaPacket]
        var preroll: [MediaPacket]
    }

    private struct CacheKey: Hashable { var stream: Int; var segment: Int }

    let info: MediaInfo
    let plan: SegmentPlan

    private let reader: any PacketSource
    /// Set when the file is played as an ordered play list: knows which parts have which streams.
    private let timeline: TimelineReader?
    private let cancellation: CancellationFlag
    private let queue = DispatchQueue(label: "dev.mediaengine.remux", qos: .userInitiated)
    private var outputs: [Int: Output] = [:]
    private let videoIndex: Int?
    private let audioIndices: [Int]
    /// Audio from separate files: ids, and for each the reader on its file.
    private let externalAudioIDs: [Int]
    private struct ExternalAudioSource {
        var reader: PacketReader
        var stream: Int
        var delay: Double
        /// The file's own first and last time in seconds.
        var start: Double
        var end: Double
    }
    private var externalAudio: [Int: ExternalAudioSource] = [:]
    private var cache: [CacheKey: Data] = [:]
    private var cacheOrder: [CacheKey] = []
    private var cacheBytes = 0
    /// Source packets of audio that still has to be transcoded; done only if the player asks for that track.
    private var pendingTranscodes: [CacheKey: PendingTranscode] = [:]
    /// Keyframe times (seconds) of the video stream, for seeking a little before a segment.
    private var videoKeyframes: [Double] = []
    /// Text subtitle tracks served as WebVTT renditions, and their cues once read (on first request).
    private let subtitleTracks: [Track]
    /// Unique rendition names, the same ones ``PlaybackSession`` offers as track choices.
    private let audioNames: [Int: String]
    private let subtitleNames: [Int: String]
    private let subtitleCodecs: [Int: String]
    private let assHeaders: [Int: ASSHeader]
    /// Cues seen so far per subtitle track, filled by the windows that are built for audio and video anyway (a window
    /// reads every stream in its time range), and which windows have been seen.
    private var subtitleCues: [Int: Set<SubtitleCue>] = [:]
    private var subtitleWindows = Set<Int>()
    /// How far back from a segment a cue may have started and still be shown in it (seconds).
    private static let subtitleLookback = 15.0
    /// The blocks of the subtitle streams the engine draws itself, kept as the windows are read for the player, so that the
    /// overlay renderers need not read the file again (`nil` for a play list of several files: those read their parts
    /// themselves).
    let overlayFeed: OverlayFeed?
    /// Seconds added to every source time so that nothing starts negative (same for all tracks).
    private(set) var mediaShift = 0.0
    /// Reordering depth of the video, to restore decode timestamps that Matroska does not store.
    private(set) var reorder: ReorderModel?
    /// How many (track, segment) transcodes have run (diagnostics and tests).
    private(set) var transcodeCount = 0
    private let cacheBudget: Int
    private let requestEpoch = Mutex(0)
    /// Test hook: rewrites the master playlist before it is served.
    nonisolated(unsafe) var masterTransform: ((String) -> String)?

    // MARK: Opening

    /// Blocking: reads the start of the file, builds the segment plan and the initialization segments.
    init(source: any ByteSource, info: MediaInfo, cancellation: CancellationFlag, cacheBudget: Int = 48 * 1024 * 1024,
         maxSegmentBytes: Int64 = SegmentPlan.defaultMaxSegmentBytes, externalSubtitles: [SubtitleTrack] = [], externalAudio audioFiles: [AudioTrack] = [], packetSource: (any PacketSource)? = nil,
         progress: (@Sendable (Double) -> Void)? = nil) throws {
        self.info = info
        self.cancellation = cancellation
        self.cacheBudget = cacheBudget
        if let packetSource {
            reader = packetSource
            timeline = packetSource as? TimelineReader
        } else {
            reader = try PacketReader(source: source, cancellation: cancellation)
            timeline = nil
        }

        let treatments = Dictionary(uniqueKeysWithValues: info.playbackPlan.tracks.map { ($0.trackID, $0.treatment) })
        let served = ServedTracks(info: info, externalSubtitles: externalSubtitles, externalAudio: audioFiles)
        videoIndex = served.video?.id
        audioIndices = served.audio.filter { !served.externalAudioIDs.contains($0.id) }.map(\.id)
        externalAudioIDs = audioFiles.indices.map { ServedTracks.externalAudioBase + $0 }
        audioNames = served.audioTitles()
        subtitleNames = served.subtitleTitles()
        let textTracks = served.subtitles.filter { !served.externalSubtitleIDs.contains($0.id) }      // read from the file's own streams
        subtitleTracks = served.subtitles
        subtitleCodecs = Dictionary(uniqueKeysWithValues: textTracks.map { ($0.id, $0.codec.name) })
        let packetReader = reader
        assHeaders = Dictionary(uniqueKeysWithValues: textTracks.filter { ["ass", "ssa"].contains($0.codec.name) }.map { track in
            let parameters = packetReader.parameters(track.id)
            let header = parameters.pointee.extradata.map {
                String(decoding: UnsafeBufferPointer(start: $0, count: Int(parameters.pointee.extradata_size)), as: UTF8.self)
            } ?? ""
            return (track.id, ASSHeader(header))
        })
        for (index, file) in externalSubtitles.enumerated() {
            subtitleCues[ServedTracks.externalSubtitleBase + index] = Set(file.shiftedCues)
        }
        let wanted = (videoIndex.map { [$0] } ?? []) + audioIndices
        guard !wanted.isEmpty else { throw MediaError.unsupported(detail: "no playable video or audio track") }

        // First packets of every wanted stream: used to describe AC-3 streams and to measure the timestamp shift.
        var first = try Self.readStart(reader, streams: wanted, video: videoIndex)
        if let videoIndex, let gop = first[videoIndex] {
            let model = ReorderModel.measure(gop, declaredDelay: Int(reader.parameters(videoIndex).pointee.video_delay))
            var repaired = gop
            model.repair(&repaired)
            first[videoIndex] = repaired
            reorder = model
        }
        var earliest = 0.0
        for (stream, packets) in first {
            if let packet = packets.first { earliest = min(earliest, reader.timeBase(stream).seconds(packet.dts)) }
        }
        // Audio from separate files starts its own timeline; it never moves the video. What would land before the start of
        // the presentation (a negative delay) is cut, and the files' first packets are read here for their init segments.
        var externalStarts: [(id: Int, file: AudioTrack, reader: PacketReader, first: [MediaPacket])] = []
        for (index, file) in audioFiles.enumerated() {
            let audioReader = try PacketReader(source: file.source.byteSource, cancellation: cancellation)
            let start = try Self.readStart(audioReader, streams: [file.stream], video: nil)
            externalStarts.append((ServedTracks.externalAudioBase + index, file, audioReader, start[file.stream] ?? []))
        }
        let shiftSeconds = -earliest
        mediaShift = shiftSeconds

        // Segment plan from the video index. A file whose index is missing or unusable gets one worked out once and kept
        // for the next opening (KeyframeIndexStore): Matroska by hopping from cluster to cluster, anything else (or a
        // Matroska file that cannot be hopped) by reading the file through.
        var keyframes: [Double] = []
        var positions: [Int64?] = []
        var duration = info.duration
        let mainReader = packetSource == nil ? reader as? PacketReader : nil
        let layout = mainReader?.isMatroska == true ? MatroskaLayout.read(from: source) : nil
        let fileKey = mainReader != nil ? KeyframeIndexStore.key(for: source) : nil
        let video = videoIndex
        let remembered = fileKey.flatMap { KeyframeIndexStore.shared.lookup($0) }.flatMap { $0.stream == video ? $0 : nil }
        if let remembered {
            keyframes = remembered.keyframes
            positions = remembered.positions
            duration = duration ?? remembered.duration
        } else if let videoIndex {
            let videoBase = reader.timeBase(videoIndex)
            // The seek to the end loads the Cues; without Cues for the video track FFmpeg's seek would read every cluster.
            let loadUpTo = layout == nil || layout?.cuesListVideo == true ? duration : nil
            let index = reader.keyframeIndex(stream: videoIndex, loadingIndexUpTo: loadUpTo)
            keyframes = index.map { videoBase.seconds($0.timestamp) }
            positions = index.map(\.position)
        }
        // An index that is missing, or has gaps far longer than any real GOP, cannot be trusted.
        let indexComplete = remembered != nil || Self.looksComplete(keyframes: keyframes, duration: duration)
        if (videoIndex != nil && !indexComplete) || duration == nil {
            Self.logger.notice("The file's index cannot be used (\(Self.reason(keyframes: keyframes, duration: duration, layout: layout), privacy: .public)); working one out")
            var built: (keyframes: [Double], positions: [Int64?], duration: Double)?
            if let layout, let mainReader, let videoIndex, let track = Self.videoTrackNumber(layout: layout, videoIndex: videoIndex, reader: mainReader) {
                let rate = reader.stream(videoIndex).pointee.avg_frame_rate
                let frame = rate.num > 0 && rate.den > 0 ? Double(rate.den) / Double(rate.num) : 0.04
                if let found = try MatroskaClusterIndex.build(source: source, layout: layout, videoTrack: track, frameDuration: frame,
                                                              cancellation: cancellation, progress: progress) {
                    let origin = mainReader.originSeconds
                    let times = found.keyframes.map { $0 - origin }
                    let total = layout.duration != nil ? found.duration : found.duration - origin
                    if Self.looksComplete(keyframes: times, duration: duration ?? total) {
                        built = (times, found.positions.map { Optional($0) }, total)
                    }
                }
            }
            if let built, let videoIndex, let mainReader {
                if !indexComplete {
                    keyframes = built.keyframes
                    positions = built.positions
                    mainReader.addKeyframes(stream: videoIndex, seconds: keyframes, positions: positions)
                }
                if duration == nil { duration = built.duration }
                Self.logger.notice("Index worked out from \(built.keyframes.count, privacy: .public) clusters")
            } else {
                let scan = try Self.scan(reader, video: videoIndex, fallbackStream: wanted[0], length: source.length, progress: progress)
                if !indexComplete { keyframes = scan.keyframes; positions = scan.positions }
                if duration == nil { duration = scan.duration }
                Self.logger.notice("Index worked out by reading the whole file")
            }
            if let fileKey, let videoIndex, let duration, Self.looksComplete(keyframes: keyframes, duration: duration) {
                KeyframeIndexStore.shared.remember(.init(stream: videoIndex, keyframes: keyframes, positions: positions, duration: duration), for: fileKey)
            }
        }
        guard let totalDuration = duration, totalDuration > 0 else { throw MediaError.unsupported(detail: "unknown duration") }
        videoKeyframes = keyframes.sorted()
        // Segments are cut by time and by size: at high bitrates six seconds of video are too much to hold at once.
        let averageRate = info.fileSize.map { Double($0) / totalDuration }
        plan = SegmentPlan.make(keyframes: keyframes, positions: positions, duration: totalDuration,
                                maxSegmentBytes: maxSegmentBytes, averageBytesPerSecond: averageRate)
        let overlayStreams = PlaybackSession.overlayStreams(of: info)
        overlayFeed = packetSource == nil && !(overlayStreams.text.isEmpty && overlayStreams.pictures.isEmpty)
            ? OverlayFeed(textStreams: overlayStreams.text, pictureStreams: overlayStreams.pictures,
                          windows: plan.segments.map { $0.start..<max($0.start, $0.end) }) : nil

        for stream in wanted {
            guard let track = info.tracks.first(where: { $0.id == stream }) else { continue }
            var transcodes = false
            if case .transcodeAudio = treatments[stream] { transcodes = true }
            outputs[stream] = try Self.makeOutput(reader: reader, stream: stream, track: track, isVideo: stream == videoIndex,
                                                  transcodes: transcodes, first: first[stream] ?? [], shiftSeconds: shiftSeconds)
        }
        for start in externalStarts {
            var track = start.file.track
            track.id = start.id
            // The writer's shift carries the delay, so the file's own timestamps land where the viewer wants them.
            outputs[start.id] = try Self.makeOutput(reader: start.reader, stream: start.file.stream, track: track, isVideo: false,
                                                    transcodes: start.file.transcodes, first: start.first,
                                                    shiftSeconds: shiftSeconds + start.file.delay)
            let base = start.reader.timeBase(start.file.stream)
            let begin = start.first.first.map { base.seconds($0.pts) } ?? 0
            externalAudio[start.id] = ExternalAudioSource(reader: start.reader, stream: start.file.stream, delay: start.file.delay,
                                                          start: min(begin, 0), end: start.file.duration ?? 0)
        }
    }

    /// The init segment, fragment writer and (for audio AVPlayer cannot decode) transcoder of one stream.
    private static func makeOutput(reader: any PacketSource, stream: Int, track: Track, isVideo: Bool, transcodes: Bool,
                                   first: [MediaPacket], shiftSeconds: Double) throws -> Output {
        let sourceBase = reader.timeBase(stream)
        if transcodes {
            // Decoded and re-encoded to ALAC: the packets, the init segment and the fragments all use 1/sample-rate.
            let transcoder = try AudioTranscoder(parameters: reader.parameters(stream), sourceTimeBase: sourceBase)
            let timeBase = transcoder.outputTimeBase
            let shift = timeBase.ticks(seconds: shiftSeconds)
            let encodedParameters = try transcoder.makeEncodedParameters()
            defer { var pointer: UnsafeMutablePointer<AVCodecParameters>? = encodedParameters; avcodec_parameters_free(&pointer) }
            let sample = try transcoder.transcode(first, stream: stream)
            let initSegment = try InitSegmentBuilder.build(
                parameters: encodedParameters, timeBase: timeBase, sampleAspect: AVRational(num: 0, den: 1),
                samples: sample, shift: shift)
            return Output(
                streamIndex: stream, kind: .audio, track: track, initSegment: initSegment,
                writer: FragmentWriter(trackID: initSegment.trackID, timescale: initSegment.timescale, timeBase: timeBase,
                                       hasCompositionOffsets: false, shift: shift),
                codecs: "alac", transcoder: transcoder, prerollSeconds: AudioTranscoder.prerollSeconds(track.codec.name))
        }

        let shift = sourceBase.ticks(seconds: shiftSeconds)
        let st = reader.stream(stream)
        let initSegment = try InitSegmentBuilder.build(
            parameters: reader.parameters(stream), timeBase: sourceBase,
            sampleAspect: isVideo ? st.pointee.sample_aspect_ratio : AVRational(num: 0, den: 1),
            samples: Array(first.prefix(8)), shift: shift)
        return Output(
            streamIndex: stream, kind: isVideo ? .video : .audio, track: track, initSegment: initSegment,
            writer: FragmentWriter(trackID: initSegment.trackID, timescale: initSegment.timescale, timeBase: sourceBase,
                                   hasCompositionOffsets: isVideo, shift: shift),
            codecs: HLSPlaylists.codecString(for: reader.parameters(stream)))
    }

    /// Whether the session serves this stream (used by tests and the player item builder).
    func hasOutput(_ stream: Int) -> Bool { outputs[stream] != nil }
    /// Which windows have been read for subtitle cues so far (diagnostics and tests).
    var scannedSubtitleWindows: Set<Int> { queue.sync { subtitleWindows } }
    /// Bytes of finished fragments held in the cache right now (diagnostics and tests).
    var cachedBytes: Int { queue.sync { cacheBytes } }
    /// Media timescale of a served stream.
    func timescale(_ stream: Int) -> Int32 { outputs[stream]?.initSegment.timescale ?? 1 }

    func close() {
        cancellation.cancel()
        queue.sync { cache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0 }
    }

    /// Reads packets from the start of the file until every stream has a handful. Video yields its whole first run
    /// (up to the second keyframe, at most 1,000 packets), which is what the reordering depth is measured on.
    private static func readStart(_ reader: any PacketSource, streams: [Int], video: Int?) throws -> [Int: [MediaPacket]] {
        var result: [Int: [MediaPacket]] = [:]               // a freshly opened file is already at its first packet
        var inspected = 0
        var keyframes = 0
        var videoDone = false
        while inspected < 8_000, let packet = try reader.next() {
            inspected += 1
            guard streams.contains(packet.stream) else { continue }
            if packet.stream == video {
                if result[packet.stream] == nil, !packet.isKeyframe { continue }
                if packet.isKeyframe { keyframes += 1 }
                if keyframes > 1 || (result[packet.stream]?.count ?? 0) >= 1_000 { videoDone = true }
                if !videoDone { result[packet.stream, default: []].append(packet) }
            } else if (result[packet.stream]?.count ?? 0) < 8 {
                result[packet.stream, default: []].append(packet)
            }
            if streams.allSatisfy({ $0 == video ? videoDone : (result[$0]?.count ?? 0) >= 8 }) { break }
        }
        guard streams.allSatisfy({ result[$0] != nil }) else { throw MediaError.corrupt(detail: "stream without packets near the start") }
        return result
    }

    /// Whether a keyframe list covers the file: some keyframe near the start and no gap longer than a minute.
    static func looksComplete(keyframes: [Double], duration: Double?) -> Bool {
        guard let first = keyframes.first, first < 10 else { return false }
        guard let duration else { return true }
        let edges = keyframes + [duration]
        return zip(edges, edges.dropFirst()).allSatisfy { $1 - $0 <= 60 }
    }

    /// Reads the whole file once to find keyframes and the true duration, saying how far it got (by byte position).
    private static func scan(_ reader: any PacketSource, video: Int?, fallbackStream: Int, length: Int64?,
                             progress: (@Sendable (Double) -> Void)?) throws -> (keyframes: [Double], positions: [Int64?], duration: Double) {
        try reader.rewind()
        var keyframes: [Double] = []
        var positions: [Int64?] = []
        var end = 0.0
        var count = 0
        var reported = -1.0
        while let packet = try reader.next() {
            let timeBase = reader.timeBase(packet.stream)
            end = max(end, timeBase.seconds(packet.pts + packet.duration))
            if packet.stream == video, packet.isKeyframe {
                keyframes.append(timeBase.seconds(packet.pts))
                positions.append(packet.position >= 0 ? packet.position : nil)
            }
            count += 1
            if let progress, let length, length > 0, count % 256 == 0, packet.position > 0 {
                let fraction = min(Double(packet.position) / Double(length), 1)
                if fraction - reported >= 0.005 { reported = fraction; progress(fraction) }
            }
        }
        return (keyframes, positions, end)
    }

    /// The Matroska track number of the demuxer's video stream `videoIndex`: the file's video tracks in order, matched
    /// with the demuxer's video streams in order (attached pictures are attachments in Matroska, not tracks).
    private static func videoTrackNumber(layout: MatroskaLayout, videoIndex: Int, reader: PacketReader) -> UInt64? {
        var ordinal = 0
        for index in 0..<videoIndex {
            let stream = reader.stream(index).pointee
            if stream.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO, stream.disposition & Int32(AV_DISPOSITION_ATTACHED_PIC) == 0 { ordinal += 1 }
        }
        return ordinal < layout.videoTracks.count ? layout.videoTracks[ordinal] : nil
    }

    /// Why an index was not used, for the log (no names or paths).
    private static func reason(keyframes: [Double], duration: Double?, layout: MatroskaLayout?) -> String {
        if duration == nil { return "no duration" }
        if let layout, layout.cuesListVideo == nil { return "no Cues" }
        if layout?.cuesListVideo == false { return "Cues without the video track" }
        guard let first = keyframes.first else { return "no keyframes" }
        return first >= 10 ? "first keyframe after 10 s" : "a gap of more than 60 s"
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
        if path.hasPrefix("subs-") { return try subtitleResource(path) }
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

    /// `subs-ID.m3u8` and `subs-ID-N.vtt`.
    private func subtitleResource(_ path: String) throws -> Resource? {
        let body = path.dropFirst("subs-".count)
        if body.hasSuffix(".m3u8"), let id = Int(body.dropLast(".m3u8".count)), subtitleTracks.contains(where: { $0.id == id }) {
            return text(HLSPlaylists.subtitles(plan: plan, segmentURI: { "subs-\(id)-\($0).vtt" }))
        }
        guard body.hasSuffix(".vtt"), let dash = body.firstIndex(of: "-"), let id = Int(body[..<dash]),
              let number = Int(body[body.index(after: dash)...].dropLast(".vtt".count)),
              subtitleTracks.contains(where: { $0.id == id }), plan.segments.indices.contains(number) else { return nil }
        let segment = plan.segments[number]
        let cues = try queue.sync { () throws -> [SubtitleCue] in
            if cancellation.isCancelled { throw MediaError.cancelled }
            if !subtitleCodecs.isEmpty { try scanSubtitles(through: number) }      // external files need no reading
            return (subtitleCues[id] ?? []).sorted { ($0.start, $0.end, $0.text) < ($1.start, $1.end, $1.text) }
        }
        return Resource(data: Data(WebVTT.segment(cues: cues, start: segment.start, end: segment.end, shift: mediaShift).utf8),
                        contentType: "text/vtt")
    }

    /// Makes sure the windows that can hold cues shown in segment `number` have been read: the ones from
    /// `subtitleLookback` seconds before it up to the next one (a block can sit just behind its keyframe). Reading a
    /// window also builds its audio and video, which the player asks for next anyway. Call on `queue`.
    private func scanSubtitles(through number: Int) throws {
        let earliest = plan.segments[number].start - Self.subtitleLookback
        let last = min(number + 1, plan.segments.count - 1)
        for index in 0...last where plan.segments[index].end > earliest && !subtitleWindows.contains(index) {
            try buildWindow(index)
        }
    }

    /// Converts a subtitle packet seen while a window is read and keeps the cue (overlapping windows see it twice).
    private func record(subtitle packet: MediaPacket) {
        guard let codec = subtitleCodecs[packet.stream] else { return }
        let base = reader.timeBase(packet.stream)
        if let cue = SubtitleText.cue(codec: codec, data: packet.data, start: base.seconds(packet.pts),
                                      duration: base.seconds(packet.duration), header: assHeaders[packet.stream]) {
            subtitleCues[packet.stream, default: []].insert(cue)
        }
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
        if let source = externalAudio[stream] {
            let data = try queue.sync { () throws -> Data in
                if cancellation.isCancelled { throw MediaError.cancelled }
                let key = CacheKey(stream: stream, segment: number)
                if let hit = touch(key) { return hit }
                return try buildExternalAudio(stream, source: source, output: output, number: number)
            }
            return Resource(data: data, contentType: "audio/mp4")
        }
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

    /// One segment of audio from a separate file: the packets whose (delayed) time falls in the segment, converted if
    /// need be, written at their own timestamps plus the delay. Call on `queue`.
    private func buildExternalAudio(_ id: Int, source: ExternalAudioSource, output: Output, number: Int) throws -> Data {
        let segment = plan.segments[number]
        let reader = source.reader
        let base = reader.timeBase(source.stream)
        let windowStart = segment.start - source.delay          // the file's own time that lands at the segment's start
        let windowEnd = segment.end - source.delay
        let isLast = number == plan.segments.count - 1
        let from = windowStart - output.prerollSeconds
        if number == 0 || from <= 0 { try reader.rewind() } else { try reader.seek(stream: source.stream, to: base.ticks(seconds: from)) }

        var packets: [MediaPacket] = [], preroll: [MediaPacket] = []
        while let packet = try reader.next() {
            if cancellation.isCancelled { throw MediaError.cancelled }
            guard packet.stream == source.stream else { continue }
            let seconds = base.seconds(packet.pts)
            if seconds >= windowEnd, !isLast { break }
            // A negative delay moves the start of the file before the start of the video: that part is dropped.
            if number == 0, seconds + base.seconds(max(packet.duration, 0)) + source.delay + mediaShift <= 0 { continue }
            if seconds < windowStart, number > 0 {
                if output.prerollSeconds > 0, seconds >= from { preroll.append(packet) }
                continue
            }
            packets.append(packet)
        }

        let sequence = UInt32(number + 1)
        var data: Data
        if let transcoder = output.transcoder, !packets.isEmpty {
            let encoded = try transcoder.transcode(packets, preroll: preroll, stream: source.stream)
            data = output.writer.fragment(sequence: sequence, packets: encoded) ?? output.writer.emptyFragment(sequence: sequence, atSeconds: segment.start)
        } else {
            data = output.writer.fragment(sequence: sequence, packets: packets) ?? output.writer.emptyFragment(sequence: sequence, atSeconds: segment.start)
        }
        store(CacheKey(stream: id, segment: number), data)
        return data
    }

    // MARK: Windows

    /// Reads the packets of one segment for every output and stores the finished fragments. Call on `queue`.
    private func buildWindow(_ number: Int) throws {
        let segment = plan.segments[number]
        let seekStream = videoIndex ?? audioIndices[0]
        let seekBase = reader.timeBase(seekStream)
        // Audio from separate files has its own reader and is built when asked for; a window of this file is not its business.
        let mainOutputs = outputs.filter { externalAudio[$0.key] == nil }
        let maxPreroll = mainOutputs.values.map(\.prerollSeconds).max() ?? 0
        if number == 0 {
            try reader.rewind()
        } else {
            // A stateful audio decoder needs to hear a little before the segment: start from the keyframe at or
            // before (start - pre-roll). Video packets before the segment keyframe are skipped below.
            var from = segment.start
            if maxPreroll > 0 {
                from = videoKeyframes.last { $0 <= segment.start - maxPreroll } ?? (segment.start - maxPreroll)
            }
            if from <= 0 { try reader.rewind() } else { try reader.seek(stream: seekStream, to: seekBase.ticks(seconds: from)) }
        }

        var packets: [Int: [MediaPacket]] = [:]
        var prerollPackets: [Int: [MediaPacket]] = [:]
        var overlayEvents: [Int: [OverlayEvent]] = [:]
        let overlayStreams = overlayFeed?.streams ?? []
        var videoStarted = videoIndex == nil
        var videoDone = videoIndex == nil
        var audioDone = Set<Int>()
        let videoStartTicks = videoIndex.map { reader.timeBase($0).ticks(seconds: segment.start) }
        let isLast = number == plan.segments.count - 1

        while !(videoDone && audioDone.count == audioIndices.count) {
            if cancellation.isCancelled { throw MediaError.cancelled }
            guard let packet = try reader.next() else { break }
            if overlayStreams.contains(packet.stream) {
                let base = reader.timeBase(packet.stream)
                overlayEvents[packet.stream, default: []].append(
                    OverlayEvent(data: packet.data, start: base.seconds(packet.pts), duration: base.seconds(max(packet.duration, 0))))
            }
            if subtitleCodecs[packet.stream] != nil { record(subtitle: packet); continue }
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
                if seconds < segment.start && number > 0 {
                    // Warm-up audio for a stateful decoder: the packets just before the segment, in order.
                    let window = outputs[packet.stream]?.prerollSeconds ?? 0
                    if window > 0, seconds >= segment.start - window { prerollPackets[packet.stream, default: []].append(packet) }
                    continue
                }
                if seconds >= segment.end && !isLast { audioDone.insert(packet.stream); continue }
                if !audioDone.contains(packet.stream) { packets[packet.stream, default: []].append(packet) }
            }
        }

        if let videoIndex, let reorder, var video = packets[videoIndex] {
            reorder.repair(&video)
            packets[videoIndex] = video
        }

        subtitleWindows.insert(number)
        overlayFeed?.record(window: number, events: overlayEvents)
        pendingTranscodes = pendingTranscodes.filter { abs($0.key.segment - number) <= 2 }      // keep only nearby windows
        for (stream, output) in mainOutputs {
            let list = packets[stream] ?? []
            let key = CacheKey(stream: stream, segment: number)
            if output.transcoder != nil, !list.isEmpty {
                pendingTranscodes[key] = PendingTranscode(packets: list, preroll: prerollPackets[stream] ?? [])
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
        guard let pending = pendingTranscodes.removeValue(forKey: key), let output = outputs[key.stream],
              let transcoder = output.transcoder else { return nil }
        let encoded = try transcoder.transcode(pending.packets, preroll: pending.preroll, stream: key.stream)
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
            let name = audioNames[id] ?? "Audio \(id)"
            return HLSPlaylists.AudioRendition(id: id, name: name, language: output.track.language?.minimalIdentifier ?? language,
                                               channels: output.track.audio?.channels ?? 2, codecs: output.codecs, isDefault: id == defaultID)
        }
        let externalRenditions = externalAudioIDs.compactMap { id -> HLSPlaylists.AudioRendition? in
            guard let output = outputs[id] else { return nil }
            return HLSPlaylists.AudioRendition(id: id, name: audioNames[id] ?? "Audio \(id)", language: output.track.language?.minimalIdentifier,
                                               channels: max(output.track.audio?.channels ?? 2, 1), codecs: output.codecs, isDefault: false)
        }
        let subtitles = subtitleTracks.map { track -> HLSPlaylists.SubtitleRendition in
            let language = track.language?.minimalIdentifier
            let name = subtitleNames[track.id] ?? "Subtitles \(track.id)"
            return HLSPlaylists.SubtitleRendition(id: track.id, name: name, language: language, isDefault: track.isDefault,
                                                  isForced: track.isForced, isHearingImpaired: track.isHearingImpaired)
        }
        return HLSPlaylists.master(video: video, audio: audio + externalRenditions, subtitles: subtitles, videoPlaylist: "video.m3u8",
                                   audioPlaylist: { "audio-\($0).m3u8" }, subtitlePlaylist: { "subs-\($0).m3u8" })
    }

    private func mediaPlaylist(stream: Int) -> String {
        if stream == videoIndex {
            return HLSPlaylists.media(plan: plan, initURI: "video-init.mp4", segmentURI: { "video-\($0).m4s" })
        }
        var gaps = Set<Int>()
        if let timeline, stream != videoIndex, externalAudio[stream] == nil {
            // A part of the play list from a file without this audio has no media for it: say so.
            let covered = timeline.coverage(of: stream)
            for segment in plan.segments where !covered.contains(where: { $0.lowerBound < segment.end - 0.001 && $0.upperBound > segment.start + 0.001 }) {
                gaps.insert(segment.index)
            }
        }
        if let external = externalAudio[stream] {
            // Segments the file does not reach hold no media; say so instead of serving empty fragments.
            let covered = (external.delay + external.start)...(external.delay + external.end)
            for segment in plan.segments where !(segment.start < covered.upperBound && segment.end > covered.lowerBound) { gaps.insert(segment.index) }
        }
        return HLSPlaylists.media(plan: plan, initURI: "audio-\(stream)-init.mp4", gaps: gaps, segmentURI: { "audio-\(stream)-\($0).m4s" })
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
