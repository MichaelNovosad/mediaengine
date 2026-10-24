#!/bin/bash
# The single check that must pass before anything is reported done.
# Verifies sources, license cleanliness, trait handling, and runs the test suite on macOS, iPhone,
# iPad, iPhone Duo and visionOS simulators. Any warning in our own code fails the run.
# usage: scripts/verify.sh [--quick]     (--quick: sources, licenses, API hygiene, ground truth and macOS tests only)
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
quick=0; [ "${1:-}" = "--quick" ] && quick=1
logdir="$BUILD/verify-logs"; rm -rf "$logdir"; mkdir -p "$logdir"
total=5; [ "$quick" -eq 0 ] && total=10
n=0; step() { n=$((n+1)); log "$n/$total $*"; }

# Warnings that come from Xcode's own tooling, not from our code.
ignorable='Metadata extraction skipped'
check_warnings() { # <logfile>
  local found; found="$(grep -E 'warning:' "$1" | grep -v "$ignorable" || true)"
  if [ -n "$found" ]; then
    echo "$found" | head -10 >&2
    die "warnings found (see $1)"
  fi
}

sim_id() { # <device name> <runtime, e.g. "iOS 27.0">
  xcrun simctl list devices available -j | python3 -I -c '
import json, re, sys
name, runtime = sys.argv[1], sys.argv[2]
def key(s): return re.sub(r"[^a-z0-9]", "", s.lower()).replace("xros", "visionos")
want = key(runtime)
for rt, devs in json.load(sys.stdin)["devices"].items():
    if key(rt.split("SimRuntime.")[-1]) == want:
        for d in devs:
            if d["name"] == name and d.get("isAvailable", True):
                print(d["udid"]); sys.exit(0)
sys.exit(1)' "$1" "$2"
}

step "sources verified"; ./scripts/fetch-sources.sh >/dev/null
step "license check"; ./scripts/check-licenses.sh
step "public API hygiene and ground truth"; ./scripts/check-public-api.sh; ./scripts/check-ground-truth.sh
step "swift test (macOS)"
swift test > "$logdir/macos.log" 2>&1 || { tail -30 "$logdir/macos.log"; die "macOS tests failed"; }
grep -E 'Test run with .* passed' "$logdir/macos.log" || die "macOS: no passing test run found"
check_warnings "$logdir/macos.log"

# Timing, memory, descriptor and CPU measurements are process-wide, so they get a pass of their own (ExclusiveTests.swift).
step "resource checks (macOS, isolated)"
MEDIAENGINE_EXCLUSIVE=1 swift test --filter ExclusiveTests > "$logdir/resources.log" 2>&1 || { tail -30 "$logdir/resources.log"; die "resource checks failed"; }
grep -E 'Test run with .* passed' "$logdir/resources.log" || die "resource checks: no passing test run found"
check_warnings "$logdir/resources.log"

if [ "$quick" -eq 0 ]; then
  step "package traits"; ./scripts/check-traits.sh >/dev/null
  run_sim() { # <label> <device name> <runtime>
    step "tests on $1"
    local id; id="$(sim_id "$2" "$3")" || die "simulator '$2' on $3 not found"
    xcodebuild test -scheme MediaEngine -destination "id=$id" -derivedDataPath "$BUILD/DerivedData" \
      > "$logdir/$1.log" 2>&1 || { tail -30 "$logdir/$1.log"; die "$1 tests failed"; }
    grep -E 'Test run with .* passed' "$logdir/$1.log" || die "$1: no passing test run found"
    check_warnings "$logdir/$1.log"
  }
  run_sim iphone      "iPhone 18 Pro Max"       "iOS 27.0"
  run_sim ipad        "iPad Air 13-inch (M4)"   "iOS 27.0"
  run_sim iphone-duo  "iPhone Duo"              "iOS 27.1"
  run_sim visionos    "Apple Vision Pro"        "visionOS 27.0"
fi
log "verify passed"
