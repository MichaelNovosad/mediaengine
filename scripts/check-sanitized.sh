#!/bin/bash
# Runs the whole test suite under AddressSanitizer with an AddressSanitizer-instrumented FFmpeg, so memory errors
# inside the demuxers and decoders are caught as well as the ones in our own code (the normal sanitizer run only
# instruments Swift). Needs the macOS slice sources: run scripts/fetch-sources.sh once. Takes about 2 minutes.
# usage: scripts/check-sanitized.sh [--rebuild]
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
if [ "${1:-}" = "--rebuild" ] || [ ! -d "$BUILD/FFmpegLGPL-address.xcframework" ]; then
  FFMPEG_SANITIZE=address ./scripts/build-ffmpeg.sh macos core
  FFMPEG_SANITIZE=address ./scripts/package-xcframework.sh core
fi
log "swift test --sanitize=address with the instrumented FFmpeg"
MEDIAENGINE_SANITIZED_FFMPEG=1 swift test --sanitize=address 2>&1 | tee "$BUILD/sanitized.log" | grep -E 'Test run with|AddressSanitizer|recorded an issue' || true
grep -E 'Test run with .* passed' "$BUILD/sanitized.log" >/dev/null || die "sanitizer run failed (see $BUILD/sanitized.log)"
grep -E 'ERROR: AddressSanitizer' "$BUILD/sanitized.log" >/dev/null && die "AddressSanitizer reported an error (see $BUILD/sanitized.log)"
log "sanitized run passed"
