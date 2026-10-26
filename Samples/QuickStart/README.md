# QuickStart

A complete SwiftUI app around the engine's five-line quick start (`Sources/QuickStart/QuickStartApp.swift`):

```swift
import MediaEngine

let session = try await PlaybackSession(url: fileURL)   // probes and chooses the best path
let item = try await session.makePlayerItem()            // plain AVPlayerItem
player.replaceCurrentItem(with: item)                    // AVPlayerViewController / VideoPlayer
```

Run it on the Mac with `swift run --package-path Samples/QuickStart`, or open `Samples/QuickStart/Package.swift` in Xcode and choose an
iPhone, iPad, Mac or Apple Vision Pro destination. Choose an MKV or WebM file when the file picker opens.

In your own app: add the package (File > Add Package Dependencies), `import MediaEngine`, and use the three lines above; nothing
else has to be configured. Files that need the optional codec module (old AVI, FLV, RealMedia, MPEG-2, VP9, AV1 on devices without
an AV1 decoder) need the extended variant of the package; see `docs/RESEARCH.md` section 24.
