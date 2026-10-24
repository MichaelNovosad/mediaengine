#!/bin/bash
# The committed ffprobe JSON must be exactly what our own host ffprobe prints for the committed fixtures.
source "$(dirname "$0")/lib/common.sh"
FP="$BUILD/tools/bin/ffprobe"; [ -x "$FP" ] || die "run scripts/build-host-tools.sh first"
cd "$ROOT/Fixtures"
for f in fixture-*.mkv; do
  "$FP" -v error -show_format -show_streams -show_chapters -of json "$f" | diff - "ground-truth/${f%.mkv}.json" >/dev/null \
    || die "ground truth out of date for $f (run scripts/make-fixtures.sh and commit both)"
done
log "ground truth matches ffprobe for $(ls fixture-*.mkv | wc -l | tr -d ' ') fixtures"
