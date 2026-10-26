---
name: engine-verify
description: Run and interpret the MediaEngine checks (swift test, scripts/verify.sh, isolated timing pass, ASan/TSan/UBSan, instrumented-FFmpeg run) and hunt flaky tests. Use before reporting any engine work done, after changing Sources/ or Tests/, or when a test fails intermittently.
---

# Verifying MediaEngine

Always `export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer` first (scripts set it themselves; plain `swift`/`xcodebuild` do not). Run from the repo root. Never run two `swift` builds at once on the same build directory, and never run the playback or isolated passes while another build or test is running (the scripts run them one after the other).

## Which command

Three kinds of test pass exist (`scripts/lib/tests.sh`): **unit** (everything except the real-time AVPlayer suites; about 13 s, parallel), **playback** (the five AVPlayer suites named in `PLAYBACK_SUITES`; about 45 s, alone on the machine so load from other tests cannot make them flaky) and **isolated** (`ExclusiveTests`: timing, memory, descriptors; about 5 s). A new suite that waits for AVPlayer goes into `PLAYBACK_SUITES` (Swift type name) and uses the shared `waitUntil` of `TestSupport.swift`, whose bounds scale with `MEDIAENGINE_TEST_PATIENCE` (sanitizer runs set 4).

| Need | Command | Time |
|---|---|---|
| After every change | `scripts/check.sh` (build with zero warnings, API hygiene, unit pass) | ~15 s |
| One suite or test | `scripts/check.sh <name>` (or `swift test --filter <name>`) | seconds |
| Before saying a step is done | `scripts/verify.sh --quick` (sources, licenses, API hygiene, ground truth, build, unit + playback + isolated passes) | ~2 min |
| Before a commit or milestone | `scripts/verify.sh` (quick + package traits + iPhone, iPad, iPhone Duo and visionOS simulators, run side by side) | ~4 min |
| Memory, threads, FFmpeg internals; releases | `scripts/verify.sh --deep` (full + AddressSanitizer with instrumented FFmpeg, ThreadSanitizer, UBSan) | ~10 min |
| One sanitizer | `scripts/check-sanitized.sh address\|thread\|undefined` (`--rebuild` rebuilds the instrumented FFmpeg) | 1-3 min each |
| A flaky test | `scripts/flake-hunt.sh <runs> --filter <SuiteOrTest>` (failure counts per test) | runs x test time |

Git hooks (`scripts/install-hooks.sh`, already set up in this clone): pre-commit runs `scripts/check.sh` when a commit touches code, tests, scripts, profiles or fixtures; pre-push runs `scripts/verify.sh --quick`. Skip once with `MEDIAENGINE_SKIP_HOOKS=1`. Every script prints how long each step took (also in `build/verify-logs/summary.txt`); build caches of the trait and sanitizer runs live in `.build-traits/`, `.build-sanitized`, `.build-tsan`, `.build-ubsan` (git-ignored) so they stay warm.

## Reading the output

- Filter noise: `... 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "error:|warning:|􀢄|Test run with" | grep -v started`.
- Search failures for the marker `􀢄`, not for "recorded an issue" (that misses some). Known and expected: `HDR10 (PQ) over HLS is rejected by AVPlayer` (E-S3, open) and `AVPlayer does not take HLS media segments from a resource loader` (two issues, a tripwire for a future SDK).
- `verify.sh` fails on any warning in our code. Fix warnings, do not filter them.
- Test counts (2026-10-26): macOS 263 = 244 unit + 19 playback (3 known issues), isolated pass 9, simulators 243 (AVPlayer/AVAssetReader tests are macOS-only).

## Rules

- Fuzz and damage tests use the seeded `SplitMix64` of `TestSupport.swift`, never the system generator: a crash that depends on luck cannot be reproduced or kept fixed (the EBML parser's `Int64(value)` trap of 2026-10-26 showed up in only about one run in four). Every number read from a file is converted with `Int64(exactly:)`/`clamping:` and added with `addingReportingOverflow`; look for a backtrace with `SWIFT_BACKTRACE="enable=yes,interactive=no,color=no,output-to=<dir>/crash-%p.txt"` (run the tests from `bash`, not `zsh`: an unmatched glob in zsh aborts the whole command).
- A test that measures time, memory, descriptors or CPU belongs in `ExclusiveTests` (skipped unless `MEDIAENGINE_EXCLUSIVE=1`); other tests run in parallel and spoil the numbers. Keep a functional version in the normal run without the time bound.
- Under AddressSanitizer footprints are meaningless (quarantine); tests detect it with `dlsym("__asan_init")`.
- A test that sleeps/polls to act while something is "in flight" is racy under parallel load; block the operation instead (`GatedByteSource`).
- Flaky test: `scripts/flake-hunt.sh`; do not guess. Fix the cause (usually a timing bound under parallel load, or a test that belongs in the playback pass) rather than raising limits blindly. A failure message of a real-time test should say why the player waits (`reasonForWaitingToPlay`, item error), so one occurrence is enough to start from.
- Report faithfully: say which commands ran, the counts, and anything not run (for example hardware-only items).
- `Package.swift` switches to the sanitized FFmpeg framework with `MEDIAENGINE_SANITIZED_FFMPEG=1`; a normal run afterwards rebuilds against the normal one.
