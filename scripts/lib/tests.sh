#!/bin/bash
# Test passes shared by check.sh, verify.sh, check-traits.sh and check-sanitized.sh. Source after common.sh.
#
# Why three passes: the suites that play through AVPlayer in real time take about 45 s and are the only ones whose
# result depends on how busy the machine is. Everything else (about 250 tests) takes about 13 s. Run together, the
# slow ones fight the fuzz and decoding tests for CPU and become flaky, so each kind gets its own pass:
#   unit      everything except the real-time suites: fast, parallel, deterministic
#   playback  the real-time AVPlayer suites alone, so load from other tests cannot starve them
#   isolated  timing, memory and descriptor measurements (ExclusiveTests), which need the process to themselves
# A suite that waits for AVPlayer belongs in PLAYBACK_SUITES (match the Swift type name).

PLAYBACK_SUITES='AVPlayerEndToEndTests|ExternalAudioPlaybackTests|ExternalSubtitlePlayerTests|PlayListPlaybackTests|TrackSelectionTests'

# Warnings that come from Xcode's own tooling, not from our code.
IGNORABLE_WARNINGS='Metadata extraction skipped'

check_warnings() { # <logfile>
  local found; found="$(sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -E 'warning:' | grep -v "$IGNORABLE_WARNINGS" || true)"
  if [ -n "$found" ]; then
    echo "$found" | head -10 >&2
    die "warnings found (see $1)"
  fi
}

# swift_pass <name> <logfile> <swift test arguments...>
swift_pass() {
  local name="$1" logfile="$2"; shift 2
  mkdir -p "$(dirname "$logfile")"
  swift test "$@" > "$logfile" 2>&1 || { sed 's/\x1b\[[0-9;]*m//g' "$logfile" | grep -vE 'started\.|^\[' | tail -40; die "$name failed (see $logfile)"; }
  sed 's/\x1b\[[0-9;]*m//g' "$logfile" | grep -E 'Test run with .* passed' || die "$name: no passing test run found (see $logfile)"
  check_warnings "$logfile"
}

unit_pass()     { local logfile="$1"; shift; swift_pass "unit tests" "$logfile" --skip "$PLAYBACK_SUITES" "$@"; }
playback_pass() { local logfile="$1"; shift; swift_pass "playback tests" "$logfile" --filter "$PLAYBACK_SUITES" "$@"; }
isolated_pass() { local logfile="$1"; shift; MEDIAENGINE_EXCLUSIVE=1 swift_pass "resource checks" "$logfile" --filter ExclusiveTests "$@"; }

# build_tests <logfile> [swift build arguments...]: compiles package and tests, fails on warnings in our code.
build_tests() {
  local logfile="$1"; shift
  mkdir -p "$(dirname "$logfile")"
  swift build --build-tests "$@" > "$logfile" 2>&1 || { sed 's/\x1b\[[0-9;]*m//g' "$logfile" | grep -E 'error' | head -20; die "build failed (see $logfile)"; }
  check_warnings "$logfile"
}

# A step timer: `begin_step "name"` closes the previous step and prints how long it took; `end_steps` prints the table.
STEP_NAMES=(); STEP_SECONDS=(); STEP_STARTED=0; STEP_CURRENT=""
begin_step() {
  local now; now="$(date +%s)"
  if [ -n "$STEP_CURRENT" ]; then STEP_NAMES+=("$STEP_CURRENT"); STEP_SECONDS+=("$((now - STEP_STARTED))"); fi
  STEP_CURRENT="${1:-}"; STEP_STARTED="$now"
  [ -z "$STEP_CURRENT" ] || log "$STEP_CURRENT"
}
end_steps() {
  begin_step ""
  local i total=0
  echo
  for i in "${!STEP_NAMES[@]}"; do printf '  %4ds  %s\n' "${STEP_SECONDS[$i]}" "${STEP_NAMES[$i]}"; total=$((total + STEP_SECONDS[$i])); done
  printf '  %4ds  total\n' "$total"
}
