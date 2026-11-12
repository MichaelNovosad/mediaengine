# Integration guide

For the app developer who adds MediaEngine to an app. The five-line quick start is in the README and in `Samples/QuickStart`.

## 1. Add the package and pick the variant

Add the package (File > Add Package Dependencies) and `import MediaEngine`. Nothing else has to be configured: no bridging header,
build phase or manual embed. The frameworks are **dynamic** (`FFmpegLGPL.framework`, `LibASS.framework`): Xcode embeds and signs them
with your identity when you build the app.

| Variant | Contains | Size per platform (arm64, stripped) |
|---|---|---|
| core (`FFmpegLGPL.xcframework`) | Matroska/WebM/TS demuxing, remuxing, royalty-free audio, subtitles | FFmpeg 2.9 MB + LibASS 2.2 MB |
| extended (`FFmpegLGPL-extended.xcframework`) | + legacy containers, software decoders (MPEG-1/2/4, WMV, Flash video, RealVideo, VP8, VP9, Theora), AV1 (dav1d) | FFmpeg 5.8 MB + LibASS 2.2 MB |

The module name is the same in both, so the Swift code does not change. In this repository `MEDIAENGINE_PROFILE=extended` selects the
extended variant; a release manifest offers it as a second product. A host that sells the legacy formats as a paid feature ships the
extended variant and gates by `requiredProfile` (below); a host that does not need them ships core.

## 2. Open, plan, play

```swift
let session = try await PlaybackSession(url: fileURL)       // file URLs (security-scoped ones too) and http(s) with range requests
let player = try await session.makeController()             // PlaybackController: system player or the software player
```

- `session.info` (`MediaInfo`): container, tracks with codec, profile, level, resolution, HDR format, languages; chapters; attachments;
  `isIncomplete` for a cut-off download.
- `session.info.playbackPlan.path`: `.native`, `.remux`, `.software` or `.unsupported`, with a reason (`blockingReason`) and per-track
  treatment. See the article *Choosing the playback path* in the DocC documentation.
- `makePlayerItem()` gives a plain `AVPlayerItem` for `.native` and `.remux` (system controls, AirPlay, PiP, HDR);
  `makeController()` gives a `PlaybackController` for every path and `MediaVideoView` shows the software player's picture.
- Keep the session alive while the item plays (the item holds it); call `close()` when you are done to stop the local server.

## 3. Gate features with `requiredProfile`

```swift
let info = try await MediaSource(url: fileURL).probe()      // reads headers only: cheap, also over the network
if info.requiredProfile.contains(.extended), !purchased { offerUpgrade(); return }
```

`requiredProfile` is `.core`, `.extended`, `.dtsCore`, `.h264Software`, `.hevcSoftware`, `.audioFallback` and/or `.licensedAudio`
(the DTS core and the engine's own decoders for what Apple's decoders refuse on the device are in the opt-in `extended-plus` variant;
see `docs/PATENT_PROFILES.md`). Apple first: a stream goes to an engine decoder only when `Codec.appleDecodes` is not `true`. The engine never gates anything itself, and `availableProfiles`
says what the linked binary contains: a file that needs a module the binary lacks plans as `.unsupported` with code `needsCodecProfile`.

## 4. Tracks, subtitles, chapters

`session.audioChoices` and `subtitleChoices` have names that stay unique when two tracks share a language; `TrackPreferences`
("Japanese audio, English subtitles") picks defaults; `session.chapters` carry kinds (opening, ending, recap) for a "Skip Opening"
button; `add(SubtitleTrack)` and `add(AudioTrack)` attach external files; `locateSegments(in:)` finds the other files of
ordered chapters. Full ASS and picture subtitles come from `makeSubtitleRenderer(for:)` (the software player draws them itself).

## 5. What the app must do

- Show the licences: `MediaEngine.acknowledgements` (see `Licences and notices` in the DocC documentation). FreeType's credit line is
  a condition of shipping.
- Say what you ship under the LGPL and how to get the source: `docs/REPLACING-FFMPEG.md`, the source pack of the release.
- Patent licences for the profiles you enable are yours (`docs/PATENT_PROFILES.md`, a draft for a lawyer).
- Video that is not H.264, HEVC or AV1: nothing to do; the plan reports it.

## 6. Platforms, App Store, privacy

- iOS and iPadOS 27.0, macOS 27.0 (Apple silicon), visionOS 27.0. tvOS is not supported. Mac Catalyst is not supported (use the macOS
  destination). **visionOS has been verified in the simulator only.**
- Both frameworks carry a privacy manifest (no tracking, no collected data, no required-reason API use). The engine opens a loopback
  HTTP listener (127.0.0.1, random port, random path prefix) for the system player to read the remuxed stream; it needs no entitlement on
  macOS. On iOS the app transport security and the local-network prompt behaviour for this listener are verified in the simulators; the
  AirPlay behaviour on real devices is still to be recorded (`docs/ACCEPTANCE_CRITERIA.md`, E-S4).
- For a file whose own index is missing or unusable, the engine works one out once and keeps it in the app's Caches folder
  (`MediaEngine/KeyframeIndexes`: one small file per movie, named by the file's length and a hash of its first 64 KB, holding
  keyframe times and byte offsets only; 200 at most; the system may clear them). ``PlaybackSession.observePreparation(_:)`` reports
  the progress of that first opening. For network sources (a byte source that reports `throughput`) the probe's result is also kept
  there (`MediaEngine/Probes`, a few KB per file, 200 at most), so opening the same file again does not read its start and end again.
- A custom `ByteSource` for a network should report `throughput` (`ThroughputMeter` does the arithmetic): the engine makes its pieces
  shorter over a slow link, so the first picture and jumps wait for less. `readSparse` should fetch just the bytes asked for.
- The engine reads media files with a hardened parser (fuzzed with mutated corpora under AddressSanitizer, ThreadSanitizer and
  UBSan). Treat files from the network as untrusted all the same, and keep the engine up to date (FFmpeg security fixes ship as patch
  releases).

## 7. Numbers (Apple M1 Max, synthetic 2-minute 1080p file; `Benchmarks/baseline.json`)

Probe 17 ms, first requests 5 ms, AVPlayer playing after about 550 ms, seek to playing about 390 ms, memory growth 64 MB for 1080p at 20 Mbps
(segments are capped at 24 MB, so 4K at 44 Mbps stays near 100 MB). Phone numbers need a device run.
