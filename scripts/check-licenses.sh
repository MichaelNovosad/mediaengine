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

for s in $SLICES; do
  inst="$BUILD/install/$s-$profile"
  [ -d "$inst" ] || { bad "$s: not built"; continue; }

  strings -a "$inst/lib/libavutil.a" | has "libavutil license: LGPL version 2.1 or later" \
    || bad "$s: libavutil does not report 'LGPL version 2.1 or later'"

  conf="$(strings -a "$inst/lib/libavformat.a" | grep -m1 -e '--disable-gpl' || true)"
  [ -n "$conf" ] || bad "$s: configuration string with --disable-gpl not found"
  for flag in --enable-gpl --enable-nonfree --enable-version3 --enable-libx264 --enable-libx265 --enable-libfdk-aac; do
    case "$conf" in *"$flag"*) bad "$s: configuration contains $flag" ;; esac
  done

  fwbin="$(find "$BUILD/frameworks/$s" -name FFmpegLGPL -type f 2>/dev/null | head -1)"
  if [ -n "$fwbin" ]; then
    strings -a "$fwbin" | has "libavutil license: LGPL version 2.1 or later" || bad "$s: shipped framework license string"
    nm -gU "$fwbin" 2>/dev/null | lacks -i 'x264|x265|fdk' || bad "$s: GPL/nonfree encoder symbols exported"
    nm -gU "$fwbin" 2>/dev/null | awk '{print $3}' | lacks -v '^_(av|swr)' || bad "$s: exports symbols outside av*/swr*"
    otool -L "$fwbin" | tail -n +2 | lacks -v '(/System/Library/|/usr/lib/|@rpath/FFmpegLGPL)' || bad "$s: links against non-system libraries"
  else
    bad "$s: framework not packaged"
  fi
done

if [ "$fail" -eq 0 ]; then log "license check passed for slices: $SLICES"; else exit 1; fi
