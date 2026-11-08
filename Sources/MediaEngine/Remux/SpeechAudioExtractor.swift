import AVFoundation
import AudioToolbox
internal import FFmpegLGPL
import Foundation

/// Decodes one sound track of a file to mono 16 kHz 16-bit sound in a CAF file, the form speech recognition takes. FFmpeg's own decoders do
/// FLAC, Opus, Vorbis, MP3, ALAC and PCM; AAC, AC-3 and E-AC-3, which the engine has no decoders of its own for, go through the system's
/// AudioToolbox (the same decoders the system player uses; a surround track comes out as stereo, which the system mixes down itself).
enum SpeechAudioExtractor {
    static let outputRate = 16_000.0
    static let systemCodecs: Set<String> = ["aac", "ac3", "eac3"]

    static func canDecode(_ codecName: String) -> Bool {
        systemCodecs.contains(codecName) || ["flac", "vorbis", "opus", "mp3", "alac"].contains(codecName) || codecName.hasPrefix("pcm_")
    }

    /// Decodes the whole track; `progress` gets 0 to 1 as the file is read. Blocks: call it on a thread of its own.
    static func extract(from byteSource: any ByteSource, stream: Int, codecName: String, to url: URL, cancellation: CancellationFlag,
                        progress: (@Sendable (Double) -> Void)?) throws {
        let reader = try PacketReader(source: byteSource, cancellation: cancellation, quick: false)      // its progress needs FFmpeg's duration
        reader.limit(to: [stream])
        let base = reader.timeBase(stream)
        let total = max(Double(reader.format.pointee.duration) / Double(AV_TIME_BASE), 0)
        let sink = try PCMSink(url: url)
        let decoder: any SpeechDecoder = systemCodecs.contains(codecName)
            ? try SystemDecoder(parameters: reader.parameters(stream), codecName: codecName)
            : try FFmpegDecoder(parameters: reader.parameters(stream), timeBase: base)
        var lastReported = -1.0
        while let packet = try reader.next() {
            if cancellation.isCancelled { throw MediaError.cancelled }
            guard packet.stream == stream else { continue }
            try decoder.decode(packet, into: sink)
            if let progress, total > 0 {
                let done = min(base.seconds(packet.pts) / total, 1)
                if done - lastReported >= 0.01 { lastReported = done; progress(done) }
            }
        }
        try decoder.finish(into: sink)
        sink.close()
        progress?(1)
    }
}

/// Mono 16 kHz 16-bit samples written to a CAF file.
private final class PCMSink {
    private var file: AVAudioFile?
    private let format: AVAudioFormat

    init(url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: SpeechAudioExtractor.outputRate, channels: 1, interleaved: true) else {
            throw MediaError.engine(detail: "no sound format")
        }
        self.format = format
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    func write(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard !samples.isEmpty, let file, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let target = buffer.int16ChannelData?[0] else { return }
        target.update(from: samples.baseAddress!, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    func close() { file = nil }
}

private protocol SpeechDecoder {
    func decode(_ packet: MediaPacket, into sink: PCMSink) throws
    func finish(into sink: PCMSink) throws
}

/// FFmpeg decoder, with its resampler turning whatever it produces into mono 16 kHz 16-bit.
private final class FFmpegDecoder: SpeechDecoder {
    private let context: UnsafeMutablePointer<AVCodecContext>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let input: UnsafeMutablePointer<AVPacket>
    private var swr: OpaquePointer?

    init(parameters: UnsafePointer<AVCodecParameters>, timeBase: Rational) throws {
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id), let context = avcodec_alloc_context3(codec) else {
            throw MediaError.unsupported(detail: "no decoder for this sound")
        }
        self.context = context
        guard avcodec_parameters_to_context(context, parameters) >= 0, avcodec_open2(context, codec, nil) >= 0,
              let frame = av_frame_alloc(), let input = av_packet_alloc() else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            throw MediaError.engine(detail: "decoder failed to open")
        }
        context.pointee.pkt_timebase = timeBase.ffmpeg
        self.frame = frame
        self.input = input
    }

    deinit {
        var context: UnsafeMutablePointer<AVCodecContext>? = self.context
        avcodec_free_context(&context)
        var frame: UnsafeMutablePointer<AVFrame>? = self.frame
        av_frame_free(&frame)
        var packet: UnsafeMutablePointer<AVPacket>? = input
        av_packet_free(&packet)
        swr_free(&swr)
    }

    func decode(_ packet: MediaPacket, into sink: PCMSink) throws {
        guard av_new_packet(input, Int32(packet.data.count)) >= 0 else { return }
        packet.data.copyBytes(to: input.pointee.data, count: packet.data.count)
        input.pointee.pts = packet.pts
        input.pointee.dts = packet.dts
        if packet.skipStart > 0 || packet.skipEnd > 0, let side = av_packet_new_side_data(input, AV_PKT_DATA_SKIP_SAMPLES, 10) {
            UnsafeMutableRawPointer(side).storeBytes(of: UInt32(packet.skipStart).littleEndian, as: UInt32.self)
            UnsafeMutableRawPointer(side).storeBytes(of: UInt32(packet.skipEnd).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        let sent = avcodec_send_packet(context, input)
        av_packet_unref(input)
        if sent < 0, sent != AVError.again { return }           // a damaged packet is skipped: speech recognition does not need every sample
        try drain(into: sink)
    }

    func finish(into sink: PCMSink) throws {
        avcodec_send_packet(context, nil)
        try drain(into: sink)
        if let swr {
            // What the resampler still holds.
            var out = [Int16](repeating: 0, count: 4096)
            let count = out.withUnsafeMutableBufferPointer { buffer -> Int32 in
                var plane: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self)
                return swr_convert(swr, &plane, 4096, nil, 0)
            }
            if count > 0 { try out.withUnsafeBufferPointer { try sink.write(UnsafeBufferPointer(rebasing: $0[0..<Int(count)])) } }
        }
    }

    private func drain(into sink: PCMSink) throws {
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if swr == nil {
                var inLayout = frame.pointee.ch_layout
                if inLayout.order == AV_CHANNEL_ORDER_UNSPEC { av_channel_layout_default(&inLayout, max(inLayout.nb_channels, 1)) }
                var outLayout = AVChannelLayout()
                av_channel_layout_default(&outLayout, 1)
                guard swr_alloc_set_opts2(&swr, &outLayout, AV_SAMPLE_FMT_S16, Int32(SpeechAudioExtractor.outputRate), &inLayout,
                                          AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate, 0, nil) >= 0,
                      swr_init(swr) >= 0 else { throw MediaError.engine(detail: "resampler failed to start") }
            }
            let capacity = Int(swr_get_out_samples(swr, frame.pointee.nb_samples)) + 64
            var out = [Int16](repeating: 0, count: capacity)
            let produced = out.withUnsafeMutableBufferPointer { buffer -> Int32 in
                var plane: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self)
                let planes = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(swr, &plane, Int32(capacity), planes, frame.pointee.nb_samples)
            }
            if produced > 0 { try out.withUnsafeBufferPointer { try sink.write(UnsafeBufferPointer(rebasing: $0[0..<Int(produced)])) } }
        }
    }
}

/// AAC, AC-3 and E-AC-3 through AudioToolbox: packets to float sound (stereo at most), mixed to mono and brought to 16 kHz.
private final class SystemDecoder: SpeechDecoder {
    private let converter: AVAudioConverter
    private let compressed: AVAudioFormat
    private let decoded: AVAudioFormat
    private var toSpeech: AVAudioConverter?
    private let mono: AVAudioFormat
    private let speech: AVAudioFormat

    init(parameters: UnsafePointer<AVCodecParameters>, codecName: String) throws {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = Double(parameters.pointee.sample_rate)
        description.mChannelsPerFrame = UInt32(max(parameters.pointee.ch_layout.nb_channels, 1))
        switch codecName {
        case "aac": description.mFormatID = kAudioFormatMPEG4AAC; description.mFramesPerPacket = 1024
        case "ac3": description.mFormatID = kAudioFormatAC3; description.mFramesPerPacket = 1536
        default: description.mFormatID = kAudioFormatEnhancedAC3; description.mFramesPerPacket = 1536
        }
        guard description.mSampleRate > 0, let compressed = AVAudioFormat(streamDescription: &description) else {
            throw MediaError.unsupported(detail: "this sound has no usable format")
        }
        if codecName == "aac", let extra = parameters.pointee.extradata, parameters.pointee.extradata_size > 0 {
            compressed.magicCookie = Data(bytes: extra, count: Int(parameters.pointee.extradata_size))
        }
        guard let decoded = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: description.mSampleRate,
                                          channels: min(AVAudioChannelCount(description.mChannelsPerFrame), 2), interleaved: false),
              let converter = AVAudioConverter(from: compressed, to: decoded),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: description.mSampleRate, channels: 1, interleaved: false),
              let speech = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: SpeechAudioExtractor.outputRate, channels: 1, interleaved: true) else {
            throw MediaError.unsupported(detail: "the system cannot decode this sound")
        }
        self.compressed = compressed
        self.decoded = decoded
        self.converter = converter
        self.mono = mono
        self.speech = speech
        toSpeech = AVAudioConverter(from: mono, to: speech)
    }

    func decode(_ packet: MediaPacket, into sink: PCMSink) throws {
        guard !packet.data.isEmpty else { return }
        let buffer = AVAudioCompressedBuffer(format: compressed, packetCapacity: 1, maximumPacketSize: packet.data.count)
        packet.data.copyBytes(to: buffer.data.assumingMemoryBound(to: UInt8.self), count: packet.data.count)
        buffer.byteLength = UInt32(packet.data.count)
        buffer.packetCount = 1
        buffer.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.data.count))
        var given = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: decoded, frameCapacity: 4096) else { return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if given { inputStatus.pointee = .noDataNow; return nil }
                given = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if output.frameLength > 0 { try write(output, into: sink) }
            if status != .haveData || error != nil { break }
        }
    }

    func finish(into sink: PCMSink) throws {}

    /// Stereo or mono float sound to mono 16 kHz 16-bit samples.
    private func write(_ pcm: AVAudioPCMBuffer, into sink: PCMSink) throws {
        guard let toSpeech, let channels = pcm.floatChannelData, let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: pcm.frameLength),
              let target = monoBuffer.floatChannelData?[0] else { return }
        let frames = Int(pcm.frameLength)
        if pcm.format.channelCount >= 2 {
            for index in 0..<frames { target[index] = (channels[0][index] + channels[1][index]) * 0.5 }
        } else {
            target.update(from: channels[0], count: frames)
        }
        monoBuffer.frameLength = pcm.frameLength
        let capacity = AVAudioFrameCount(Double(frames) * SpeechAudioExtractor.outputRate / mono.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: speech, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        toSpeech.convert(to: out, error: &error) { _, inputStatus in
            if given { inputStatus.pointee = .noDataNow; return nil }
            given = true
            inputStatus.pointee = .haveData
            return monoBuffer
        }
        if let samples = out.int16ChannelData?[0], out.frameLength > 0 {
            try sink.write(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        }
    }
}
