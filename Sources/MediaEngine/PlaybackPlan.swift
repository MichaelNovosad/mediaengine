import CoreMedia
import Foundation
import VideoToolbox

/// Groups of codecs that ship as separate, opt-in modules (see `docs/RESEARCH.md` section 3).
public struct CodecProfile: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Demuxing, remuxing, royalty-free audio and subtitles. Always available.
    public static let core = CodecProfile(rawValue: 1 << 0)
    /// Software decoders for codecs Apple does not decode (legacy video formats, VP9).
    public static let extended = CodecProfile(rawValue: 1 << 1)
    /// Dolby TrueHD (and MLP) decoders. Patent-licensed; off until legally cleared.
    public static let licensedAudio = CodecProfile(rawValue: 1 << 2)
    /// The original DTS core (DTS Coherent Acoustics, up to 5.1 channels), converted to Apple Lossless. DTS-HD, DTS Express
    /// and DTS:X are not decoded: a DTS-HD or DTS:X track plays the DTS core it carries; DTS Express, which has none, does not
    /// play. Opt-in: the integrator weighs the patent position (`docs/PATENT_PROFILES.md`).
    public static let dtsCore = CodecProfile(rawValue: 1 << 3)
    /// A software H.264 decoder, used only when Apple's decoder on this device refuses the stream (High 10, High 4:2:2, High 4:4:4:
    /// see ``Codec/appleDecodes``). Such video plays on the software path. Opt-in: the integrator weighs the patent position
    /// (`docs/PATENT_PROFILES.md`).
    public static let h264Software = CodecProfile(rawValue: 1 << 4)
    /// A software HEVC decoder, used only when Apple's decoder on this device refuses the stream (typically 4:2:2 and 4:4:4 range
    /// extensions). Such video plays on the software path. Opt-in: the integrator weighs the patent position.
    public static let hevcSoftware = CodecProfile(rawValue: 1 << 5)
    /// AAC, AC-3 and E-AC-3 decoders of the engine, used only when Apple cannot play a track (AAC Main, SSR, LTP; a missing system
    /// decoder); the sound is converted to Apple Lossless. Opt-in: the integrator weighs the patent position (AAC).
    public static let audioFallback = CodecProfile(rawValue: 1 << 6)
}

/// What the engine does with one track.
public enum TrackTreatment: Sendable, Equatable, Codable {
    /// Apple's own decoders play the track as is.
    case passthrough
    /// The engine decodes the audio and re-encodes it with Apple's encoder (always lossless ALAC today).
    case transcodeAudio(AudioTarget)
    /// Text subtitles converted to WebVTT for the system player.
    case convertToWebVTT
    /// Picture subtitles drawn by the app on top of the video.
    case bitmapOverlay
    /// Decoded by the engine's software decoders; needs the given profile.
    case software(CodecProfile)
    /// This build cannot play the track.
    case unavailable(UnavailableReason)
}

public enum AudioTarget: String, Sendable, Codable {
    case aac
    /// Apple Lossless: keeps lossless sources lossless.
    case alac
}

public struct UnavailableReason: Sendable, Equatable, Codable {
    public enum Code: String, Sendable, Codable {
        /// An optional codec module that this build does not include would play it.
        case needsCodecProfile
        /// Held back until a legal review clears it.
        case pendingLegalClearance
        /// Deliberately unsupported. (H.264 High 10 was reported this way until the ``CodecProfile/h264Software`` module.)
        case outOfScope
        /// A profile of a supported codec that Apple's decoders do not handle.
        case unsupportedProfile
        /// The codec is not one the engine knows.
        case unknownCodec
    }

    public var code: Code
    /// A plain-English explanation; apps should localize their own message from `code`.
    public var detail: String
    /// The module that would make the track playable, when there is one.
    public var requires: CodecProfile?
}

public struct TrackPlan: Sendable, Equatable, Codable {
    public var trackID: Int
    public var kind: Track.Kind
    public var treatment: TrackTreatment
    /// The profile this track needs, even when this build does not include it.
    public var requiredProfile: CodecProfile
}

public enum PlaybackPath: String, Sendable, Codable {
    /// AVFoundation plays the file as is.
    case native
    /// The engine repackages the file for AVPlayer; system UI, AirPlay and PiP stay available.
    case remux
    /// The engine's software decoders render the video.
    case software
    /// This build cannot play the video. See ``PlaybackPlan/blockingReason``.
    case unsupported
}

public struct PlaybackPlan: Sendable, Equatable, Codable {
    public var path: PlaybackPath
    public var tracks: [TrackPlan]
    /// Union of what the tracks need. Hosts use it to decide what to allow, for example whether to offer an upgrade.
    public var requiredProfile: CodecProfile
    /// Why the file cannot be played, when `path` is `.unsupported`.
    public var blockingReason: UnavailableReason?
    /// Things worth telling the person, such as an audio track that cannot be played.
    public var notes: [String]
}

/// What the current device and build can do.
struct DeviceCapabilities: Sendable {
    var hardwareAV1: Bool
    var availableProfiles: CodecProfile
    /// Whether the device decodes Dolby Vision (profiles 5 and 8 then reach AVPlayer as Dolby Vision).
    var dolbyVision = true

    static var current: DeviceCapabilities {
        DeviceCapabilities(
            // `MEDIAENGINE_DISABLE_HARDWARE_AV1=1` makes the engine decode AV1 in software on Macs and iPhones that have a
            // hardware decoder (tests, and a way to compare the two when a picture looks wrong).
            hardwareAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
                && ProcessInfo.processInfo.environment["MEDIAENGINE_DISABLE_HARDWARE_AV1"] == nil,
            availableProfiles: MediaEngine.availableProfiles,
            dolbyVision: AppleDecoding.decodesDolbyVision)
    }
}

enum PlaybackPlanner {
    private struct Decision {
        var treatment: TrackTreatment
        var needs: CodecProfile = []
    }

    static func plan(container: Container, tracks: [Track], capabilities: DeviceCapabilities) -> PlaybackPlan {
        var plans: [TrackPlan] = []
        var notes: [String] = []
        for track in tracks {
            var decision = decide(track, capabilities)
            if !decision.needs.isEmpty, !capabilities.availableProfiles.isSuperset(of: decision.needs),
               !isUnavailable(decision.treatment) {
                decision.treatment = .unavailable(UnavailableReason(
                    code: .needsCodecProfile,
                    detail: "\(track.codec.displayName) needs an optional module that this build does not include.",
                    requires: decision.needs))
            }
            plans.append(TrackPlan(trackID: track.id, kind: track.kind, treatment: decision.treatment,
                                   requiredProfile: decision.needs))
            if track.kind == .audio, case .unavailable(let reason) = decision.treatment {
                notes.append("Audio track \(track.id) (\(track.codec.displayName)) cannot be played: \(reason.detail)")
            }
        }

        // Legacy containers are grouped with the extended module (RESEARCH.md section 24): the host gates them like its codecs.
        let containerNeeds = legacyContainerProfile(container, tracks)
        var required = plans.reduce(into: CodecProfile()) { $0.formUnion($1.requiredProfile) }
        required.formUnion(containerNeeds)
        if !containerNeeds.isEmpty, !capabilities.availableProfiles.isSuperset(of: containerNeeds) {
            let reason = UnavailableReason(code: .needsCodecProfile,
                                           detail: "\(containerName(container)) files need an optional module that this build does not include.",
                                           requires: containerNeeds)
            return PlaybackPlan(path: .unsupported, tracks: plans, requiredProfile: required, blockingReason: reason, notes: notes)
        }
        let primaryVideo = tracks.first { $0.kind == .video }
        let videoPlan = primaryVideo.flatMap { video in plans.first { $0.trackID == video.id } }

        if let videoPlan, case .unavailable(let reason) = videoPlan.treatment {
            return PlaybackPlan(path: .unsupported, tracks: plans, requiredProfile: required,
                                blockingReason: reason, notes: notes)
        }

        let audioPlans = plans.filter { $0.kind == .audio }
        if !audioPlans.isEmpty, !audioPlans.contains(where: { !isUnavailable($0.treatment) }) {
            notes.append("None of the audio tracks can be played, so the video would be silent.")
        }

        let usesSoftware = plans.contains { plan in
            plan.kind != .subtitle && { if case .software = plan.treatment { true } else { false } }()
        }
        let allNative = plans.allSatisfy { plan in
            switch plan.kind {
            case .video, .audio: plan.treatment == .passthrough
            case .subtitle: isNativeSubtitle(tracks.first { $0.id == plan.trackID }?.codec.name)
            }
        }
        let path: PlaybackPath = usesSoftware ? .software : (container.kind == .mp4 && allNative ? .native : .remux)
        return PlaybackPlan(path: path, tracks: plans, requiredProfile: required, blockingReason: nil, notes: notes)
    }

    // MARK: Decisions

    /// AVI, Flash video, RealMedia and ASF, and Ogg with a video track (OGM, Ogg Theora), need the extended module.
    private static func legacyContainerProfile(_ container: Container, _ tracks: [Track]) -> CodecProfile {
        switch container.kind {
        case .avi, .asf, .flv, .realMedia: .extended
        case .ogg: tracks.contains { $0.kind == .video } ? .extended : []
        default: []
        }
    }

    private static func containerName(_ container: Container) -> String {
        switch container.kind {
        case .avi: "AVI"
        case .asf: "Windows Media (ASF)"
        case .flv: "Flash video (FLV)"
        case .realMedia: "RealMedia"
        case .ogg: "Ogg video (OGM)"
        default: container.formatName
        }
    }

    private static func isUnavailable(_ treatment: TrackTreatment) -> Bool {
        if case .unavailable = treatment { true } else { false }
    }

    private static func isNativeSubtitle(_ name: String?) -> Bool {
        name == "mov_text" || name == "webvtt"
    }

    private static func unavailable(_ code: UnavailableReason.Code, _ detail: String, requires: CodecProfile? = nil) -> Decision {
        Decision(treatment: .unavailable(UnavailableReason(code: code, detail: detail, requires: requires)))
    }

    private static func decide(_ track: Track, _ capabilities: DeviceCapabilities) -> Decision {
        let name = track.codec.name
        switch track.kind {
        case .video: return decideVideo(track, name, capabilities)
        case .audio: return decideAudio(track, name)
        case .subtitle: return decideSubtitle(name)
        }
    }

    private static func decideVideo(_ track: Track, _ name: String, _ capabilities: DeviceCapabilities) -> Decision {
        switch name {
        case "h264":
            // Apple first (owner, 2026-11-12). Every Apple device decodes Baseline, Main, Extended and High (8-bit 4:2:0); other
            // profiles were asked at probe time (`Codec.appleDecodes`; measured 2026-11-12: Apple's hardware decodes High 10 on an
            // M1 Max). Only when Apple refuses, High 10, High 4:2:2 and High 4:4:4 (and their intra variants, which share the
            // profile numbers) go to the engine's own decoder (opt-in `h264Software`). Anything else (SVC, MVC) is not supported.
            guard let profile = track.codec.profileIdentifier, !AppleDecoding.alwaysH264Profiles.contains(profile) else {
                return Decision(treatment: .passthrough)
            }
            if track.codec.appleDecodes == true { return Decision(treatment: .passthrough) }
            if [110, 122, 244, 44].contains(profile) {
                return Decision(treatment: .software(.h264Software), needs: .h264Software)
            }
            return unavailable(.unsupportedProfile, "H.264 \(track.codec.profile ?? "\(profile)") video is not supported.")
        case "hevc":
            // Dolby Vision profile 5 has no HDR10 base layer: without a Dolby Vision decoder its colours come out wrong.
            if case .dolbyVision(let dolbyProfile, _, _)? = track.video?.hdr, dolbyProfile == 5, !capabilities.dolbyVision {
                return unavailable(.unsupportedProfile, "Dolby Vision profile 5 video needs a device that decodes Dolby Vision.")
            }
            // Apple first, as for H.264: Main, Main 10 and Main Still Picture everywhere; range extensions (4:2:2, 4:4:4) when this
            // device's decoder accepts them, else the engine's own decoder (opt-in `hevcSoftware`).
            guard let profile = track.codec.profileIdentifier, !AppleDecoding.alwaysHEVCProfiles.contains(profile) else {
                return Decision(treatment: .passthrough)
            }
            if track.codec.appleDecodes == true { return Decision(treatment: .passthrough) }
            if profile == 4 { return Decision(treatment: .software(.hevcSoftware), needs: .hevcSoftware) }
            return unavailable(.unsupportedProfile, "HEVC \(track.codec.profile ?? "\(profile)") video is not supported.")
        case "av1":
            return capabilities.hardwareAV1
                ? Decision(treatment: .passthrough)
                : Decision(treatment: .software(.extended), needs: .extended)
        case "prores":
            return Decision(treatment: .passthrough)
        case "vp9", "vp8", "mpeg1video", "mpeg2video", "mpeg4", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3",
             "wmv1", "wmv2", "theora", "h263", "h263i", "h263p", "flv1", "vp6", "vp6f", "vp6a", "rv10", "rv20", "rv30", "rv40":
            return Decision(treatment: .software(.extended), needs: .extended)
        case "vc1", "wmv3":
            return unavailable(.pendingLegalClearance, "\(track.codec.displayName) video is held back until its licensing is cleared.")
        default:
            return unavailable(.unknownCodec, "The video format \(name) is not supported.")
        }
    }

    private static func decideAudio(_ track: Track, _ name: String) -> Decision {
        switch name {
        case "aac", "ac3", "eac3":
            // Apple first (owner, 2026-11-12): passthrough unless the probe found Apple cannot play it (`Codec.appleDecodes`:
            // AAC Main, SSR, LTP; no system decoder); then the engine's own decoder, converted to ALAC (opt-in `audioFallback`).
            if track.codec.appleDecodes == false { return Decision(treatment: .transcodeAudio(.alac), needs: .audioFallback) }
            return Decision(treatment: .passthrough)
        case "alac", "mp3":
            return Decision(treatment: .passthrough)
        case "flac":
            return Decision(treatment: .transcodeAudio(.alac))
        case "opus", "vorbis":
            return Decision(treatment: .transcodeAudio(.alac))
        case _ where name.hasPrefix("pcm_"):
            return Decision(treatment: .transcodeAudio(.alac))
        case "dts":
            // Only the DTS core is decoded (`CodecProfile.dtsCore`); DTS-HD and DTS:X tracks carry one. DTS Express
            // (FFmpeg's profile 70) has no core.
            if track.codec.profileIdentifier == 70 {
                return unavailable(.unsupportedProfile, "DTS Express audio has no DTS core and is not supported.")
            }
            return Decision(treatment: .transcodeAudio(.alac), needs: .dtsCore)
        case "truehd", "mlp":
            return Decision(treatment: .transcodeAudio(.alac), needs: .licensedAudio)
        // AVPlayer does not play MPEG audio layer II in the engine's HLS stream; the extended build decodes it.
        case "mp2", "adpcm_ms", "adpcm_ima_wav":
            return Decision(treatment: .transcodeAudio(.alac), needs: .extended)
        // The conversion works a segment at a time, which these codecs' frames (spanning packets) do not allow yet.
        case "wmav1", "wmav2", "cook", "ra_144", "ra_288":
            return unavailable(.unknownCodec, "The audio format \(track.codec.displayName) is not supported by this version.")
        default:
            return unavailable(.unknownCodec, "The audio format \(name) is not supported.")
        }
    }

    private static func decideSubtitle(_ name: String) -> Decision {
        switch name {
        case "subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "microdvd":
            return Decision(treatment: .convertToWebVTT)
        case "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub":
            return Decision(treatment: .bitmapOverlay)
        default:
            return unavailable(.unknownCodec, "The subtitle format \(name) is not supported.")
        }
    }
}
