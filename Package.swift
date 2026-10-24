// swift-tools-version: 6.2
import PackageDescription

// Local development manifest: the FFmpeg framework is the artifact built by scripts/package-xcframework.sh.
// Release manifests point `FFmpegLGPL` at a versioned, checksummed download instead.
let package = Package(
    name: "MediaEngine",
    platforms: [.iOS("27.0"), .macOS("27.0"), .visionOS("27.0")],
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
        .binaryTarget(name: "FFmpegLGPL", path: "build/FFmpegLGPL.xcframework"),
        .target(
            name: "MediaEngine",
            dependencies: ["FFmpegLGPL"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaEngineTests",
            dependencies: ["MediaEngine", "FFmpegLGPL"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
