# MediaEngine (working title)

A Swift-native media engine for Apple platforms. It opens Matroska/WebM and other containers AVFoundation cannot, and hands the result either to **AVPlayer** (system UI, AirPlay, PiP, HDR) or to a **software-decode renderer**. Built on our own **LGPL-only FFmpeg**. First consumer is `~/Documents/Development/PlayerApp`. Later it is to be licensed and sold as a separate product to other developers.

**This is step one.** The PlayerApp project is not created until milestone E3 in the acceptance criteria passes (an MKV plays through AVPlayer).

@docs/ACCEPTANCE_CRITERIA.md
@docs/PROGRESS.md

Evidence behind the choices: `docs/RESEARCH.md`. Read it before touching licensing, build scripts or distribution.

## Locked decisions (from the owner)

- Separate package and repository with its own license boundary. No app code, StoreKit, analytics or UI chrome lives here.
- Platforms: iOS/iPadOS 27.0, macOS 27.0 (Apple silicon only), visionOS 27.0 (the owner has no device, so visionOS is simulator-verified only). **tvOS is excluded for good.** Swift 6.4, Xcode 27.1 SDK.
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

- Run the verify script before reporting done, tick the acceptance boxes with evidence, and list what is unverified.
- Hardware-only items are tagged `[device]`; write a short device test script for the owner. visionOS items stay `[sim]` until someone with a headset tests.
- Ask the owner before: installing tools, downloading simulator runtimes, spending money, touching Apple accounts, publishing anything.
- Anything legal (EULA, patents, selling) is a draft for a lawyer, never a conclusion.

## Session continuity (so a new window can continue)

- Start of any session: read this file, then `docs/PROGRESS.md`, then continue from "Right now". Do not ask the owner to repeat decisions that are in the decisions log.
- When the owner gives a new task: add it to "Backlog" in `docs/PROGRESS.md` first (with the date), then work on it.
- After every finished step: update `docs/PROGRESS.md` (board, evidence, "Right now", handoff notes) and tick criteria with evidence. Update it before ending a turn, even when the work is half done.
- Cross-project: the engine lives in `~/Documents/Development/MediaEngine`, the app in `~/Documents/Development/PlayerApp`; each has its own `docs/PROGRESS.md`.

## Status

Phase: building. **E0 and E1 are complete** (verified 2026-10-24 by `scripts/verify.sh`); E2 (remux to AVPlayer) is next. Live status is in `docs/PROGRESS.md`.
