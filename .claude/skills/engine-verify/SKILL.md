---
name: engine-verify
description: Run and interpret the MediaEngine checks (swift test, scripts/verify.sh, isolated timing pass, ASan/TSan/UBSan, instrumented-FFmpeg run) and hunt flaky tests. Use before reporting any engine work done, after changing Sources/ or Tests/, or when a test fails intermittently.
---

# Verifying MediaEngine

Always `export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer` first (scripts set it themselves; plain `swift`/`xcodebuild` do not). Run from the repo root. Never run two `swift` builds at once, and never run timing-sensitive work while another build or test is running.

## Which command

| Need | Command | Time |
|---|---|---|
| Quick feedback while coding | `swift test` (functional only, macOS) | ~40 s |
| One suite or test | `swift test --filter <SuiteOrTestName>` | seconds |
| Gate before "done" | `scripts/verify.sh` (sources, licenses, API hygiene, ground truth, macOS tests, isolated pass, traits, iPhone, iPad, iPhone Duo, visionOS simulators) | ~6 min |
| Same without simulators | `scripts/verify.sh --quick` | 1-2 min |
| Timing, memory, descriptors, CPU | `MEDIAENGINE_EXCLUSIVE=1 swift test --filter ExclusiveTests` | ~5 s |
| Sanitizers on Swift code | `swift test --sanitize=address` / `thread` / `undefined` | ~40 s each |
| Memory errors inside FFmpeg too | `scripts/check-sanitized.sh` (`--rebuild` to rebuild the instrumented framework) | ~1-2 min |

## Reading the output

- Filter noise: `... 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "error:|warning:|􀢄|Test run with" | grep -v started`.
- Search failures for the marker `􀢄`, not for "recorded an issue" (that misses some). Known and expected: `HDR10 (PQ) over HLS is rejected by AVPlayer` (E-S3, open) and `AVPlayer does not take HLS media segments from a resource loader` (two issues, a tripwire for a future SDK).
- `verify.sh` fails on any warning in our code. Fix warnings, do not filter them.
- Test counts (2026-10-25): macOS 144 (3 known issues), simulators 134 (AVPlayer/AVAssetReader tests are macOS-only), isolated pass 8.

## Rules

- A test that measures time, memory, descriptors or CPU belongs in `ExclusiveTests` (skipped unless `MEDIAENGINE_EXCLUSIVE=1`); other tests run in parallel and spoil the numbers. Keep a functional version in the normal run without the time bound.
- Under AddressSanitizer footprints are meaningless (quarantine); tests detect it with `dlsym("__asan_init")`.
- A test that sleeps/polls to act while something is "in flight" is racy under parallel load; block the operation instead (`GatedByteSource`).
- Flaky test: loop `swift test > build/flake/runN.log 2>&1` several times and grep the logs; do not guess. Fix the cause (usually a timing bound under parallel load) rather than raising limits blindly.
- Report faithfully: say which commands ran, the counts, and anything not run (for example hardware-only items).
- `Package.swift` switches to the sanitized FFmpeg framework with `MEDIAENGINE_SANITIZED_FFMPEG=1`; a normal run afterwards rebuilds against the normal one.
