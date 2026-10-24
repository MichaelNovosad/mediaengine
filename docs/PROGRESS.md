# MediaEngine: progress and handoff

**How to use (any new session or window):** read `CLAUDE.md`, then this file, then continue from "Right now". The owner can add tasks at any time: record each one under "Backlog" first (with the date), then work on it. After every finished step, update this file (move the task, add evidence, refresh "Right now" and "Handoff notes"). Update it before ending a turn so an interrupted session loses nothing.

## Right now

- Milestone: E0, E1 and E2 work committed (`dfe779e`, `d9da1c7`, `b253911`). **E2 (remux to AVPlayer) is done and verified except the open items below** (2026-10-24): an MKV plays through AVPlayer with the system controls, seeks, and switches audio tracks; FLAC, PCM, Opus and Vorbis audio is transcoded to lossless ALAC; damaged files, leaks, B-frames and memory are covered (E2.5, see the Done list and RESEARCH.md section 14).
- What exists: `PacketReader`, `SegmentPlan` (keyframe-aligned ~6 s segments), `InitSegmentBuilder` (FFmpeg MP4 muxer, no edit list, `hvc1`, nominal HDR10 boxes for PQ), `FragmentWriter` (own moof/mdat, exact timestamps), `HLSPlaylists`, `RemuxSession` (random-access segments, LRU cache, read-ahead, lazy audio transcoding with decoder pre-roll), `AudioTranscoder` (FLAC/PCM/Opus/Vorbis to lossless ALAC, native encoder), `LoopbackServer` (loopback only, random port, 128-bit token, Host check), public `PlaybackSession.makePlayerItem()` (`@MainActor`; the item retains the session).
- Verified (full `scripts/verify.sh`, 2026-10-24, 5 min 58 s): AVFoundation decodes the assembled streams frame-exact (H.264, HEVC, HLG, B-frames); AVPlayer plays, seeks and finishes them through our HLS; the audio menu lists every track and switching works across segment boundaries for Opus and Vorbis; FLAC/PCM to ALAC is bit-exact, Vorbis sample-exact and Opus within rounding noise per segment. macOS runs 108 tests (1 known issue), the four simulators 100 each (AVPlayer and AVAssetReader tests are macOS-only).
- **Open issue (E-S3 finding): HDR10 (PQ) over HLS.** AVPlayer rejects PQ video in HLS (CoreMedia -17223) even for FFmpeg's own HLS output of the same file; the same stream plays as a local fMP4, and HLG and 10-bit SDR play through HLS. Tried: `VIDEO-RANGE` variants, SDR+PQ twin variants, `mdcv`/`clli` boxes, VUI-tagged bitstream, other level strings. Next: a REAL HDR10 rip (SEI metadata, 4K, proper level) on the owner's iPhone/iPad/Mac. Tracked as `PlaybackSessionTests.pqKnownIssue`.
- Next actions (in this order): (a) byte-bounded segments for high bitrates; (b) `.resourceLoader` transport; (c) E-S4 AirPlay on the owner's Apple TV or HomePod; (d) settle HDR10 over HLS with a real clip. Then E3 (subtitles and tracks, same-language track names in the menu), after which PlayerApp may start.
- Waiting on the owner: nothing blocking. Useful when convenient: one real HDR10 MKV clip (30-60 s), a few big real MKVs for performance numbers (`MEDIAENGINE_BENCH_FILE=... swift test --filter BenchmarkTests`), and an hour with a Mac, iPhone and Apple TV for the AirPlay spike.

## Task board

### In progress
- Between steps. Candidates in "Up next".

### Up next (ordered)
1. Byte-bounded segments (cut by size as well as by time, using Cue byte positions) and releasing packets while a fragment is written, so UHD remuxes stay under the memory target (RMX-7)
2. `.resourceLoader` transport (RMX-9)
3. AirPlay spike E-S4 on real devices (RMX-10); HDR10/PQ over HLS (RMX-1, RMX-11)
4. E3 subtitles and tracks; then PlayerApp may start
5. Optional: libFuzzer harness on the demux wrapper; stored benchmark baselines (PRF-1); variable-frame-rate and deep-pyramid real files (RMX-12)

### Backlog (owner requests, newest last)
- (empty)

### Done (newest first; date, what, evidence)
- 2026-10-24 **Project skills added** (`.claude/skills/`: engine-verify, engine-add-fixture, engine-benchmark, engine-finish-step, engine-rebuild-ffmpeg, engine-playback-debug), listed in `CLAUDE.md`. Engine work E2.4b/E2.5 committed as `b253911`.
- 2026-10-24 **E2.5 hardening, B-frame fix and measurements** (committed in `b253911`). Evidence: `DamagedFileTests` (756 deterministic mutations per run of four fixtures through the whole remux path: no crash, no hang; a source failing after open now reports an error; `truncatedDownload` plays a file cut at 60% up to its last complete data), whole suite clean under ASan, TSan, UBSan and under ASan with an instrumented FFmpeg (`scripts/check-sanitized.sh`), `ExclusiveTests` (100 open/close cycles, idle CPU, probe speed, cancellation latency, fragment memory) and `LifetimeTests`. **Bug found by the 3-hour benchmark and fixed: files with B-frames did not open** (`ReorderModel`, `DecodeTimestampTests`, `fixture-bframes`); **memory bug fixed** (appending to a growing buffer kept 464 MB behind, now 129 MB for a 1080p 13 Mbps file; segment cache 48 MB). Numbers (M1 Max): AVPlayer playing after 464-541 ms, seek until playing again 242-393 ms, A/V offset drift 0.2-0.8 ms over 3 hours (RESEARCH.md section 14). Ticked: PRF-2, PRF-3, RMX-13; progress notes on RMX-5/6/7/12 and PRF-1. `scripts/verify.sh` passes (5 min 58 s, exit 0): macOS 108 tests (1 known issue, the PQ one), isolated pass 7 tests, iPhone / iPad / iPhone Duo / visionOS simulators 100 tests each, zero warnings.
- 2026-10-24 **E2.4b Opus and Vorbis transcoding with decoder pre-roll, and the Matroska Cues fix** (committed in `b253911`). Evidence: `AudioTranscodeTests.prerollSegments` (Vorbis sample-exact, Opus within rounding noise, cold start differs), `KeyframeIndexTests`, `startsAreAligned`, `AVPlayerEndToEndTests.crossesBoundary` (English/Japanese across a segment boundary), new fixture `fixture-opus-vorbis.mkv`. Details in RESEARCH.md section 13.
- 2026-10-24 **E2.4 audio transcoding (FLAC/PCM to ALAC), lazy per track** (committed in `d9da1c7`). Evidence: `AudioTranscodeTests` (bit-exact 16-bit mono and 24-bit stereo, segments join, timestamps contiguous, lazy), `RemuxTests` (ALAC init segments, AVFoundation decodes the ALAC renditions), `AVPlayerEndToEndTests.audioSelection`; `scripts/verify.sh` passed. Ticked: ANM-5.
- 2026-10-24 **E2.1 to E2.3 passthrough remux to AVPlayer** (committed in `d9da1c7`). Evidence: `scripts/verify.sh` passes in 3 min 4 s; `RemuxTests` (packet-exact fragments, continuous timestamps, init segment boxes, AVFoundation frame-exact decode), `LoopbackServerTests` (ranges, HEAD, 403/404/405/416, token, loopback-only), `PlaybackSessionTests` (item lifetime, close), `AVPlayerEndToEndTests` (play, seek, finish for H.264, HEVC, HLG). Server hardening part of RMX-9 verified (the `.resourceLoader` transport is still open).
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

- Test layout (E2.5): normal `swift test` (~37 s, 108 tests) is functional only. Anything that measures time, memory, descriptors or CPU lives in `ExclusiveTests` and runs with `MEDIAENGINE_EXCLUSIVE=1 swift test --filter ExclusiveTests` (a separate pass in `scripts/verify.sh`, macOS only); a plain run skips it. `BenchmarkTests` run only with `MEDIAENGINE_BENCH_FILE=/path/file.mkv` (optional `MEDIAENGINE_BENCH_TRACE=1`). Generate a long B-frame test file with the host ffmpeg (`build/tools/bin/ffmpeg`, `h264_videotoolbox -profile:v high -bf 2`, lavfi `testsrc2`); the one used for the numbers lived in the scratchpad and is not kept.
- Sanitizers: `swift test --sanitize=address|thread|undefined` cover Swift only; `scripts/check-sanitized.sh` swaps in an ASan-instrumented FFmpeg (`FFMPEG_SANITIZE=address` in build-ffmpeg.sh / package-xcframework.sh, `MEDIAENGINE_SANITIZED_FFMPEG=1` in Package.swift, output `build/FFmpegLGPL-address.xcframework`). `dlsym("__asan_init")` detects ASan in tests (footprints are meaningless under its quarantine).
- Flake hunting: loop `swift test > log` and search the logs for the failure marker (`grep "􀢄"`); grepping for "recorded an issue" misses some failures.
- Decode timestamps: Matroska has no dts; `ReorderModel` rebuilds them for video per window (sorted pts shifted by the reorder depth). Never reintroduce `dts = pts` for B-frame video. Fixtures made before this had no B-frames; `fixture-bframes.mkv` was added by running its command from `make-fixtures.sh` alone (regenerating all fixtures rewrites every file).
- Memory: build large buffers with the final size (`ByteWriter(capacity:)`); growing a `Data` by appending leaves the abandoned blocks in the process footprint. Segment cache budget is 48 MB (`RemuxSession.init(cacheBudget:)`).
- Project skills live in `.claude/skills/` (see CLAUDE.md); use them for verification, fixtures, benchmarks, rebuilds, debugging and the end-of-step ritual.

## Open questions for the owner

- None right now.
