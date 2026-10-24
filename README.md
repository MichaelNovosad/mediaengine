# MediaEngine (working title)

A Swift-native media engine for Apple platforms (iOS, iPadOS, macOS, visionOS 27). It opens Matroska/WebM and other containers AVFoundation cannot, and hands the result to AVPlayer (system UI, AirPlay, PiP, HDR) or to a software-decode renderer. Built on our own LGPL-only FFmpeg.

Status: milestone E2 (MKV plays through AVPlayer) mostly done. Planning, criteria and decisions: `CLAUDE.md`, `docs/`.

## Build and verify

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
scripts/build-all.sh      # fetch + verify sources, build 5 slices, package build/FFmpegLGPL.xcframework (about 2.5 minutes)
scripts/verify.sh         # license check + tests on macOS, iPhone, iPad, iPhone Duo, visionOS simulators
scripts/verify.sh --quick # macOS only
```

Needs Xcode 27.1, Homebrew `meson`, `ninja`, `cmake`, `gpg`, and Rust (see `CLAUDE.md`). The framework is not committed; `Package.swift` points at `build/FFmpegLGPL.xcframework` during development.

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

The item keeps the session alive. MKV video (H.264, HEVC) and audio (AAC, AC-3, E-AC-3 as is; FLAC and PCM as lossless ALAC) play with the system controls, AirPlay button and Picture in Picture.

## Layout

| Path | Purpose |
|---|---|
| `scripts/` | Build, packaging, license check, verify. Bash 3.2 compatible, no sudo. |
| `profiles/*.json` | Codec profiles as data: they generate both the FFmpeg configure flags and the license report. |
| `third_party/sources.lock` | Pinned upstream sources with SHA-256 and signing-key fingerprints. |
| `Sources/`, `Tests/` | Swift package. |
| `Fixtures/` | Tiny generated test media (<2 MB), made by `scripts/make-fixtures.sh`. |
| `docs/` | Acceptance criteria, research, progress and handoff notes. |

## Licensing in one paragraph

FFmpeg is used under the LGPL 2.1 or later, built without `--enable-gpl` and `--enable-nonfree`, and linked dynamically as `FFmpegLGPL.framework` so it can be replaced by your own build. Source for the exact version and the build configuration are listed in `third_party/sources.lock` and `build/BUILD-INFO.txt`. This product uses FFmpeg (https://ffmpeg.org); FFmpeg is a trademark of its respective owners and is not affiliated with this project. See `third_party/NOTICES.md`.
