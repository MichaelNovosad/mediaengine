---
name: engine-add-fixture
description: Add a tiny generated test video (fixture) to MediaEngine with its ffprobe ground truth and wire it into the tests. Use when a bug needs a new kind of media (B-frames, new codec, odd timestamps) or a test needs a file that does not exist yet.
---

# Adding a fixture

Fixtures live in `Fixtures/*.mkv` (each under 2 MB, committed) with ffprobe JSON in `Fixtures/ground-truth/`. They are made by our own host `build/tools/bin/ffmpeg` (LGPL build plus dev-only encoders from `profiles/host-tools.json`), never by Homebrew's GPL ffmpeg. If `build/tools/bin/` is missing, run `scripts/build-host-tools.sh`.

1. **Add the recipe** to `scripts/make-fixtures.sh` (copy a neighbouring section; lavfi sources like `testsrc2`, `sine`, `anoisesrc`; VideoToolbox/AudioToolbox encoders for H.264/HEVC/AAC). Keep it short (3-14 s) and say in the `log` line what the file is for.
2. **Generate only this file.** `make-fixtures.sh` rewrites every fixture (VideoToolbox output is not reproducible) and so does `scripts/build-all.sh`. Run the new recipe's command by hand from `Fixtures/` instead (use absolute paths afterwards; `cd` moves the shell), then:
   `build/tools/bin/ffprobe -v error -show_format -show_streams -show_chapters -of json fixture-x.mkv > ground-truth/fixture-x.json`
3. **Register it in tests:** add the name to `Fixture.names` in `Tests/MediaEngineTests/TestSupport.swift` (ground-truth and probe-speed tests iterate it). Then decide where else it belongs: `RemuxTests` argument lists (`fragmentsAreComplete`, `avfoundationDecodes`), `DamagedFileTests.names` (fuzz corpus), an AVPlayer end-to-end test in `PlaybackSessionTests`.
4. **Check:** `scripts/check-ground-truth.sh`, then `swift test`. If the fixture is meant to exercise a code path (for example reordering), add an assertion that proves it does (`session.reorder.delay >= 1`), so a re-encode that loses the feature fails loudly.
5. Note it in `docs/PROGRESS.md` (Done) and, if it lifts a gap, in the matching criterion (for example ANM-1).

Never commit large or real media; real test files go in a gitignored `TestMedia/` or the scratchpad.
