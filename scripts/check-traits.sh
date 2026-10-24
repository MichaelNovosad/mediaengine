#!/bin/bash
# Proves SwiftPM traits reach the code: runs the tests for several trait combinations.
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
run() { # <expected traits, comma separated> <swift test args...>
  local expected="$1"; shift
  log "traits → expect [$expected]"
  EXPECTED_TRAITS="$expected" swift test "$@" > "$BUILD/traits.log" 2>&1 \
    || { tail -25 "$BUILD/traits.log"; die "trait combination [$expected] failed"; }
  grep -E 'Test run with .* passed' "$BUILD/traits.log" >/dev/null || die "no passing run for [$expected]"
}
run "Subtitles"
run "SoftwareDecoding"                        --disable-default-traits --traits SoftwareDecoding
run "Subtitles,SoftwareDecoding,LicensedAudio" --traits default,SoftwareDecoding,LicensedAudio
run "DolbyVision,LicensedAudio,SoftwareDecoding,Subtitles" --enable-all-traits
log "trait check passed"
