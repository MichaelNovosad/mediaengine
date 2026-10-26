#!/bin/bash
# The quick loop: build with zero warnings, hygiene checks, then the unit tests (about 15 s once built).
# usage: scripts/check.sh [test filter]      (with a filter: just the tests whose name matches, any suite)
# Run it after every change; scripts/verify.sh --quick before reporting a step done; scripts/verify.sh for the whole gate.
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/tests.sh"
cd "$ROOT"
logdir="$BUILD/check-logs"; mkdir -p "$logdir"

begin_step "build (warnings fail)"; build_tests "$logdir/build.log"
begin_step "public API hygiene"; ./scripts/check-public-api.sh >/dev/null
if [ "$#" -gt 0 ]; then
  begin_step "tests matching '$1'"; swift_pass "tests" "$logdir/filtered.log" --filter "$1"
else
  begin_step "unit tests"; unit_pass "$logdir/unit.log"
fi
end_steps
log "check passed"
