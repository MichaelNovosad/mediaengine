internal import FFmpegLGPL
import Foundation

/// Decodes audio that AVPlayer cannot play (FLAC, PCM, ...) and re-encodes it to Apple Lossless with FFmpeg's
/// native ALAC encoder.
///
/// ALAC is used for every transcode because it is lossless and has no encoder delay: each segment can be
/// encoded on its own, from a fresh decoder, and the pieces join without a glitch. (AAC would repeat its
/// priming samples at every segment boundary.) The native encoder is used instead of AudioToolbox's because
/// it writes a short final frame as is, where AudioToolbox pads it with silence and would stretch every segment.
final class AudioTranscoder: @unchecked Sendable {
    /// Codecs whose decoder keeps no state between packets, so a segment can be decoded from its first packet.
    static func canTranscodeStatelessly(_ codecName: String) -> Bool {
        codecName == "flac" || codecName.hasPrefix("pcm_")
    }

    let sampleRate: Int
    let channels: Int
    private let parameters: UnsafeMutablePointer<AVCodecParameters>      // our own copy
    private let sourceTimeBase: Rational
    private let outputFormat: AVSampleFormat
    private let bitDepth: Int32

    init(parameters source: UnsafePointer<AVCodecParameters>, sourceTimeBase: Rational) throws {
        guard let copy = avcodec_parameters_alloc(), avcodec_parameters_copy(copy, source) >= 0 else {
            throw MediaError.engine(detail: "could not copy audio parameters")
        }
        parameters = copy
        self.sourceTimeBase = sourceTimeBase
        sampleRate = Int(source.pointee.sample_rate)
        channels = Int(source.pointee.ch_layout.nb_channels)
        guard sampleRate > 0, channels > 0 else { throw MediaError.corrupt(detail: "audio without sample rate or channels") }
        let depth = max(source.pointee.bits_per_raw_sample, source.pointee.bits_per_coded_sample)
        bitDepth = depth > 16 ? min(depth, 32) : 16
        outputFormat = depth > 16 ? AV_SAMPLE_FMT_S32P : AV_SAMPLE_FMT_S16P
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVCodecParameters>? = parameters
        avcodec_parameters_free(&pointer)
    }

    /// Time base of the packets this transcoder produces: one tick per sample.
    var outputTimeBase: Rational { Rational(num: 1, den: Int64(sampleRate)) }

    // MARK: Encoder description

    /// Codec parameters of the ALAC stream (including its magic cookie) for the initialization segment.
    /// Returns owned parameters; the caller frees them with `avcodec_parameters_free`.
    func makeEncodedParameters() throws -> UnsafeMutablePointer<AVCodecParameters> {
        let encoder = try openEncoder()
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = encoder; avcodec_free_context(&context) }
        guard let result = avcodec_parameters_alloc() else { throw MediaError.engine(detail: "no parameters") }
        guard avcodec_parameters_from_context(result, encoder) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = result
            avcodec_parameters_free(&pointer)
            throw MediaError.engine(detail: "could not describe the ALAC stream")
        }
        return result
    }

    private func openEncoder() throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let codec = avcodec_find_encoder_by_name("alac"), let context = avcodec_alloc_context3(codec) else {
            throw MediaError.engine(detail: "ALAC encoder unavailable")
        }
        context.pointee.sample_rate = Int32(sampleRate)
        context.pointee.sample_fmt = outputFormat
        context.pointee.time_base = outputTimeBase.ffmpeg
        var layout = parameters.pointee.ch_layout
        if layout.order == AV_CHANNEL_ORDER_UNSPEC { av_channel_layout_default(&layout, Int32(channels)) }
        av_channel_layout_copy(&context.pointee.ch_layout, &layout)
        context.pointee.bits_per_raw_sample = bitDepth
        let result = avcodec_open2(context, codec, nil)
        guard result >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            throw MediaError.engine(detail: "ALAC encoder failed to open: \(AVError.describe(result))")
        }
        return context
    }

    // MARK: Transcoding

    /// Decodes `packets` (consecutive packets of one stream) and returns ALAC packets whose timestamps count
    /// samples (`outputTimeBase`). The first output sample sits at the first packet's presentation time.
    func transcode(_ packets: [MediaPacket], stream: Int) throws -> [MediaPacket] {
        guard let first = packets.first else { return [] }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let decoder = avcodec_alloc_context3(codec) else { throw MediaError.engine(detail: "no decoder") }
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = decoder; avcodec_free_context(&context) }
        guard avcodec_parameters_to_context(decoder, parameters) >= 0, avcodec_open2(decoder, codec, nil) >= 0 else {
            throw MediaError.engine(detail: "decoder failed to open")
        }
        let encoder = try openEncoder()
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = encoder; avcodec_free_context(&context) }

        var output: [MediaPacket] = []
        let bytesPerSample = outputFormat == AV_SAMPLE_FMT_S32P ? 4 : 2
        let frameSize = max(Int(encoder.pointee.frame_size), 1)
        var pending = [Data](repeating: Data(), count: channels)     // planar PCM waiting to be encoded, one buffer per channel
        func pendingSamples() -> Int { pending[0].count / bytesPerSample }
        var nextSample = sourceTimeBase.convert(first.pts, to: outputTimeBase)

        var swr: OpaquePointer?
        defer { swr_free(&swr) }
        guard let frame = av_frame_alloc(), let encoded = av_packet_alloc(), let input = av_packet_alloc() else {
            throw MediaError.engine(detail: "allocation failed")
        }
        defer {
            var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f)
            var p: UnsafeMutablePointer<AVPacket>? = encoded; av_packet_free(&p)
            var q: UnsafeMutablePointer<AVPacket>? = input; av_packet_free(&q)
        }

        func drainEncoder() throws {
            while true {
                let result = avcodec_receive_packet(encoder, encoded)
                if result == AVError.again || result == AVError.eof { return }
                guard result >= 0 else { throw MediaError.engine(detail: "ALAC encode failed: \(AVError.describe(result))") }
                let size = Int(encoded.pointee.size)
                let duration = encoded.pointee.duration > 0 ? encoded.pointee.duration : Int64(frameSize)
                output.append(MediaPacket(stream: stream, data: Data(bytes: encoded.pointee.data, count: size),
                                          pts: encoded.pointee.pts, dts: encoded.pointee.pts, duration: duration, isKeyframe: true))
                av_packet_unref(encoded)
            }
        }

        func encodeFrames(flush: Bool) throws {
            let encodeFrame = av_frame_alloc()
            defer { var f = encodeFrame; av_frame_free(&f) }
            guard let encodeFrame else { throw MediaError.engine(detail: "allocation failed") }
            while pendingSamples() >= frameSize || (flush && pendingSamples() > 0) {
                let samples = min(frameSize, pendingSamples())
                encodeFrame.pointee.nb_samples = Int32(samples)
                encodeFrame.pointee.format = outputFormat.rawValue
                encodeFrame.pointee.sample_rate = Int32(sampleRate)
                av_channel_layout_copy(&encodeFrame.pointee.ch_layout, &encoder.pointee.ch_layout)
                guard av_frame_get_buffer(encodeFrame, 0) >= 0 else { throw MediaError.engine(detail: "frame buffer failed") }
                let byteCount = samples * bytesPerSample
                for channel in 0..<channels {
                    pending[channel].prefix(byteCount).copyBytes(to: encodeFrame.pointee.extended_data[channel]!, count: byteCount)
                    pending[channel].removeFirst(byteCount)
                }
                encodeFrame.pointee.pts = nextSample
                nextSample += Int64(samples)
                let sent = avcodec_send_frame(encoder, encodeFrame)
                av_frame_unref(encodeFrame)
                guard sent >= 0 else { throw MediaError.engine(detail: "ALAC send failed: \(AVError.describe(sent))") }
                try drainEncoder()
            }
            if flush {
                avcodec_send_frame(encoder, nil)
                try drainEncoder()
            }
        }

        func convert(_ decoded: UnsafeMutablePointer<AVFrame>) throws {
            if swr == nil {
                var inLayout = decoded.pointee.ch_layout
                if inLayout.order == AV_CHANNEL_ORDER_UNSPEC { av_channel_layout_default(&inLayout, Int32(channels)) }
                guard swr_alloc_set_opts2(&swr, &encoder.pointee.ch_layout, outputFormat, Int32(sampleRate), &inLayout,
                                          AVSampleFormat(rawValue: decoded.pointee.format), decoded.pointee.sample_rate, 0, nil) >= 0,
                      swr_init(swr) >= 0 else { throw MediaError.engine(detail: "resampler failed to start") }
            }
            let capacity = Int(swr_get_out_samples(swr, decoded.pointee.nb_samples)) + 64
            let planes = (0..<channels).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * bytesPerSample) }
            defer { planes.forEach { $0.deallocate() } }
            var outputs: [UnsafeMutablePointer<UInt8>?] = planes
            let produced: Int32 = outputs.withUnsafeMutableBufferPointer { buffer in
                let inputPlanes = UnsafeRawPointer(decoded.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(swr, buffer.baseAddress, Int32(capacity), inputPlanes, decoded.pointee.nb_samples)
            }
            guard produced >= 0 else { throw MediaError.engine(detail: "resample failed") }
            for channel in 0..<channels { pending[channel].append(planes[channel], count: Int(produced) * bytesPerSample) }
        }

        for packet in packets {
            guard av_new_packet(input, Int32(packet.data.count)) >= 0 else { continue }
            packet.data.copyBytes(to: input.pointee.data, count: packet.data.count)
            input.pointee.pts = packet.pts
            input.pointee.dts = packet.dts
            let sent = avcodec_send_packet(decoder, input)
            av_packet_unref(input)
            if sent < 0, sent != AVError.again { throw MediaError.corrupt(detail: "audio decode failed: \(AVError.describe(sent))") }
            while avcodec_receive_frame(decoder, frame) >= 0 {
                try convert(frame)
                av_frame_unref(frame)
            }
            try encodeFrames(flush: false)
        }
        avcodec_send_packet(decoder, nil)
        while avcodec_receive_frame(decoder, frame) >= 0 {
            try convert(frame)
            av_frame_unref(frame)
        }
        try encodeFrames(flush: true)
        return output
    }
}
