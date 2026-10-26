import Testing
@testable import MediaEngine

@Suite("Playback planner")
struct PlaybackPlannerTests {
    private let matroska = Container(kind: .matroska, formatName: "matroska,webm")
    private let mp4 = Container(kind: .mp4, formatName: "mov,mp4,m4a,3gp,3g2,mj2")
    private let coreOnly = DeviceCapabilities(hardwareAV1: true, availableProfiles: .core)
    private let withExtended = DeviceCapabilities(hardwareAV1: false, availableProfiles: [.core, .extended])
    private let everything = DeviceCapabilities(hardwareAV1: false, availableProfiles: [.core, .extended, .licensedAudio])

    private func plan(_ tracks: [Track], in container: Container? = nil, _ caps: DeviceCapabilities? = nil) -> PlaybackPlan {
        PlaybackPlanner.plan(container: container ?? matroska, tracks: tracks, capabilities: caps ?? coreOnly)
    }

    private func video(_ codec: String, profile: String? = nil, id: Int? = nil) -> Track {
        makeTrack(id: 0, kind: .video, codec: codec, profile: profile, profileID: id)
    }
    private func audio(_ codec: String, id: Int = 1) -> Track { makeTrack(id: id, kind: .audio, codec: codec) }

    @Test("H.264 High 10 (Hi10P) is out of scope and no module can fix it")
    func hi10p() {
        let result = plan([video("h264", profile: "High 10", id: 110), audio("aac")])
        #expect(result.path == .unsupported)
        #expect(result.blockingReason?.code == .outOfScope)
        #expect(result.blockingReason?.requires == nil)
        #expect(result.requiredProfile.isEmpty)
    }

    @Test("ordinary H.264 and HEVC Main profiles play through Apple's decoders")
    func appleDecoders() {
        for track in [video("h264", profile: "High", id: 100), video("h264", profile: "Main", id: 77), video("hevc", profile: "Main 10", id: 2)] {
            let result = plan([track, audio("ac3")])
            #expect(result.path == .remux)
            #expect(result.tracks.map(\.treatment) == [.passthrough, .passthrough])
        }
    }

    @Test("HEVC range-extension profiles are unsupported")
    func hevcRext() {
        let result = plan([video("hevc", profile: "Format Range Extensions", id: 4)])
        #expect(result.path == .unsupported)
        #expect(result.blockingReason?.code == .unsupportedProfile)
    }

    @Test("AV1 plays on hardware where available, otherwise needs the extended module")
    func av1() {
        #expect(plan([video("av1"), audio("opus")], coreOnly).path == .remux)

        let noHardware = DeviceCapabilities(hardwareAV1: false, availableProfiles: .core)
        let blocked = plan([video("av1"), audio("opus")], noHardware)
        #expect(blocked.path == .unsupported)
        #expect(blocked.blockingReason?.code == .needsCodecProfile)
        #expect(blocked.blockingReason?.requires == .extended)
        #expect(blocked.requiredProfile == .extended)

        let playable = plan([video("av1"), audio("opus")], withExtended)
        #expect(playable.path == .software)
        #expect(playable.requiredProfile == .extended)
    }

    @Test("legacy video needs the extended module; VC-1 waits for legal clearance")
    func legacyVideo() {
        for codec in ["vp9", "mpeg4", "mpeg2video", "theora"] {
            #expect(plan([video(codec)], coreOnly).blockingReason?.requires == .extended, "\(codec)")
            #expect(plan([video(codec)], withExtended).path == .software, "\(codec)")
        }
        let vc1 = plan([video("vc1")], withExtended)
        #expect(vc1.path == .unsupported)
        #expect(vc1.blockingReason?.code == .pendingLegalClearance)
    }

    @Test("audio decisions: passthrough or lossless ALAC transcode")
    func audioDecisions() {
        func treatment(_ codec: String) -> TrackTreatment? {
            plan([video("h264", profile: "High", id: 100), audio(codec)], everything).tracks.last?.treatment
        }
        for codec in ["aac", "ac3", "eac3", "alac", "mp3"] { #expect(treatment(codec) == .passthrough, "\(codec)") }
        #expect(treatment("flac") == .transcodeAudio(.alac))
        #expect(treatment("pcm_s24le") == .transcodeAudio(.alac))
        #expect(treatment("opus") == .transcodeAudio(.alac))
        #expect(treatment("vorbis") == .transcodeAudio(.alac))
        #expect(treatment("dts") == .transcodeAudio(.alac))
        #expect(treatment("truehd") == .transcodeAudio(.alac))
    }

    @Test("DTS-only audio keeps the video playable but warns about silence")
    func dtsOnly() {
        let result = plan([video("h264", profile: "High", id: 100), audio("dts")], coreOnly)
        #expect(result.path == .remux)
        #expect(result.requiredProfile == .licensedAudio)
        #expect(result.notes.contains { $0.contains("silent") })
        guard case .unavailable(let reason) = result.tracks[1].treatment else { Issue.record("expected unavailable"); return }
        #expect(reason.requires == .licensedAudio)
    }

    @Test("one playable audio track is enough: no silence warning")
    func oneGoodAudioTrack() {
        let result = plan([video("h264", profile: "High", id: 100), audio("dts", id: 1), audio("ac3", id: 2)], coreOnly)
        #expect(!result.notes.contains { $0.contains("silent") })
        #expect(result.notes.count == 1)
    }

    @Test("subtitles: text becomes WebVTT, pictures become overlays")
    func subtitles() {
        let tracks = [video("h264", profile: "High", id: 100), audio("aac"),
                      makeTrack(id: 2, kind: .subtitle, codec: "ass"), makeTrack(id: 3, kind: .subtitle, codec: "hdmv_pgs_subtitle"),
                      makeTrack(id: 4, kind: .subtitle, codec: "mystery")]
        let treatments = plan(tracks).tracks.map(\.treatment)
        #expect(treatments[2] == .convertToWebVTT)
        #expect(treatments[3] == .bitmapOverlay)
        if case .unavailable(let reason) = treatments[4] { #expect(reason.code == .unknownCodec) } else { Issue.record("expected unavailable") }
    }

    @Test("MP4 with Apple codecs and timed text plays natively; anything the engine converts is a remux")
    func nativeVersusRemux() {
        let native = plan([video("h264", profile: "High", id: 100), audio("aac"), makeTrack(id: 2, kind: .subtitle, codec: "mov_text")], in: mp4)
        #expect(native.path == .native)
        let withFlac = plan([video("h264", profile: "High", id: 100), audio("flac")], in: mp4)
        #expect(withFlac.path == .remux)
        let matroskaSame = plan([video("h264", profile: "High", id: 100), audio("aac")])
        #expect(matroskaSame.path == .remux)
    }

    @Test("audio-only files have a plan too")
    func audioOnly() {
        let result = plan([audio("flac", id: 0)])
        #expect(result.path == .remux)
        #expect(result.blockingReason == nil)
    }

    // MARK: Legacy containers and codecs (ANM-8, SWD-3)

    private let avi = Container(kind: .avi, formatName: "avi")
    private let flv = Container(kind: .flv, formatName: "flv")
    private let realMedia = Container(kind: .realMedia, formatName: "rm")
    private let asf = Container(kind: .asf, formatName: "asf")
    private let ogg = Container(kind: .ogg, formatName: "ogg")

    @Test("every legacy video codec is decoded by software and needs the extended module", arguments: [
        "mpeg1video", "mpeg2video", "mpeg4", "msmpeg4v3", "wmv2", "h263", "h263p", "flv1", "vp6f", "rv10", "rv20", "rv30", "rv40", "vp8", "vp9", "theora",
    ])
    func legacyVideo(codec: String) {
        let result = plan([video(codec), audio("mp3")], in: matroska, withExtended)
        #expect(result.path == .software && result.requiredProfile == .extended, "\(codec): \(result.path)")
        let missing = plan([video(codec), audio("mp3")], in: matroska, coreOnly)
        #expect(missing.path == .unsupported && missing.blockingReason?.code == .needsCodecProfile && missing.blockingReason?.requires == .extended)
    }

    @Test("legacy audio codecs the engine converts need the extended module", arguments: ["mp2", "adpcm_ms", "adpcm_ima_wav"])
    func legacyAudio(codec: String) {
        let result = plan([video("h264", profile: "High", id: 100), audio(codec)], in: matroska, withExtended)
        #expect(result.tracks[1].treatment == .transcodeAudio(.alac) && result.tracks[1].requiredProfile == .extended)
        #expect(result.path == .remux)
        let noModule = plan([video("h264", profile: "High", id: 100), audio(codec)], in: matroska, coreOnly)
        if case .unavailable(let reason) = noModule.tracks[1].treatment { #expect(reason.code == .needsCodecProfile) } else { Issue.record("playable without the module") }
    }

    @Test("audio that cannot be converted a segment at a time is reported as unavailable, in every build", arguments: ["wmav1", "wmav2", "cook", "ra_144", "ra_288"])
    func notConverted(codec: String) {
        for capabilities in [coreOnly, withExtended] {
            let result = plan([video("mpeg4"), audio(codec)], in: avi, capabilities)
            if case .unavailable = result.tracks[1].treatment {} else { Issue.record("\(codec) is playable") }
        }
    }

    @Test("AVI, Flash video, RealMedia and ASF files need the extended module even when Apple decodes what is inside", arguments: [0, 1, 2, 3])
    func legacyContainers(which: Int) {
        let container = [avi, flv, realMedia, asf][which]
        let tracks = [video("h264", profile: "High", id: 100), audio("aac")]
        let with = plan(tracks, in: container, withExtended)
        #expect(with.path == .remux && with.requiredProfile == .extended, "\(container.kind): \(with.path) \(with.requiredProfile)")
        let without = plan(tracks, in: container, coreOnly)
        #expect(without.path == .unsupported && without.requiredProfile == .extended)
        #expect(without.blockingReason?.code == .needsCodecProfile && without.blockingReason?.requires == .extended)
        #expect(without.blockingReason?.detail.contains("files need an optional module") == true, "\(without.blockingReason?.detail ?? "")")
    }

    @Test("Ogg needs the module only when it carries video (OGM, Ogg Theora): Vorbis and Opus files stay in core")
    func oggVideo() {
        #expect(plan([audio("vorbis", id: 0)], in: ogg, coreOnly).path == .remux)
        #expect(plan([audio("opus", id: 0)], in: ogg, coreOnly).requiredProfile.isEmpty)
        let ogm = plan([video("mpeg4"), audio("vorbis")], in: ogg, coreOnly)
        #expect(ogm.path == .unsupported && ogm.requiredProfile == .extended)
        #expect(plan([video("mpeg4"), audio("vorbis")], in: ogg, withExtended).path == .software)
    }

    @Test("Matroska, MP4 and the other core containers are never held back by the container rule")
    func coreContainers() {
        for container in [matroska, mp4, Container(kind: .mpegTS, formatName: "mpegts"), Container(kind: .mpegPS, formatName: "mpeg"), Container(kind: .wav, formatName: "wav")] {
            let result = plan([video("h264", profile: "High", id: 100), audio("aac")], in: container, coreOnly)
            #expect(result.path != .unsupported && result.requiredProfile.isEmpty, "\(container.kind)")
        }
    }
}
