# MediaEngine (working title)

A Swift-native media engine for Apple platforms (iOS, iPadOS, macOS, visionOS 27). It opens Matroska/WebM and other containers AVFoundation cannot, and hands the result to AVPlayer (system UI, AirPlay, PiP, HDR) or to a software-decode renderer. Built on our own LGPL-only FFmpeg.

Status: the engine is feature-complete for version 1 (milestones E0 to E6 as far as they can be done without devices and a lawyer): an MKV plays through AVPlayer with tracks, subtitles, chapters, ordered chapters and an overlay renderer for full ASS and picture subtitles; files Apple cannot decode (legacy containers and codecs, VP8, VP9, AV1 on older chips) play through the software player. What needs hardware or a lawyer is listed in `docs/PROGRESS.md`. Planning, criteria and decisions: `CLAUDE.md`, `docs/`.

## Platforms

iOS and iPadOS 27.0, macOS 27.0 (Apple silicon) and visionOS 27.0. **visionOS has been verified in the simulator only; it has not been
verified on hardware** (nobody with a headset has run the device script yet). tvOS and Mac Catalyst are not supported (on a Mac use the macOS
destination). AirPlay, Picture in Picture and phone performance are not yet measured on devices.

## Build and verify

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
scripts/build-all.sh      # fetch + verify sources, build 5 slices, package build/FFmpegLGPL.xcframework and build/LibASS.xcframework (about 4 minutes)
scripts/check.sh          # the quick loop: build with zero warnings + unit tests (about 30 s, background priority, silent)
scripts/verify.sh --quick # sources, licences, docs, API hygiene, ground truth, all macOS test passes, extended variant (about 6 minutes)
scripts/verify.sh         # + package traits and the sample apps for macOS (about 8 minutes)
scripts/verify.sh --sims  # + iOS and visionOS samples and the iPhone, iPad, iPhone Duo and visionOS simulators, one at a time
scripts/verify.sh --deep  # + benchmark gate and AddressSanitizer (instrumented FFmpeg), ThreadSanitizer and UBSan
scripts/install-hooks.sh  # git hooks: quick check on commit, verify --quick on push
MEDIAENGINE_BENCH_FILE=/path/movie.mkv swift test --filter BenchmarkTests   # open time, seeks, memory, A/V continuity on a real file
MEDIAENGINE_EXCLUSIVE=1 swift test --filter ExclusiveTests                  # timing, leak and CPU checks that need the process to themselves
```

Needs Xcode 27.1, Homebrew `meson`, `ninja`, `cmake`, `gpg`, and Rust (see `CLAUDE.md`). The frameworks are not committed; `Package.swift` points at `build/FFmpegLGPL.xcframework` and `build/LibASS.xcframework` during development.

## Probe a file

```swift
import MediaEngine

let source = try await MediaSource(url: fileURL)       // local file, security-scoped URL, or http(s) with range requests
let info = try await source.probe()                    // container, tracks, chapters, attachments; reads headers only

info.container.isMatroskaFamily                        // true for .mkv / .webm
info.audioTracks.map { ($0.language, $0.codec.displayName) }
info.playbackPlan.path                                 // .native, .remux, .software or .unsupported
info.requiredProfile                                   // which optional codec modules this file needs (.core, .extended, .licensedAudio)
```

Bring your own storage (SMB, WebDAV, a cloud API) by implementing `ByteSource`: one blocking `read(at:into:)` and a `length`.

## Play a file that AVFoundation cannot open

```swift
import AVKit
import MediaEngine

let session = try await PlaybackSession(url: fileURL)   // probes and picks the best path
let item = try await session.makePlayerItem()            // a plain AVPlayerItem (main actor)
player.replaceCurrentItem(with: item)                    // AVPlayerViewController, VideoPlayer, AVPlayerView
```

The item keeps the session alive. MKV video (H.264, HEVC) and audio (AAC, AC-3, E-AC-3 as is; FLAC, PCM, Opus and Vorbis as lossless ALAC) play with the system controls, AirPlay button and Picture in Picture.

## Tracks, chapters, subtitles

```swift
try await session.apply(TrackPreferences(audioLanguages: ["ja"], subtitleLanguages: ["en"]), to: item)   // "Japanese audio, English subtitles"
session.audioChoices, session.subtitleChoices            // names that are unique even when two tracks share a language
session.chapters                                         // with kinds (opening, ending, recap...) so an app can offer "Skip Opening"
try session.add(await SubtitleTrack(url: srtURL))        // external subtitles (encoding detected) and AudioTrack(url:) for external audio
try await session.locateSegments(in: folderURL)          // ordered chapters that play parts of other files; session.missingSegments says what is absent
```

Text subtitles reach the system player as WebVTT. For full ASS (karaoke, rotation, blur, drawings, fonts from the file) and picture subtitles (PGS, VobSub, DVB) the engine draws the pictures itself:

```swift
let renderer = try await session.makeSubtitleRenderer(for: session.overlayChoices[0])
let frame = renderer.frame(at: player.currentTime().seconds, size: videoSizeInPixels)   // call on every display refresh
if frame.changed { overlay.draw(frame.images) }                                          // CGImages with their frames
```

## One controller for every path, and the software player

```swift
let session = try await PlaybackSession(url: fileURL)
let player = try await session.makeController()          // PlaybackController: AVPlayer for MKV/MP4, the software player for the rest
MediaVideoView(controller: player)                        // SwiftUI view for the picture (UIKit and AppKit hosts exist too)
player.play(); await player.seek(to: 90)
(player as? SoftwareController)?.deinterlacing = .automatic   // own deinterlacer for interlaced files (the default)
```

`makeController()` hands back an `AVPlayerController` when the system can play the file (system UI, AirPlay, PiP) and a
`SoftwareController` when the file needs the engine's decoders (extended variant: old AVI, FLV, RealMedia, MPEG-2, WMV, VP8,
VP9, AV1 on devices without an AV1 decoder). Same protocol: state, time, rate, seek, audio and subtitle choices.

## Licences, notices and replacing FFmpeg

```swift
ForEach(MediaEngine.acknowledgements) { item in            // FFmpeg, libass, FreeType, ... with licence texts and source addresses
    Text("\(item.name) \(item.version): \(item.license)")
}
```

- `third_party/NOTICES.md` and `MediaEngine.acknowledgements` (generated by `scripts/gen-acknowledgements.py`, checked against the pins).
- `docs/REPLACING-FFMPEG.md`: rebuild or replace `FFmpegLGPL.framework` (tested by `scripts/test-framework-swap.sh` with `Samples/SwapProbe`).
- `scripts/make-source-pack.sh`: the source pack for a release (exact archives, build scripts, `BUILD-INFO.txt`), checked by `scripts/check-source-pack.sh`.
- `docs/INTEGRATION.md` (integration guide), `docs/VERSIONING.md` (versioning and support, draft), `CHANGELOG.md`; the DocC documentation (symbols, the "Play an MKV in five minutes" tutorial, articles) builds with `scripts/check-docs.sh`.
- `docs/PATENT_PROFILES.md`: every codec of each profile with its royalty status (draft for a lawyer); `docs/DECISION_D-E1_LICENSE.md`: the open licence question.
- `Samples/QuickStart` (the five lines as a SwiftUI app) and `Samples/Player` (system or software player, audio and subtitle menus, external subtitles, profile gating, licences screen) for iOS, macOS and visionOS (`scripts/check-samples.sh`).

## Layout

| Path | Purpose |
|---|---|
| `scripts/` | Build, packaging, license check, verify. Bash 3.2 compatible, no sudo. |
| `profiles/*.json` | Codec profiles as data: they generate both the FFmpeg configure flags and the license report. |
| `third_party/sources.lock` | Pinned upstream sources with SHA-256 and signing-key fingerprints. |
| `Sources/`, `Tests/` | Swift package. `Tests/MediaEngineTests/Golden` holds the recorded frames of the ASS rendering tests. |
| `Fixtures/` | Tiny generated test media (<2 MB), made by `scripts/make-fixtures.sh`. Official codec test vectors are downloaded by `scripts/fetch-conformance.sh` into `build/`. |
| `Samples/` | `QuickStart` (SwiftUI app) and `SwapProbe` (proves the FFmpeg framework can be replaced). |
| `docs/` | Acceptance criteria, research, progress and handoff notes. |

## Licensing in one paragraph

FFmpeg is used under the LGPL 2.1 or later, built without `--enable-gpl` and `--enable-nonfree`, and linked dynamically as `FFmpegLGPL.framework` so it can be replaced by your own build. Subtitle rendering uses libass (ISC), FreeType (FreeType License; an app must show its credit line), HarfBuzz (MIT) and FriBidi (LGPL-2.1), linked dynamically as `LibASS.framework`. Source for the exact version and the build configuration are listed in `third_party/sources.lock` and `build/BUILD-INFO.txt`. This product uses FFmpeg (https://ffmpeg.org); FFmpeg is a trademark of its respective owners and is not affiliated with this project. See `third_party/NOTICES.md`.
