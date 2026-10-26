# Optional codec modules

Decoders for patent-sensitive or rarely needed formats are not part of the default binary. They live in separate **profiles**, and the
package is delivered in variants that contain them or not.

## Profiles

| ``CodecProfile`` | Contains | Default binary |
|---|---|---|
| `core` | Matroska, WebM, MPEG-TS and friends; FLAC, Opus, Vorbis, PCM; subtitles (SRT, ASS, WebVTT, PGS, VobSub, DVB) | yes |
| `extended` | AVI, FLV, RealMedia, OGM files; software decoders for MPEG-1/2/4, WMV, Flash video, RealVideo, VP8, VP9, Theora and AV1 (dav1d) | the *extended* variant only |
| `licensedAudio` | DTS, DTS-HD and TrueHD | no (patent licensing; off until cleared) |

Apple's own decoders decode H.264, HEVC, AAC, AC-3 and E-AC-3 in every variant; the engine only repackages them.

## Gating in your app

The engine never decides what is allowed: you do.

```swift
let info = try await MediaSource(url: fileURL).probe()
if info.requiredProfile.contains(.extended) && !userHasPro {
    showUpgrade()                                         // "this format is part of Pro"
} else {
    try await play(info)
}
```

``MediaEngine/availableProfiles`` says which profiles the linked binary actually contains. A file that needs a module the binary lacks has
``PlaybackPath/unsupported`` and a ``PlaybackPlan/blockingReason`` of code `needsCodecProfile` that names the module.

## Choosing the variant

Link `FFmpegLGPL.xcframework` (core) or `FFmpegLGPL-extended.xcframework`: same module name inside, so no code changes
(`MEDIAENGINE_PROFILE=extended` picks it in this repository's `Package.swift`). The extended binary is about twice the size.
Patent licences for what you enable are your responsibility: see `docs/PATENT_PROFILES.md`.
