# MediaEngine: progress and handoff

**How to use (any new session or window):** read `CLAUDE.md`, then this file, then continue from "Right now". The owner can add tasks at any time: record each one under "Backlog" first (with the date), then work on it. After every finished step, update this file (move the task, add evidence, refresh "Right now" and "Handoff notes"). Update it before ending a turn so an interrupted session loses nothing.

## Right now

- Milestone: E0 and **E1 complete** (2026-10-24). **E2 not started.**
- Next action: E2, remux to AVPlayer (the first MKV plays). Start with the packet reader and the fragmented-MP4 writer, then the local server and `AVPlayerItem` (spike E-S3 on macOS first). AirPlay (E-S4) needs a real Apple TV or HomePod and your iPhone.
- Waiting on the owner: nothing blocking. Optional but useful for E2: real MKV test files (list in `PlayerApp/docs/RESEARCH.md` section 7); generated fixtures are enough to start.

## Task board

### In progress
- (none)

### Up next (ordered)
1. E2.1 Packet reader API on top of the demuxer (`async` sequence of packets per track, seek by time through the index) (RMX-5)
2. E2.2 Fragmented MP4 writer: init segment plus media segments for H.264/HEVC and AAC/AC-3/E-AC-3 copied unchanged; correct codec tags (`avc1`, `hvc1`) (RMX-1, RMX-12)
3. E2.3 HLS playlists and a session server (`.resourceLoader` and `.loopbackServer` transports), then `PlaybackSession.makePlayerItem()` (RMX-9, API-1). Spike E-S3 on macOS first.
4. E2.4 Audio the system cannot play: FLAC to ALAC (lossless), Opus/Vorbis to AAC through AudioToolbox (RMX-2, ANM-5)
5. E2.5 Alternate audio renditions in the system menu, seeking latency, memory budget, damaged-file behavior (RMX-3, RMX-5, RMX-7, RMX-13, PRF-2)
6. E2.6 AirPlay spike E-S4 on a real Apple TV/HomePod (needs the owner's devices); HDR/Dolby Vision signaling stays off until LIC-6 (RMX-10, RMX-11)
7. Then E3 subtitles and tracks; then PlayerApp may start

### Backlog (owner requests, newest last)
- (empty)

### Done (newest first; date, what, evidence)
- 2026-10-24 **E1 probe API and byte sources.** Evidence: `scripts/verify.sh` passes in 2 min 29 s (macOS, iPhone, iPad, iPhone Duo, visionOS simulators; 46 tests each; zero warnings); ThreadSanitizer clean; `scripts/check-public-api.sh`, `scripts/check-ground-truth.sh`. Ticked: API-2, API-3, API-4, API-5, API-11, PRB-1, PRB-3, PRB-4, IO-1, IO-2, PRF-5. PRB-2 and ANM-1 partly done (see notes in the criteria).
- 2026-10-24 **E0 build system and license skeleton.** Evidence: `scripts/verify.sh` passes in 1 min 47 s (macOS, iPhone 18 Pro Max, iPad Air 13-inch (M4), iPhone Duo, Apple Vision Pro simulators; 6 tests each; zero warnings); `scripts/build-all.sh` clean rebuild 2 min 21 s; `scripts/check-licenses.sh` passes and fails on a tampered build. Ticked in `ACCEPTANCE_CRITERIA.md`: BLD-1, 2, 3, 5, 7, LIC-1, PLT-1, PLT-2, E-S1.
- 2026-10-24 E-S1 result: FFmpeg 9.0.2 builds LGPL-clean for five slices; one merged dynamic framework `FFmpegLGPL` (2.7-2.8 MB per slice); Swift demuxes MKV through custom I/O with no H.264/HEVC/AC-3 decoder compiled in.
- 2026-10-24 E-S2 partial result: traits switch code at compile time; they cannot swap binaries. Opened D-E11.
- 2026-10-24 Fixtures: `Fixtures/fixture-basic.mkv` (H.264, AAC, FLAC, SRT, 2 chapters) and `fixture-hevc.mkv` (HEVC, AC-3), about 250 KB each, made by our own host `ffmpeg`.
- 2026-10-24 Tools installed (meson, ninja, cmake, gpg, Rust); visionOS 27.0 simulator runtime installed.

## Decisions log

| Date | Decision | By |
|---|---|---|
| 2026-10-24 | Separate package, LGPL-only FFmpeg, dynamic frameworks; platforms iOS/iPadOS/macOS/visionOS 27.0; no tvOS | Owner |
| 2026-10-24 | Licensing strategy: Apple decoders; own decoders only for royalty-free or expired codecs; remux needs no codec licence; everything else opt-in and off until a lawyer clears it | Owner |
| 2026-10-24 | **H.264 Hi10P is out of scope**: no software H.264 decoder; such files report a clear "unsupported" reason | Owner |
| 2026-10-24 | Pro package C for the app; team = Michael Novosad (Personal Team) | Owner |
| 2026-10-24 | FFmpeg 9.0.x (9.0.2 pinned) and a single merged framework `FFmpegLGPL` | Claude, from E-S1 evidence |
| 2026-10-24 | Open: D-E11 packaging of optional codec profiles (plug-in frameworks vs variant products), decided in E4 | — |

## Handoff notes (what a fresh session must know)

- Always `export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer`. Scripts set it themselves; plain `swift`/`xcodebuild` in a shell need it. Rust lives in `/opt/homebrew/opt/rustup/bin`.
- Everyday commands: `scripts/verify.sh` (full, about 2.5 min), `scripts/verify.sh --quick` (macOS only), `scripts/build-all.sh` (rebuild frameworks and fixtures, about 2.5 min), `scripts/bootstrap.sh` (tool check), `scripts/check-traits.sh`, `scripts/check-public-api.sh`, `scripts/check-ground-truth.sh`.
- Public API so far: `MediaSource` (`init(url:)`, `init(byteSource:)`, `probe()`), `MediaInfo` and friends, `PlaybackPlan`, `CodecProfile`, `ByteSource` (+ `DataByteSource`, `FileByteSource`, `HTTPByteSource`), `MediaError`, `MediaEngine.buildInfo/availableProfiles/enabledTraits`. Sources are under `Sources/MediaEngine/` (`Internal/` holds the FFmpeg bridge, prober, extradata and language helpers).
- Test patterns: fixtures and ground-truth JSON are read through `#filePath` (works on simulators); HTTP tests use a `URLProtocol` stub (`StubServer`/`StubProtocol` in `ByteSourceTests.swift`, suite is `.serialized`); planner tests build synthetic tracks with `makeTrack`.
- Regenerating fixtures changes their bytes (VideoToolbox is not bit-reproducible): rerun `scripts/make-fixtures.sh`, which also rewrites the ground-truth JSON; commit both together.
- The probe plans with `DeviceCapabilities.current`: AV1 hardware support comes from VideoToolbox and may differ between simulator and device.
- The XCFramework (`build/FFmpegLGPL.xcframework`) is a build product and is git-ignored; `Package.swift` references it by path. Fresh clone: run `scripts/bootstrap.sh`, then `scripts/build-all.sh`.
- Simulators used: iPhone 18 Pro Max (iOS 27.0), iPad Air 13-inch (M4) (iOS 27.0), iPhone Duo (iOS 27.1), Apple Vision Pro (visionOS 27.0). `verify.sh` finds them by name; there are two "iPhone Duo" devices, the first is used.
- The core profile compiles no H.264/HEVC/AAC/AC-3 decoders on purpose; probing works through parsers. Do not add decoders to `core.json` without the owner and LIC-6.
- Homebrew's `ffmpeg` is GPL: never link it. Fixtures come from `scripts/build-host-tools.sh` + `scripts/make-fixtures.sh`.
- Bash 3.2 rules (macOS default): no `mapfile`, no associative arrays; avoid `grep -q` in `pipefail` pipelines (use the `has`/`lacks` helpers in `check-licenses.sh`).
- Downloaded sources live in `build/downloads/` (untrusted until SHA-256 and signature pass); builds are out of tree in `build/work/`.
- Never use the company Apple team that is signed in on this Mac. Commit only when the owner asks; no Claude co-author trailers.
- Sibling project: `~/Documents/Development/PlayerApp` (starts after this package passes E3); its own `docs/PROGRESS.md` tracks the app.
- Homebrew side effect to remember: installing meson re-linked `/opt/homebrew/bin/python3` to python@3.15.

## Open questions for the owner

- None right now.
