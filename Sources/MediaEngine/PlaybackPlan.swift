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
    /// DTS and TrueHD decoders. Patent-licensed; off until legally cleared.
    public static let licensedAudio = CodecProfile(rawValue: 1 << 2)
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
        /// Deliberately unsupported (for example H.264 High 10).
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

    static var current: DeviceCapabilities {
        DeviceCapabilities(
            hardwareAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            availableProfiles: MediaEngine.availableProfiles)
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

        let required = plans.reduce(into: CodecProfile()) { $0.formUnion($1.requiredProfile) }
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
            // Apple decodes Baseline, Main, Extended and High (8-bit 4:2:0). Hi10P and the 4:2:2 / 4:4:4
            // profiles are out of scope by owner decision (2026-10-24): no software H.264 decoder ships.
            if let profile = track.codec.profileIdentifier, ![66, 77, 88, 100].contains(profile) {
                return unavailable(.outOfScope, "H.264 \(track.codec.profile ?? "High 10") video is not supported.")
            }
            return Decision(treatment: .passthrough)
        case "hevc":
            if let profile = track.codec.profileIdentifier, ![1, 2, 3].contains(profile) {
                return unavailable(.unsupportedProfile, "HEVC \(track.codec.profile ?? "extended") profiles are not supported.")
            }
            return Decision(treatment: .passthrough)
        case "av1":
            return capabilities.hardwareAV1
                ? Decision(treatment: .passthrough)
                : Decision(treatment: .software(.extended), needs: .extended)
        case "prores":
            return Decision(treatment: .passthrough)
        case "vp9", "vp8", "mpeg1video", "mpeg2video", "mpeg4", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3",
             "wmv1", "wmv2", "theora":
            return Decision(treatment: .software(.extended), needs: .extended)
        case "vc1", "wmv3":
            return unavailable(.pendingLegalClearance, "\(track.codec.displayName) video is held back until its licensing is cleared.")
        default:
            return unavailable(.unknownCodec, "The video format \(name) is not supported.")
        }
    }

    private static func decideAudio(_ track: Track, _ name: String) -> Decision {
        switch name {
        case "aac", "ac3", "eac3", "alac", "mp3", "mp2":
            return Decision(treatment: .passthrough)
        case "flac":
            return Decision(treatment: .transcodeAudio(.alac))
        case "opus", "vorbis":
            return Decision(treatment: .transcodeAudio(.alac))
        case _ where name.hasPrefix("pcm_"):
            return Decision(treatment: .transcodeAudio(.alac))
        case "dts":
            return Decision(treatment: .transcodeAudio(.alac), needs: .licensedAudio)
        case "truehd", "mlp":
            return Decision(treatment: .transcodeAudio(.alac), needs: .licensedAudio)
        case "wmav1", "wmav2":
            return Decision(treatment: .transcodeAudio(.alac), needs: .extended)
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
