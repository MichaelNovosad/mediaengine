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

    /// The finished fragments, shared by the build queue and the requests: a request whose fragment is built already gets
    /// it at once, even while the queue builds another piece (over a network an audio request used to wait behind a video
    /// build of several seconds, and the player gave up on it).
    private struct FragmentCache {
        var entries: [CacheKey: Data] = [:]
        var order: [CacheKey] = []                       // least recently used first
        var bytes = 0
        /// The piece the player asked for last (any track).
        var focus = 0

        mutating func fetch(_ key: CacheKey) -> Data? {
            guard let data = entries[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return data
        }

        /// Keeps a fragment, then makes room down to `budget`. Never given up: the piece just built and the piece the player
        /// asked for last (a request the player gave up on comes again, and rebuilding it over a network takes as long as the
        /// first time). Given up first: pieces behind the player or far ahead of it, then big fragments (video), then the
        /// rest, each oldest first; the small audio fragments a lagging track still needs stay longest. Over a network a piece
        /// can be larger than half the budget, so the two kept pieces may pass it for a while.
        mutating func insert(_ key: CacheKey, _ data: Data, budget: Int) {
            if let old = entries[key] { bytes -= old.count }
            entries[key] = data
            bytes += data.count
            order.removeAll { $0 == key }
            order.append(key)
            while bytes > budget {
                let candidates = order.filter { $0.segment != key.segment && $0.segment != focus }
                let far = candidates.first { $0.segment < focus - 1 || $0.segment > focus + 2 }
                let big = candidates.first { (entries[$0]?.count ?? 0) >= 2 << 20 }
                guard let victim = far ?? big ?? candidates.first, let removed = entries.removeValue(forKey: victim) else { break }
                bytes -= removed.count
                order.removeAll { $0 == victim }
            }
        }

        mutating func removeAll() {
            entries.removeAll()
            order.removeAll()
            bytes = 0
        }
    }

    /// A build stopped: a read-ahead because the player asked for another piece that is not built (`wanted`), or a build the
    /// player asked for and then hung up on, with nobody else waiting for that piece (`wanted` is `nil`).
    private struct GaveWay: Error { var wanted: Int? }

    /// A request waiting for a fragment that has to be built, and how to tell that its client hung up.
    private struct Waiter {
        var key: CacheKey
        var abandoned: @Sendable () -> Bool
    }

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
    private let fragments = Mutex(FragmentCache())
    /// Requests waiting for a fragment that has to be built, by a number of their own. A read-ahead build gives way when one of
    /// them wants another piece (the player jumped) and none wants its own; a build for a request whose client hung up stops
    /// when no other request wants that piece, so a jump never waits for a piece nobody wants any more.
    private let waiting = Mutex<(next: Int, entries: [Int: Waiter])>((0, [:]))
    /// The file is read over a network (not a local file or memory): every piece read costs seconds.
    private let remote: Bool
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
    /// For the log: the source's speed when the plan was made, the last piece built and how many were.
    private var linkRate: Double?
    private var lastBuilt: Int?
    private var builtCount = 0
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
        remote = !(source is FileByteSource || source is DataByteSource)
        let opening = ContinuousClock.now
        if let packetSource {
            reader = packetSource
            timeline = packetSource as? TimelineReader
        } else {
            reader = try PacketReader(source: source, cancellation: cancellation)
            timeline = nil
        }
        let readerOpened = ContinuousClock.now

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
        let startRead = ContinuousClock.now
        // How long the first group of pictures lasts (keyframe to keyframe): grid pieces must be longer than a GOP.
        var firstGOP = 1.0
        if let videoIndex, let run = first[videoIndex], let earliest = run.map(\.pts).min(), let latest = run.map(\.pts).max() {
            let base = reader.timeBase(videoIndex)
            firstGOP = base.seconds(latest - earliest) + base.seconds(max(run.last?.duration ?? 0, 0))
        }
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

        // Segment plan. With a complete keyframe index (the file's own, such as Matroska Cues or an MP4 sync table, or one kept
        // from an earlier opening) the pieces are cut at keyframes. Without one the movie is not read through first: the
        // pieces lie on a fixed time grid made from the duration alone, and each piece's video starts at the first keyframe at
        // or after its grid time, which `buildWindow` finds when the piece is asked for; a seek far from anything the index
        // knows finds a cluster by itself (`PacketReader.seek`, `MatroskaSeeker`). The movie starts at once either way.
        var keyframes: [Double] = []
        var positions: [Int64?] = []
        var duration = info.duration
        let mainReader = packetSource == nil ? reader as? PacketReader : nil
        let fileKey = mainReader != nil ? KeyframeIndexStore.key(for: source) : nil
        let video = videoIndex
        let remembered = fileKey.flatMap { KeyframeIndexStore.shared.lookup($0) }.flatMap { $0.stream == video ? $0 : nil }
        if let remembered {
            keyframes = remembered.keyframes
            positions = remembered.positions
            duration = duration ?? remembered.duration
            Self.logger.notice("Index: \(keyframes.count, privacy: .public) keyframes kept from an earlier opening")
        } else if let videoIndex {
            let videoBase = reader.timeBase(videoIndex)
            let index = reader.keyframeIndex(stream: videoIndex, loadingIndexUpTo: duration)
            keyframes = index.map { videoBase.seconds($0.timestamp) }
            positions = index.map(\.position)
            Self.logger.notice("Index: \(keyframes.count, privacy: .public) keyframes from the file; \(Self.describeGaps(keyframes: keyframes, duration: duration), privacy: .public)")
        }
        let indexRead = ContinuousClock.now
        var useGrid = false
        let complete = duration != nil && (remembered != nil || Self.looksComplete(keyframes: keyframes, duration: duration))
        if !complete, let videoIndex, let mainReader {
            if duration == nil {
                // No duration in the file: read from the last keyframe known to the end (the opening has usually looked at the end).
                let gaps: [(from: Double, to: Double?)] = [(keyframes.last ?? 0, nil)]
                let spans = Self.byteSpans(of: gaps, keyframes: keyframes, positions: positions, duration: nil, length: source.length)
                let filled = try Self.readGaps(mainReader, video: videoIndex, spans: spans, cancellation: cancellation, progress: progress)
                let list = Self.merged(zip(keyframes, positions).map { ($0, $1) }, filled.keyframes)
                keyframes = list.keyframes
                positions = list.positions
                duration = filled.end
            }
            if let total = duration {
                if Self.looksComplete(keyframes: keyframes, duration: total) {
                    if let fileKey { KeyframeIndexStore.shared.remember(.init(stream: videoIndex, keyframes: keyframes, positions: positions, duration: total), for: fileKey) }
                } else {
                    useGrid = true
                    Self.logger.notice("No complete index (\(Self.reason(keyframes: keyframes, duration: total), privacy: .public)): playing at once on a time grid (first GOP \(firstGOP, privacy: .public) s)")
                }
            }
        } else if !complete, duration == nil || packetSource != nil {
            // A play list of several files, or a file without video and without a duration: read it through, as before.
            let scan = try Self.scan(reader, video: videoIndex, fallbackStream: wanted[0], length: source.length, progress: progress)
            if videoIndex != nil, !Self.looksComplete(keyframes: keyframes, duration: duration) { keyframes = scan.keyframes; positions = scan.positions }
            if duration == nil { duration = scan.duration }
        }
        guard let totalDuration = duration, totalDuration > 0 else { throw MediaError.unsupported(detail: "unknown duration") }
        videoKeyframes = keyframes.sorted()
        // Segments are cut by time and by size: at high bitrates six seconds of video are too much to hold at once.
        let averageRate = info.fileSize.map { Double($0) / totalDuration }
        // Over a network each piece should load in about a second at the speed the source has shown so far: the first
        // picture and every jump wait for one whole piece. A local file keeps six-second pieces.
        let link = source.throughput
        let target = Self.pieceTarget(link: link, movie: averageRate)
        if useGrid {
            let step = Self.gridStep(firstGOP: firstGOP, target: target, bytesPerSecond: averageRate, maxSegmentBytes: maxSegmentBytes)
            plan = SegmentPlan.make(keyframes: [], duration: totalDuration, target: step)
        } else {
            plan = SegmentPlan.make(keyframes: keyframes, positions: positions, duration: totalDuration, target: target,
                                    maxSegmentBytes: maxSegmentBytes, averageBytesPerSecond: averageRate)
        }
        linkRate = link
        if let link {
            let pieces = plan.segments.prefix(10).map(\.duration)
            let typical = pieces.isEmpty ? 0 : pieces.reduce(0, +) / Double(pieces.count)
            let count = plan.segments.count
            Self.logger.notice("Pieces of about \(String(format: "%.1f", typical), privacy: .public) s (\(count, privacy: .public) in all): link about \(String(format: "%.1f", link / 1e6), privacy: .public) MB/s, movie \(String(format: "%.1f", (averageRate ?? 0) / 1e6), privacy: .public) MB/s")
        }
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
        if remote {
            func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Int {
                let span = to - from
                return Int(span.components.seconds * 1000 + span.components.attoseconds / 1_000_000_000_000_000)
            }
            let done = ContinuousClock.now
            Self.logger.notice("Ready to play in \(milliseconds(opening, done), privacy: .public) ms: file opened \(milliseconds(opening, readerOpened), privacy: .public) ms, first packets \(milliseconds(readerOpened, startRead), privacy: .public) ms, index \(milliseconds(startRead, indexRead), privacy: .public) ms, plan and the rest \(milliseconds(indexRead, done), privacy: .public) ms")
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
    var cachedBytes: Int { fragments.withLock { $0.bytes } }
    /// Media timescale of a served stream.
    func timescale(_ stream: Int) -> Int32 { outputs[stream]?.initSegment.timescale ?? 1 }

    func close() {
        cancellation.cancel()
        queue.sync { fragments.withLock { $0.removeAll() } }
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

    /// Where each stretch starts and ends in the file: the byte positions of its keyframes when the index has them, else an
    /// estimate from the average bitrate (only used for the progress bar).
    private static func byteSpans(of gaps: [(from: Double, to: Double?)], keyframes: [Double], positions: [Int64?], duration: Double?,
                                  length: Int64?) -> [(from: Double, to: Double?, startByte: Int64, endByte: Int64)] {
        let size = length ?? 0
        func position(_ time: Double) -> Int64 {
            if time <= 0 { return 0 }
            if let index = keyframes.firstIndex(where: { abs($0 - time) < 0.0005 }), let known = positions[index] { return known }
            guard let duration, duration > 0 else { return 0 }
            return Int64(Double(size) * min(time / duration, 1))
        }
        return gaps.map { gap in
            let start = position(gap.from)
            return (gap.from, gap.to, start, max(gap.to.map(position) ?? size, start))
        }
    }

    /// Reads only the given stretches of the file (video packets only) and returns the keyframes found in them; a stretch
    /// without an end (`to == nil`) is read to the end of the file, which also gives the end of the video.
    private static func readGaps(_ reader: PacketReader, video: Int, spans: [(from: Double, to: Double?, startByte: Int64, endByte: Int64)],
                                 cancellation: CancellationFlag, progress: ((Double) -> Void)?) throws -> (keyframes: [(Double, Int64?)], end: Double?) {
        let base = reader.timeBase(video)
        let total = max(spans.reduce(Int64(0)) { $0 + ($1.endByte - $1.startByte) }, 1)
        var done: Int64 = 0
        var reported = -1.0
        var found: [(Double, Int64?)] = []
        var end: Double?
        reader.limit(to: [video])
        defer { reader.limit(to: Set(0..<reader.streamCount)) }
        for span in spans {
            if span.from <= 0 { try reader.rewind() } else { try reader.seek(stream: video, to: base.ticks(seconds: span.from)) }
            while let packet = try reader.next() {
                if cancellation.isCancelled { throw MediaError.cancelled }
                guard packet.stream == video else { continue }
                let time = base.seconds(packet.pts)
                if let to = span.to {
                    if packet.isKeyframe, time >= to - 0.0005 { break }
                    if time > to + 30 { break }                       // past it without meeting its keyframe: a damaged stretch
                } else {
                    end = max(end ?? 0, base.seconds(packet.pts + packet.duration))
                }
                if packet.isKeyframe, time >= span.from { found.append((time, packet.position >= 0 ? packet.position : nil)) }
                if let progress, packet.position > 0 {
                    let within = min(max(packet.position - span.startByte, 0), span.endByte - span.startByte)
                    let fraction = min(Double(done + within) / Double(total), 1)
                    if fraction - reported >= 0.005 { reported = fraction; progress(fraction) }
                }
            }
            done += span.endByte - span.startByte
        }
        return (found, end)
    }

    /// Two keyframe lists as one, in time order, without repeats (a position is kept from either).
    private static func merged(_ a: [(Double, Int64?)], _ b: [(Double, Int64?)]) -> (keyframes: [Double], positions: [Int64?]) {
        var keyframes: [Double] = [], positions: [Int64?] = []
        for (time, position) in (a + b).sorted(by: { $0.0 < $1.0 }) {
            if let last = keyframes.last, time - last < 0.0005 {
                if positions[positions.count - 1] == nil { positions[positions.count - 1] = position }
                continue
            }
            keyframes.append(time)
            positions.append(position)
        }
        return (keyframes, positions)
    }

    /// How complete a keyframe list is, for the log: its longest gap and where it is, and how many gaps over a minute.
    private static func describeGaps(keyframes: [Double], duration: Double?) -> String {
        guard let first = keyframes.first, let last = keyframes.last else { return "no keyframes" }
        var longest = (length: 0.0, at: 0.0)
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where b - a > longest.length { longest = (b - a, a) }
        let long = zip(keyframes, keyframes.dropFirst()).filter { $1 - $0 > 60 }.count
        let tail = duration.map { String(format: "%.0f s after the last one", $0 - last) } ?? "end unknown"
        return String(format: "first at %.1f s, longest gap %.1f s at %.0f s, %ld gaps over a minute, ", first, longest.length, longest.at, long) + tail
    }

    /// How long pieces should be: what loads in about a second over the link (`link` and `movie` in bytes per second), from
    /// two to six seconds; six when the link speed is unknown (a local file) or fast.
    static func pieceTarget(link: Double?, movie: Double?) -> Double {
        guard let link, let movie, link > 0, movie > 0 else { return 6 }
        return min(max(link / movie, 2), 6)
    }

    /// How long the grid pieces are: the target (six seconds, or less over a slow link), shorter for high bitrates (a piece is held in memory whole), never shorter
    /// than two GOPs (each piece's video starts at a keyframe, so a piece shorter than a GOP could hold none), at most 20 s.
    static func gridStep(firstGOP: Double, target: Double = 6, bytesPerSecond: Double?, maxSegmentBytes: Int64) -> Double {
        var step = target
        if let rate = bytesPerSecond, rate > 0 { step = min(step, Double(maxSegmentBytes) / rate) }
        return min(max(step, 2 * firstGOP, 2), 20)
    }

    /// Why an index was not used, for the log (no names or paths).
    private static func reason(keyframes: [Double], duration: Double?) -> String {
        if duration == nil { return "no duration" }
        guard let first = keyframes.first else { return "no keyframes" }
        return first >= 10 ? "first keyframe after 10 s" : "a gap of more than 60 s"
    }

    // MARK: Serving

    /// Everything the server hands out, by path. Returns `nil` for unknown paths.
    func resource(path: String, isAbandoned: @escaping @Sendable () -> Bool) throws -> Resource? {
        requestEpoch.withLock { $0 += 1 }
        switch path {
        case "master.m3u8": return text(masterTransform.map { $0(master()) } ?? master())
        case "video.m3u8": return videoIndex.map { text(mediaPlaylist(stream: $0)) }
        case "video-init.mp4": return videoIndex.flatMap { outputs[$0] }.map { Resource(data: $0.initSegment.data, contentType: "video/mp4") }
        default: break
        }
        if path.hasPrefix("video-"), let stream = videoIndex, let number = Self.segmentNumber(path, prefix: "video-") {
            return try segment(stream: stream, number: number, isAbandoned: isAbandoned)
        }
        if path.hasPrefix("subs-") { return try subtitleResource(path, isAbandoned: isAbandoned) }
        if path.hasPrefix("audio-") {
            if path.hasSuffix(".m3u8"), let id = Int(path.dropFirst("audio-".count).dropLast(".m3u8".count)),
               outputs[id]?.kind == .audio {
                return text(mediaPlaylist(stream: id))
            }
            let parts = path.dropFirst("audio-".count).split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let id = Int(parts[0]), let output = outputs[id], output.kind == .audio else { return nil }
            let tail = String(parts[1])
            if tail == "init.mp4" { return Resource(data: output.initSegment.data, contentType: "audio/mp4") }
            if let number = Self.segmentNumber(tail, prefix: "") { return try segment(stream: id, number: number, isAbandoned: isAbandoned) }
        }
        return nil
    }

    /// `subs-ID.m3u8` and `subs-ID-N.vtt`.
    private func subtitleResource(_ path: String, isAbandoned: @Sendable () -> Bool) throws -> Resource? {
        let body = path.dropFirst("subs-".count)
        if body.hasSuffix(".m3u8"), let id = Int(body.dropLast(".m3u8".count)), subtitleTracks.contains(where: { $0.id == id }) {
            return text(HLSPlaylists.subtitles(plan: plan, segmentURI: { "subs-\(id)-\($0).vtt" }))
        }
        guard body.hasSuffix(".vtt"), let dash = body.firstIndex(of: "-"), let id = Int(body[..<dash]),
              let number = Int(body[body.index(after: dash)...].dropLast(".vtt".count)),
              subtitleTracks.contains(where: { $0.id == id }), plan.segments.indices.contains(number) else { return nil }
        let segment = plan.segments[number]
        let cues = try queue.sync { () throws -> [SubtitleCue] in
            if cancellation.isCancelled || isAbandoned() { throw MediaError.cancelled }
            if !subtitleCodecs.isEmpty { try scanSubtitles(through: number) }      // external files need no reading
            return (subtitleCues[id] ?? []).sorted { ($0.start, $0.end, $0.text) < ($1.start, $1.end, $1.text) }
        }
        return Resource(data: Data(WebVTT.segment(cues: cues, start: segment.start, end: segment.end, shift: mediaShift).utf8),
                        contentType: "text/vtt")
    }

    /// Makes sure the windows that can hold cues shown in segment `number` have been read: the ones from
    /// `subtitleLookback` seconds before it up to the next one (a block can sit just behind its keyframe). Reading a
    /// window also builds its audio and video, which the player asks for next anyway. Call on `queue`.
    ///
    /// Over a network every window is megabytes and seconds: only the segment's own window is read (a line that began in a
    /// window not read yet is missed after a jump; the next window comes with the read-ahead). Before 2026-11-08 a subtitle
    /// request after a jump read up to four windows there, unlogged, while the player's video and audio requests waited.
    private func scanSubtitles(through number: Int) throws {
        let earliest = plan.segments[number].start - (remote ? 0 : Self.subtitleLookback)
        let last = remote ? number : min(number + 1, plan.segments.count - 1)
        for index in 0...last where plan.segments[index].end > earliest && !subtitleWindows.contains(index) {
            let began = DispatchTime.now()
            try buildWindow(index)
            noteBuilt(index, since: began, asked: true, why: " for subtitles")
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

    private func segment(stream: Int, number: Int, isAbandoned: @escaping @Sendable () -> Bool) throws -> Resource? {
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
        let key = CacheKey(stream: stream, segment: number)
        // A fragment that is built already goes out at once, even while the queue builds another piece.
        var data = fragments.withLock { cache -> Data? in
            cache.focus = number
            return cache.fetch(key)
        }
        if data == nil {
            let token = waiting.withLock { state -> Int in
                state.next += 1
                state.entries[state.next] = Waiter(key: key, abandoned: isAbandoned)
                return state.next
            }
            defer { waiting.withLock { _ = $0.entries.removeValue(forKey: token) } }
            data = try queue.sync {
                if cancellation.isCancelled { throw MediaError.cancelled }
                if let hit = try fragment(for: key) { return hit }
                // The player hung up while this request waited (it gave up, or jumped elsewhere): build nothing for it.
                if isAbandoned(), liveWaiters(for: number) == 0 { throw MediaError.cancelled }
                let began = DispatchTime.now()
                do {
                    try buildWindow(number, abandoned: isAbandoned)
                } catch is GaveWay {
                    Self.logger.notice("Piece \(number, privacy: .public) stopped after \(Self.milliseconds(since: began), privacy: .public) ms: the player no longer wants it")
                    throw MediaError.cancelled
                }
                noteBuilt(number, since: began, asked: true)
                return try fragment(for: key)
            }
        }
        readAhead(after: number, stream: stream, epoch: epoch)
        return data.map { Resource(data: $0, contentType: output.kind == .video ? "video/mp4" : "audio/mp4") }
    }

    /// Builds the next window while the player consumes this one, unless a newer request arrived. The build gives way as soon
    /// as the player asks for a piece that is not built (a jump), so that the jump does not wait for a piece nobody wants.
    private func readAhead(after number: Int, stream: Int, epoch: Int) {
        guard number + 1 < plan.segments.count else { return }
        let next = CacheKey(stream: stream, segment: number + 1)
        queue.async { [self] in
            guard requestEpoch.withLock({ $0 }) == epoch, !cancellation.isCancelled,
                  fragments.withLock({ $0.entries[next] == nil }), pendingTranscodes[next] == nil else { return }
            let began = DispatchTime.now()
            do {
                try buildWindow(number + 1, ahead: true)
                noteBuilt(number + 1, since: began, asked: false)
            } catch let gaveWay as GaveWay {
                Self.logger.notice("Piece \(number + 1, privacy: .public) read ahead stopped after \(Self.milliseconds(since: began), privacy: .public) ms: the player asked for piece \(gaveWay.wanted ?? -1, privacy: .public)")
            } catch {}
        }
    }

    /// Logs how long a piece took to build: the first ones after the opening, the first after a jump, and any slow one
    /// (over a second), with the link speed. Call on `queue`.
    private static func milliseconds(since began: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000)
    }

    private func noteBuilt(_ number: Int, since began: DispatchTime, asked: Bool, why: String = "") {
        let milliseconds = Self.milliseconds(since: began)
        let jumped = lastBuilt.map { number != $0 + 1 } ?? false
        defer { lastBuilt = number; builtCount += 1 }
        guard builtCount < 3 || jumped || milliseconds > 1000 else { return }
        let segment = plan.segments[number]
        let speed = linkRate.map { String(format: ", link %.1f MB/s", $0 / 1e6) } ?? ""
        Self.logger.notice("Piece \(number, privacy: .public) (\(Int(segment.start), privacy: .public) s, \(String(format: "%.1f", segment.duration), privacy: .public) s long) built in \(milliseconds, privacy: .public) ms\(asked ? "" : " ahead", privacy: .public)\(jumped ? " after a jump" : "", privacy: .public)\(why, privacy: .public)\(speed, privacy: .public)")
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

    /// Reads the packets of one segment for every output and stores the finished fragments. A build `ahead` of the player
    /// throws ``GaveWay`` when a request waits for another piece that is not built and none for this one; a build for a request
    /// (`abandoned` given) throws it when that request's client hung up and no other request wants this piece. Call on `queue`.
    private func buildWindow(_ number: Int, ahead: Bool = false, abandoned: (@Sendable () -> Bool)? = nil) throws {
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
            // Only a keyframe close before: without a complete index (time-grid pieces) the nearest known one can be near the
            // start of the film, and seeking there would read everything up to the piece.
            var from = segment.start
            if maxPreroll > 0 {
                let wanted = segment.start - maxPreroll
                from = videoKeyframes.last { $0 <= wanted && wanted - $0 <= 30 } ?? wanted
            }
            // Transport and program streams are sought by decode time: start a few frames early (the reordering depth), or the
            // seek lands just after the piece's own keyframe and the piece starts at the next one, a GOP late (2026-11-08: Blu-ray
            // extras lost 0.6 s per piece and their open GOPs became undecodable). Frames before the keyframe are skipped below.
            if (reader as? PacketReader)?.seeksByDecodeTime == true, let reorder, let video = videoIndex {
                from -= reader.timeBase(video).seconds(Int64(reorder.delay + 2) * max(reorder.frameTicks, 1))
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
        var read = 0

        while !(videoDone && audioDone.count == audioIndices.count) {
            if cancellation.isCancelled { throw MediaError.cancelled }
            // Every 16 packets (a fraction of a second over a network): whether the player still wants this piece.
            if read % 16 == 0 {
                if ahead, let wanted = pieceWantedInstead(of: number) { throw GaveWay(wanted: wanted) }
                if let abandoned, abandoned(), liveWaiters(for: number) == 0 { throw GaveWay(wanted: nil) }
            }
            read += 1
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
                    // The first keyframe is already the next piece's start (a GOP longer than this piece, possible on a time
                    // grid): this piece has no video of its own, rather than a copy of the next one's.
                    if !isLast, number > 0, seconds >= segment.end - 0.0005 { videoDone = true; continue }
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
        fragments.withLock { $0.fetch(key) }
    }

    private func store(_ key: CacheKey, _ data: Data) {
        let budget = cacheBudget
        fragments.withLock { $0.insert(key, data, budget: budget) }
    }

    /// The requests still waiting for piece `number` whose clients have not hung up.
    private func liveWaiters(for number: Int) -> Int {
        let waiters = waiting.withLock { Array($0.entries.values) }
        return waiters.filter { $0.key.segment == number && !$0.abandoned() }.count
    }

    /// The piece a waiting request wants when nobody waits for `number` and that piece is neither built nor waiting to be
    /// transcoded (the player jumped): a read-ahead build of `number` stops for it. Call on `queue`.
    private func pieceWantedInstead(of number: Int) -> Int? {
        let waiters = waiting.withLock { Array($0.entries.values) }.filter { !$0.abandoned() }
        guard !waiters.isEmpty, !waiters.contains(where: { $0.key.segment == number }) else { return nil }
        for waiter in waiters where pendingTranscodes[waiter.key] == nil {
            if fragments.withLock({ $0.entries[waiter.key] == nil }) { return waiter.key.segment }
        }
        return nil
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
