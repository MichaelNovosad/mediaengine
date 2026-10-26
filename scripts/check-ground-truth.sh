#!/bin/bash
# The committed ffprobe JSON must be exactly what our own host ffprobe prints for the committed fixtures.
source "$(dirname "$0")/lib/common.sh"
FP="$BUILD/tools/bin/ffprobe"; [ -x "$FP" ] || die "run scripts/build-host-tools.sh first"
cd "$ROOT/Fixtures"
count=0
for f in fixture-*.*; do
  case "$f" in *.json) continue ;; esac
  "$FP" -v error -show_format -show_streams -show_chapters -of json "$f" | diff - "ground-truth/${f%.*}.json" >/dev/null \
    || die "ground truth out of date for $f (run scripts/make-fixtures.sh and commit both)"
  count=$((count + 1))
done
log "ground truth matches ffprobe for $count fixtures"
