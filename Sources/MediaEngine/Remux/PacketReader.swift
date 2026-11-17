internal import FFmpegLGPL
import Foundation
import os

/// A time base: one tick lasts `num / den` seconds.
struct Rational: Sendable, Equatable {
    var num: Int64
    var den: Int64

    init(num: Int64, den: Int64) { self.num = num; self.den = den }
    init(_ value: AVRational) { self.init(num: Int64(value.num), den: Int64(value.den)) }

    var ffmpeg: AVRational { AVRational(num: Int32(num), den: Int32(den)) }
    func seconds(_ ticks: Int64) -> Double { Double(ticks) * Double(num) / Double(den) }
    func ticks(seconds: Double) -> Int64 { Int64((seconds * Double(den) / Double(num)).rounded()) }

    /// Converts `ticks` expressed in `self` into `other`, rounding to nearest.
    func convert(_ ticks: Int64, to other: Rational) -> Int64 {
        av_rescale_q_rnd(ticks, ffmpeg, other.ffmpeg, AV_ROUND_NEAR_INF)
    }
}

/// One compressed frame of one stream, copied out of FFmpeg's memory.
struct MediaPacket: Sendable, Equatable {
    var stream: Int
    var data: Data
    /// Presentation and decode timestamps in the stream's time base. `pts` equals `dts` when the file has no pts.
    var pts: Int64
    var dts: Int64
    /// Duration in the stream's time base, `0` when unknown.
    var duration: Int64
    var isKeyframe: Bool
    /// Samples the decoder must drop from the start / end of this packet (Opus codec delay, end padding).
    var skipStart: Int = 0
    var skipEnd: Int = 0
    /// Byte position of the packet in the file, `-1` when the demuxer does not know it.
    var position: Int64 = -1
}

/// What the remuxer needs from a source of packets: one opened file (``PacketReader``) or a play list that stitches
/// parts of several files into one timeline (``TimelineReader``).
protocol PacketSource: AnyObject {
    /// Whether the opened file has this stream. A file opened again can have fewer streams than the probe described: an MPEG program
    /// stream (a DVD's VOB) shows a stream only once it is read, and the quick reopening does not read the end of the file, where the
    /// probe may have found it (the app's owner, 2026-11-12: two crashes on an iPhone). Ask before `parameters`, `stream` or `timeBase`
    /// with a stream number that came from the probe.
    func hasStream(_ index: Int) -> Bool
    func timeBase(_ index: Int) -> Rational
    func parameters(_ index: Int) -> UnsafeMutablePointer<AVCodecParameters>
    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>
    func next() throws -> MediaPacket?
    func seek(stream index: Int, to timestamp: Int64) throws
    func rewind() throws
    func keyframeIndex(stream index: Int, loadingIndexUpTo duration: Double?) -> [(timestamp: Int64, position: Int64?)]
    /// Delivers packets of these streams only (the demuxer skips the others without copying them).
    func limit(to streams: Set<Int>)
}

/// Reads compressed packets from an opened file. Not thread-safe: confine it to one serial queue.
final class PacketReader: PacketSource {
    private(set) var context: FormatContext
    private let source: any ByteSource
    private let cancellation: CancellationFlag
    private let packet: UnsafeMutablePointer<AVPacket>

    /// Raw AAC (ADTS) files carry no timestamps and, with no AAC decoder compiled in, FFmpeg cannot tell how long a
    /// frame is. For those streams the reader numbers the frames itself (1024 samples per raw data block, from the ADTS
    /// header), strips the headers, gives the codec parameters their AudioSpecificConfig, and keeps a byte index for
    /// seeking.
    private var clock: [Int: Int64] = [:]
    private var untimedStreams: Set<Int> = []
    private var untimedIndex: [Int: [(ticks: Int64, position: Int64)]] = [:]
    private var onlyStreams: Set<Int>?

    /// H.264 and HEVC in Annex B form (MPEG-TS, AVI): converted to length-prefixed NAL units, with the parameter sets found
    /// at the start of the stream put into the codec parameters (see ``AnnexB``).
    private var annexB: [Int: AnnexB.Codec] = [:]
    private var parameterSets: [Int: [Int: [Data]]] = [:]
    /// The parameter sets of each Annex B stream's decoder configuration (what its init segment holds), by NAL type, taken
    /// once from the codec parameters; and the streams that keep their parameter sets in the samples because they change
    /// (see ``AnnexB/convert(_:codec:configuration:keepsSets:)``).
    private var configurationSets: [Int: [Int: [Data]]] = [:]
    private var inBandSets: Set<Int> = []
    private static let logger = Logger(subsystem: "dev.mediaengine", category: "index")
    /// AAC with ADTS headers and container timestamps (MPEG-TS): the header is cut off and its content goes into the
    /// codec parameters. Raw `.aac` files have no timestamps at all and are handled below with `untimedStreams`.
    private var adtsStreams: Set<Int> = []
    private var adtsConfigurations: [Int: ADTSFrame] = [:]

    /// `quick` (the default) opens a file whose duration the engine knows already (see ``FormatContext/open(source:cancellation:quick:)``);
    /// a reader that needs FFmpeg's own duration passes `false`.
    /// `durationHint`: the length the session knows (the quick opening does not measure it), for jumps by byte position.
    init(source: any ByteSource, cancellation: CancellationFlag, quick: Bool = true, durationHint: Double? = nil) throws {
        self.source = source
        self.cancellation = cancellation
        self.quick = quick
        self.durationHint = durationHint
        dvd = (source as? DVDTitleByteSource)?.layout
        context = try FormatContext.open(source: source, cancellation: cancellation, quick: quick)
        guard let packet = av_packet_alloc() else { throw MediaError.engine(detail: "could not allocate packet") }
        self.packet = packet
        try prepareStreams()
        adoptRememberedIndex()
        let name = String(cString: format.pointee.iformat.pointee.name)
        indexesKeyframes = (name == "mpegts" || name == "mpeg") && dvd == nil
    }

    private let quick: Bool
    private let durationHint: Double?
    /// A DVD title (``DVDTitleByteSource``): its packets are put on the title's timeline cell by cell, and it seeks through the
    /// disc's time map; FFmpeg's own timestamps restart and jump between cells and its seeks by time land anywhere.
    private let dvd: DVDTitleLayout?
    /// The cell the last packet came from.
    private var dvdCell = 0
    /// DVD subtitles still being put together, per stream: the start of one subtitle and the size its first two bytes give.
    private var subpictures: [Int: (data: Data, expected: Int, pts: Int64, position: Int64)] = [:]
    private static let ninetyKilohertz = Rational(num: 1, den: 90_000)
    /// MPEG transport and program streams have no index, and FFmpeg's seek in them searches the file by jumping about in it
    /// unless its index already brackets the target: the reader adds every video keyframe it reads, so the next piece's
    /// seek lands almost at once.
    private var indexesKeyframes = false
    /// FFmpeg seeks this file by decode time (MPEG transport and program streams): a keyframe shown at time t is decoded a few
    /// frames before t, so a seek to t lands just after it.
    var seeksByDecodeTime: Bool { indexesKeyframes || dvd != nil }

    /// Whether the file is Matroska or WebM (FFmpeg's demuxer name).
    var isMatroska: Bool { String(cString: format.pointee.iformat.pointee.name).contains("matroska") }

    /// Where the file's timeline starts, in seconds (see `originTicks`): the engine's timeline is the file's minus this.
    var originSeconds: Double {
        if dvd != nil { return 0 }                                      // a DVD title's timeline is made by the reader
        let start = format.pointee.start_time
        guard start != Int64.min, start > 1_000 else { return 0 }
        return Double(start) / 1_000_000
    }

    /// Adds keyframes the engine found itself (a Matroska file without usable Cues) to the demuxer's index, so that its
    /// seeks jump to a cluster instead of reading every cluster up to the target. Times are on the engine's timeline.
    func addKeyframes(stream index: Int, seconds: [Double], positions: [Int64?]) {
        guard index < streamCount else { return }
        let st = stream(index), base = timeBase(index), origin = originTicks(index)
        for (time, position) in zip(seconds, positions) {
            guard let position, position >= 0 else { continue }
            av_add_index_entry(st, position, base.ticks(seconds: time) + origin, 0, 0, Int32(AVINDEX_KEYFRAME))
        }
    }

    /// Finds clusters for seeks the demuxer's index does not cover (Matroska only); made on the first such seek.
    private var seeker: MatroskaSeeker?
    private var seekerTried = false
    /// Matroska loads its Cues on the first seek: a seek to the start does that cheaply, before the index is asked anything.
    private var cuesLoaded = false

    /// The time (engine timeline) of the demuxer's index entry at or before `seconds` for a stream, if any.
    func indexEntry(stream index: Int, atOrBefore seconds: Double) -> Double? {
        guard index < streamCount else { return nil }
        let st = stream(index), base = timeBase(index)
        let position = av_index_search_timestamp(st, base.ticks(seconds: seconds) + originTicks(index), AVSEEK_FLAG_BACKWARD)
        guard position >= 0, let entry = avformat_index_get_entry(st, position) else { return nil }
        return base.seconds(entry.pointee.timestamp - originTicks(index))
    }

    /// Before a Matroska seek to a time the index knows nothing near (no Cues there, nothing read there yet): FFmpeg would
    /// read every cluster from the last one it knows up to the target. A cluster close before the target is found instead
    /// (``MatroskaSeeker``) and put into the index as a seek point.
    private func helpSeek(stream index: Int, to timestamp: Int64) throws {
        guard isMatroska else { return }
        let base = timeBase(index)
        let target = base.seconds(timestamp)
        guard target > 20 else { return }
        if !cuesLoaded {
            cuesLoaded = true
            _ = av_seek_frame(format, Int32(index), originTicks(index), AVSEEK_FLAG_BACKWARD)
        }
        if let near = indexEntry(stream: index, atOrBefore: target), target - near <= 20 { return }
        if !seekerTried {
            seekerTried = true
            let duration = format.pointee.duration > 0 ? Double(format.pointee.duration) / 1_000_000 : nil
            seeker = MatroskaSeeker(source: source, scale: Double(base.num) / Double(base.den), duration: duration, cancellation: cancellation)
        }
        guard let seeker, let spot = try seeker.cluster(atOrBefore: target + originSeconds) else { return }
        av_add_index_entry(stream(index), spot.position, base.ticks(seconds: spot.time), 0, 0, Int32(AVINDEX_KEYFRAME))
    }

    /// A Matroska file whose keyframes the engine worked out at an earlier opening (``KeyframeIndexStore``): every reader of
    /// it (the remuxer, the subtitle overlay, the software player) seeks with that list.
    private func adoptRememberedIndex() {
        guard isMatroska, let key = KeyframeIndexStore.key(for: source), let entry = KeyframeIndexStore.shared.lookup(key) else { return }
        addKeyframes(stream: entry.stream, seconds: entry.keyframes, positions: entry.positions)
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }

    var format: UnsafeMutablePointer<AVFormatContext> { context.format }
    var streamCount: Int { Int(format.pointee.nb_streams) }
    func hasStream(_ index: Int) -> Bool { index >= 0 && index < streamCount && format.pointee.streams[index] != nil }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream> { format.pointee.streams[index]! }
    /// Where the file's timeline starts, when it does not start at zero (MPEG-TS recordings begin at 1.4 s or later; Matroska
    /// files cut from a longer one at wherever the cut was). Every timestamp the reader hands out has this taken off, so the
    /// engine sees a timeline from zero; seeks and the keyframe list add and take it off the same way.
    private func originTicks(_ index: Int) -> Int64 {
        if dvd != nil { return 0 }
        let start = format.pointee.start_time
        guard start != Int64.min, start > 1_000 else { return 0 }          // under a millisecond, or unknown (and negative leads are handled by the shift)
        return timeBase(index).ticks(seconds: Double(start) / 1_000_000)
    }

    private func codecParameters(_ index: Int) -> UnsafeMutablePointer<AVCodecParameters> { stream(index).pointee.codecpar }

    /// The codec parameters of a stream. For AAC from MPEG-TS the demuxer's parser overwrites the sample rate and channels
    /// with "unknown" as it reads packets, so what the ADTS header said is put back whenever it is asked for.
    func parameters(_ index: Int) -> UnsafeMutablePointer<AVCodecParameters> {
        let parameters = codecParameters(index)
        if let frame = adtsConfigurations[index], parameters.pointee.sample_rate == 0 || parameters.pointee.ch_layout.nb_channels == 0 {
            prepareADTS(stream: index, frame: frame)
        }
        return parameters
    }
    func timeBase(_ index: Int) -> Rational { Rational(stream(index).pointee.time_base) }

    /// Timestamps of the keyframes listed in the file's index (Matroska Cues, MP4 sync table), in the stream's time base.
    ///
    /// A freshly opened Matroska file has only loaded the index entries of the packets it probed; the Cues at the
    /// end of the file load lazily, on the first seek. Seeking once to the end makes the demuxer read them. The
    /// read position is undefined afterwards: seek or rewind before reading packets.
    func keyframeTimestamps(stream index: Int, loadingIndexUpTo duration: Double? = nil) -> [Int64] {
        keyframeIndex(stream: index, loadingIndexUpTo: duration).map(\.timestamp)
    }

    /// Keyframes of a stream from the container's index (time in the stream's time base, byte position when known),
    /// in time order. The index is loaded by a seek to the end first, since Matroska reads its Cues lazily.
    func keyframeIndex(stream index: Int, loadingIndexUpTo duration: Double? = nil) -> [(timestamp: Int64, position: Int64?)] {
        if let dvd {
            // The disc's time map: a video object unit starts (with a keyframe) at each of these points.
            let base = timeBase(index)
            return dvd.titleSeekPoints(read: DVDTitleLayout.reader(source)).map { (base.ticks(seconds: $0.time), $0.logical) }
        }
        if let duration { _ = try? seek(stream: index, to: timeBase(index).ticks(seconds: duration)) }
        let st = stream(index)
        let count = avformat_index_get_entries_count(st)
        var result: [(timestamp: Int64, position: Int64?)] = []
        result.reserveCapacity(Int(count))
        let origin = originTicks(index)
        for entry in 0..<count {
            guard let item = avformat_index_get_entry(st, entry) else { continue }
            if item.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0 {
                result.append((item.pointee.timestamp - origin, item.pointee.pos >= 0 ? item.pointee.pos : nil))
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    func limit(to streams: Set<Int>) {
        onlyStreams = streams
        applyStreamLimit()
    }

    private func applyStreamLimit() {
        guard let onlyStreams else { return }
        for index in 0..<streamCount { stream(index).pointee.discard = onlyStreams.contains(index) ? AVDISCARD_DEFAULT : AVDISCARD_ALL }
    }

    /// Starts again from the very first packet. Seeking to time zero would skip packets with negative
    /// timestamps (the encoder-delay "priming" frames of AAC and others), so the file is simply reopened.
    func rewind() throws {
        context = try FormatContext.open(source: source, cancellation: cancellation, quick: quick)
        clock = [:]
        dvdCell = 0
        subpictures = [:]
        cuesLoaded = false
        applyStreamLimit()
        applyPreparedParameters()
        adoptRememberedIndex()
        // The new context knows nothing of the extradata made for raw ADTS files; it is made again on the first frame.
    }

    /// Positions the reader at the last keyframe at or before `timestamp` of the given stream.
    func seek(stream index: Int, to timestamp: Int64) throws {
        if let dvd {
            // The last point of the disc's time map at or before the time: a video object unit that starts with a keyframe.
            let point = dvd.seekPoint(atOrBefore: timeBase(index).seconds(timestamp), read: DVDTitleLayout.reader(source))
            let result = av_seek_frame(format, -1, point.logical, AVSEEK_FLAG_BYTE)
            if result < 0 { throw FormatContext.openError(result, context.bridge) }
            if let cell = dvd.cellIndex(containingLogical: point.logical) { dvdCell = cell }
            subpictures = [:]
            return
        }
        if untimedStreams.contains(index) { return try seekUntimed(stream: index, to: timestamp) }
        if indexesKeyframes {
            // No keyframe the reader knows within 20 s before the time: a jump by byte position, from the file's average byte rate.
            let seconds = timeBase(index).seconds(timestamp)
            let video = Int(av_find_default_stream_index(format))
            let near = video >= 0 ? indexEntry(stream: video, atOrBefore: seconds) : nil
            if near.map({ seconds - $0 > 20 }) ?? true, try interpolatedSeek(to: seconds) { return }
        }
        if indexesKeyframes, stream(index).pointee.codecpar.pointee.codec_type != AVMEDIA_TYPE_VIDEO {
            // MPEG transport and program streams: FFmpeg's search for a time looks for packets of the stream it is asked about,
            // and a subtitle stream's packets can be minutes apart, so each step of the search read on and on (a subtitle switch
            // on a 27 GB Blu-ray stream over a network read for minutes and showed nothing: the app's owner, 2026-11-17). The
            // file's own default stream (its video) is searched instead; the reader lands at or before the time and reads on.
            let micro = timeBase(index).convert(timestamp + originTicks(index), to: Rational(num: 1, den: Int64(AV_TIME_BASE)))
            let result = av_seek_frame(format, -1, micro, AVSEEK_FLAG_BACKWARD)
            if result < 0 { throw FormatContext.openError(result, context.bridge) }
            return
        }
        try helpSeek(stream: index, to: timestamp)
        let result = av_seek_frame(format, Int32(index), timestamp + originTicks(index), AVSEEK_FLAG_BACKWARD)
        if result < 0 { throw FormatContext.openError(result, context.bridge) }
    }

    /// The next packet of any stream, or `nil` at the end of the file.
    func next() throws -> MediaPacket? {
        while true {
            let result = av_read_frame(format, packet)
            if result == AVError.eof {
                // Demuxers turn a failed read into a premature end of file; a failing source must not look like a short file.
                if context.bridge.failure.withLock({ $0 != nil }) { throw FormatContext.openError(result, context.bridge) }
                return nil
            }
            if result < 0 { throw FormatContext.openError(result, context.bridge) }
            defer { av_packet_unref(packet) }
            if indexesKeyframes, packet.pointee.flags & AV_PKT_FLAG_KEY != 0, packet.pointee.pos >= 0,
               let st = format.pointee.streams[Int(packet.pointee.stream_index)], st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                let stamp = packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
                if stamp != Int64.min { av_add_index_entry(st, packet.pointee.pos, stamp, 0, 0, Int32(AVINDEX_KEYFRAME)) }
            }

            if dvd != nil, let st = format.pointee.streams[Int(packet.pointee.stream_index)],
               st.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_DVD_SUBTITLE {
                switch subpicture(stream: Int(packet.pointee.stream_index)) {
                case .pending: continue
                case .complete(let whole): return whole
                case .single: break
                }
            }

            var pts = packet.pointee.pts
            var dts = packet.pointee.dts
            var duration = max(packet.pointee.duration, 0)
            if pts == Int64.min { pts = dts }
            if dts == Int64.min { dts = pts }
            if pts != Int64.min {
                let origin = originTicks(Int(packet.pointee.stream_index))
                pts -= origin
                if dts != Int64.min { dts -= origin }
            }
            var payloadOffset = 0
            let streamIndex = Int(packet.pointee.stream_index)
            if let dvd, pts != Int64.min {
                if packet.pointee.pos >= 0, let cell = dvd.cellIndex(containingLogical: packet.pointee.pos) { dvdCell = cell }
                pts = titleTicks(pts, layout: dvd, stream: streamIndex)
                if dts != Int64.min { dts = titleTicks(dts, layout: dvd, stream: streamIndex) }
            }
            // Raw AAC: number the frames ourselves. (After a seek FFmpeg invents timestamps for the file, so a stream known
            // to be untimed keeps using ours.)
            if adtsStreams.contains(streamIndex), pts != Int64.min, !untimedStreams.contains(streamIndex), let frame = adtsFrame() {
                payloadOffset = frame.headerLength                  // the container gave the timestamps: only the header goes
            } else if pts == Int64.min || untimedStreams.contains(streamIndex), let frame = adtsFrame() {
                let index = streamIndex
                let base = stream(index).pointee.time_base
                let rate = Int64(frame.sampleRate)
                guard rate > 0, base.num > 0 else { continue }
                duration = Int64(frame.samples) * Int64(base.den) / (rate * Int64(base.num))
                pts = clock[index] ?? 0
                dts = pts
                clock[index] = pts + duration
                untimedStreams.insert(index)
                prepareADTS(stream: index, frame: frame)
                payloadOffset = frame.headerLength
                if packet.pointee.pos >= 0 {
                    let last = untimedIndex[index]?.last?.ticks ?? Int64.min
                    if last == Int64.min || pts - last >= Int64(base.den) / Int64(base.num) {       // about every second
                        untimedIndex[index, default: []].append((pts, packet.pointee.pos))
                    }
                }
            }
            if pts == Int64.min { continue }                       // no usable timestamp: skip

            let size = Int(packet.pointee.size) - payloadOffset
            var data = size > 0 ? Data(bytes: packet.pointee.data + payloadOffset, count: size) : Data()
            if let codec = annexB[streamIndex] {
                var keeps = inBandSets.contains(streamIndex)
                data = AnnexB.convert(data, codec: codec, configuration: configuration(streamIndex, codec), keepsSets: &keeps)
                if keeps, inBandSets.insert(streamIndex).inserted {
                    Self.logger.notice("Video stream \(streamIndex, privacy: .public) changes its parameter sets after the start: they stay in the samples")
                }
            }
            var skipStart = 0, skipEnd = 0
            var sideSize = 0
            if let side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &sideSize), sideSize >= 8 {
                let raw = UnsafeRawPointer(side)
                skipStart = Int(UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self)))
                skipEnd = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            }
            return MediaPacket(
                stream: Int(packet.pointee.stream_index), data: data, pts: pts, dts: dts,
                duration: duration,
                isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0, skipStart: skipStart, skipEnd: skipEnd,
                position: packet.pointee.pos)
        }
    }

    // MARK: Streams that need preparing (Annex B video, ADTS audio in MPEG-TS)

    /// Looks at the start of the file for what MP4 needs and these streams do not carry: the parameter sets of Annex B
    /// video and the ADTS configuration of AAC, then reopens the file. Without it the init segment would have no decoder
    /// configuration.
    private func prepareStreams() throws {
        var needsSets = Set<Int>(), needsADTS = Set<Int>()
        for index in 0..<streamCount {
            let parameters = codecParameters(index)
            if let codec = AnnexB.codec(for: parameters) {
                annexB[index] = codec
                if parameters.pointee.extradata_size == 0 { needsSets.insert(index) }
            } else if parameters.pointee.codec_id == AV_CODEC_ID_AAC, parameters.pointee.extradata_size == 0 {
                needsADTS.insert(index)
            }
        }
        guard !needsSets.isEmpty || !needsADTS.isEmpty else { return }
        var scanned = 0
        while scanned < 600, !(needsSets.isEmpty && needsADTS.isEmpty) {
            if av_read_frame(format, packet) < 0 { break }
            defer { av_packet_unref(packet) }
            scanned += 1
            let index = Int(packet.pointee.stream_index)
            if needsSets.contains(index), let codec = annexB[index], let data = packet.pointee.data {
                let buffer = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
                for range in AnnexB.units(in: buffer) {
                    let type = AnnexB.nalType(buffer[range.lowerBound], codec)
                    guard AnnexB.isParameterSet(type, codec) else { continue }
                    let unit = Data(buffer[range])
                    if !(parameterSets[index]?[type] ?? []).contains(unit) { parameterSets[index, default: [:]][type, default: []].append(unit) }
                }
                if AnnexB.extradata(from: parameterSets[index] ?? [:], codec: codec) != nil { needsSets.remove(index) }
            }
            if needsADTS.contains(index), let frame = adtsFrame() {
                adtsStreams.insert(index)
                adtsConfigurations[index] = frame
                needsADTS.remove(index)
            }
        }
        try rewind()                                                   // back to the first packet, with the parameters applied
    }

    /// The parameter sets in the decoder configuration of an Annex B stream, by NAL type: read once from its codec parameters
    /// (FFmpeg's own extradata or the sets ``prepareStreams()`` found), which is what the init segment is made from.
    private func configuration(_ index: Int, _ codec: AnnexB.Codec) -> [Int: [Data]] {
        if let known = configurationSets[index] { return known }
        let parameters = codecParameters(index)
        var sets: [Int: [Data]] = [:]
        if parameters.pointee.extradata_size > 0, let extradata = parameters.pointee.extradata {
            let buffer = UnsafeBufferPointer(start: extradata, count: Int(parameters.pointee.extradata_size))
            for range in AnnexB.units(in: buffer) {
                let type = AnnexB.nalType(buffer[range.lowerBound], codec)
                if AnnexB.isParameterSet(type, codec) { sets[type, default: []].append(Data(buffer[range])) }
            }
        }
        configurationSets[index] = sets
        return sets
    }

    /// Puts what was found at the start into the codec parameters of the (re)opened file.
    private func applyPreparedParameters() {
        for (index, codec) in annexB {
            let parameters = codecParameters(index)
            guard parameters.pointee.extradata_size == 0, let sets = parameterSets[index],
                  let configuration = AnnexB.extradata(from: sets, codec: codec),
                  let buffer = av_mallocz(configuration.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else { continue }
            configuration.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: configuration.count)
            parameters.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
            parameters.pointee.extradata_size = Int32(configuration.count)
        }
        for (index, frame) in adtsConfigurations { prepareADTS(stream: index, frame: frame) }
    }

    // MARK: Raw AAC (ADTS)

    private struct ADTSFrame {
        var headerLength: Int
        var samples: Int
        var objectType: Int
        var frequencyIndex: Int
        var channelConfiguration: Int
        var sampleRate: Int { Self.rates.indices.contains(frequencyIndex) ? Self.rates[frequencyIndex] : 0 }
        static let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
    }

    /// The header of the current packet if it is an ADTS frame.
    private func adtsFrame() -> ADTSFrame? {
        guard packet.pointee.size >= 9, let bytes = packet.pointee.data, bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0 else { return nil }
        let protectionAbsent = bytes[1] & 0x01 == 1
        return ADTSFrame(headerLength: protectionAbsent ? 7 : 9, samples: 1024 * (Int(bytes[6] & 0x03) + 1),
                         objectType: Int((bytes[2] >> 6) & 0x03) + 1, frequencyIndex: Int((bytes[2] >> 2) & 0x0F),
                         channelConfiguration: Int(((bytes[2] & 0x01) << 2) | (bytes[3] >> 6)))
    }

    /// Fills in what the ADTS header says and the demuxer could not work out without a decoder: the AudioSpecificConfig
    /// (which the MP4 muxer needs for raw frames), the sample rate, the channels and the frame size.
    private func prepareADTS(stream index: Int, frame: ADTSFrame) {
        let parameters = codecParameters(index)
        if parameters.pointee.sample_rate == 0 { parameters.pointee.sample_rate = Int32(frame.sampleRate) }
        if parameters.pointee.ch_layout.nb_channels == 0 {
            let channels: Int32 = [0, 1, 2, 3, 4, 5, 6, 8][min(max(frame.channelConfiguration, 0), 7)]
            if channels > 0 { av_channel_layout_default(&parameters.pointee.ch_layout, channels) }
        }
        if parameters.pointee.frame_size == 0 { parameters.pointee.frame_size = 1024 }
        guard parameters.pointee.extradata_size == 0 else { return }
        let size = 2
        guard let buffer = av_mallocz(size + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else { return }
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        bytes[0] = UInt8(frame.objectType << 3 | frame.frequencyIndex >> 1)
        bytes[1] = UInt8((frame.frequencyIndex & 1) << 7 | frame.channelConfiguration << 3)
        parameters.pointee.extradata = bytes
        parameters.pointee.extradata_size = Int32(size)
    }

    /// A jump in an MPEG transport or program stream by byte position: the file's average byte rate gives a guess a few seconds
    /// early; the first timed packet there says where it landed, and a guess that landed after the time steps back. FFmpeg's own
    /// search for a time in such a file without an index read packet after packet: a jump in a 27 GB Blu-ray stream over a network
    /// took 2 to 5 s, and a subtitle switch (a reader of its own, without the keyframes the remuxer had met) minutes (the app's
    /// owner, 2026-11-17: Labyrinth). `false` when the file gives no length or duration to interpolate with.
    private func interpolatedSeek(to seconds: Double) throws -> Bool {
        // The length FFmpeg measured, else the one the session knows (a quick reopening skips FFmpeg's estimate: the first jumps in
        // a Blu-ray stream, a subtitle reader's, then fell back to FFmpeg's slow search).
        let measured = format.pointee.duration > 0 ? Double(format.pointee.duration) / Double(AV_TIME_BASE) : nil
        guard let length = source.length, length > 0, let total = measured ?? durationHint, total > 0 else { return false }
        let rate = Double(length) / total
        guard rate.isFinite, rate > 0 else { return false }
        let early = 6.0
        var guess = Int64(max(0, (seconds - early) * rate))
        for _ in 0..<5 {
            guess = max(0, min(guess, length - 1))
            if cancellation.isCancelled { throw MediaError.cancelled }
            guard av_seek_frame(format, -1, guess, AVSEEK_FLAG_BYTE) >= 0, let landed = firstPacketTime() else { return false }
            if landed <= seconds || guess == 0 {
                return av_seek_frame(format, -1, guess, AVSEEK_FLAG_BYTE) >= 0
            }
            guess -= Int64((landed - seconds + early) * rate)
        }
        return false
    }

    /// The time (engine timeline) of the first packet with a timestamp from the read position, reading at most 2,000 packets.
    private func firstPacketTime() -> Double? {
        for _ in 0..<2_000 {
            guard av_read_frame(format, packet) >= 0 else { return nil }
            defer { av_packet_unref(packet) }
            let stamp = packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
            guard stamp != Int64.min else { continue }
            let index = Int(packet.pointee.stream_index)
            return timeBase(index).seconds(stamp - originTicks(index))
        }
        return nil
    }

    private enum Subpicture { case pending, complete(MediaPacket), single }

    /// A DVD subtitle that spans several packets, put together. FFmpeg's demuxer joins them with its parser only in streams it made
    /// itself; a DVD title's subtitle streams are made by `FormatContext` (so that they are known from the start), and their later
    /// packets also have no timestamp, so they were dropped: a subtitle larger than one packet came out cut or not at all (the app's
    /// owner, 2026-11-17: subtitles that did not show or switch; Häxan's drawn three times). A subtitle's first two bytes give its
    /// size; its packets follow one another in the stream.
    private func subpicture(stream index: Int) -> Subpicture {
        let size = Int(packet.pointee.size)
        guard size > 0, let bytes = packet.pointee.data else { return .pending }
        if var partial = subpictures[index] {
            partial.data.append(bytes, count: size)
            guard partial.data.count >= partial.expected else { subpictures[index] = partial; return .pending }
            subpictures[index] = nil
            return .complete(MediaPacket(stream: index, data: partial.data.prefix(partial.expected), pts: partial.pts, dts: partial.pts,
                                         duration: 0, isKeyframe: true, position: partial.position))
        }
        guard size >= 2 else { return .pending }
        let expected = Int(bytes[0]) << 8 | Int(bytes[1])
        guard expected > size else { return .single }
        // The start of a longer subtitle: it needs its time (a later part met on its own, after a jump, is passed over).
        let stamp = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        guard stamp != Int64.min, let dvd else { return .pending }
        if packet.pointee.pos >= 0, let cell = dvd.cellIndex(containingLogical: packet.pointee.pos) { dvdCell = cell }
        subpictures[index] = (Data(bytes: bytes, count: size), expected, titleTicks(stamp, layout: dvd, stream: index), packet.pointee.pos)
        return .pending
    }

    /// A DVD title's packet time on the title's timeline (``DVDTitleLayout/placement(cell:fallback:read:)``): the cell's
    /// timestamps, unwrapped near its start, moved by the cell's offset.
    private func titleTicks(_ ticks: Int64, layout: DVDTitleLayout, stream index: Int) -> Int64 {
        let base = timeBase(index)
        let raw = base.convert(ticks, to: Self.ninetyKilohertz)
        let place = layout.placement(cell: dvdCell, fallback: raw, read: DVDTitleLayout.reader(source))
        return Self.ninetyKilohertz.convert(DVDTitleLayout.unwrap(raw, near: place.anchor) + place.offset, to: base)
    }

    /// Seeks by byte position through an index made by reading the file once.
    private func seekUntimed(stream index: Int, to timestamp: Int64) throws {
        if untimedIndex[index]?.isEmpty ?? true {
            try rewind()
            while try next() != nil {}
        }
        let entries = untimedIndex[index] ?? []
        guard let entry = entries.last(where: { $0.ticks <= timestamp }) ?? entries.first else { return try rewind() }
        let result = av_seek_frame(format, -1, entry.position, AVSEEK_FLAG_BYTE)
        if result < 0 { throw FormatContext.openError(result, context.bridge) }
        clock[index] = entry.ticks
    }

}
