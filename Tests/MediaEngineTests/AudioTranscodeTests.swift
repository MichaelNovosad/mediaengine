import FFmpegLGPL
import Foundation
import Testing
@testable import MediaEngine

/// Decodes packets with FFmpeg and returns 32-bit interleaved samples (planar or packed input, any bit depth).
private func decodeToS32(_ parameters: UnsafePointer<AVCodecParameters>, packets: [MediaPacket]) throws -> (samples: [Int32], channels: Int) {
    let codec = try #require(avcodec_find_decoder(parameters.pointee.codec_id))
    let created = try #require(avcodec_alloc_context3(codec))
    var context: UnsafeMutablePointer<AVCodecContext>? = created
    defer { avcodec_free_context(&context) }
    #expect(avcodec_parameters_to_context(created, parameters) >= 0)
    #expect(avcodec_open2(created, codec, nil) >= 0)
    let channels = Int(parameters.pointee.ch_layout.nb_channels)
    let frame = try #require(av_frame_alloc())
    var frameToFree: UnsafeMutablePointer<AVFrame>? = frame
    defer { av_frame_free(&frameToFree) }
    let packet = try #require(av_packet_alloc())
    var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
    defer { av_packet_free(&packetToFree) }
    var swr: OpaquePointer?
    defer { swr_free(&swr) }
    var samples: [Int32] = []

    func drain() throws {
        while avcodec_receive_frame(created, frame) >= 0 {
            if swr == nil {
                var layout = frame.pointee.ch_layout
                if layout.order == AV_CHANNEL_ORDER_UNSPEC { av_channel_layout_default(&layout, Int32(channels)) }
                var out = layout
                #expect(swr_alloc_set_opts2(&swr, &out, AV_SAMPLE_FMT_S32, frame.pointee.sample_rate, &layout,
                                            AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate, 0, nil) >= 0)
                #expect(swr_init(swr) >= 0)
            }
            let capacity = Int(frame.pointee.nb_samples) + 64
            var buffer = [Int32](repeating: 0, count: capacity * channels)
            let produced = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
                var pointer: UnsafeMutablePointer<UInt8>? = UnsafeMutableRawPointer(out.baseAddress!).assumingMemoryBound(to: UInt8.self)
                let planes = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(swr, &pointer, Int32(capacity), planes, frame.pointee.nb_samples)
            }
            samples.append(contentsOf: buffer.prefix(Int(produced) * channels))
            av_frame_unref(frame)
        }
    }

    for item in packets {
        av_new_packet(packet, Int32(item.data.count))
        item.data.copyBytes(to: packet.pointee.data, count: item.data.count)
        packet.pointee.pts = item.pts
        packet.pointee.dts = item.dts
        avcodec_send_packet(created, packet)
        av_packet_unref(packet)
        try drain()
    }
    avcodec_send_packet(created, nil)
    try drain()
    return (samples, channels)
}

private func allPackets(_ name: String, stream: Int) throws -> (reader: PacketReader, packets: [MediaPacket]) {
    let reader = try PacketReader(source: FileByteSource(url: Fixture.url(name)), cancellation: CancellationFlag())
    var packets: [MediaPacket] = []
    while let packet = try reader.next() { if packet.stream == stream { packets.append(packet) } }
    return (reader, packets)
}

@Suite("Audio transcoding")
struct AudioTranscodeTests {
    @Test("FLAC becomes ALAC without changing a single sample", arguments: [("fixture-basic", 2, 48_000, 1), ("fixture-flac24", 1, 44_100, 2)])
    func lossless(name: String, stream: Int, rate: Int, channels: Int) throws {
        let (reader, packets) = try allPackets(name, stream: stream)
        let transcoder = try AudioTranscoder(parameters: reader.parameters(stream), sourceTimeBase: reader.timeBase(stream))
        #expect(transcoder.sampleRate == rate && transcoder.channels == channels)

        let encoded = try transcoder.transcode(packets, stream: stream)
        #expect(!encoded.isEmpty && encoded.allSatisfy { $0.isKeyframe })

        let original = try decodeToS32(reader.parameters(stream), packets: packets)
        let alac = try transcoder.makeEncodedParameters()
        defer { var pointer: UnsafeMutablePointer<AVCodecParameters>? = alac; avcodec_parameters_free(&pointer) }
        #expect(alac.pointee.codec_id == AV_CODEC_ID_ALAC && alac.pointee.extradata_size > 0)
        let roundTrip = try decodeToS32(alac, packets: encoded)

        #expect(original.channels == channels && roundTrip.channels == channels)
        #expect(original.samples.count == roundTrip.samples.count, "sample counts \(original.samples.count) vs \(roundTrip.samples.count)")
        #expect(original.samples == roundTrip.samples, "the transcode changed samples")
        #expect(Double(roundTrip.samples.count / channels) / Double(rate) > 2.9)
    }

    @Test("output timestamps count samples and are contiguous")
    func timestamps() throws {
        let (reader, packets) = try allPackets("fixture-flac24", stream: 1)
        let transcoder = try AudioTranscoder(parameters: reader.parameters(1), sourceTimeBase: reader.timeBase(1))
        let encoded = try transcoder.transcode(packets, stream: 1)
        #expect(transcoder.outputTimeBase == Rational(num: 1, den: 44_100))
        #expect(encoded.first?.pts == reader.timeBase(1).convert(packets[0].pts, to: transcoder.outputTimeBase))
        for pair in zip(encoded, encoded.dropFirst()) { #expect(pair.1.pts == pair.0.pts + pair.0.duration) }
    }

    @Test("a segment can be transcoded on its own and joins the previous one exactly")
    func segmentsJoin() throws {
        let (reader, packets) = try allPackets("fixture-flac24", stream: 1)
        let transcoder = try AudioTranscoder(parameters: reader.parameters(1), sourceTimeBase: reader.timeBase(1))
        let whole = try decodeToS32(try transcoder.makeEncodedParameters(), packets: try transcoder.transcode(packets, stream: 1))
        let cut = packets.count / 2
        let first = try transcoder.transcode(Array(packets[..<cut]), stream: 1)
        let second = try transcoder.transcode(Array(packets[cut...]), stream: 1)
        let params = try transcoder.makeEncodedParameters()
        defer { var pointer: UnsafeMutablePointer<AVCodecParameters>? = params; avcodec_parameters_free(&pointer) }
        let joined = try decodeToS32(params, packets: first).samples + decodeToS32(params, packets: second).samples
        #expect(joined == whole.samples)
    }

    @Test("a transcoded track is only processed when the player asks for it")
    func lazyTranscoding() async throws {
        let info = try await Fixture.probe("fixture-basic")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-basic")), info: info, cancellation: CancellationFlag())
        let initialTranscodes = session.transcodeCount                 // the init segment trial run
        _ = try session.resource(path: "video-0.m4s")
        _ = try session.resource(path: "audio-1-0.m4s")               // AAC: passthrough
        #expect(session.transcodeCount == initialTranscodes, "FLAC was transcoded without being requested")
        let flac = try #require(try session.resource(path: "audio-2-0.m4s"))
        #expect(session.transcodeCount == initialTranscodes + 1 && flac.data.count > 1_000)
        _ = try session.resource(path: "audio-2-0.m4s")
        #expect(session.transcodeCount == initialTranscodes + 1, "the second request must come from the cache")
    }

    @Test("only stateless codecs are transcoded segment by segment")
    func statelessList() {
        #expect(AudioTranscoder.canTranscodeStatelessly("flac") && AudioTranscoder.canTranscodeStatelessly("pcm_s24le"))
        #expect(!AudioTranscoder.canTranscodeStatelessly("opus") && !AudioTranscoder.canTranscodeStatelessly("vorbis") && !AudioTranscoder.canTranscodeStatelessly("dts"))
    }
}
