internal import FFmpegLGPL
import Foundation

/// Reads the container and builds ``MediaInfo``. Runs synchronously on a background thread.
enum Prober {
    private static let unknownProfile: Int32 = -99      // AV_PROFILE_UNKNOWN

    static func probe(source: any ByteSource, cancellation: CancellationFlag,
                      capabilities: DeviceCapabilities = .current) throws -> MediaInfo {
        let docType = sniffMatroskaDocType(source)
        let context = try FormatContext.open(source: source, cancellation: cancellation)
        return build(context.format, source: source, docType: docType, capabilities: capabilities)
    }

    /// Reads the first bytes to tell WebM from Matroska: the EBML header names its DocType.
    private static func sniffMatroskaDocType(_ source: any ByteSource) -> String? {
        var header = [UInt8](repeating: 0, count: 64)
        let count = header.withUnsafeMutableBytes { (try? source.read(at: 0, into: $0)) ?? 0 }
        guard count >= 8, header[0] == 0x1A, header[1] == 0x45, header[2] == 0xDF, header[3] == 0xA3 else { return nil }
        let text = String(decoding: header.prefix(count), as: UTF8.self)
        if text.contains("webm") { return "webm" }
        return text.contains("matroska") ? "matroska" : nil
    }

    // MARK: Building MediaInfo

    private static func build(_ format: UnsafeMutablePointer<AVFormatContext>, source: any ByteSource,
                              docType: String?, capabilities: DeviceCapabilities) -> MediaInfo {
        let formatName = String(cString: format.pointee.iformat.pointee.name)
        let container = Container(kind: containerKind(formatName, docType: docType), formatName: formatName)
        let tags = dictionary(format.pointee.metadata)

        var tracks: [Track] = []
        var attachments: [Attachment] = []
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[index], let par = stream.pointee.codecpar else { continue }
            let disposition = stream.pointee.disposition
            let streamTags = dictionary(stream.pointee.metadata)

            if par.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT || disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
                let size = par.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT
                    ? Int(par.pointee.extradata_size) : Int(stream.pointee.attached_pic.size)
                attachments.append(attachment(index: index, tags: streamTags, byteCount: size))
                continue
            }
            guard let kind = trackKind(par.pointee.codec_type) else { continue }

            var track = Track(
                id: index, kind: kind, codec: Codec(name: "", displayName: ""),
                language: LanguageCodes.language(from: streamTags["language"]),
                title: streamTags["title"],
                isDefault: disposition & AV_DISPOSITION_DEFAULT != 0,
                isForced: disposition & AV_DISPOSITION_FORCED != 0,
                isHearingImpaired: disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0,
                isCommentary: disposition & AV_DISPOSITION_COMMENT != 0,
                bitrate: par.pointee.bit_rate > 0 ? par.pointee.bit_rate : nil)
            switch kind {
            case .video:
                let (codec, details) = videoInfo(stream: stream, par: par)
                track.codec = codec
                track.video = details
            case .audio:
                track.codec = codecInfo(par: par, extra: nil)
                track.audio = audioInfo(par: par, codecName: track.codec.name)
            case .subtitle:
                track.codec = codecInfo(par: par, extra: nil)
                let bitmap = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"].contains(track.codec.name)
                track.subtitle = SubtitleDetails(format: bitmap ? .bitmap : .text)
            }
            tracks.append(track)
        }

        var chapters: [Chapter] = []
        for index in 0..<Int(format.pointee.nb_chapters) {
            guard let chapter = format.pointee.chapters[index] else { continue }
            let base = Double(chapter.pointee.time_base.num) / Double(max(chapter.pointee.time_base.den, 1))
            chapters.append(Chapter(
                id: Int(chapter.pointee.id),
                start: Double(chapter.pointee.start) * base,
                end: Double(chapter.pointee.end) * base,
                title: dictionary(chapter.pointee.metadata)["title"]))
        }

        let duration = format.pointee.duration != Int64.min && format.pointee.duration > 0
            ? Double(format.pointee.duration) / Double(AV_TIME_BASE) : nil
        var plan = PlaybackPlanner.plan(container: container, tracks: tracks, capabilities: capabilities)

        // What FFmpeg does not tell: this file's segment identifier and an ordered edition (chapters as a play list).
        var segmentUID: String?
        var ordered: OrderedChapters?
        if container.kind == .matroska, let structure = MatroskaChapters.read(from: source) {
            segmentUID = structure.segmentUID.map { LinkedSegment(data: $0).uid }
            ordered = OrderedChapters.make(editions: structure.editions, ownUID: structure.segmentUID)
            if let ordered, !ordered.segments.isEmpty {
                plan.notes.append("This file plays parts of \(ordered.segments.count) other file(s); they are looked for next to it.")
            }
        }
        return MediaInfo(
            container: container, duration: duration, title: tags["title"], tags: tags,
            bitrate: format.pointee.bit_rate > 0 ? format.pointee.bit_rate : nil,
            fileSize: source.length, tracks: tracks, chapters: chapters, attachments: attachments,
            playbackPlan: plan, segmentUID: segmentUID, orderedChapters: ordered)
    }

    private static func containerKind(_ name: String, docType: String?) -> Container.Kind {
        if name.contains("matroska") { return docType == "webm" ? .webm : .matroska }
        if name.hasPrefix("mov,") { return .mp4 }
        switch name {
        case "mpegts": return .mpegTS
        case "mpeg": return .mpegPS
        case "avi": return .avi
        case "asf": return .asf
        case "flv": return .flv
        case "ogg": return .ogg
        case "wav": return .wav
        case "flac": return .flac
        case "mp3": return .mp3
        case "aac": return .aac
        case "ac3": return .ac3
        case "eac3": return .eac3
        default: return .other
        }
    }

    private static func trackKind(_ type: AVMediaType) -> Track.Kind? {
        switch type {
        case AVMEDIA_TYPE_VIDEO: .video
        case AVMEDIA_TYPE_AUDIO: .audio
        case AVMEDIA_TYPE_SUBTITLE: .subtitle
        default: nil
        }
    }

    private static func attachment(index: Int, tags: [String: String], byteCount: Int) -> Attachment {
        let filename = tags["filename"]
        let mime = tags["mimetype"]
        let ext = filename.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        let fontMimes: Set<String> = ["application/x-truetype-font", "application/vnd.ms-opentype", "application/x-font-ttf",
                                      "application/x-font-otf", "application/font-sfnt", "font/ttf", "font/otf", "font/sfnt"]
        let kind: Attachment.Kind
        if let mime, fontMimes.contains(mime.lowercased()) || ["ttf", "otf", "ttc"].contains(ext) { kind = .font }
        else if ["ttf", "otf", "ttc"].contains(ext) { kind = .font }
        else if mime?.lowercased().hasPrefix("image/") == true { kind = .coverArt }
        else { kind = .other }
        return Attachment(id: index, kind: kind, filename: filename, mimeType: mime, byteCount: byteCount)
    }

    // MARK: Codecs

    private static let displayNames: [String: String] = [
        "h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "mpeg1video": "MPEG-1",
        "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4 Part 2", "msmpeg4v1": "MS MPEG-4 v1", "msmpeg4v2": "MS MPEG-4 v2",
        "msmpeg4v3": "MS MPEG-4 v3", "vc1": "VC-1", "wmv1": "WMV 7", "wmv2": "WMV 8", "wmv3": "WMV 9",
        "theora": "Theora", "prores": "ProRes", "mjpeg": "Motion JPEG",
        "aac": "AAC", "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "truehd": "Dolby TrueHD", "mlp": "MLP",
        "flac": "FLAC", "alac": "Apple Lossless", "opus": "Opus", "vorbis": "Vorbis", "mp3": "MP3", "mp2": "MP2",
        "wmav1": "WMA", "wmav2": "WMA",
        "subrip": "SubRip", "srt": "SubRip", "ass": "ASS/SSA", "ssa": "SSA", "webvtt": "WebVTT",
        "mov_text": "Timed Text", "text": "Plain text", "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub",
        "dvb_subtitle": "DVB subtitles", "microdvd": "MicroDVD",
    ]

    private static func codecInfo(par: UnsafeMutablePointer<AVCodecParameters>, extra: (name: String?, id: Int?, level: String?)?) -> Codec {
        let name = String(cString: avcodec_get_name(par.pointee.codec_id))
        let display = displayNames[name] ?? (name.hasPrefix("pcm_") ? "PCM" : name.uppercased())
        var profileName = extra?.name
        if profileName == nil, par.pointee.profile != unknownProfile,
           let text = avcodec_profile_name(par.pointee.codec_id, par.pointee.profile) {
            profileName = String(cString: text)
        }
        return Codec(name: name, displayName: display, profile: profileName,
                     profileIdentifier: extra?.id ?? (par.pointee.profile != unknownProfile ? Int(par.pointee.profile) : nil),
                     level: extra?.level)
    }

    private static func bytes(_ par: UnsafeMutablePointer<AVCodecParameters>) -> [UInt8] {
        guard let pointer = par.pointee.extradata, par.pointee.extradata_size > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(par.pointee.extradata_size)))
    }

    private static func videoInfo(stream: UnsafeMutablePointer<AVStream>, par: UnsafeMutablePointer<AVCodecParameters>) -> (Codec, VideoDetails) {
        let data = bytes(par)
        var extra: (name: String?, id: Int?, level: String?)?
        var bitDepth: Int? = par.pointee.bits_per_raw_sample > 0 ? Int(par.pointee.bits_per_raw_sample) : nil
        var chroma: VideoDetails.Chroma?

        switch par.pointee.codec_id {
        case AV_CODEC_ID_H264:
            if let avc = Extradata.avc(data) {
                extra = (Extradata.h264ProfileName(avc.profileIdc), avc.profileIdc, Extradata.h264Level(avc.levelIdc))
                if bitDepth == nil { bitDepth = avc.profileIdc == 110 || avc.profileIdc == 122 ? 10 : (avc.profileIdc == 100 ? 8 : nil) }
                if avc.profileIdc == 100 { chroma = .yuv420 }
            }
        case AV_CODEC_ID_HEVC:
            if let hevc = Extradata.hevc(data) {
                extra = (Extradata.hevcProfileName(hevc.profileIdc), hevc.profileIdc, Extradata.hevcLevel(hevc.levelIdc))
                bitDepth = hevc.bitDepth
                chroma = [VideoDetails.Chroma.monochrome, .yuv420, .yuv422, .yuv444][min(hevc.chromaFormatIdc, 3)]
            }
        case AV_CODEC_ID_AV1:
            if let av1 = Extradata.av1(data) {
                extra = (Extradata.av1ProfileName(av1.seqProfile), av1.seqProfile, Extradata.av1Level(av1.levelIdx))
                bitDepth = av1.bitDepth
                chroma = av1.isMonochrome ? .monochrome : (av1.subsamplingX ? (av1.subsamplingY ? .yuv420 : .yuv422) : .yuv444)
            }
        default:
            break
        }

        var rate: Double?
        let frameRate = stream.pointee.avg_frame_rate.num > 0 ? stream.pointee.avg_frame_rate : stream.pointee.r_frame_rate
        if frameRate.num > 0, frameRate.den > 0 { rate = Double(frameRate.num) / Double(frameRate.den) }

        var aspect = stream.pointee.sample_aspect_ratio
        if aspect.num <= 0 || aspect.den <= 0 { aspect = par.pointee.sample_aspect_ratio }

        let interlaced: Bool? = switch par.pointee.field_order {
        case AV_FIELD_PROGRESSIVE: false
        case AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT: true
        default: nil
        }

        let details = VideoDetails(
            width: Int(par.pointee.width), height: Int(par.pointee.height), frameRate: rate,
            bitDepth: bitDepth, chroma: chroma,
            pixelAspectRatio: aspect.num > 0 && aspect.den > 0 ? Double(aspect.num) / Double(aspect.den) : nil,
            isInterlaced: interlaced,
            colorPrimaries: par.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED ? nil : av_color_primaries_name(par.pointee.color_primaries).map(String.init(cString:)),
            colorTransfer: par.pointee.color_trc == AVCOL_TRC_UNSPECIFIED ? nil : av_color_transfer_name(par.pointee.color_trc).map(String.init(cString:)),
            colorMatrix: par.pointee.color_space == AVCOL_SPC_UNSPECIFIED ? nil : av_color_space_name(par.pointee.color_space).map(String.init(cString:)),
            isFullRange: par.pointee.color_range == AVCOL_RANGE_UNSPECIFIED ? nil : par.pointee.color_range == AVCOL_RANGE_JPEG,
            hdr: hdrFormat(par), rotation: rotation(par))
        return (codecInfo(par: par, extra: extra), details)
    }

    private static func hdrFormat(_ par: UnsafeMutablePointer<AVCodecParameters>) -> HDRFormat {
        if let side = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
           side.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size {
            let record = UnsafeRawPointer(side.pointee.data).loadUnaligned(as: AVDOVIDecoderConfigurationRecord.self)
            return .dolbyVision(profile: Int(record.dv_profile), level: Int(record.dv_level),
                                baseLayerCompatibility: Int(record.dv_bl_signal_compatibility_id))
        }
        switch par.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: return .hdr10
        case AVCOL_TRC_ARIB_STD_B67: return .hlg
        default: return .sdr
        }
    }

    private static func rotation(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Int {
        guard let side = av_packet_side_data_get(par.pointee.coded_side_data, par.pointee.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX),
              side.pointee.size >= 9 * MemoryLayout<Int32>.size else { return 0 }
        let counterClockwise = av_display_rotation_get(UnsafeRawPointer(side.pointee.data).assumingMemoryBound(to: Int32.self))
        guard counterClockwise.isFinite else { return 0 }
        let clockwise = Int((-counterClockwise).rounded())
        return ((clockwise % 360) + 360) % 360
    }

    private static func audioInfo(par: UnsafeMutablePointer<AVCodecParameters>, codecName: String) -> AudioDetails {
        var layout = par.pointee.ch_layout
        if layout.order == AV_CHANNEL_ORDER_UNSPEC, layout.nb_channels > 0 {
            // Without a decoder FFmpeg cannot name the layout; use the standard one for this channel count.
            av_channel_layout_default(&layout, layout.nb_channels)
        }
        var description: String?
        var buffer = [CChar](repeating: 0, count: 128)
        if av_channel_layout_describe(&layout, &buffer, buffer.count) > 0 { description = String(cBuffer: buffer) }
        let profile = par.pointee.profile
        let depth = par.pointee.bits_per_raw_sample > 0 ? par.pointee.bits_per_raw_sample : par.pointee.bits_per_coded_sample
        let lossless = ["flac", "alac", "truehd", "mlp"].contains(codecName) || codecName.hasPrefix("pcm_")
            || (codecName == "dts" && profile == AV_PROFILE_DTS_HD_MA)
        let objectBased = (codecName == "eac3" && profile == AV_PROFILE_EAC3_DDP_ATMOS)
            || (codecName == "truehd" && profile == AV_PROFILE_TRUEHD_ATMOS)
        return AudioDetails(
            channels: Int(par.pointee.ch_layout.nb_channels), channelLayout: description,
            sampleRate: par.pointee.sample_rate > 0 ? Int(par.pointee.sample_rate) : nil,
            bitDepth: depth > 0 ? Int(depth) : nil, isLossless: lossless, isObjectBased: objectBased)
    }

    private static func dictionary(_ dict: OpaquePointer?) -> [String: String] {
        var result: [String: String] = [:]
        var entry: UnsafePointer<AVDictionaryEntry>?
        while let next = av_dict_iterate(dict, entry) {
            entry = next
            result[String(cString: next.pointee.key)] = String(cString: next.pointee.value)
        }
        return result
    }
}
