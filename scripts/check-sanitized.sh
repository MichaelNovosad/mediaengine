#!/bin/bash
# Runs the test suite under the sanitizers, in the same passes as verify.sh (unit, then the real-time playback suites
# alone). Waits in the playback tests are stretched for the slowdown (MEDIAENGINE_TEST_PATIENCE).
#   address    AddressSanitizer with an AddressSanitizer-instrumented FFmpeg, so memory errors inside the demuxers and
#              decoders are caught as well as the ones in our own code (needs the macOS slice sources:
#              scripts/fetch-sources.sh; builds the instrumented framework once)
#   thread     ThreadSanitizer on the Swift code
#   undefined  UBSan on the Swift code
#   all        the three, in this order (default)
# usage: scripts/check-sanitized.sh [address|thread|undefined|all] [--rebuild]      (--rebuild: rebuild the instrumented FFmpeg)
# Each sanitizer has its own build cache (.build-sanitized, .build-tsan, .build-ubsan), so they never rebuild each other
# and a normal build is not disturbed. (A TSan run right after the old shared-build version once crashed in the
# sanitizer runtime, most likely from stale instrumented artifacts.)
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/tests.sh"
cd "$ROOT"
mode="${1:-all}"; rebuild="${2:-}"
case "$mode" in address|thread|undefined|all) ;; *) die "usage: scripts/check-sanitized.sh [address|thread|undefined|all] [--rebuild]" ;; esac
logdir="$BUILD/sanitizer-logs"; mkdir -p "$logdir"

run_sanitizer() { # <name> <sanitize flag> <scratch dir> <patience>
  local name="$1" flag="$2" scratch="$3" patience="$4"
  log "swift test --sanitize=$flag ($name)"
  MEDIAENGINE_TEST_PATIENCE="$patience" unit_pass "$logdir/$name-unit.log" --sanitize="$flag" --scratch-path "$scratch" >/dev/null
  MEDIAENGINE_TEST_PATIENCE="$patience" playback_pass "$logdir/$name-playback.log" --sanitize="$flag" --scratch-path "$scratch" >/dev/null
  if grep -hE 'ERROR: (Address|Thread)Sanitizer|WARNING: ThreadSanitizer|runtime error:' "$logdir/$name-unit.log" "$logdir/$name-playback.log" >/dev/null; then
    die "$name reported an error (see $logdir/$name-*.log)"
  fi
  log "$name run passed"
}

if [ "$mode" = address ] || [ "$mode" = all ]; then
  # The instrumented FFmpeg is a build product: it is rebuilt when missing, on --rebuild, and when the core profile or the
  # build scripts are newer than it (a stale one lacks new demuxers and decoders and fails the tests for the wrong reason).
  if [ "$rebuild" = "--rebuild" ] || [ ! -d "$BUILD/FFmpegLGPL-address.xcframework" ] \
     || [ "$ROOT/profiles/core.json" -nt "$BUILD/FFmpegLGPL-address.xcframework" ] \
     || [ "$ROOT/scripts/build-ffmpeg.sh" -nt "$BUILD/FFmpegLGPL-address.xcframework" ]; then
    FFMPEG_SANITIZE=address ./scripts/build-ffmpeg.sh macos core
    FFMPEG_SANITIZE=address ./scripts/package-xcframework.sh core
  fi
  export MEDIAENGINE_SANITIZED_FFMPEG=1
  run_sanitizer address address "$ROOT/.build-sanitized" 4
  unset MEDIAENGINE_SANITIZED_FFMPEG
fi
if [ "$mode" = thread ] || [ "$mode" = all ]; then run_sanitizer thread thread "$ROOT/.build-tsan" 4; fi
if [ "$mode" = undefined ] || [ "$mode" = all ]; then run_sanitizer undefined undefined "$ROOT/.build-ubsan" 1; fi
log "sanitizer runs passed ($mode)"
