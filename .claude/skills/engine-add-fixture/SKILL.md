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

## Subtitle fixtures

- Rendering tests that must not depend on system fonts use the generated block font (`Fixtures/src/BlockFont.ttf`, made by `scripts/make-block-font.py`, family "Media Blocks": every letter is a rectangle). Attach it with `-attach src/BlockFont.ttf -metadata:s:t:0 mimetype=application/x-truetype-font -metadata:s:t:0 filename=BlockFont.ttf`. `fixture-ass-fx.mkv` and the ordered-chapter fixtures carry it.
- Picture subtitles (PGS, VobSub, DVB): `scripts/make-bitmap-subs.py` writes the `.sup` and `.idx/.sub` by hand; `fixture-bitmap.mkv` holds all three. Needs the rebuilt host tools (see engine-rebuild-ffmpeg) and `-copyts`.
- Golden frames: `Tests/MediaEngineTests/GoldenFrameTests.swift` (scenes) and `Tests/MediaEngineTests/Golden/*.png`; re-record with `MEDIAENGINE_RECORD_GOLDEN=1` and look at every picture.
- A recipe that changes the ordered-chapter fixtures changes their ground truth: regenerate `Fixtures/ground-truth/*.json` for them and rerun `OrderedChapters|TimelineReader|PlayListSession|PlayListPlayback`.

## Legacy-container fixtures

`scripts/make-fixtures.sh` has the recipes (AVI/Xvid and AVI/H.264, FLV, RealMedia with RealVideo 2, WMV, MPEG-2 program stream, MPEG-TS, and OGM written by `scripts/make-ogm.py`). `Fixture.url(_:)` finds a fixture by name with any known extension; `Fixture.legacyNames` lists them; `Fixture.probeable` is what the running build can read completely (RealMedia only in the extended build, Flash video size needs its decoder). Ground truth works for every `fixture-*.*` file.

## Interlaced and anamorphic fixtures

`fixture-interlaced-tff.mpg`, `fixture-interlaced-bff.mpg` (MPEG-2, two fields from a 50 Hz source woven into 25 Hz pictures with `scale=...,weave=first_field=top|bottom`) and `fixture-anamorphic.mkv` (MPEG-4 with `setsar=16/11`) come from the last recipe block of `scripts/make-fixtures.sh`. Official codec test vectors are not fixtures: `scripts/fetch-conformance.sh` downloads them into the git-ignored `build/conformance`.
