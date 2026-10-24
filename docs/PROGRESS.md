# MediaEngine: progress and handoff

**How to use (any new session or window):** read `CLAUDE.md`, then this file, then continue from "Right now". The owner can add tasks at any time: record each one under "Backlog" first (with the date), then work on it. After every finished step, update this file (move the task, add evidence, refresh "Right now" and "Handoff notes"). Update it before ending a turn so an interrupted session loses nothing.

## Right now

- Milestone: E0 and E1 complete and committed (`dfe779e`). **E2 (remux to AVPlayer) is mostly done and verified, not yet committed** (2026-10-24): an MKV plays through AVPlayer with the system controls, seeks, and switches audio tracks.
- What exists: `PacketReader`, `SegmentPlan` (keyframe-aligned ~6 s segments), `InitSegmentBuilder` (FFmpeg MP4 muxer, no edit list, `hvc1`, nominal HDR10 boxes for PQ), `FragmentWriter` (own moof/mdat, exact timestamps), `HLSPlaylists`, `RemuxSession` (random-access segments, LRU cache, read-ahead, lazy audio transcoding), `AudioTranscoder` (FLAC/PCM to lossless ALAC, native encoder), `LoopbackServer` (loopback only, random port, 128-bit token, Host check), public `PlaybackSession.makePlayerItem()` (`@MainActor`; the item retains the session).
- Verified (last full `scripts/verify.sh`: 2 min 49 s, exit 0): AVFoundation decodes the assembled streams frame-exact; AVPlayer plays, seeks and finishes the H.264, HEVC and HLG fixtures through our HLS; the audio menu lists English (AAC passthrough) and Japanese (FLAC to ALAC) and switching plays; FLAC to ALAC is bit-exact (16-bit mono, 24-bit stereo 44.1 kHz). macOS runs 76 tests (1 known issue), iPhone/iPad/iPhone Duo/visionOS simulators 72 each (AVPlayer and AVAssetReader tests are macOS-only).
- **Open issue (E-S3 finding): HDR10 (PQ) over HLS.** AVPlayer rejects PQ video in HLS (CoreMedia -17223) even for FFmpeg's own HLS output of the same file; the same stream plays as a local fMP4, and HLG and 10-bit SDR play through HLS. Tried: `VIDEO-RANGE` variants, SDR+PQ twin variants, `mdcv`/`clli` boxes, VUI-tagged bitstream, other level strings. Next: a REAL HDR10 rip (SEI metadata, 4K, proper level) on the owner's iPhone/iPad/Mac. Tracked as `PlaybackSessionTests.pqKnownIssue`.
- Next actions (in this order): (a) Opus/Vorbis transcoding with decoder pre-roll; (b) E2.5 measurements and hardening: first-frame time, seek latency, memory budget, damaged-file behavior, fuzzing, leak check (realistic numbers need big real files from the owner); (c) `.resourceLoader` transport; (d) E-S4 AirPlay on the owner's Apple TV or HomePod; (e) settle HDR10 over HLS with a real clip. Then E3 (subtitles and tracks, same-language track names in the menu), after which PlayerApp may start.
- Waiting on the owner: nothing blocking. Useful when convenient: one real HDR10 MKV clip (30-60 s), a few big real MKVs for performance numbers, and an hour with a Mac, iPhone and Apple TV for the AirPlay spike.

## Task board

### In progress
- Between steps. Candidates in "Up next".

### Up next (ordered)
1. Opus/Vorbis transcoding with pre-roll (RMX-2)
2. E2.5 measurements and hardening (RMX-5, RMX-6, RMX-7, RMX-12, RMX-13, PRF-2, PRF-3, PRF-4)
3. `.resourceLoader` transport (RMX-9)
4. AirPlay spike E-S4 on real devices (RMX-10); HDR10/PQ over HLS (RMX-1, RMX-11)
5. E3 subtitles and tracks; then PlayerApp may start

### Backlog (owner requests, newest last)
- (empty)

### Done (newest first; date, what, evidence)
- 2026-10-24 **E2.4 audio transcoding (FLAC/PCM to ALAC), lazy per track** (uncommitted). Evidence: `AudioTranscodeTests` (bit-exact 16-bit mono and 24-bit stereo, segments join, timestamps contiguous, lazy), `RemuxTests` (ALAC init segments, AVFoundation decodes the ALAC renditions), `AVPlayerEndToEndTests.audioSelection`; `scripts/verify.sh` passed. Ticked: ANM-5.
- 2026-10-24 **E2.1 to E2.3 passthrough remux to AVPlayer** (uncommitted). Evidence: `scripts/verify.sh` passes in 3 min 4 s; `RemuxTests` (packet-exact fragments, continuous timestamps, init segment boxes, AVFoundation frame-exact decode), `LoopbackServerTests` (ranges, HEAD, 403/404/405/416, token, loopback-only), `PlaybackSessionTests` (item lifetime, close), `AVPlayerEndToEndTests` (play, seek, finish for H.264, HEVC, HLG). Server hardening part of RMX-9 verified (the `.resourceLoader` transport is still open).
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
- Audio: core now includes FFmpeg's native `alac` encoder (framework rebuilt with `scripts/build-all.sh core`). Transcoded tracks use a 1/sample-rate time base end to end; `FragmentWriter`, the init segment and `shift` follow it.
- E2 gotchas learned the hard way: (1) seeking to time 0 skips packets with negative timestamps (AAC priming), so the first window reopens the file (`PacketReader.rewind()`); (2) the MP4 muxer writes an edit list that shifts AVFoundation's timeline, so `use_editlist=0`; (3) the muxer returns `ftyp`+`moov` only (no `moof`) with `delay_moov`, which is what we use as the init segment; (4) sample durations come from dts deltas (Matroska timestamps are ms-rounded); (5) in the macOS 27 SDK `AVPlayerItem` is main-actor isolated and `AVAssetReader.add/startReading/copyNextSampleBuffer`, `AVPlayerItemVideoOutput.copyPixelBuffer`, `errorLog()` are deprecated (use `outputProvider(for:)`, `start()`, `provider.next()`, `pixelBufferAndDisplayTime(forItemTime:)`); (6) Python's `http.server` cannot listen inside the tool sandbox, `NWListener` can.
- Test hooks: `RemuxSession.masterTransform` rewrites the master playlist (for AVPlayer experiments); `ResourceProvider` lets the loopback server serve any directory or session.
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
