#!/bin/bash
# LIC-3: the source pack that ships next to every release: the exact upstream source archives with their signatures and keys,
# our patches (third_party/patches), the build scripts and codec profiles, BUILD-INFO.txt (configure lines, tool versions), the notices, and
# the procedure for replacing the FFmpeg framework. Everything an LGPL recipient needs to rebuild the binaries.
# usage: scripts/make-source-pack.sh [--label <name>] [--no-compress] [--out <dir>]
#   default output: dist/MediaEngine-sources-<label>.tar.xz (+ .sha256); label = the date.
source "$(dirname "$0")/lib/common.sh"

label="$(date -u +%Y%m%d)"; compress=true; out="$ROOT/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --no-compress) compress=false; shift ;;
    --out) out="$2"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

name="MediaEngine-sources-$label"
stage="$out/$name"
rm -rf "$stage"; mkdir -p "$stage/sources" "$stage/patches"

# 1. The exact archives (and what verifies them), as pinned.
grep -v '^#' "$ROOT/third_party/sources.lock" | while IFS=$'\t' read -r pin version url sha sigurl fpr keyurl; do
  [ -n "${pin:-}" ] || continue
  dl="$BUILD/downloads/$pin-$version"; file="$dl/$(basename "$url")"
  [ -f "$file" ] || die "$pin: archive missing, run scripts/fetch-sources.sh"
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ "$actual" = "$sha" ] || die "$pin: archive does not match the pinned SHA-256"
  mkdir -p "$stage/sources/$pin-$version"
  cp "$file" "$stage/sources/$pin-$version/"
  [ -f "$file.asc" ] && cp "$file.asc" "$stage/sources/$pin-$version/"
  [ -f "$dl/key.asc" ] && [ -n "${sigurl:-}" ] && cp "$dl/key.asc" "$stage/sources/$pin-$version/signing-key.asc"
  echo "$pin $version $url $sha ${fpr:-}" >> "$stage/sources/ARCHIVES.txt"
done

# 2. Build recipe: scripts, profiles, pins, notices, patches.
cp -R "$ROOT/scripts" "$stage/scripts"; rm -rf "$stage/scripts/hooks"
cp -R "$ROOT/profiles" "$stage/profiles"
mkdir -p "$stage/third_party"
cp "$ROOT/third_party/sources.lock" "$ROOT/third_party/NOTICES.md" "$ROOT/third_party/components.json" "$stage/third_party/"
cp "$ROOT/third_party/patches/README.md" "$stage/patches/"
find "$ROOT/third_party/patches" -name '*.diff' -exec cp {} "$stage/patches/" \;
cp "$ROOT/docs/REPLACING-FFMPEG.md" "$ROOT/docs/PATENT_PROFILES.md" "$stage/" 2>/dev/null || true
[ -f "$BUILD/REQUIRED-FFMPEG-SYMBOLS.txt" ] && cp "$BUILD/REQUIRED-FFMPEG-SYMBOLS.txt" "$stage/"
[ -f "$BUILD/BUILD-INFO.txt" ] || ./scripts/write-build-info.sh >/dev/null
cp "$BUILD/BUILD-INFO.txt" "$stage/"
for report in core extended extended-plus; do [ -f "$BUILD/LICENSE-REPORT-$report.md" ] && cp "$BUILD/LICENSE-REPORT-$report.md" "$stage/"; done

cat > "$stage/README.txt" <<TXT
MediaEngine source pack ($label)

This folder is the corresponding source of the binaries that ship with MediaEngine: FFmpeg (LGPL-2.1-or-later, dynamically
linked as FFmpegLGPL.framework), dav1d (BSD-2-Clause, inside the extended variants of that framework; the extended-plus variant also decodes the DTS core
and, where Apple's decoders refuse a stream, H.264, HEVC, AAC, AC-3 and E-AC-3; see PATENT_PROFILES.md and patches/) and the subtitle libraries
libass, FreeType, HarfBuzz and FriBidi (LibASS.framework).

  sources/            the unmodified upstream archives with signatures and signing keys (ARCHIVES.txt lists names, URLs, SHA-256)
  patches/            our changes to those sources as diffs (applied by scripts/fetch-sources.sh)
  scripts/, profiles/ how the binaries are built: scripts/build-all.sh does everything; profiles decide what FFmpeg contains
  BUILD-INFO.txt      tool versions and the exact configure line of every binary
  REPLACING-FFMPEG.md how to rebuild or replace the framework, REQUIRED-FFMPEG-SYMBOLS.txt what a replacement must export
  PATENT_PROFILES.md  the codecs in every profile with their licensing status (a draft for review, not legal advice)
  third_party/        pins and third-party notices
  SHA256SUMS          checksums of every file in this pack

Quick rebuild: copy sources/<name>-<version>/<archive> into build/downloads/<name>-<version>/ of a checkout of the scripts,
then run scripts/build-all.sh (needs Xcode 27, meson, ninja, cmake, gpg).
TXT

( cd "$stage" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 > SHA256SUMS )
if $compress; then
  ( cd "$out" && tar -cJf "$name.tar.xz" "$name" && shasum -a 256 "$name.tar.xz" > "$name.tar.xz.sha256" )
  log "source pack: $out/$name.tar.xz ($(du -h "$out/$name.tar.xz" | awk '{print $1}'))"
else
  log "source pack (not compressed): $stage"
fi
