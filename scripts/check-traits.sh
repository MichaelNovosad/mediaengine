#!/bin/bash
# Proves SwiftPM traits reach the code. For each trait combination: compile the package and tests with it and run the
# one test that compares the compile-time traits with what the script expects. The build of every combination keeps its
# own cache (.build-traits/<name>), so only the first run is slow. The all-traits build also runs the unit tests, which
# exercise the code that the optional traits switch on.
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/tests.sh"
cd "$ROOT"
logdir="$BUILD/traits-logs"; mkdir -p "$logdir"
run() { # <name> <expected traits, comma separated> <swift arguments...>
  local name="$1" expected="$2"; shift 2
  log "traits: $name → expect [$expected]"
  build_tests "$logdir/$name-build.log" --scratch-path "$ROOT/.build-traits/$name" "$@"
  EXPECTED_TRAITS="$expected" swift_pass "trait check ($name)" "$logdir/$name.log" --scratch-path "$ROOT/.build-traits/$name" "$@" --filter traitsReachTheCode >/dev/null
}
run default       "Subtitles"
run software      "SoftwareDecoding"                        --disable-default-traits --traits SoftwareDecoding
run licensed      "Subtitles,SoftwareDecoding,LicensedAudio" --traits default,SoftwareDecoding,LicensedAudio
run all           "DolbyVision,LicensedAudio,SoftwareDecoding,Subtitles" --enable-all-traits
log "traits: unit tests with every trait on"
unit_pass "$logdir/all-unit.log" --scratch-path "$ROOT/.build-traits/all" --enable-all-traits >/dev/null
log "trait check passed"
