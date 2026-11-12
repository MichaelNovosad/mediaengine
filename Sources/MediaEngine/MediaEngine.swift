internal import FFmpegLGPL
import Synchronization

/// Entry point for facts about the engine build.
///
/// The media engine is built on FFmpeg under the LGPL. Apps must show the acknowledgements
/// this information feeds into (see the integration guide).
public enum MediaEngine {
    /// Facts about the bundled FFmpeg build.
    public struct BuildInfo: Sendable, Equatable {
        /// Version of the bundled FFmpeg release, for example "9.0.2".
        public let ffmpegVersion: String
        /// License FFmpeg was built under. Always an LGPL string in shipped builds.
        public let ffmpegLicense: String
    }

    /// The codec profiles this build contains, found by asking the linked FFmpeg which decoders it has: `.core` always,
    /// `.extended` in the extended variant (legacy containers and software decoders), `.dtsCore`, `.h264Software`,
    /// `.hevcSoftware` and `.audioFallback` in the `extended-plus` variant (the DTS core, and the engine's own decoders for
    /// what Apple's decoders refuse on this device: Apple first), `.licensedAudio`
    /// in a build with the TrueHD decoder. Which binary an app links is decided when it picks the package variant
    /// (`docs/RESEARCH.md` section 24); a host that gates features by profile reads ``MediaInfo/requiredProfile``.
    /// Profiles in ``disabledProfiles`` are left out.
    public static var availableProfiles: CodecProfile { detectedProfiles.subtracting(disabledProfiles) }

    /// Profiles the host switches off while the app runs, for example in a country where it does not want a module used. Files
    /// probed afterwards plan as if the binary lacked them: their tracks are `needsCodecProfile`, and other tracks still play.
    /// `.core` cannot be switched off. Thread-safe.
    public static var disabledProfiles: CodecProfile {
        get { disabled.withLock { $0 } }
        set { disabled.withLock { $0 = newValue.subtracting(.core) } }
    }

    private static let disabled = Mutex<CodecProfile>([])

    private static let detectedProfiles: CodecProfile = {
        var profiles: CodecProfile = .core
        if avcodec_find_decoder_by_name("mpeg4") != nil, avcodec_find_decoder_by_name("vp9") != nil, av_find_input_format("rm") != nil {
            profiles.insert(.extended)
        }
        // Every build of ours decodes only the DTS core (third_party/patches/ffmpeg-0001-dts-core-only.diff).
        if avcodec_find_decoder_by_name("dca") != nil { profiles.insert(.dtsCore) }
        if avcodec_find_decoder_by_name("h264") != nil { profiles.insert(.h264Software) }
        if avcodec_find_decoder_by_name("hevc") != nil { profiles.insert(.hevcSoftware) }
        if avcodec_find_decoder_by_name("aac") != nil, avcodec_find_decoder_by_name("ac3") != nil,
           avcodec_find_decoder_by_name("eac3") != nil { profiles.insert(.audioFallback) }
        if avcodec_find_decoder_by_name("truehd") != nil { profiles.insert(.licensedAudio) }
        return profiles
    }()

    /// Package traits that were enabled when this build was made (see `Package.swift`).
    public static var enabledTraits: [String] {
        var traits: [String] = []
        #if Subtitles
        traits.append("Subtitles")
        #endif
        #if SoftwareDecoding
        traits.append("SoftwareDecoding")
        #endif
        #if LicensedAudio
        traits.append("LicensedAudio")
        #endif
        #if DolbyVision
        traits.append("DolbyVision")
        #endif
        return traits
    }

    /// Information about the bundled FFmpeg build.
    public static var buildInfo: BuildInfo {
        BuildInfo(
            ffmpegVersion: String(cString: av_version_info()),
            ffmpegLicense: String(cString: avutil_license())
        )
    }
}
