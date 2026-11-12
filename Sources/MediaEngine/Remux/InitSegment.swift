internal import FFmpegLGPL
import Foundation

/// The `ftyp` + `moov` part of a fragmented MP4 stream (EXT-X-MAP in HLS).
struct InitSegment: Sendable {
    var data: Data
    /// Ticks per second of the track's media time, from `mdhd`.
    var timescale: Int32
    var trackID: UInt32
}

/// Produces the initialization segment with FFmpeg's MP4 muxer, which knows how to describe every codec
/// (`avcC`, `hvcC`, `esds`, `dac3`, `dec3`, `colr`, ...). Media fragments are written by ``FragmentWriter``.
enum InitSegmentBuilder {
    /// - Parameters:
    ///   - parameters: The codec parameters of the source stream.
    ///   - samples: A few packets from the start of the stream. AC-3 and E-AC-3 descriptions are derived from real frames.
    ///   - shift: Added to every timestamp, in `timeBase` ticks, so no track starts before zero.
    static func build(parameters: UnsafePointer<AVCodecParameters>, timeBase: Rational, sampleAspect: AVRational,
                      samples: [MediaPacket], shift: Int64) throws -> InitSegment {
        var output: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&output, nil, "mp4", nil) >= 0, let context = output else {
            throw MediaError.engine(detail: "mp4 muxer unavailable")
        }
        defer { avformat_free_context(context) }

        var memory: UnsafeMutablePointer<AVIOContext>?
        guard avio_open_dyn_buf(&memory) >= 0, let buffer = memory else { throw MediaError.engine(detail: "no output buffer") }
        context.pointee.pb = buffer
        context.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

        func finish() -> Data {
            var bytes: UnsafeMutablePointer<UInt8>?
            let size = avio_close_dyn_buf(buffer, &bytes)
            defer { av_free(bytes) }
            return bytes.map { Data(bytes: $0, count: Int(max(size, 0))) } ?? Data()
        }

        guard let stream = avformat_new_stream(context, nil),
              avcodec_parameters_copy(stream.pointee.codecpar, parameters) >= 0 else {
            _ = finish()
            throw MediaError.engine(detail: "could not describe stream")
        }
        ensureHDR10Metadata(stream.pointee.codecpar)
        stream.pointee.time_base = timeBase.ffmpeg
        stream.pointee.sample_aspect_ratio = sampleAspect
        // Apple's players require the "hvc1" form of HEVC sample entries; FFmpeg defaults to "hev1".
        stream.pointee.codecpar.pointee.codec_tag = parameters.pointee.codec_id == AV_CODEC_ID_HEVC ? 0x3163_7668 : 0
        // Dolby Vision 5 and 8 go to Apple as Dolby Vision when the device decodes it (owner, 2026-11-12; before this the
        // configuration was dropped and profile 8 played as HDR10). FFmpeg writes the `dvcC`/`dvvC` box only at "unofficial"
        // strictness; profile 5 (no HDR10 base layer) needs the `dvh1` sample entry, profile 8 keeps `hvc1` (Apple's HLS
        // authoring specification). Profile 7 and devices without Dolby Vision keep the base layer only, as before.
        if let profile = Self.dolbyVisionProfile(parameters), [5, 8].contains(profile), AppleDecoding.decodesDolbyVision {
            context.pointee.strict_std_compliance = -1                      // FF_COMPLIANCE_UNOFFICIAL
            if profile == 5 { stream.pointee.codecpar.pointee.codec_tag = 0x3168_7664 }   // 'dvh1'
        }

        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_custom+empty_moov+delay_moov+default_base_moof+negative_cts_offsets", 0)
        // Our fragments carry exact timestamps; an edit list would shift the timeline players see.
        av_dict_set(&options, "use_editlist", "0", 0)
        defer { av_dict_free(&options) }
        let header = avformat_write_header(context, &options)
        guard header >= 0 else {
            _ = finish()
            throw MediaError.engine(detail: "mp4 header failed for \(String(cString: avcodec_get_name(parameters.pointee.codec_id))): \(AVError.describe(header))")
        }

        guard let packet = av_packet_alloc() else { _ = finish(); throw MediaError.engine(detail: "no packet") }
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        // The samples only describe the stream (the header is everything before the first fragment), so one whose decode time does not
        // move forward is left out: the muxer refuses it, and with it the whole movie (the app's owner, 2026-11-12: the later VOB files of
        // a DVD start with AC-3 packets that share a timestamp).
        var lastDTS: Int64?
        for sample in samples {
            guard sample.dts != Int64.min, lastDTS.map({ sample.dts > $0 }) ?? true else { continue }
            lastDTS = sample.dts
            guard av_new_packet(packet, Int32(sample.data.count)) >= 0 else { continue }
            sample.data.copyBytes(to: packet.pointee.data, count: sample.data.count)
            packet.pointee.stream_index = 0
            packet.pointee.pts = sample.pts + shift
            packet.pointee.dts = sample.dts + shift
            packet.pointee.duration = sample.duration
            packet.pointee.flags = sample.isKeyframe ? AV_PKT_FLAG_KEY : 0
            let written = av_write_frame(context, packet)
            av_packet_unref(packet)
            if written < 0 { _ = finish(); throw MediaError.engine(detail: "mp4 write failed: \(AVError.describe(written))") }
        }
        av_write_frame(context, nil)                         // flush the fragment; delay_moov writes the moov now

        let produced = finish()
        let boxes = MP4Box.parse(produced)
        guard boxes.contains(where: { $0.type == "moov" }) else {
            throw MediaError.engine(detail: "muxer produced boxes \(boxes.map(\.type)) in \(produced.count) bytes")
        }
        // Everything before the first fragment (if the muxer wrote one) is the initialization segment.
        let initData = produced.prefix(boxes.first(where: { $0.type == "moof" })?.start ?? produced.count)
        guard let mdhd = MP4Box.find(["moov", "trak", "mdia", "mdhd"], in: initData),
              let tkhd = MP4Box.find(["moov", "trak", "tkhd"], in: initData) else {
            throw MediaError.engine(detail: "init segment lacks mdhd/tkhd")
        }
        let mdhdVersion = initData[initData.startIndex + mdhd.payload.lowerBound]
        let timescale = initData.uint32(at: mdhd.payload.lowerBound + (mdhdVersion == 1 ? 20 : 12))
        let tkhdVersion = initData[initData.startIndex + tkhd.payload.lowerBound]
        let trackID = initData.uint32(at: tkhd.payload.lowerBound + (tkhdVersion == 1 ? 20 : 12))
        return InitSegment(data: Data(initData), timescale: Int32(timescale), trackID: trackID)
    }
}

extension InitSegmentBuilder {
    /// The Dolby Vision profile of a stream from its configuration record (Matroska's BlockAdditionMapping, MP4's `dvcC`/`dvvC`),
    /// or `nil` when the stream carries none.
    static func dolbyVisionProfile(_ parameters: UnsafePointer<AVCodecParameters>) -> Int? {
        guard let side = av_packet_side_data_get(parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data,
                                                 AV_PKT_DATA_DOVI_CONF),
              side.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return nil }
        let record = UnsafeRawPointer(side.pointee.data).loadUnaligned(as: AVDOVIDecoderConfigurationRecord.self)
        return Int(record.dv_profile)
    }

    /// Apple's HLS rules expect PQ (HDR10) video to carry mastering display and content light level boxes
    /// (`mdcv`, `clli`). Files with real values keep them; for files without any, nominal HDR10 values are
    /// written (BT.2020 primaries, D65 white, 0.0001 to 1000 nits, MaxCLL 1000, MaxFALL 400) so the stream is
    /// accepted and tone-mapped sensibly.
    static func ensureHDR10Metadata(_ parameters: UnsafeMutablePointer<AVCodecParameters>) {
        guard parameters.pointee.color_trc == AVCOL_TRC_SMPTE2084 else { return }

        if av_packet_side_data_get(parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data,
                                   AV_PKT_DATA_MASTERING_DISPLAY_METADATA) == nil,
           let side = av_packet_side_data_new(&parameters.pointee.coded_side_data, &parameters.pointee.nb_coded_side_data,
                                              AV_PKT_DATA_MASTERING_DISPLAY_METADATA, MemoryLayout<AVMasteringDisplayMetadata>.size, 0) {
            var metadata = AVMasteringDisplayMetadata()
            // order: red, green, blue
            let primaries: [(Int32, Int32)] = [(708, 1000), (292, 1000), (170, 1000), (797, 1000), (131, 1000), (46, 1000)]
            withUnsafeMutableBytes(of: &metadata.display_primaries) { raw in
                let rationals = raw.bindMemory(to: AVRational.self)
                for (index, value) in primaries.enumerated() { rationals[index] = AVRational(num: value.0, den: value.1) }
            }
            metadata.white_point = (AVRational(num: 3127, den: 10000), AVRational(num: 3290, den: 10000))
            metadata.min_luminance = AVRational(num: 1, den: 10000)
            metadata.max_luminance = AVRational(num: 1000, den: 1)
            metadata.has_primaries = 1
            metadata.has_luminance = 1
            UnsafeMutableRawPointer(side.pointee.data).storeBytes(of: metadata, as: AVMasteringDisplayMetadata.self)
        }

        if av_packet_side_data_get(parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data,
                                   AV_PKT_DATA_CONTENT_LIGHT_LEVEL) == nil,
           let side = av_packet_side_data_new(&parameters.pointee.coded_side_data, &parameters.pointee.nb_coded_side_data,
                                              AV_PKT_DATA_CONTENT_LIGHT_LEVEL, MemoryLayout<AVContentLightMetadata>.size, 0) {
            let light = AVContentLightMetadata(MaxCLL: 1000, MaxFALL: 400)
            UnsafeMutableRawPointer(side.pointee.data).storeBytes(of: light, as: AVContentLightMetadata.self)
        }
    }
}
