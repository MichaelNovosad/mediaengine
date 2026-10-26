---
name: engine-verify
description: Run and interpret the MediaEngine checks (swift test, scripts/verify.sh, isolated timing pass, ASan/TSan/UBSan, instrumented-FFmpeg run) and hunt flaky tests. Use before reporting any engine work done, after changing Sources/ or Tests/, or when a test fails intermittently.
---

# Verifying MediaEngine

**The owner works on this Mac while checks run (video calls, audio): read the rule in CLAUDE.md first. Scripts run at background priority and silent; do not start `--sims`, `--deep`, `build-all.sh` or sanitizer runs without the owner's go-ahead, and never run several heavy things at once.**

Always `export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer` first (scripts set it themselves; plain `swift`/`xcodebuild` do not). Run from the repo root. Never run two `swift` builds at once on the same build directory, and never run the playback or isolated passes while another build or test is running (the scripts run them one after the other).

## Which command

Three kinds of test pass exist (`scripts/lib/tests.sh`): **unit** (everything except the real-time AVPlayer suites; about 13 s, parallel), **playback** (the AVPlayer and software-player suites named in `PLAYBACK_SUITES`, run one after another with `--no-parallel`; about 85 s, alone on the machine so load from other tests cannot make them flaky) and **isolated** (`ExclusiveTests`: timing, memory, descriptors; about 5 s). A new suite that waits for AVPlayer goes into `PLAYBACK_SUITES` (Swift type name) and uses the shared `waitUntil` of `TestSupport.swift`, whose bounds scale with `MEDIAENGINE_TEST_PATIENCE` (sanitizer runs set 4).

| Need | Command | Time |
|---|---|---|
| After every change | `scripts/check.sh` (build with zero warnings, API hygiene, unit pass) | ~15 s |
| One suite or test | `scripts/check.sh <name>` (or `swift test --filter <name>`) | seconds |
| Before saying a step is done | `scripts/verify.sh --quick` (sources, licenses, API hygiene, ground truth, build, unit + playback + isolated passes) | ~2 min |
| Before a commit or milestone | `scripts/verify.sh` (quick + package traits + sample apps for macOS) | ~8 min at background priority |
| Simulators (ask the owner first) | `scripts/verify.sh --sims` (full + iOS/visionOS samples + iPhone, iPad, iPhone Duo and visionOS simulators, one at a time, each shut down after) | ~10 min |
| Memory, threads, FFmpeg internals; releases (ask the owner first) | `scripts/verify.sh --deep` (full + benchmark gate + AddressSanitizer with instrumented FFmpeg, ThreadSanitizer, UBSan) | ~15 min |
| One sanitizer | `scripts/check-sanitized.sh address\|thread\|undefined` (the instrumented FFmpeg is rebuilt on `--rebuild` and whenever `profiles/core.json` or `build-ffmpeg.sh` is newer than it; a stale one fails tests for the wrong reason) | 1-3 min each |
| A flaky test | `scripts/flake-hunt.sh <runs> --filter <SuiteOrTest>` (failure counts per test) | runs x test time |
| Benchmarks against the stored baseline (PRF-1) | `scripts/bench.sh` (3 runs of `BenchmarkTests` on a synthetic 1080p file; `--record` stores this machine's baseline in `Benchmarks/baseline.json`); part of `--deep` | ~1 min |
| Documentation, samples, source pack, framework swap | `scripts/check-docs.sh` (DocC, zero warnings), `scripts/check-samples.sh` (QuickStart and Player for macOS, iOS, visionOS), `scripts/check-source-pack.sh`, `scripts/test-framework-swap.sh`; all run inside `verify.sh` | 0.5-3 min each |
| Generated documents and data | `scripts/gen-patent-profiles.py` (docs/PATENT_PROFILES.md), `scripts/gen-acknowledgements.py` (Sources/MediaEngine/Acknowledgements.generated.swift): `--check` is part of `check.sh` and `verify.sh`; regenerate after changing a profile or a pin |
| Decoder conformance | `scripts/fetch-conformance.sh` downloads 64 libvpx/libaom vectors into `build/conformance` (pinned in `third_party/conformance.lock`); `ConformanceTests` need the extended build (`MEDIAENGINE_PROFILE=extended swift test --scratch-path .build-extended --filter ConformanceTests`) |

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

## Lessons from the E4 to E6 work (2026-10-26)

- The playback pass runs its suites one after another (`--no-parallel`). Run side by side they starve each other: the play-list suite took 100 s and failed seeks instead of 12 s and passing. Anything real-time (AVPlayer, the software player's display layer) belongs in `PLAYBACK_SUITES`, including `SoftwarePipelineTests`.
- The owner's own apps (a browser playing video) use CPU too: if a real-time test fails once and passes alone, check `ps -Ao pcpu,comm -r | head` before suspecting the code, then `scripts/flake-hunt.sh`.
- Tests that need the extended binary use `.enabled(if: isExtendedBuild)`; verify runs them against `.build-extended`. Sanitizer runs of the extended variant are not part of `check-sanitized.sh` yet.
