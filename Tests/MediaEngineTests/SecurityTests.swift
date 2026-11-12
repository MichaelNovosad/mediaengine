import FFmpegLGPL
import Foundation
import Testing
@testable import MediaEngine

/// The engine must never touch files or networks on its own initiative, whatever a container says.
@Suite("Security")
struct SecurityTests {
    private let protocolNotFound: Int32 = -1_330_794_744   // AVERROR_PROTOCOL_NOT_FOUND

    @Test("no FFmpeg protocol is compiled in, for reading or writing")
    func noProtocols() {
        for direction: Int32 in [0, 1] {
            var opaque: UnsafeMutableRawPointer?
            var names: [String] = []
            while let name = avio_enum_protocols(&opaque, direction) { names.append(String(cString: name)) }
            #expect(names.isEmpty, "protocols for direction \(direction): \(names)")
        }
    }

    @Test("file and network locations cannot be opened directly")
    func directLocationsFail() {
        for location in ["file:///etc/hosts", "/etc/hosts", "http://127.0.0.1:9/x.mkv", "https://example.com/x.mkv", "concat:a|b", "subfile,,start,0,end,0,,:/etc/hosts"] {
            var context: UnsafeMutablePointer<AVFormatContext>?
            let result = avformat_open_input(&context, location, nil, nil)
            #expect(result < 0, "opened \(location)")
            if context != nil { avformat_close_input(&context) }
        }
    }

    @Test("only the intended demuxers are compiled in")
    func demuxerAllowList() {
        var opaque: UnsafeMutableRawPointer?
        var names: Set<String> = []
        while let demuxer = av_demuxer_iterate(&opaque) { names.insert(String(cString: demuxer.pointee.name)) }
        let forbidden: Set<String> = ["concat", "hls", "dash", "ffconcat", "rtsp", "sdp", "tcp", "lavfi", "image2", "sap"]
        #expect(names.isDisjoint(with: forbidden), "unexpected demuxers: \(names.intersection(forbidden))")
        #expect(names.contains("matroska,webm") && names.contains("mov,mp4,m4a,3gp,3g2,mj2"))
    }

    @Test("no decoders for patent-pooled codecs: never VC-1, TrueHD; MPEG-2 only in the extended builds; H.264, HEVC, AAC, AC-3, E-AC-3 and the DTS core only in the opt-in extended-plus build")
    func noPooledDecoders() {
        let profiles = MediaEngine.availableProfiles
        var never: [AVCodecID] = [AV_CODEC_ID_VC1, AV_CODEC_ID_TRUEHD]
        if !profiles.contains(.extended) { never.append(AV_CODEC_ID_MPEG2VIDEO) }   // expired, and part of the extended profile
        // Opt-in (owner, 2026-11-12): the DTS core, and the fallbacks for what Apple's decoders refuse (Apple first).
        if !profiles.contains(.h264Software) { never.append(AV_CODEC_ID_H264) }
        if !profiles.contains(.hevcSoftware) { never.append(AV_CODEC_ID_HEVC) }
        if !profiles.contains(.audioFallback) { never += [AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3] }
        if !profiles.contains(.dtsCore) { never.append(AV_CODEC_ID_DTS) }
        for id in never {
            #expect(avcodec_find_decoder(id) == nil, "decoder present for \(String(cString: avcodec_get_name(id)))")
        }
        // Our patch (third_party/patches/ffmpeg-0001-dts-core-only.diff) removes the decoder's `core_only` option: it is
        // always core-only, so DTS-HD lossless, DTS Express and DTS:X cannot be decoded by any build.
        if let dca = avcodec_find_decoder(AV_CODEC_ID_DTS) {
            var privClass = dca.pointee.priv_class
            let option = withUnsafeMutablePointer(to: &privClass) {
                av_opt_find(UnsafeMutableRawPointer($0), "core_only", nil, 0, AV_OPT_SEARCH_FAKE_OBJ)
            }
            #expect(option == nil, "the DTS decoder still has the core_only option: the core-only patch was not applied")
        }
        for id in [AV_CODEC_ID_FLAC, AV_CODEC_ID_VORBIS, AV_CODEC_ID_OPUS] {
            #expect(avcodec_find_decoder(id) != nil, "royalty-free decoder missing for \(String(cString: avcodec_get_name(id)))")
        }
    }
}
