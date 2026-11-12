#!/bin/bash
# Fails if any built slice or shipped framework could be anything other than LGPL-2.1-or-later FFmpeg.
# usage: scripts/check-licenses.sh [profile]      (default: core)
source "$(dirname "$0")/lib/common.sh"
profile="${1:-core}"
fail=0
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }
# No `grep -q` in pipelines: it exits at the first match, the upstream tool gets SIGPIPE, and
# `pipefail` then reports a failure for a pipeline that actually matched.
has()   { grep -E "$@" >/dev/null; }          # a matching line exists
lacks() { ! grep -E "$@" >/dev/null; }        # no matching line exists

# The core binary and every variant ($VARIANTS in lib/common.sh; all are required: the extended variant is what an app that
# gates legacy formats links, extended-plus the one with the DTS core and the fallback decoders). Same rules for all: LGPL FFmpeg, no GPL or nonfree configuration, only av*/swr* exported.
for variant_profile in $VARIANTS; do
  variant="$(variant_suffix "$variant_profile")"
  for s in $SLICES; do
    inst="$BUILD/install/$s-$variant_profile"
    [ -d "$inst" ] || { bad "$s: $variant_profile not built"; continue; }

    strings -a "$inst/lib/libavutil.a" | has "libavutil license: LGPL version 2.1 or later" \
      || bad "$s ($variant_profile): libavutil does not report 'LGPL version 2.1 or later'"

    conf="$(strings -a "$inst/lib/libavformat.a" | grep -m1 -e '--disable-gpl' || true)"
    [ -n "$conf" ] || bad "$s ($variant_profile): configuration string with --disable-gpl not found"
    for flag in --enable-gpl --enable-nonfree --enable-version3 --enable-libx264 --enable-libx265 --enable-libfdk-aac; do
      case "$conf" in *"$flag"*) bad "$s ($variant_profile): configuration contains $flag" ;; esac
    done

    fwbin="$(find "$BUILD/frameworks$variant/$s" -name FFmpegLGPL -type f 2>/dev/null | head -1)"
    if [ -n "$fwbin" ]; then
      strings -a "$fwbin" | has "libavutil license: LGPL version 2.1 or later" || bad "$s ($variant_profile): shipped framework license string"
      nm -gU "$fwbin" 2>/dev/null | lacks -i 'x264|x265|fdk' || bad "$s ($variant_profile): GPL/nonfree encoder symbols exported"
      nm -gU "$fwbin" 2>/dev/null | awk '{print $3}' | lacks -v '^_(av|swr)' || bad "$s ($variant_profile): exports symbols outside av*/swr*"
      otool -L "$fwbin" | tail -n +2 | lacks -v '(/System/Library/|/usr/lib/|@rpath/FFmpegLGPL)' || bad "$s ($variant_profile): links against non-system libraries"
      if [ "$variant_profile" != core ]; then
        fwres="$(dirname "$fwbin")"; [ -d "$fwres/Resources" ] && fwres="$fwres/Resources"
        [ -f "$fwres/licenses/dav1d-BSD-2-Clause.txt" ] || bad "$s ($variant_profile): the dav1d licence text is not inside the framework"
        strings -a "$fwbin" | has "dav1d" || bad "$s ($variant_profile): dav1d is not linked into the extended framework"
      fi
      # Our patch (third_party/patches/ffmpeg-0001-dts-core-only.diff): only the DTS core is decoded. Log texts of the DTS-HD
      # lossless and DTS Express decoders and of the core-extension search must not be in a framework.
      strings -a "$fwbin" | lacks "Invalid XLL sub-header checksum|Tonal group chunk too short|XCH sync word not found" \
        || bad "$s ($variant_profile): DTS extension code is in the framework (the core-only patch was not applied)"
    else
      bad "$s ($variant_profile): framework not packaged"
    fi
  done
done

# LibASS.framework: libass (ISC), FreeType (FTL), HarfBuzz (MIT), libunibreak (zlib), FriBidi (LGPL-2.1, replaceable because the framework is dynamic).
for s in $SLICES; do
  fwbin="$(find "$BUILD/frameworks-subs/$s" -name LibASS -type f 2>/dev/null | head -1)"
  if [ -z "$fwbin" ]; then bad "$s: LibASS framework not packaged"; continue; fi
  nm -gU "$fwbin" 2>/dev/null | awk '{print $3}' | lacks -v '^_ass_' || bad "$s: LibASS exports symbols outside ass_*"
  otool -L "$fwbin" | tail -n +2 | lacks -v '(/System/Library/|/usr/lib/|@rpath/LibASS)' || bad "$s: LibASS links against non-system libraries"
  strings -a "$fwbin" | lacks -i 'gnu general public|GPLv[23]|fontconfig' || bad "$s: LibASS contains GPL or unexpected components"
  res="$(dirname "$fwbin")"; [ -d "$res/Resources/licenses" ] && res="$res/Resources" || res="$res"
  for notice in libass-ISC.txt freetype-FTL.txt harfbuzz-MIT.txt fribidi-LGPL-2.1.txt libunibreak-zlib.txt; do
    [ -f "$res/licenses/$notice" ] || bad "$s: LibASS is missing the notice $notice"
  done
  grep -E 'LGPL|Lesser' "$res/licenses/fribidi-LGPL-2.1.txt" >/dev/null || bad "$s: FriBidi notice is not the LGPL text"
  grep -E 'as-is' "$res/licenses/libunibreak-zlib.txt" >/dev/null || bad "$s: libunibreak notice is not the zlib-style text"
  nm -gU "$fwbin" 2>/dev/null | lacks -i 'unibreak' || bad "$s: LibASS exports libunibreak symbols"
done

if [ "$fail" -eq 0 ]; then log "license check passed for slices: $SLICES"; else exit 1; fi
