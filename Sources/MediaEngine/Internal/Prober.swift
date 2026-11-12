internal import FFmpegLGPL
import Foundation

/// Reads the container and builds ``MediaInfo``. Runs synchronously on a background thread.
enum Prober {
    private static let unknownProfile: Int32 = -99      // AV_PROFILE_UNKNOWN

    static func probe(source: any ByteSource, cancellation: CancellationFlag,
                      capabilities: DeviceCapabilities = .current) throws -> MediaInfo {
        let docType = sniffMatroskaDocType(source)
        // A legacy container this build has no demuxer for must be recognised before FFmpeg is asked: its raw audio
        // demuxers (AC-3, MP3, AAC) would otherwise "find" the audio stream inside the file and report a bogus audio file.
        if let name = LegacyContainer.name(of: source) {
            throw MediaError.unsupported(detail: "\(name) files need the extended module, which this build does not include.")
        }
        let context = try FormatContext.open(source: source, cancellation: cancellation)
        fillADTSParameters(context.format)
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
            if stream.pointee.id != 0 { track.containerID = Int(stream.pointee.id) }
            switch kind {
            case .video:
                let (codec, details) = videoInfo(stream: stream, par: par)
                track.codec = codec
                track.codec.appleDecodes = AppleDecoding.video(par, codec: codec)      // Apple first (owner, 2026-11-12)
                track.video = details
            case .audio:
                track.codec = codecInfo(par: par, extra: nil)
                track.codec.appleDecodes = AppleDecoding.audio(track.codec)
                track.audio = audioInfo(par: par, codecName: track.codec.name, container: container.kind)
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
        var incomplete = false
        if container.isMatroskaFamily, let length = source.length, let end = MatroskaChapters.declaredEnd(of: source), end > length {
            incomplete = true
            let percent = max(0, min(99, Int(Double(length) / Double(end) * 100)))
            plan.notes.append("This file is incomplete: about \(percent) % of it is there. The duration shown is the one its header claims.")
        }
        return MediaInfo(
            container: container, duration: duration, title: tags["title"], tags: tags,
            bitrate: format.pointee.bit_rate > 0 ? format.pointee.bit_rate : nil,
            fileSize: source.length, tracks: tracks, chapters: chapters, attachments: attachments,
            playbackPlan: plan, segmentUID: segmentUID, orderedChapters: ordered, isIncomplete: incomplete)
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
        case "rm": return .realMedia
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
        "theora": "Theora", "prores": "ProRes", "mjpeg": "Motion JPEG", "flv1": "Sorenson Spark", "h263": "H.263",
        "h263p": "H.263+", "h263i": "H.263", "vp6": "VP6", "vp6f": "VP6 (Flash)", "rv10": "RealVideo 1.0", "rv20": "RealVideo 2.0",
        "rv30": "RealVideo 3.0", "rv40": "RealVideo 4.0", "cook": "RealAudio Cook", "ra_144": "RealAudio 1.0", "ra_288": "RealAudio 2.0",
        "adpcm_ms": "MS ADPCM", "adpcm_ima_wav": "IMA ADPCM",
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

    /// AAC in MPEG-TS carries ADTS headers and no configuration record, and with no AAC decoder compiled in FFmpeg does
    /// not read the sample rate and channel count from them. The first frame of each such stream says it.
    private static func fillADTSParameters(_ format: UnsafeMutablePointer<AVFormatContext>) {
        var pending = Set<Int>()
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let par = format.pointee.streams[index]?.pointee.codecpar, par.pointee.codec_id == AV_CODEC_ID_AAC,
                  par.pointee.sample_rate == 0 || par.pointee.ch_layout.nb_channels == 0 else { continue }
            pending.insert(index)
        }
        guard !pending.isEmpty, let packet = av_packet_alloc() else { return }
        defer { var pointer: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&pointer) }
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var scanned = 0
        while !pending.isEmpty, scanned < 300, av_read_frame(format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            scanned += 1
            let index = Int(packet.pointee.stream_index)
            guard pending.contains(index), packet.pointee.size >= 7, let bytes = packet.pointee.data,
                  bytes[0] == 0xFF, bytes[1] & 0xF0 == 0xF0, let par = format.pointee.streams[index]?.pointee.codecpar else { continue }
            let rate = Int((bytes[2] >> 2) & 0x0F)
            let configuration = Int(((bytes[2] & 0x01) << 2) | (bytes[3] >> 6))
            let channels = [0, 1, 2, 3, 4, 5, 6, 8][min(configuration, 7)]
            guard rate < rates.count, channels > 0 else { continue }
            par.pointee.sample_rate = Int32(rates[rate])
            av_channel_layout_default(&par.pointee.ch_layout, Int32(channels))
            pending.remove(index)
        }
    }

    /// Sample rate and channel count from an AAC AudioSpecificConfig. FLV tags always claim 44.1 kHz stereo for AAC; the
    /// configuration in the stream header is the truth (and no AAC decoder is compiled in to find it out).
    private static func aacConfiguration(_ par: UnsafeMutablePointer<AVCodecParameters>) -> (sampleRate: Int, channels: Int)? {
        guard par.pointee.extradata_size >= 2, let data = par.pointee.extradata else { return nil }
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let objectType = Int(data[0] >> 3)
        let index = Int(((data[0] & 7) << 1) | (data[1] >> 7))
        guard objectType != 31, index < rates.count else { return nil }
        let channelConfiguration = Int((data[1] >> 3) & 0xF)
        let channels = [0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 8][channelConfiguration] ?? 0
        return channels > 0 ? (rates[index], channels) : nil
    }

    private static func audioInfo(par: UnsafeMutablePointer<AVCodecParameters>, codecName: String, container: Container.Kind) -> AudioDetails {
        var layout = par.pointee.ch_layout
        var sampleRate = Int(par.pointee.sample_rate)
        if container == .flv, codecName == "aac", let configuration = aacConfiguration(par) {
            sampleRate = configuration.sampleRate
            av_channel_layout_default(&layout, Int32(configuration.channels))
        }
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
            channels: Int(layout.nb_channels), channelLayout: description,
            sampleRate: sampleRate > 0 ? sampleRate : nil,
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
