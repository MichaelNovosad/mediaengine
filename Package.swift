// swift-tools-version: 6.2
import PackageDescription

// Local development manifest: the FFmpeg framework is the artifact built by scripts/package-xcframework.sh.
// Release manifests point `FFmpegLGPL` at a versioned, checksummed download instead.
// MEDIAENGINE_SANITIZED_FFMPEG=1 swaps in the AddressSanitizer-instrumented macOS framework (scripts/check-sanitized.sh).
// MEDIAENGINE_PROFILE=extended builds against the variant that also contains the legacy containers and software decoders
// (scripts/package-xcframework.sh core+extended); the default is the core binary. Release manifests do the same per product.
let profile = Context.environment["MEDIAENGINE_PROFILE"] ?? "core"
let ffmpegFramework = Context.environment["MEDIAENGINE_SANITIZED_FFMPEG"] == "1"
    ? "build/FFmpegLGPL-address.xcframework"
    : (profile == "core" ? "build/FFmpegLGPL.xcframework" : "build/FFmpegLGPL-\(profile).xcframework")

let package = Package(
    name: "MediaEngine",
    platforms: [.iOS("26.0"), .macOS("26.0"), .visionOS("26.0")],
    products: [
        .library(name: "MediaEngine", targets: ["MediaEngine"]),
    ],
    traits: [
        .default(enabledTraits: ["Subtitles"]),
        .trait(name: "Subtitles", description: "Text and bitmap subtitle decoding and rendering."),
        .trait(name: "SoftwareDecoding", description: "Software decoders for codecs Apple does not decode (extended profile)."),
        .trait(name: "LicensedAudio", description: "DTS and TrueHD decoders. Patent-licensed; see docs/RESEARCH.md section 3."),
        .trait(name: "DolbyVision", description: "Dolby Vision profile 7 conversion. Off until legally cleared."),
    ],
    targets: [
        .binaryTarget(name: "FFmpegLGPL", path: ffmpegFramework),
        // libass with FreeType, HarfBuzz and FriBidi, built by scripts/build-subtitle-libs.sh and scripts/package-subtitle-xcframework.sh.
        .binaryTarget(name: "LibASS", path: "build/LibASS.xcframework"),
        .target(
            name: "MediaEngine",
            dependencies: ["FFmpegLGPL", "LibASS"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaEngineTests",
            dependencies: ["MediaEngine", "FFmpegLGPL", "LibASS"],
            exclude: ["Corpus", "Golden"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
