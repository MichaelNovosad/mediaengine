#!/bin/bash
# The check that must pass before anything is reported done. Three tiers, each a superset of the one before:
#   scripts/verify.sh --quick   sources, licenses, API hygiene, ground truth, build with zero warnings, unit, playback and
#                               isolated test passes on macOS (about 2 minutes)
#   scripts/verify.sh           + package traits and the iPhone, iPad, iPhone Duo and visionOS simulators (about 4 minutes)
#   scripts/verify.sh --deep    + AddressSanitizer (with instrumented FFmpeg), ThreadSanitizer and UBSan (about 10 minutes)
# For the quick loop while coding use scripts/check.sh (about 15 s). Every step prints how long it took.
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/tests.sh"
cd "$ROOT"
tier=full
case "${1:-}" in
  "") ;; --quick) tier=quick ;; --deep) tier=deep ;;
  *) die "usage: scripts/verify.sh [--quick|--deep]" ;;
esac
logdir="$BUILD/verify-logs"; rm -rf "$logdir"; mkdir -p "$logdir"

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

# Builds once per platform, then runs the tests on several simulators of that platform at the same time. The simulator
# runs hold no real-time AVPlayer tests (those are macOS-only), so running them side by side is safe.
simulator_tests() { # <platform label> <derived data suffix> <scheme destination name:runtime>...
  local label="$1" suffix="$2"; shift 2
  local derived="$BUILD/DerivedData-$suffix" first="" spec name runtime id
  local -a ids=() labels=() pids=()
  for spec in "$@"; do
    label_of="${spec%%|*}"; rest="${spec#*|}"; name="${rest%%|*}"; runtime="${rest#*|}"
    id="$(sim_id "$name" "$runtime")" || die "simulator '$name' on $runtime not found"
    [ -n "$first" ] || first="$id"
    ids+=("$id"); labels+=("$label_of")
  done
  xcodebuild build-for-testing -scheme MediaEngine -destination "id=$first" -derivedDataPath "$derived" \
    > "$logdir/$label-build.log" 2>&1 || { tail -30 "$logdir/$label-build.log"; die "$label build failed"; }
  check_warnings "$logdir/$label-build.log"
  local i
  for i in "${!ids[@]}"; do
    rm -rf "$logdir/${labels[$i]}.xcresult"
    xcodebuild test-without-building -scheme MediaEngine -destination "id=${ids[$i]}" -derivedDataPath "$derived" \
      -resultBundlePath "$logdir/${labels[$i]}.xcresult" > "$logdir/${labels[$i]}.log" 2>&1 &
    pids+=("$!")
  done
  local failed=0
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { tail -30 "$logdir/${labels[$i]}.log"; echo "${labels[$i]} tests failed" >&2; failed=1; continue; }
    grep -E 'Test run with .* passed' "$logdir/${labels[$i]}.log" | sed "s/^/${labels[$i]}: /" || { echo "${labels[$i]}: no passing test run found" >&2; failed=1; }
    check_warnings "$logdir/${labels[$i]}.log"
  done
  [ "$failed" -eq 0 ] || die "simulator tests failed"
}

begin_step "sources verified"; ./scripts/fetch-sources.sh >/dev/null
begin_step "license check"; ./scripts/check-licenses.sh
begin_step "public API hygiene and ground truth"; ./scripts/check-public-api.sh; ./scripts/check-ground-truth.sh
begin_step "build (warnings fail)"; build_tests "$logdir/build.log"
begin_step "unit tests (macOS)"; unit_pass "$logdir/unit.log"
begin_step "playback tests (macOS, AVPlayer, alone on the machine)"; playback_pass "$logdir/playback.log"
begin_step "resource checks (macOS, isolated)"; isolated_pass "$logdir/resources.log"

if [ "$tier" != quick ]; then
  begin_step "package traits"; ./scripts/check-traits.sh >/dev/null
  # The two platforms build into separate derived-data folders, so they can build and test at the same time.
  begin_step "simulators: iPhone, iPad, iPhone Duo and visionOS (side by side)"
  ( simulator_tests ios ios "iphone|iPhone 18 Pro Max|iOS 27.0" "ipad|iPad Air 13-inch (M4)|iOS 27.0" "iphone-duo|iPhone Duo|iOS 27.1" ) & ios_pid=$!
  ( simulator_tests visionos xros "visionos|Apple Vision Pro|visionOS 27.0" ) & vision_pid=$!
  sim_failed=0
  wait "$ios_pid" || sim_failed=1
  wait "$vision_pid" || sim_failed=1
  [ "$sim_failed" -eq 0 ] || die "simulator tests failed"
fi
if [ "$tier" = deep ]; then
  begin_step "sanitizers (AddressSanitizer with instrumented FFmpeg, ThreadSanitizer, UBSan)"; ./scripts/check-sanitized.sh all >/dev/null
fi
end_steps | tee "$logdir/summary.txt"
log "verify passed ($tier)"
