---
name: engine-codec-profile
description: Switch on (or off) an opt-in codec profile in MediaEngine and get it into Eiga - the profile JSON, CodecProfile flag and detection, the planner, the extended-plus variant in the scripts, the FFmpeg rebuild, the licence check, the patent-profile and DocC docs, the export to the app, and the app's format policy and records. Use when the owner decides that a held-back codec (as DTS core on 2026-11-12 and VC-1 on 2026-11-17) should play, or that one should be taken out, and when the app says "X needs an optional module that this build does not include".
---

# Switching on an opt-in codec profile

The licensing strategy (CLAUDE.md, RESEARCH 3): Apple's decoders first; our own decoders only for royalty-free or expired codecs;
anything else in an opt-in profile. A pooled codec goes in **only on the owner's explicit decision**, recorded as "risk accepted by the
owner, not a legal clearance" (never as cleared). Before that, give the owner the facts once (what Apple decodes, the pool, what is
known and unknown about expiry, with sources), then do what they decide. Legal wording is a draft for a lawyer.

## The recipe (VC-1, 2026-11-17, is the worked example)

1. **Profile** `profiles/<name>.json`: `libraries`, `parsers`, `decoders` (and demuxers/bsfs if needed), a `description` that names the
   owner's decision and date, and `codecStatus` per codec (`accepted-risk` with a note: pool, expiry facts, "Apple's licence does not
   cover this decoder"). `scripts/gen-config.py` turns it into configure flags. Never put a pooled decoder in `core.json`.
2. **Flag** in `PlaybackPlan.swift`: `public static let <name> = CodecProfile(rawValue: 1 << n)` (next free bit; `vc1Software` is 1 << 7).
3. **Detection** in `MediaEngine.swift` (`detectedProfiles`): `if avcodec_find_decoder_by_name("<decoder>") != nil { profiles.insert(.<name>) }`.
   `MediaEngine.availableProfiles` is what the planner and the app see.
4. **Planner** (`PlaybackPlan.swift`): the codec's case returns the treatment that needs the profile (VC-1:
   `Decision(treatment: .software(.vc1Software), needs: .vc1Software)`, since Apple has no VC-1 decoder; DTS: transcode to ALAC needing
   `.dtsCore`). Without the profile the plan says `.unsupported` with `needsCodecProfile`.
5. **Tests** (written now, run on the owner's word): `SecurityTests.noPooledDecoders` (the codec is allowed only when the profile is
   present), `PlaybackPlannerTests` (with and without the profile).
6. **Variant**: the app links `extended-plus` = `core+extended+dtsCore+h264Software+hevcSoftware+audioFallback+vc1Software`. Add the
   profile to that string everywhere it is spelled out: `scripts/lib/common.sh` (`VARIANTS` and `variant_suffix`), `build-all.sh`
   (build and package lines), `write-build-info.sh`, comments in `package-xcframework.sh` and `export-package.sh`,
   `scripts/gen-patent-profiles.py` (`PROFILES` and its text). Install folders are `build/install/<slice>-<profiles joined by +>`; the
   old ones stay behind unused.
7. **Docs**: `python3 -I scripts/gen-patent-profiles.py` (regenerates `docs/PATENT_PROFILES.md`; `--check` must pass), the DocC article
   `MediaEngine.docc/OptionalCodecModules.md`, `docs/INTEGRATION.md`, RESEARCH 3.2 (a numbered point with the facts and the owner's
   words), `CLAUDE.md` licensing line, PROGRESS (Backlog, decisions log, Done), the acceptance note of the affected criterion.
8. **Rebuild** (heavy: announce it, start only when the owner says it is a good moment): `scripts/build-all.sh`, or per slice
   `scripts/build-ffmpeg.sh <slice> <profiles…>` then `scripts/package-xcframework.sh <variant>`. On 2026-11-17 the five-slice rebuild of
   extended-plus took 54 min at background priority; since visionOS left there are three slices. Run it in the background, one
   notification per finished slice.
9. **Check the binary**: `nm` on the slice's static `libavcodec.a` in `build/install/…` (e.g. `ff_vc1_decoder`; the framework's own
   symbols are not exported, so `strings` on the framework binary for the decoder's long name, "SMPTE VC-1"), and that nothing else
   came in (no TrueHD). `MEDIAENGINE_VARIANTS=<variant> scripts/check-licenses.sh` must pass.
10. **Export to the app**: `scripts/export-package.sh extended-plus` (the app builds against `dist/package/MediaEngine`, not the working
    tree). **Forgetting this is the symptom "X needs an optional module that this build does not include"**: the app still links the old
    framework. Then in Xcode Product > Clean Build Folder.
11. **App** (`~/Documents/Development/PlayerApp`): `Packages/PlayerCore/Sources/PlayerCore/FormatPolicy.swift` decides free or Pro
    (only `.extended` outside Matroska asks for Pro, so VC-1 in Blu-ray streams and MKV is free and WMV 9 in ASF is Pro; DTS free);
    `CLAUDE.md` licensing lines, the criteria's decision table (D-3, D-12), PROGRESS decisions log, `docs/HOW_TO_TEST.md`, Jira (EGA-53
    holds what stays for 2.0; tickets begin with "**Claude-generated.**").
12. **Play a real file** (skill `engine-share-check`) before calling it done; on the software path also the picture rate (skill
    `engine-software-player`).

## Taking one out

The same places in reverse; the binary must lose the decoder (`check-licenses.sh` and `nm`), the planner must say `needsCodecProfile`
again, and the app must show the held-back sign (the ⓘ "How to Hear It" for sound).

## Facts found on the way

- Apple has no VC-1 decoder at all: no VC-1 codec type in CoreMedia's `CMFormatDescription.h`, so VC-1 is always our decoder.
- The DTS core decoder is patched to core only (`third_party/patches/ffmpeg-0001-dts-core-only.diff`); DTS-HD and DTS:X tracks play
  their core.
- FFmpeg's VC-1 decoder has no threading (one core): see `engine-software-player` for what that means on a phone.
