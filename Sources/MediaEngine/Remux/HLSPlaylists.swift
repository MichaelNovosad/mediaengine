internal import FFmpegLGPL
import Foundation

/// Builds the HLS text for a remuxed file: one master playlist, one video playlist, one audio playlist per track.
enum HLSPlaylists {
    struct VideoRendition {
        var codecs: String
        var width: Int
        var height: Int
        var frameRate: Double?
        var range: String?              // "PQ", "HLG" or nil for SDR
        var bandwidth: Int
    }

    struct AudioRendition {
        var id: Int
        var name: String
        var language: String?
        var channels: Int
        var codecs: String
        var isDefault: Bool
    }

    static func master(video: VideoRendition?, audio: [AudioRendition], videoPlaylist: String, audioPlaylist: (Int) -> String) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for rendition in audio {
            var attributes = ["TYPE=AUDIO", "GROUP-ID=\"audio\"", "NAME=\(quoted(rendition.name))"]
            if let language = rendition.language { attributes.append("LANGUAGE=\(quoted(language))") }
            attributes.append("DEFAULT=\(rendition.isDefault ? "YES" : "NO")")
            attributes.append("AUTOSELECT=YES")
            attributes.append("CHANNELS=\"\(rendition.channels)\"")
            attributes.append("URI=\(quoted(audioPlaylist(rendition.id)))")
            lines.append("#EXT-X-MEDIA:" + attributes.joined(separator: ","))
        }
        if let video {
            let codecs = ([video.codecs] + audio.prefix(1).map(\.codecs)).joined(separator: ",")
            var attributes = ["BANDWIDTH=\(video.bandwidth)", "AVERAGE-BANDWIDTH=\(video.bandwidth)", "CODECS=\(quoted(codecs))",
                              "RESOLUTION=\(video.width)x\(video.height)"]
            if let rate = video.frameRate { attributes.append("FRAME-RATE=\(String(format: "%.3f", rate))") }
            if let range = video.range { attributes.append("VIDEO-RANGE=\(range)") }
            if !audio.isEmpty { attributes.append("AUDIO=\"audio\"") }
            lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
            lines.append(videoPlaylist)
        } else if let first = audio.first {
            // Audio-only: the first rendition doubles as the only variant.
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=256000,CODECS=\(quoted(first.codecs))")
            lines.append(audioPlaylist(first.id))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func media(plan: SegmentPlan, initURI: String, segmentURI: (Int) -> String) -> String {
        let target = Int((plan.segments.map(\.duration).max() ?? 6).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(target, 1))", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\(quoted(initURI))"]
        for segment in plan.segments {
            lines.append("#EXTINF:\(String(format: "%.5f", segment.duration)),")
            lines.append(segmentURI(segment.index))
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    // MARK: Codec strings (RFC 6381)

    static func codecString(for parameters: UnsafePointer<AVCodecParameters>) -> String {
        let extradata: [UInt8] = parameters.pointee.extradata.map {
            Array(UnsafeBufferPointer(start: $0, count: Int(parameters.pointee.extradata_size)))
        } ?? []
        switch parameters.pointee.codec_id {
        case AV_CODEC_ID_H264:
            guard Extradata.avc(extradata) != nil else { return "avc1.640028" }
            return "avc1." + [extradata[1], extradata[2], extradata[3]].map { String(format: "%02X", $0) }.joined()
        case AV_CODEC_ID_HEVC:
            return hevcString(extradata)
        case AV_CODEC_ID_AV1:
            guard let av1 = Extradata.av1(extradata) else { return "av01.0.08M.10" }
            let tier = extradata[2] & 0x80 != 0 ? "H" : "M"
            return "av01.\(av1.seqProfile).\(String(format: "%02d", av1.levelIdx))\(tier).\(String(format: "%02d", av1.bitDepth))"
        case AV_CODEC_ID_AAC:
            let objectType = extradata.first.map { Int($0 >> 3) } ?? 2
            return "mp4a.40.\(objectType == 0 ? 2 : objectType)"
        case AV_CODEC_ID_AC3: return "ac-3"
        case AV_CODEC_ID_EAC3: return "ec-3"
        case AV_CODEC_ID_ALAC: return "alac"
        case AV_CODEC_ID_MP3: return "mp4a.6B"
        case AV_CODEC_ID_FLAC: return "fLaC"
        default: return "mp4a.40.2"
        }
    }

    /// `hvc1.<space><profile>.<reversed compatibility flags>.<tier><level>.<constraint bytes>`
    static func hevcString(_ hvcc: [UInt8]) -> String {
        guard hvcc.count >= 13, hvcc[0] == 1 else { return "hvc1.1.6.L93.B0" }
        let space = ["", "A", "B", "C"][Int(hvcc[1] >> 6)]
        let profile = Int(hvcc[1] & 0x1F)
        let tier = hvcc[1] & 0x20 != 0 ? "H" : "L"
        var compatibility = UInt32(hvcc[2]) << 24 | UInt32(hvcc[3]) << 16 | UInt32(hvcc[4]) << 8 | UInt32(hvcc[5])
        var reversed: UInt32 = 0
        for _ in 0..<32 { reversed = (reversed << 1) | (compatibility & 1); compatibility >>= 1 }
        var constraints = Array(hvcc[6..<12])
        while constraints.last == 0, constraints.count > 1 { constraints.removeLast() }
        let constraintText = constraints.map { String(format: "%02X", $0) }.joined(separator: ".")
        return "hvc1.\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(Int(hvcc[12])).\(constraintText)"
    }
}
