// swift-tools-version: 6.2
import PackageDescription

// The five-line quick start as a complete SwiftUI app: pick a video file, play it. The only setup is the package dependency
// below (no bridging header, build phase, manual embed or framework search path). scripts/check-samples.sh builds it for
// macOS, iOS and visionOS. In your own app, add MediaEngine through File > Add Package Dependencies instead of the path.
let package = Package(
    name: "QuickStart",
    platforms: [.iOS("27.0"), .macOS("27.0"), .visionOS("27.0")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "QuickStart", dependencies: [.product(name: "MediaEngine", package: "MediaEngine")],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
