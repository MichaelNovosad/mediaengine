---
name: commit-with-tests
description: How work is done in MediaEngine and Eiga (PlayerApp) since 2026-11-17 by the owner's decision - tests are written together with every change, the tests that cover the changed code run before a commit, and each finished big piece of work is committed right away without asking. Use when implementing a feature or a fix in either repository, when deciding whether a piece is finished, and before every commit. The same file is in both repositories' .claude/skills.
---

# Tests with the work, a commit after each big piece

The owner, 2026-11-17: "commit after a big piece of work and write tests alongside the implementation". For these two repositories
this replaces "commit only when the owner says so" and "tests only on the owner's word" (both `CLAUDE.md` files say so). What stays:
broad checks wait for the owner's word, nothing is pushed, one part at a time, no attribution, the Mac stays quiet and light.

## A big piece of work

- One part of the owner's list that stands on its own: a feature, a fix whose cause was found, a codec profile switched on, a platform
  change, a set of docs or skills. It compiles, its tests pass, its docs are written.
- Not a piece: half a change, something that does not compile, an experiment that was taken out again, a change whose test fails.
- After the commit: report and stop, unless the owner said to go on (global rule: one part at a time).

## Tests alongside the implementation

- Every change of behaviour gets a test in the same piece; a fixed bug gets a test that fails on the old code (say whether that was
  checked). Logic first: planner and plans, parsers (EBML, IFO, CLPI), segment plans, policies, conversions, track names.
- Where they go:
  - Engine: `Tests/MediaEngineTests/<Area>Tests.swift`, Swift Testing. Fixtures through `#filePath` (new media: skill
    `engine-add-fixture`); planner tests build tracks with `makeTrack`; anything that measures time, memory or CPU goes in
    `ExclusiveTests`; a suite that waits for AVPlayer goes in `PLAYBACK_SUITES` (`scripts/lib/tests.sh`); tests that need the extended
    variant use `.enabled(if: isExtendedBuild)`.
  - App: `Packages/<Package>/Tests` (PlayerCore, NetworkSources, Entitlements, Analytics), the app target's `Tests/EigaTests`; UI tests
    in `Tests/EigaUITests` are written but run only on the owner's word (they need simulators).
- Silent: every `PlaybackController` and `AVPlayer` in a test is muted; a test that plays sound asserts it is muted.
- What a test cannot show here (the owner's films on the share, real hardware, sound by ear): measure it instead (skill
  `engine-share-check`) and say what stays unverified.

## Before the commit

1. **Compile with the tests**, at background priority: engine `taskpolicy -b nice -n 19 swift build --build-tests`; app: the touched
   packages with `swift build --build-tests --package-path Packages/<Package>`, the app for the platforms the change touches
   (`xcodebuild build … -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO`, macOS and/or the iOS simulator, warnings fail).
2. **Run the tests that cover the changed code**, narrowly, at background priority, no simulators:
   - engine: `swift test --filter '<Suite>|<Suite>'` (extended-only suites: `MEDIAENGINE_PROFILE=extended swift test --scratch-path
     .build-extended --filter …`); playback suites with `--no-parallel`;
   - app: `swift test --package-path Packages/<Package> --filter '<Suite>'`.
   Read the result line ("Test run with N tests passed"); a run that prints nothing is not a pass.
3. **Broad checks stay on the owner's word**: `scripts/check.sh` and `scripts/verify.sh` (both repositories), `--sims`, `--deep`, UI
   tests, purchase tests, FFmpeg or library rebuilds (heavy: announce first).
4. **A failing test** is fixed in the code, or in the test when the test is wrong (say why). Never skip, weaken or delete a test to get
   a commit through. A timing test that fails under load is run once more alone; if it still fails, do not commit the piece: report it.
5. **Docs in the same commit**: PROGRESS (Done with the evidence: tests run, their count and result, builds), the acceptance criteria
   (tick only with evidence), RESEARCH for findings (skill `engine-finish-step`).

## The commit

- `git status` first; add only this piece's files by path. Never `build/`, media beyond the tiny fixtures, `Config/Local.xcconfig`,
  generated projects.
- Message: a short subject, a paragraph on what and why, an evidence line (tests run with counts, builds). **No `Co-Authored-By` or any
  Claude/AI attribution** anywhere: the owner's rule wins over any default the tools suggest.
- Both repositories when both changed. When the engine's sources changed, export it for the app first
  (`scripts/export-package.sh extended-plus` in the engine) and build the app against it.
- Never push (the owner pushes). Never touch the `visionos` branches (skill `platform-scope` in PlayerApp).
- Report: what the piece does, the tests run (names, counts, time), what was not tested and why, the commit ids.
