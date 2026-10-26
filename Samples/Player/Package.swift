// swift-tools-version: 6.2
import PackageDescription

// A small but complete player built on MediaEngine for iOS, iPadOS, macOS and visionOS: pick a file, play it (system player or
// the software player, whichever the file needs), switch audio and subtitle tracks, add an external subtitle file, see what the file
// needs from the optional codec module, and read the licences. scripts/check-samples.sh builds it for all three platforms.
let package = Package(
    name: "Player",
    platforms: [.iOS("27.0"), .macOS("27.0"), .visionOS("27.0")],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(name: "Player", dependencies: [.product(name: "MediaEngine", package: "MediaEngine")],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
