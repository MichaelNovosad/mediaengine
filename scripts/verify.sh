#!/bin/bash
# The check that must pass before anything is reported done. It runs at background priority and plays no sound (see
# scripts/lib/common.sh), but it still takes minutes of CPU: run it when the owner has agreed, not on every change.
#   scripts/verify.sh --quick   sources, licenses, API hygiene, ground truth, docs, build with zero warnings, unit, playback and
#                               isolated test passes on macOS, the extended variant, source pack, framework swap (about 6 minutes)
#   scripts/verify.sh           + package traits and the sample apps built for macOS (about 8 minutes)
#   scripts/verify.sh --sims    + the sample apps for iOS and visionOS and the iPhone, iPad, iPhone Duo and visionOS simulators
#                               (boots four simulators, the heaviest part: ask first)
#   scripts/verify.sh --deep    + AddressSanitizer (with instrumented FFmpeg), ThreadSanitizer, UBSan and the benchmark gate
# For the quick loop while coding use scripts/check.sh (about 30 s). Every step prints how long it took.
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/tests.sh"
cd "$ROOT"
tier=full
case "${1:-}" in
  "") ;; --quick) tier=quick ;; --sims) tier=sims ;; --deep) tier=deep ;;
  *) die "usage: scripts/verify.sh [--quick|--sims|--deep]" ;;
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
  local -a ids=() labels=()
  for spec in "$@"; do
    label_of="${spec%%|*}"; rest="${spec#*|}"; name="${rest%%|*}"; runtime="${rest#*|}"
    id="$(sim_id "$name" "$runtime")" || die "simulator '$name' on $runtime not found"
    [ -n "$first" ] || first="$id"
    ids+=("$id"); labels+=("$label_of")
  done
  xcodebuild build-for-testing -scheme MediaEngine -destination "id=$first" -derivedDataPath "$derived" \
    > "$logdir/$label-build.log" 2>&1 || { tail -30 "$logdir/$label-build.log"; die "$label build failed"; }
  check_warnings "$logdir/$label-build.log"
  # One simulator at a time, each shut down afterwards: four booted simulators next to the owner's own work were too much.
  local i failed=0
  for i in "${!ids[@]}"; do
    rm -rf "$logdir/${labels[$i]}.xcresult"
    if xcodebuild test-without-building -scheme MediaEngine -destination "id=${ids[$i]}" -derivedDataPath "$derived" \
         -resultBundlePath "$logdir/${labels[$i]}.xcresult" > "$logdir/${labels[$i]}.log" 2>&1; then
      grep -E 'Test run with .* passed' "$logdir/${labels[$i]}.log" | sed "s/^/${labels[$i]}: /" || { echo "${labels[$i]}: no passing test run found" >&2; failed=1; }
      check_warnings "$logdir/${labels[$i]}.log"
    else
      tail -30 "$logdir/${labels[$i]}.log"; echo "${labels[$i]} tests failed" >&2; failed=1
    fi
    xcrun simctl shutdown "${ids[$i]}" >/dev/null 2>&1 || true
  done
  [ "$failed" -eq 0 ] || die "simulator tests failed"
}

begin_step "sources verified, acknowledgements up to date"; ./scripts/fetch-sources.sh >/dev/null; python3 -I ./scripts/gen-acknowledgements.py --check || die "Acknowledgements.generated.swift is stale: run scripts/gen-acknowledgements.py"
begin_step "license check"; ./scripts/check-licenses.sh
begin_step "source pack complete (LIC-3) and FFmpeg replaceable (LIC-2)"; ./scripts/check-source-pack.sh >/dev/null; ./scripts/test-framework-swap.sh >/dev/null
begin_step "public API hygiene and ground truth"; ./scripts/check-public-api.sh; ./scripts/check-ground-truth.sh
begin_step "documentation builds without warnings (API-10)"; ./scripts/check-docs.sh >/dev/null
begin_step "build (warnings fail)"; build_tests "$logdir/build.log"
begin_step "unit tests (macOS)"; unit_pass "$logdir/unit.log"
begin_step "playback tests (macOS, AVPlayer, alone on the machine)"; playback_pass "$logdir/playback.log"
begin_step "resource checks (macOS, isolated)"; isolated_pass "$logdir/resources.log"
# The extended variant is a second binary behind the same Swift code (RESEARCH.md section 24): build and test against it too.
begin_step "extended variant (macOS: unit tests with the software decoders, AVI/H.264 in AVPlayer, the software player)"
[ -d "$BUILD/FFmpegLGPL-extended.xcframework" ] || die "the extended variant is not built: run scripts/build-all.sh (or build-ffmpeg.sh <slice> core extended for every slice, then package-xcframework.sh core+extended)"
./scripts/fetch-conformance.sh >/dev/null            # VP8/VP9/AV1 conformance vectors (cached in build/conformance; needs the network once)
MEDIAENGINE_PROFILE=extended build_tests "$logdir/build-extended.log" --scratch-path "$ROOT/.build-extended"
MEDIAENGINE_PROFILE=extended unit_pass "$logdir/unit-extended.log" --scratch-path "$ROOT/.build-extended"
MEDIAENGINE_PROFILE=extended swift_pass "legacy containers in AVPlayer" "$logdir/playback-extended.log" --scratch-path "$ROOT/.build-extended" --no-parallel --filter "LegacyContainerPlaybackTests|SoftwareControllerPlaybackTests|SoftwarePipelineTests|InterlacedPlaybackTests"

if [ "$tier" != quick ]; then
  begin_step "package traits"; ./scripts/check-traits.sh >/dev/null
  begin_step "sample apps build for macOS (API-1, DOC-2)"; ./scripts/check-samples.sh --macos-only >/dev/null
fi
if [ "$tier" = sims ]; then
  begin_step "sample apps build for iOS and visionOS (API-1, DOC-2)"; ./scripts/check-samples.sh >/dev/null
  begin_step "simulators: iPhone, iPad, iPhone Duo, then visionOS (one at a time)"
  simulator_tests ios ios "iphone|iPhone 18 Pro Max|iOS 27.0" "ipad|iPad Air 13-inch (M4)|iOS 27.0" "iphone-duo|iPhone Duo|iOS 27.1"
  simulator_tests visionos xros "visionos|Apple Vision Pro|visionOS 27.0"
fi
if [ "$tier" = deep ]; then
  begin_step "benchmark against the stored baseline (PRF-1; a regression over 10% fails)"; ./scripts/bench.sh >/dev/null
  begin_step "sanitizers (AddressSanitizer with instrumented FFmpeg, ThreadSanitizer, UBSan)"; ./scripts/check-sanitized.sh all >/dev/null
fi
end_steps | tee "$logdir/summary.txt"
log "verify passed ($tier)"
