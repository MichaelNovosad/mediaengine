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

    /// The codec profiles compiled into this build. Today only `.core`: optional modules arrive with the
    /// packaging decision D-E11, and until then nothing outside `.core` is ever reported as available.
    public static var availableProfiles: CodecProfile { .core }

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
