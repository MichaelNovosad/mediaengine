import AVFoundation
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
        codecName == "flac" || codecName.hasPrefix("pcm_") || codecName == "adpcm_ms" || codecName == "adpcm_ima_wav"
    }

    /// Seconds of audio that must be decoded (and thrown away) before a segment so the decoder is in the right
    /// state: 0 for stateless codecs, a fraction of a second for Opus and Vorbis (overlapping windows).
    static func prerollSeconds(_ codecName: String) -> Double {
        switch codecName {
        case "opus": 0.5        // measured: 0.2 s still left differences of up to -82 dBFS for about 0.35 s
        case "vorbis": 0.2      // one overlapping window; sample-exact after this (tested)
        // Legacy audio of the extended profile (MPEG audio layer II: one frame of filter-bank history).
        case "mp2": 0.1
        // The DTS core (filter-bank and ADPCM history across frames) and the fallback decoders for what Apple cannot play
        // (AAC: one overlapping 1024-sample window, more with SBR; AC-3/E-AC-3: one 256-sample overlap). Not measured: chosen
        // with room, as for MP2 (2026-11-12; before this DTS was planned for conversion but never converted).
        case "dts", "ac3", "eac3": 0.1
        case "aac": 0.2
        default: 0
        }
    }

    /// Whether this codec can be transcoded segment by segment (with pre-roll where needed).
    static func canTranscode(_ codecName: String) -> Bool {
        canTranscodeStatelessly(codecName) || prerollSeconds(codecName) > 0
    }

    /// AAC-LC with one, two or six channels (``SoundProcessing/Route/system``): Apple's AudioToolbox decodes it in step with its packets
    /// (measured 2026-11-19: 97 packets give 97 × 1024 samples, the first one where FFmpeg's decoder has it) and in FFmpeg's channel
    /// order (5.1 comes out as L R C LFE Ls Rs whatever layout the input format claims). HE-AAC is left out: its delay was not measured.
    static func systemDecodes(_ parameters: UnsafePointer<AVCodecParameters>) -> Bool {
        guard parameters.pointee.codec_id == AV_CODEC_ID_AAC, [1, 2, 6].contains(parameters.pointee.ch_layout.nb_channels),
              parameters.pointee.sample_rate > 0, let extra = parameters.pointee.extradata, parameters.pointee.extradata_size >= 2 else { return false }
        return extra[0] >> 3 == 2                                              // audio object type 2: AAC-LC
    }

    let sampleRate: Int
    let channels: Int
    private let parameters: UnsafeMutablePointer<AVCodecParameters>      // our own copy
    private let sourceTimeBase: Rational
    private let outputFormat: AVSampleFormat
    private let bitDepth: Int32
    /// Changes the decoded sound before it is encoded (``PlaybackSession/soundProcessor``).
    private let processor: (any SoundProcessor)?
    /// Decoded by AudioToolbox instead of FFmpeg (``systemDecodes(_:)``).
    private let systemDecoding: Bool
    /// FFmpeg's ALAC compression level for this source (``compressionLevel(codec:channels:sampleRate:bitDepth:)``).
    let compressionLevel: Int32

    init(parameters source: UnsafePointer<AVCodecParameters>, sourceTimeBase: Rational, processor: (any SoundProcessor)? = nil,
         systemDecoding: Bool = false) throws {
        self.processor = processor
        self.systemDecoding = systemDecoding
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
        compressionLevel = Self.compressionLevel(codec: source.pointee.codec_id, channels: channels, sampleRate: sampleRate, bitDepth: Int(bitDepth))
    }

    /// The ALAC encoder's level (the app's Jira EGA-123). At FFmpeg's default, 2, it looks for the best predictor in every frame: four
    /// fifths of the time of a converted piece (measured 2026-11-20 with a stack sample on a 5.1 DTS track: 125 ms for 10 s, the DTS
    /// decoder a sixth, the engine's own code under 3 %). Level 0 stores the samples as they are, still lossless: 39 ms for the same
    /// piece, the piece about a quarter bigger (more for real film sound, which compresses better). It is used for sound that was lossy
    /// to begin with (DTS, AC-3, E-AC-3, AAC, Opus, Vorbis, MP2, MP3) when it makes at most 1 MiB a second (5.1 at 48 kHz: 864 KB; the
    /// encoder writes a sample deeper than 16 bits with 24); everything else, lossless sources up to 7.1 at 192 kHz among them, keeps
    /// level 2.
    static func compressionLevel(codec: AVCodecID, channels: Int, sampleRate: Int, bitDepth: Int) -> Int32 {
        let lossy = [AV_CODEC_ID_DTS, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_AAC, AV_CODEC_ID_OPUS, AV_CODEC_ID_VORBIS,
                     AV_CODEC_ID_MP2, AV_CODEC_ID_MP3]
        let bytesPerSecond = channels * sampleRate * (bitDepth > 16 ? 3 : 2)
        return lossy.contains(codec) && bytesPerSecond <= 1 << 20 ? 0 : 2
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
        var layout = Self.encoderLayout(source: parameters.pointee.ch_layout, channels: channels, encoder: context, codec: codec)
        av_channel_layout_copy(&context.pointee.ch_layout, &layout)
        context.pointee.bits_per_raw_sample = bitDepth
        context.pointee.compression_level = compressionLevel
        let result = avcodec_open2(context, codec, nil)
        guard result >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            throw MediaError.engine(detail: "ALAC encoder failed to open: \(AVError.describe(result))")
        }
        return context
    }

    /// The channel layout of the ALAC stream: the source's own when FFmpeg's ALAC encoder takes it, else the encoder's layout with the
    /// same number of channels. DTS (and other decoders) report 5.1 with side surrounds, "5.1(side)", which the encoder refuses: it takes
    /// "5.1", the same speakers with the surrounds named back, as Apple Lossless does; the resampler moves side to back. Refusing it
    /// stopped every movie with such a track from opening (the app's owner, 2026-11-12: Lawrence of Arabia, Brazil).
    static func encoderLayout(source: AVChannelLayout, channels: Int, encoder: UnsafeMutablePointer<AVCodecContext>,
                              codec: UnsafePointer<AVCodec>) -> AVChannelLayout {
        var wanted = AVChannelLayout()
        if source.order == AV_CHANNEL_ORDER_UNSPEC || source.nb_channels != Int32(channels) {
            av_channel_layout_default(&wanted, Int32(channels))
        } else {
            var copy = source
            av_channel_layout_copy(&wanted, &copy)
        }
        var configs: UnsafeRawPointer?
        var count: Int32 = 0
        guard avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, &configs, &count) >= 0,
              let configs, count > 0 else { return wanted }
        let supported = UnsafeBufferPointer(start: configs.assumingMemoryBound(to: AVChannelLayout.self), count: Int(count))
        if supported.contains(where: { var layout = $0; return av_channel_layout_compare(&layout, &wanted) == 0 }) { return wanted }
        guard var same = supported.first(where: { $0.nb_channels == Int32(channels) }) else { return wanted }
        av_channel_layout_uninit(&wanted)
        var result = AVChannelLayout()
        av_channel_layout_copy(&result, &same)
        return result
    }

    // MARK: Transcoding

    /// Decodes `packets` (consecutive packets of one stream) and returns ALAC packets whose timestamps count
    /// samples (`outputTimeBase`). The first output sample sits where the decoder says the first packet's audio
    /// starts. `preroll` are the packets just before `packets`: they are decoded to bring a stateful decoder
    /// (Opus, Vorbis) into the right state, and their audio is discarded.
    func transcode(_ packets: [MediaPacket], preroll: [MediaPacket] = [], stream: Int) throws -> [MediaPacket] {
        guard let first = packets.first else { return [] }
        if systemDecoding { return try transcodeWithSystem(packets, preroll: preroll, stream: stream) }
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let decoder = avcodec_alloc_context3(codec) else { throw MediaError.engine(detail: "no decoder") }
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = decoder; avcodec_free_context(&context) }
        decoder.pointee.pkt_timebase = sourceTimeBase.ffmpeg
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
        // Where the first output sample sits: taken from the decoder's first frame (it knows about start-skip and
        // decoder delay); until then the first packet's time plus its start-skip is the best guess.
        var nextSample = sourceTimeBase.convert(first.pts, to: outputTimeBase) + Int64(first.skipStart)
        var positioned = false

        var swr: OpaquePointer?
        defer { swr_free(&swr) }
        // With a processor: decoded sound to planar float first (`swr`), through the stage, then to the encoder's format (`floats`).
        let stage = processor?.makeStage(sampleRate: Double(sampleRate), channels: channels)
        let floats = try stage.map { _ in try FloatToOutput(layout: encoder.pointee.ch_layout, format: outputFormat, sampleRate: sampleRate) }
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

        /// `warmingUp`: a pre-roll frame, which only brings the stage into step (with no stage it is not converted at all).
        func convert(_ decoded: UnsafeMutablePointer<AVFrame>, warmingUp: Bool = false) throws {
            if !positioned, !warmingUp {
                positioned = true
                if decoded.pointee.pts != Int64.min { nextSample = sourceTimeBase.convert(decoded.pointee.pts, to: outputTimeBase) }
            }
            if swr == nil {
                var inLayout = decoded.pointee.ch_layout
                if inLayout.order == AV_CHANNEL_ORDER_UNSPEC { av_channel_layout_default(&inLayout, Int32(channels)) }
                guard swr_alloc_set_opts2(&swr, &encoder.pointee.ch_layout, stage == nil ? outputFormat : AV_SAMPLE_FMT_FLTP,
                                          Int32(sampleRate), &inLayout, AVSampleFormat(rawValue: decoded.pointee.format),
                                          decoded.pointee.sample_rate, 0, nil) >= 0,
                      swr_init(swr) >= 0 else { throw MediaError.engine(detail: "resampler failed to start") }
            }
            let capacity = Int(swr_get_out_samples(swr, decoded.pointee.nb_samples)) + 64
            let width = stage == nil ? bytesPerSample : MemoryLayout<Float>.size
            let planes = (0..<channels).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * width) }
            defer { planes.forEach { $0.deallocate() } }
            var outputs: [UnsafeMutablePointer<UInt8>?] = planes
            let produced: Int32 = outputs.withUnsafeMutableBufferPointer { buffer in
                let inputPlanes = UnsafeRawPointer(decoded.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(swr, buffer.baseAddress, Int32(capacity), inputPlanes, decoded.pointee.nb_samples)
            }
            guard produced >= 0 else { throw MediaError.engine(detail: "resample failed") }
            if let stage, let floats {
                let floatPlanes = planes.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: Float.self) }
                try floats.run(floatPlanes, frames: Int(produced), through: stage, discard: warmingUp) { channel, bytes, count in
                    pending[channel].append(bytes, count: count)
                }
            } else {
                for channel in 0..<channels { pending[channel].append(planes[channel], count: Int(produced) * bytesPerSample) }
            }
        }

        func send(_ packet: MediaPacket) throws {
            guard av_new_packet(input, Int32(packet.data.count)) >= 0 else { return }
            packet.data.copyBytes(to: input.pointee.data, count: packet.data.count)
            input.pointee.pts = packet.pts
            input.pointee.dts = packet.dts
            if packet.skipStart > 0 || packet.skipEnd > 0, let side = av_packet_new_side_data(input, AV_PKT_DATA_SKIP_SAMPLES, 10) {
                UnsafeMutableRawPointer(side).storeBytes(of: UInt32(packet.skipStart).littleEndian, as: UInt32.self)
                UnsafeMutableRawPointer(side).storeBytes(of: UInt32(packet.skipEnd).littleEndian, toByteOffset: 4, as: UInt32.self)
            }
            let sent = avcodec_send_packet(decoder, input)
            av_packet_unref(input)
            if sent < 0, sent != AVError.again { throw MediaError.corrupt(detail: "audio decode failed: \(AVError.describe(sent))") }
        }

        // Pre-roll: run the decoder (and a processor's stage) over the packets before the segment and throw their audio away.
        for packet in preroll {
            try send(packet)
            while avcodec_receive_frame(decoder, frame) >= 0 {
                if stage != nil { try convert(frame, warmingUp: true) }
                av_frame_unref(frame)
            }
        }
        for packet in packets {
            try send(packet)
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

    // MARK: AudioToolbox

    /// AAC-LC through Apple's decoder: each packet gives its own samples at once (no delay to trim), so a fresh decoder per piece, with
    /// the pre-roll before it, joins the pieces exactly. Only used with a processor (else the track is passed through untouched).
    private func transcodeWithSystem(_ packets: [MediaPacket], preroll: [MediaPacket], stream: Int) throws -> [MediaPacket] {
        guard let first = packets.first else { return [] }
        let decoder = try SystemAACDecoder(parameters: parameters)
        let encoder = try openEncoder()
        defer { var context: UnsafeMutablePointer<AVCodecContext>? = encoder; avcodec_free_context(&context) }
        let floats = try FloatToOutput(layout: encoder.pointee.ch_layout, format: outputFormat, sampleRate: sampleRate,
                                       source: parameters.pointee.ch_layout)
        let stage = processor?.makeStage(sampleRate: Double(sampleRate), channels: channels)
        let bytesPerSample = outputFormat == AV_SAMPLE_FMT_S32P ? 4 : 2
        let frameSize = max(Int(encoder.pointee.frame_size), 1)
        var pending = [Data](repeating: Data(), count: channels)
        var nextSample = sourceTimeBase.convert(first.pts, to: outputTimeBase) + Int64(first.skipStart)
        var skip = first.skipStart                                             // samples of the first packet the file says to drop
        var output: [MediaPacket] = []

        func take(_ pcm: AVAudioPCMBuffer, warmingUp: Bool) throws {
            guard let data = pcm.floatChannelData else { return }
            var frames = Int(pcm.frameLength)
            var start = 0
            if !warmingUp, skip > 0 {
                let dropped = min(skip, frames)
                if let stage {                                                 // dropped samples still keep the stage in step
                    var heads = (0..<channels).map { data[$0] }
                    heads.withUnsafeMutableBufferPointer { stage.process($0, frames: dropped) }
                }
                skip -= dropped
                start = dropped
                frames -= dropped
            }
            guard frames > 0 else { return }
            let planes = (0..<channels).map { data[$0] + start }
            if let stage {
                try floats.run(planes, frames: frames, through: stage, discard: warmingUp) { channel, bytes, count in
                    pending[channel].append(bytes, count: count)
                }
            } else if !warmingUp {
                try floats.convert(planes, frames: frames) { channel, bytes, count in pending[channel].append(bytes, count: count) }
            }
        }

        func encode(flush: Bool) throws {
            guard let frame = av_frame_alloc(), let encoded = av_packet_alloc() else { throw MediaError.engine(detail: "allocation failed") }
            defer {
                var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f)
                var p: UnsafeMutablePointer<AVPacket>? = encoded; av_packet_free(&p)
            }
            func drain() throws {
                while true {
                    let result = avcodec_receive_packet(encoder, encoded)
                    if result == AVError.again || result == AVError.eof { return }
                    guard result >= 0 else { throw MediaError.engine(detail: "ALAC encode failed: \(AVError.describe(result))") }
                    let duration = encoded.pointee.duration > 0 ? encoded.pointee.duration : Int64(frameSize)
                    output.append(MediaPacket(stream: stream, data: Data(bytes: encoded.pointee.data, count: Int(encoded.pointee.size)),
                                              pts: encoded.pointee.pts, dts: encoded.pointee.pts, duration: duration, isKeyframe: true))
                    av_packet_unref(encoded)
                }
            }
            while pending[0].count / bytesPerSample >= frameSize || (flush && !pending[0].isEmpty) {
                let samples = min(frameSize, pending[0].count / bytesPerSample)
                frame.pointee.nb_samples = Int32(samples)
                frame.pointee.format = outputFormat.rawValue
                frame.pointee.sample_rate = Int32(sampleRate)
                av_channel_layout_copy(&frame.pointee.ch_layout, &encoder.pointee.ch_layout)
                guard av_frame_get_buffer(frame, 0) >= 0 else { throw MediaError.engine(detail: "frame buffer failed") }
                let byteCount = samples * bytesPerSample
                for channel in 0..<channels {
                    pending[channel].prefix(byteCount).copyBytes(to: frame.pointee.extended_data[channel]!, count: byteCount)
                    pending[channel].removeFirst(byteCount)
                }
                frame.pointee.pts = nextSample
                nextSample += Int64(samples)
                let sent = avcodec_send_frame(encoder, frame)
                av_frame_unref(frame)
                guard sent >= 0 else { throw MediaError.engine(detail: "ALAC send failed: \(AVError.describe(sent))") }
                try drain()
            }
            if flush {
                avcodec_send_frame(encoder, nil)
                try drain()
            }
        }

        for packet in preroll { try decoder.decode(packet) { try take($0, warmingUp: true) } }
        for packet in packets {
            try decoder.decode(packet) { try take($0, warmingUp: false) }
            try encode(flush: false)
        }
        try decoder.finish { try take($0, warmingUp: false) }
        try encode(flush: true)
        return output
    }
}

/// Planar float sound to the encoder's planar integer format (FFmpeg clips what goes past full scale), after a processor's stage.
private final class FloatToOutput {
    private var swr: OpaquePointer?
    private let bytesPerSample: Int
    private let channels: Int

    init(layout: AVChannelLayout, format: AVSampleFormat, sampleRate: Int, source: AVChannelLayout? = nil) throws {
        var outLayout = layout
        var inLayout = AVChannelLayout()
        if let source, source.nb_channels == layout.nb_channels, source.order != AV_CHANNEL_ORDER_UNSPEC {
            var copy = source
            av_channel_layout_copy(&inLayout, &copy)
        } else {
            av_channel_layout_copy(&inLayout, &outLayout)
        }
        defer { av_channel_layout_uninit(&inLayout) }
        channels = Int(layout.nb_channels)
        bytesPerSample = format == AV_SAMPLE_FMT_S32P ? 4 : 2
        guard swr_alloc_set_opts2(&swr, &outLayout, format, Int32(sampleRate), &inLayout, AV_SAMPLE_FMT_FLTP, Int32(sampleRate), 0, nil) >= 0,
              swr_init(swr) >= 0 else { throw MediaError.engine(detail: "resampler failed to start") }
    }

    deinit { swr_free(&swr) }

    /// The samples through `stage`, then converted and handed to `append` per channel, unless `discard` (a warm-up).
    func run(_ planes: [UnsafeMutablePointer<Float>], frames: Int, through stage: any SoundStage, discard: Bool,
             append: (Int, UnsafePointer<UInt8>, Int) throws -> Void) throws {
        var heads = planes
        heads.withUnsafeMutableBufferPointer { stage.process($0, frames: frames) }
        if !discard { try convert(planes, frames: frames, append: append) }
    }

    func convert(_ planes: [UnsafeMutablePointer<Float>], frames: Int, append: (Int, UnsafePointer<UInt8>, Int) throws -> Void) throws {
        guard frames > 0 else { return }
        let capacity = frames + 64
        let outputs = (0..<channels).map { _ in UnsafeMutablePointer<UInt8>.allocate(capacity: capacity * bytesPerSample) }
        defer { outputs.forEach { $0.deallocate() } }
        var outs: [UnsafeMutablePointer<UInt8>?] = outputs
        var ins: [UnsafePointer<UInt8>?] = planes.map { UnsafePointer(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self)) }
        let produced = outs.withUnsafeMutableBufferPointer { out in
            ins.withUnsafeMutableBufferPointer { input in swr_convert(swr, out.baseAddress, Int32(capacity), input.baseAddress, Int32(frames)) }
        }
        guard produced >= 0 else { throw MediaError.engine(detail: "resample failed") }
        for channel in 0..<channels { try append(channel, outputs[channel], Int(produced) * bytesPerSample) }
    }
}

/// AAC-LC packets to planar float through AudioToolbox (``AudioTranscoder/systemDecodes(_:)``).
private final class SystemAACDecoder {
    private let converter: AVAudioConverter
    private let compressed: AVAudioFormat
    private let decoded: AVAudioFormat

    init(parameters: UnsafePointer<AVCodecParameters>) throws {
        let channels = parameters.pointee.ch_layout.nb_channels
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_WAVE_5_1_A
        var description = AudioStreamBasicDescription()
        description.mSampleRate = Double(parameters.pointee.sample_rate)
        description.mChannelsPerFrame = UInt32(channels)
        description.mFormatID = kAudioFormatMPEG4AAC
        description.mFramesPerPacket = 1024
        // A compressed format of more than two channels needs a layout to exist; the decoder takes its own from the stream and maps it
        // to the output's (measured: the same levels per channel whichever 5.1 layout the input names).
        guard let layout = AVAudioChannelLayout(layoutTag: tag),
              let compressed = AVAudioFormat(streamDescription: &description, channelLayout: layout),
              let extra = parameters.pointee.extradata, parameters.pointee.extradata_size > 0 else {
            throw MediaError.unsupported(detail: "this AAC track has no usable format")
        }
        compressed.magicCookie = Data(bytes: extra, count: Int(parameters.pointee.extradata_size))
        let decoded = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: description.mSampleRate, interleaved: false, channelLayout: layout)
        guard let converter = AVAudioConverter(from: compressed, to: decoded) else {
            throw MediaError.unsupported(detail: "the system cannot decode this AAC track")
        }
        self.compressed = compressed
        self.decoded = decoded
        self.converter = converter
    }

    func decode(_ packet: MediaPacket, into sink: (AVAudioPCMBuffer) throws -> Void) throws {
        guard !packet.data.isEmpty else { return }
        let buffer = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: packet.data.count)
        packet.data.copyBytes(to: buffer.data.assumingMemoryBound(to: UInt8.self), count: packet.data.count)
        buffer.byteLength = UInt32(packet.data.count)
        buffer.packetCount = 1
        buffer.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.data.count))
        var given = false
        try pull(into: sink) { status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
    }

    /// What the decoder still holds.
    func finish(into sink: (AVAudioPCMBuffer) throws -> Void) throws {
        try pull(into: sink) { status in status.pointee = .endOfStream; return nil }
    }

    private func pull(into sink: (AVAudioPCMBuffer) throws -> Void,
                      input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) throws {
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: decoded, frameCapacity: 4096) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in input(inputStatus) }
            if let error { throw MediaError.corrupt(detail: "audio decode failed: \(error.localizedDescription)") }
            if output.frameLength > 0 { try sink(output) }
            if status != .haveData || output.frameLength == 0 { return }
        }
    }
}
