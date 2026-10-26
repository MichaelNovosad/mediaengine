// swift-tools-version: 6.2
import PackageDescription

// The smallest possible client of MediaEngine: one executable that prints what the linked FFmpeg framework can do.
// scripts/test-framework-swap.sh builds it, then replaces FFmpegLGPL.framework next to it with another build and runs it again
// without relinking (LIC-2).
let package = Package(
    name: "SwapProbe",
    platforms: [.macOS("27.0")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "SwapProbe", dependencies: [.product(name: "MediaEngine", package: "MediaEngine")],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
