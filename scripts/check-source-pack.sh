#!/bin/bash
# LIC-3 check: a source pack can be made from this checkout and contains everything the LGPL asks for.
source "$(dirname "$0")/lib/common.sh"
out="$BUILD/source-pack-check"; rm -rf "$out"
./scripts/make-source-pack.sh --label check --no-compress --out "$out" >/dev/null
pack="$out/MediaEngine-sources-check"
fail=0; bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

# Every pinned source is in the pack and matches its pin; GPL-only extras are not.
grep -v '^#' "$ROOT/third_party/sources.lock" | while IFS=$'\t' read -r pin version url sha rest; do
  [ -n "${pin:-}" ] || continue
  f="$pack/sources/$pin-$version/$(basename "$url")"
  [ -f "$f" ] && [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$sha" ] || { echo "FAIL: $pin $version is missing or does not match its pin" >&2; exit 1; }
done || fail=1

# BUILD-INFO names every variant and slice, and the configure lines are complete.
info="$pack/BUILD-INFO.txt"
for variant in core core+extended; do
  for s in $SLICES; do
    grep -q "FFmpeg configure line, $variant, slice $s:" "$info" || bad "BUILD-INFO.txt lacks the configure line of $variant/$s"
  done
done
[ "$(grep -c -e '--disable-gpl' "$info")" -ge 10 ] || bad "BUILD-INFO.txt: configure lines without --disable-gpl"
grep -q -e '--enable-libdav1d' "$info" || bad "BUILD-INFO.txt: the extended configure lines do not mention libdav1d"
grep -q 'dav1d build, slice macos' "$info" && ! grep -q '(not built)' "$info" || bad "BUILD-INFO.txt lacks the dav1d build recipe"
grep -q -e '--enable-gpl' "$info" && bad "BUILD-INFO.txt: a configure line enables GPL"

# Procedure, notices, build scripts, checksums.
for f in README.txt REPLACING-FFMPEG.md REQUIRED-FFMPEG-SYMBOLS.txt PATENT_PROFILES.md third_party/NOTICES.md third_party/sources.lock \
         scripts/build-all.sh scripts/build-ffmpeg.sh scripts/build-dav1d.sh scripts/build-subtitle-libs.sh scripts/package-xcframework.sh \
         profiles/core.json profiles/extended.json patches/README.md SHA256SUMS; do
  [ -f "$pack/$f" ] || bad "the pack lacks $f"
done
( cd "$pack" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1 ) || bad "SHA256SUMS does not verify"

# Patches: none, or every diff applies (the pack says how many).
patches="$(find "$pack/patches" -name '*.diff' | wc -l | tr -d ' ')"
grep -q "Patches applied to the sources: $patches" "$info" || bad "BUILD-INFO.txt and patches/ disagree about the number of patches"

[ "$fail" = 0 ] || die "source pack check failed"
log "source pack complete: $(find "$pack" -type f | wc -l | tr -d ' ') files, $(du -sh "$pack" | awk '{print $1}')"
rm -rf "$out"
