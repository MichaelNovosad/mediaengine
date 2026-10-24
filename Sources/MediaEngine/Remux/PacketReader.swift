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
}

/// Reads compressed packets from an opened file. Not thread-safe: confine it to one serial queue.
final class PacketReader {
    private(set) var context: FormatContext
    private let source: any ByteSource
    private let cancellation: CancellationFlag
    private let packet: UnsafeMutablePointer<AVPacket>

    init(source: any ByteSource, cancellation: CancellationFlag) throws {
        self.source = source
        self.cancellation = cancellation
        context = try FormatContext.open(source: source, cancellation: cancellation)
        guard let packet = av_packet_alloc() else { throw MediaError.engine(detail: "could not allocate packet") }
        self.packet = packet
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }

    var format: UnsafeMutablePointer<AVFormatContext> { context.format }
    var streamCount: Int { Int(format.pointee.nb_streams) }

    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream> { format.pointee.streams[index]! }
    func parameters(_ index: Int) -> UnsafeMutablePointer<AVCodecParameters> { stream(index).pointee.codecpar }
    func timeBase(_ index: Int) -> Rational { Rational(stream(index).pointee.time_base) }

    /// Timestamps of the keyframes listed in the file's index (Matroska Cues, MP4 sync table), in the stream's time base.
    ///
    /// A freshly opened Matroska file has only loaded the index entries of the packets it probed; the Cues at the
    /// end of the file load lazily, on the first seek. Seeking once to the end makes the demuxer read them. The
    /// read position is undefined afterwards: seek or rewind before reading packets.
    func keyframeTimestamps(stream index: Int, loadingIndexUpTo duration: Double? = nil) -> [Int64] {
        if let duration { _ = try? seek(stream: index, to: timeBase(index).ticks(seconds: duration)) }
        let st = stream(index)
        let count = avformat_index_get_entries_count(st)
        var result: [Int64] = []
        result.reserveCapacity(Int(count))
        for entry in 0..<count {
            guard let item = avformat_index_get_entry(st, entry) else { continue }
            if item.pointee.flags & Int32(AVINDEX_KEYFRAME) != 0 { result.append(item.pointee.timestamp) }
        }
        return result.sorted()
    }

    /// Starts again from the very first packet. Seeking to time zero would skip packets with negative
    /// timestamps (the encoder-delay "priming" frames of AAC and others), so the file is simply reopened.
    func rewind() throws {
        context = try FormatContext.open(source: source, cancellation: cancellation)
    }

    /// Positions the reader at the last keyframe at or before `timestamp` of the given stream.
    func seek(stream index: Int, to timestamp: Int64) throws {
        let result = av_seek_frame(format, Int32(index), timestamp, AVSEEK_FLAG_BACKWARD)
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
            if pts == Int64.min { pts = dts }
            if dts == Int64.min { dts = pts }
            if pts == Int64.min { continue }                       // no usable timestamp: skip

            let size = Int(packet.pointee.size)
            let data = size > 0 ? Data(bytes: packet.pointee.data, count: size) : Data()
            var skipStart = 0, skipEnd = 0
            var sideSize = 0
            if let side = av_packet_get_side_data(packet, AV_PKT_DATA_SKIP_SAMPLES, &sideSize), sideSize >= 8 {
                let raw = UnsafeRawPointer(side)
                skipStart = Int(UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self)))
                skipEnd = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            }
            return MediaPacket(
                stream: Int(packet.pointee.stream_index), data: data, pts: pts, dts: dts,
                duration: max(packet.pointee.duration, 0),
                isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0, skipStart: skipStart, skipEnd: skipEnd)
        }
    }
}
