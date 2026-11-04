# MediaEngine (working title)

A Swift-native media engine for Apple platforms. It opens Matroska/WebM and other containers AVFoundation cannot, and hands the result either to **AVPlayer** (system UI, AirPlay, PiP, HDR) or to a **software-decode renderer**. Built on our own **LGPL-only FFmpeg**. First consumer is `~/Documents/Development/PlayerApp`. Later it is to be licensed and sold as a separate product to other developers.

**This is step one.** The PlayerApp project is not created until milestone E3 in the acceptance criteria passes (an MKV plays through AVPlayer).

@docs/ACCEPTANCE_CRITERIA.md
@docs/PROGRESS.md

Evidence behind the choices: `docs/RESEARCH.md`. Read it before touching licensing, build scripts or distribution.

## Locked decisions (from the owner)

- Separate package and repository with its own license boundary. No app code, StoreKit, analytics or UI chrome lives here.
- Platforms: iOS/iPadOS 26.0, macOS 26.0 (Apple silicon only), visionOS 26.0 (26.0 since 2026-11-04, the app's minimum; `MIN_OS` in `scripts/lib/common.sh` builds the libraries for it) (the owner has no device, so visionOS is simulator-verified only). **tvOS is excluded for good.** Swift 6.4, Xcode 27.1 SDK.
- **H.264 Hi10P is out of scope** (owner, 2026-10-24): no software H.264 decoder in the engine.
- LGPL only: FFmpeg built with `--disable-gpl --disable-nonfree`, dynamic frameworks, pinned versions, exact sources and build configuration shipped with every release.
- Patent-encumbered software codecs are opt-in modules (profiles `core`, `extended`, `licensedAudio`), never included silently. **Licensing strategy, agreed by the owner on 2026-10-24:** (1) Apple's decoders decode whatever they cover; (2) our own decoders only for royalty-free or expired codecs; (3) container work (demux/remux) is free of codec licences; (4) everything else is isolated in opt-in modules that stay off until a lawyer clears them. Details in `docs/RESEARCH.md` §3.
- The package never knows about purchases. It reports which profile a file needs (`requiredProfile`); the host app decides what to allow.
- The product name must not contain "FFmpeg" (the name is only used for attribution).
- Signing identity: Michael Novosad (Personal Team) until the paid enrolment.
- Easy to adopt is a hard requirement: one package URL, no manual steps, a five-line quick start, full DocC.

## Toolchain

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
```

- Build scripts live in `scripts/`: bash with `set -euo pipefail`, no sudo, idempotent. Sources are fetched from pinned URLs and verified by SHA-256 before use.
- Installed on 2026-10-24 with the owner's approval: `meson` 1.12.1, `ninja` 1.13.2, `cmake` 4.4.4, `gpg` 2.5.24 (Homebrew) and Rust 1.99.1 via `rustup` (stable, with the macOS and iOS targets; the visionOS targets are Tier 3 and need nightly, see spike E-S7). `rustup` is keg-only, so scripts must put `/opt/homebrew/opt/rustup/bin` on `PATH`. Ask the owner before installing anything else.
- Homebrew's `ffmpeg` is a GPL build: use it only as a developer tool for making fixtures, never link or ship it.

## Conventions

- Swift 6 language mode, strict concurrency, zero warnings. No C types, pointers or FFmpeg names in public API. Public API uses Foundation, AVFoundation, CoreMedia and CoreGraphics types.
- `async`/`await`, `AsyncSequence`, actors. Cancellation must be honored.
- Every public symbol has DocC. API changes are checked with `swift package diagnose-api-breaking-changes` once 1.0 exists.
- Logging with `os.Logger`; file names and paths are `.private`.
- No new third-party component without checking its license against the LGPL-only rule and recording it in the license report.
- Git: repo is created in E0. Commit only when asked. **No `Co-Authored-By: Claude` trailers** (standing instruction from the owner). Never commit media or build products.

## Working rules

- **Tests run only when the owner says so** (owner, 2026-10-30: running new tests is good practice, but it over-complicated the work). Without the owner's word a change is checked by compiling it (`swift build` for the package, at background priority) and nothing else; "commit" means compile, then commit; "check", "test" or "check and then commit" means the tests below. Every report says which tests were not run.
- When the owner asks for tests: `scripts/check.sh` (about 30 s), `scripts/verify.sh --quick` before reporting a step done, `scripts/verify.sh` before a commit, `--sims` (simulators) and `--deep` (sanitizers, benchmark) only when the owner asks; tick the acceptance boxes with evidence and list what is unverified. The git hooks (`scripts/install-hooks.sh`) run the quick check on commit and `verify --quick` on push. Details: skill `engine-verify`.
- Hardware-only items are tagged `[device]`; write a short device test script for the owner. visionOS items stay `[sim]` until someone with a headset tests.
- **Work only inside this project folder** (owner, 2026-10-26): no system changes, no installs, no git configuration, nothing written outside the folder (temporary files and logs go to `build/`, which is git-ignored, never to `/tmp` or a scratchpad), no memory notes, no edits to the PlayerApp project or any other folder, unless the owner asks for it.
- **The owner uses this Mac while I work (video calls, audio): checks must never get in the way** (owner, 2026-10-26, after a video call and the Vision Pro keyboard service were disturbed by a full verify with four simulators and sanitizers). Rules: every script runs itself at background priority (`taskpolicy -b`, `nice 19`, half the cores; `scripts/lib/common.sh`); tests are silent (every controller and `AVPlayer` in a test is muted); simulators are never booted unless the owner asks (`verify.sh --sims`, one at a time); sanitizers, the benchmark and builds of FFmpeg, dav1d or the subtitle libraries (`--deep`, `build-all.sh`) only when the owner says it is a good moment, announced before they start; the everyday loop is `scripts/check.sh` (about 30 s) and nothing heavier runs unasked. Do not repeat a full check just to be sure: one passing run per finished part is enough, and extra sanitizer or flake runs need a reason.
- Ask the owner before: installing tools, downloading simulator runtimes, spending money, touching Apple accounts, publishing anything.
- Anything legal (EULA, patents, selling) is a draft for a lawyer, never a conclusion.

## Session continuity (so a new window can continue)

- Start of any session: read this file, then `docs/PROGRESS.md`, then continue from "Right now". Do not ask the owner to repeat decisions that are in the decisions log.
- When the owner gives a new task: add it to "Backlog" in `docs/PROGRESS.md` first (with the date), then work on it.
- After every finished step: update `docs/PROGRESS.md` (board, evidence, "Right now", handoff notes) and tick criteria with evidence. Update it before ending a turn, even when the work is half done.
- Cross-project: the engine lives in `~/Documents/Development/MediaEngine`, the app in `~/Documents/Development/PlayerApp`; each has its own `docs/PROGRESS.md`.

## Project skills (in `.claude/skills/`, committed)

- `engine-verify`: which check to run when, how to read the output, flake hunting, sanitizers.
- `engine-add-fixture`: new tiny test video with ground truth and test wiring.
- `engine-benchmark`: `BenchmarkTests`, synthetic long/high-bitrate files, baseline numbers, memory lessons.
- `engine-finish-step`: the end-of-step ritual (PROGRESS, criteria, RESEARCH, commit rules, no Claude trailer).
- `engine-rebuild-ffmpeg`: changing profiles, rebuilding frameworks, the sanitized variant, licensing guard rails.
- `engine-playback-debug`: debugging the HLS fMP4 remux path and the lessons already paid for.

## Status

Phase: **the engine is finished for version 1** (2026-10-26). E0 to E4 are done and verified: MKV/WebM and legacy containers play through AVPlayer (system player, seeks, audio and subtitle switching, B-frames, damaged files; AirPlay and PiP come with the system player and are not yet tried on devices), lossless audio conversion, text subtitles as WebVTT, full ASS (libass with Unicode line breaking) and picture subtitles through `SubtitleRenderer`, chapters and ordered chapters, track choices, external subtitle and audio files, one `PlaybackController` for every path, and the software player (extended variant: MPEG-1/2/4, WMV, Flash video, RealVideo, VP8, VP9, AV1 with dav1d, own deinterlacer, pixel aspect ratio, conformance-tested). E5/E6 release readiness is in place (acknowledgements, source pack, framework replacement test, patent profile draft, DocC, samples, benchmark gate). What is left needs the owner, a lawyer, an Apple account or devices: see "Deferred after v1" in `docs/PROGRESS.md`. **PlayerApp M0 may start**, in its own git repository. Live status is in `docs/PROGRESS.md`.
