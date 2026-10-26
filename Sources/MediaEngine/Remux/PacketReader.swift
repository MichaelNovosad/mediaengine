internal import FFmpegLGPL
import Foundation

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
    /// AAC with ADTS headers and container timestamps (MPEG-TS): the header is cut off and its content goes into the
    /// codec parameters. Raw `.aac` files have no timestamps at all and are handled below with `untimedStreams`.
    private var adtsStreams: Set<Int> = []
    private var adtsConfigurations: [Int: ADTSFrame] = [:]

    init(source: any ByteSource, cancellation: CancellationFlag) throws {
        self.source = source
        self.cancellation = cancellation
        context = try FormatContext.open(source: source, cancellation: cancellation)
        guard let packet = av_packet_alloc() else { throw MediaError.engine(detail: "could not allocate packet") }
        self.packet = packet
        try prepareStreams()
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }

    var format: UnsafeMutablePointer<AVFormatContext> { context.format }
    var streamCount: Int { Int(format.pointee.nb_streams) }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream> { format.pointee.streams[index]! }
    /// Where the file's timeline starts, when it does not start at zero (MPEG-TS recordings begin at 1.4 s or later; Matroska
    /// files cut from a longer one at wherever the cut was). Every timestamp the reader hands out has this taken off, so the
    /// engine sees a timeline from zero; seeks and the keyframe list add and take it off the same way.
    private func originTicks(_ index: Int) -> Int64 {
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
        context = try FormatContext.open(source: source, cancellation: cancellation)
        clock = [:]
        applyStreamLimit()
        applyPreparedParameters()
        // The new context knows nothing of the extradata made for raw ADTS files; it is made again on the first frame.
    }

    /// Positions the reader at the last keyframe at or before `timestamp` of the given stream.
    func seek(stream index: Int, to timestamp: Int64) throws {
        if untimedStreams.contains(index) { return try seekUntimed(stream: index, to: timestamp) }
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
            if let codec = annexB[streamIndex] { data = AnnexB.convert(data, codec: codec, sets: &parameterSets[streamIndex, default: [:]]) }
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
