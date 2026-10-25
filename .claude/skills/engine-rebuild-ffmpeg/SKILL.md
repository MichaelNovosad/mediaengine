---
name: engine-rebuild-ffmpeg
description: Rebuild the LGPL FFmpeg framework for MediaEngine after changing a codec profile, the FFmpeg version, or the build scripts; also host tools and the sanitized variant. Use when adding an encoder/decoder/demuxer to profiles/*.json or when a build or license check fails.
---

# Rebuilding FFmpeg

Pinned sources: `third_party/sources.lock` (SHA-256 and key fingerprints, verified by `scripts/fetch-sources.sh`). Builds are out of tree under `build/`. Needs the tools from `scripts/bootstrap.sh` (meson, ninja, cmake, gpg, Rust); ask the owner before installing anything.

## Changing what is compiled in

1. Edit `profiles/core.json` (or `extended`, `licensedAudio`; `host-tools.json` is developer-only). `scripts/gen-config.py` turns the lists (demuxers, muxers, parsers, bsfs, decoders, encoders, indevs, protocols) into configure flags and the license report. Nothing else needs editing.
2. **Do not add decoders for pooled codecs to `core`** (H.264, HEVC, AAC, AC-3, VC-1, DTS...). Strategy agreed with the owner: Apple decodes what it can, own decoders only for royalty-free or expired codecs, the rest opt-in and off until a lawyer clears it (`docs/RESEARCH.md` section 3). H.264 Hi10P is out of scope. Ask the owner when unsure.
3. `scripts/build-all.sh core` rebuilds all five slices (macos, ios, ios-simulator, xros, xros-simulator, arm64) and packages `build/FFmpegLGPL.xcframework` (~2.5 min). **It also regenerates every fixture and ground-truth JSON** (not bit-reproducible): either commit them together or `git checkout Fixtures` afterwards.
4. `scripts/check-licenses.sh` must pass (no GPL/nonfree strings or symbols). Then `scripts/verify.sh`.

## Variants

- One slice only: `scripts/build-ffmpeg.sh <slice> core`, then `scripts/package-xcframework.sh core` (the script needs the install of all five slices under `build/install/`, so a single-slice build is for checking configure/compile only).
- Host tools (ffmpeg/ffprobe for fixtures, with VideoToolbox encoders etc.): `scripts/build-host-tools.sh`.
- AddressSanitizer variant: `FFMPEG_SANITIZE=address scripts/build-ffmpeg.sh macos core && FFMPEG_SANITIZE=address scripts/package-xcframework.sh core` (or `scripts/check-sanitized.sh --rebuild`); output `build/FFmpegLGPL-address.xcframework`, never replaces the normal one.

## Gotchas

- Bash 3.2 rules (macOS default): no `mapfile`, no associative arrays; avoid `grep -q` in `pipefail` pipelines.
- `lavfi` is an input device (`indevs`), needs the `wrapped_avframe` decoder; `ffmetadata` is a demuxer.
- The native `alac` encoder is used for lossless audio (AudioToolbox's pads the last frame and rejects 24-bit).
- Never link Homebrew's `ffmpeg` (GPL). Product name must not contain "FFmpeg".
- The framework is a build product (git-ignored); `Package.swift` points at `build/FFmpegLGPL.xcframework`.

## The subtitle libraries (LibASS.framework)

libass, FreeType, HarfBuzz and FriBidi are a second binary, `build/LibASS.xcframework` (git-ignored like the FFmpeg one; `Package.swift` points at it). Pins and signatures are in `third_party/sources.lock` (HarfBuzz and FriBidi publish none: SHA-256 only).

- Rebuild: `for s in macos ios ios-simulator xros xros-simulator; do scripts/build-subtitle-libs.sh $s; done && scripts/package-subtitle-xcframework.sh` (about 1 min, slices can run in parallel). `scripts/build-all.sh` does it too.
- New version: change the line in `sources.lock` (download first, `shasum -a 256`, check the signature with `gpg`, note that the lock wants the **primary** key fingerprint that `VALIDSIG` prints last), run `scripts/fetch-sources.sh`, rebuild, run the tests, then **re-record the golden frames** (`MEDIAENGINE_RECORD_GOLDEN=1 swift test --filter GoldenFrameTests`) and look at the pictures before committing them.
- Never build with `-fvisibility=hidden`: the framework's export list (`_ass_*`) then matches nothing. Only libass's `ass_*` leaves the framework; `scripts/check-licenses.sh` checks that, the linked libraries and the four licence texts.
- Licences: libass ISC, FreeType under the FTL (an app must show the credit line in `third_party/NOTICES.md`), HarfBuzz MIT, FriBidi LGPL-2.1 (the framework is dynamic so it can be replaced).
- The host `ffmpeg` also has the `sup`, `vobsub`, `mpegps` demuxers, the `dvdsub`, `pgssub`, `dvbsub` decoders and the `dvdsub`, `dvbsub` encoders, for the picture-subtitle fixtures (`scripts/make-bitmap-subs.py`; give `-copyts` when muxing a `.sup`).
