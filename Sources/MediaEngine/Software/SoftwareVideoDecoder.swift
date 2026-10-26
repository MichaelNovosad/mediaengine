internal import FFmpegLGPL
import CoreVideo
import Foundation
import Synchronization

/// One picture out of the decoder, ready for the display layer.
struct DecodedFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer
    /// Presentation time and length in seconds on the file's timeline.
    var time: Double
    var duration: Double
    var isKeyframe: Bool
    /// The source says the picture is made of two fields (interlaced) and which comes first.
    var isInterlaced: Bool
    var topFieldFirst: Bool
    /// Extra field periods from soft telecine (`repeat_pict`): the frame stays on screen that much longer (already part of `duration`).
    var repeatFields: Int
    /// The picture was cleaned of combing before it was handed over.
    var wasDeinterlaced: Bool
}

/// FFmpeg's decoder for one video stream (the software decoders of the extended profile and dav1d).
final class SoftwareVideoDecoder {
    private let context: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let packet: UnsafeMutablePointer<AVPacket>
    private let converter = PixelBufferConverter()
    private let timeBase: Rational
    private let defaultDuration: Double
    private let containerAspect: AVRational?
    private let deinterlacing = Mutex(Deinterlacing.automatic)

    /// - Parameters:
    ///   - frameRate: The stream's frame rate, used for frames that carry no duration.
    ///   - containerAspect: The pixel aspect ratio the container declares (Matroska display size, for example); it wins over
    ///     what the video bitstream says, as in other players.
    init(parameters: UnsafeMutablePointer<AVCodecParameters>, timeBase: Rational, frameRate: Double?, containerAspect: Rational? = nil) throws {
        FFmpegLogging.ensureInstalled()
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw MediaError.unsupported(detail: "this build has no decoder for this video format")
        }
        guard let context = avcodec_alloc_context3(codec), let frame = av_frame_alloc(), let packet = av_packet_alloc() else {
            throw MediaError.engine(detail: "could not allocate the decoder")
        }
        self.context = context; self.frame = frame; self.packet = packet
        self.timeBase = timeBase
        self.defaultDuration = frameRate.flatMap { $0 > 0 ? 1 / $0 : nil } ?? 1.0 / 25
        self.containerAspect = containerAspect.flatMap { $0.num > 0 && $0.den > 0 && $0.num <= Int64(Int32.max) && $0.den <= Int64(Int32.max) ? $0.ffmpeg : nil }
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { throw MediaError.engine(detail: "decoder parameters") }
        context.pointee.pkt_timebase = timeBase.ffmpeg
        context.pointee.thread_count = 0                                   // as many threads as the machine has
        context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        guard avcodec_open2(context, codec, nil) >= 0 else { throw MediaError.unsupported(detail: "the video decoder could not be opened") }
    }

    deinit {
        var contextPointer: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&contextPointer)
        var framePointer: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&framePointer)
        var packetPointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&packetPointer)
    }

    /// Hands a compressed packet to the decoder; `nil` signals the end of the stream (flush out what is buffered).
    func send(_ media: MediaPacket?) {
        guard let media else { avcodec_send_packet(context, nil); return }
        av_packet_unref(packet)
        guard av_new_packet(packet, Int32(media.data.count)) >= 0 else { return }
        media.data.withUnsafeBytes { raw in if let base = raw.baseAddress { memcpy(packet.pointee.data, base, raw.count) } }
        packet.pointee.pts = media.pts
        packet.pointee.dts = media.dts
        packet.pointee.duration = media.duration
        packet.pointee.flags = media.isKeyframe ? AV_PKT_FLAG_KEY : 0
        avcodec_send_packet(context, packet)
        av_packet_unref(packet)
    }

    /// What to do with interlaced pictures from now on.
    func setDeinterlacing(_ mode: Deinterlacing) { deinterlacing.withLock { $0 = mode } }

    /// How long a picture stays on screen when the file does not say: one frame period, and half a period more for every field
    /// the stream asks to repeat (soft telecine: `repeat_pict` counts field periods, so 3:2 pulldown flags lengthen a picture
    /// the way a television would show it, and a 24 fps film keeps its rhythm instead of being played at 30).
    static func displayDuration(packetDuration: Double?, framePeriod: Double, repeatFields: Int) -> Double {
        if let packetDuration, packetDuration > 0 { return packetDuration }
        return framePeriod * Double(2 + max(repeatFields, 0)) / 2
    }

    /// The next finished picture, or `nil` when the decoder needs more packets (or has none left).
    func receive() -> DecodedFrame? {
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if let aspect = containerAspect { frame.pointee.sample_aspect_ratio = aspect }
            let isInterlaced = frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0
            let topFieldFirst = frame.pointee.flags & AV_FRAME_FLAG_TOP_FIELD_FIRST != 0
            let clean = isInterlaced && deinterlacing.withLock { $0 } == .automatic
            guard let buffer = try? converter.convert(frame, deinterlaceTopFieldFirst: clean ? topFieldFirst : nil) else { continue }
            let stamp = frame.pointee.best_effort_timestamp
            guard stamp != Int64.min else { continue }
            let repeatFields = Int(frame.pointee.repeat_pict)
            let duration = Self.displayDuration(packetDuration: frame.pointee.duration > 0 ? timeBase.seconds(frame.pointee.duration) : nil,
                                                framePeriod: defaultDuration, repeatFields: repeatFields)
            return DecodedFrame(
                pixelBuffer: buffer, time: timeBase.seconds(stamp), duration: duration,
                isKeyframe: frame.pointee.flags & AV_FRAME_FLAG_KEY != 0,
                isInterlaced: isInterlaced, topFieldFirst: topFieldFirst, repeatFields: repeatFields, wasDeinterlaced: clean)
        }
        return nil
    }

    /// Forgets everything buffered (after a seek).
    func flush() { avcodec_flush_buffers(context) }
}
