# Optional codec modules

Decoders for patent-sensitive or rarely needed formats are not part of the default binary. They live in separate **profiles**, and the
package is delivered in variants that contain them or not.

## Profiles

| ``CodecProfile`` | Contains | Default binary |
|---|---|---|
| `core` | Matroska, WebM, MPEG-TS and friends; FLAC, Opus, Vorbis, PCM; subtitles (SRT, ASS, WebVTT, PGS, VobSub, DVB) | yes |
| `extended` | AVI, FLV, RealMedia, OGM files; software decoders for MPEG-1/2/4, WMV, Flash video, RealVideo, VP8, VP9, Theora and AV1 (dav1d) | the *extended* variant only |
| `dtsCore` | the original DTS core (up to 5.1); DTS-HD and DTS:X tracks play the core they carry, DTS Express does not play | the *extended-plus* variant only (opt-in; patent position is yours to weigh) |
| `h264Software` | a software H.264 decoder, used when Apple's decoder refuses a stream (High 10 "Hi10P", High 4:2:2, High 4:4:4) | the *extended-plus* variant only (opt-in; patent position is yours to weigh) |
| `hevcSoftware` | a software HEVC decoder, used when Apple's decoder refuses a stream (range extensions: 4:2:2, 4:4:4) | the *extended-plus* variant only (opt-in; patent position is yours to weigh) |
| `audioFallback` | AAC, AC-3 and E-AC-3 decoders, used when Apple cannot play a track (AAC Main, SSR, LTP) | the *extended-plus* variant only (opt-in; AAC's patent position is yours to weigh) |
| `licensedAudio` | Dolby TrueHD | no (patent licensing; off until cleared) |

**Apple first.** Apple's own decoders decode H.264, HEVC, AAC, AC-3 and E-AC-3 in every variant; the engine only repackages them.
For streams outside the profiles every Apple device decodes, the probe asks this device's decoder (``Codec/appleDecodes``) and the
plan uses the engine's own decoder only when Apple refuses. Dolby Vision 5 and 8 are passed to Apple as Dolby Vision on devices that
decode it. No build decodes DTS-HD lossless or DTS Express: the FFmpeg source is patched so the DTS decoder keeps only the core.

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

To switch a module off while the app runs, for example in a country where you do not want it used, set
``MediaEngine/disabledProfiles`` before the files are probed: they then plan as if the binary lacked it.

## Choosing the variant

Link `FFmpegLGPL.xcframework` (core), `FFmpegLGPL-extended.xcframework` or `FFmpegLGPL-extended-plus.xcframework`: same
module name inside, so no code changes (`MEDIAENGINE_PROFILE=extended` or `extended-plus` picks one in this repository's
`Package.swift`). The extended binary is about twice the size of the core one.
Patent licences for what you enable are your responsibility: see `docs/PATENT_PROFILES.md`.
