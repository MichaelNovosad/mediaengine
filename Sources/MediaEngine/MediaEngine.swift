internal import FFmpegLGPL

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
    /// `.extended` in the extended variant (legacy containers and software decoders), `.licensedAudio` in a build
    /// with the DTS and TrueHD decoders. Which binary an app links is decided when it picks the package variant
    /// (`docs/RESEARCH.md` section 24); a host that gates features by profile reads ``MediaInfo/requiredProfile``.
    public static var availableProfiles: CodecProfile { detectedProfiles }

    private static let detectedProfiles: CodecProfile = {
        var profiles: CodecProfile = .core
        if avcodec_find_decoder_by_name("mpeg4") != nil, avcodec_find_decoder_by_name("vp9") != nil, av_find_input_format("rm") != nil {
            profiles.insert(.extended)
        }
        if avcodec_find_decoder_by_name("dca") != nil, avcodec_find_decoder_by_name("truehd") != nil { profiles.insert(.licensedAudio) }
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
