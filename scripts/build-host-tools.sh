#!/bin/bash
# Builds developer-only ffmpeg/ffprobe (macOS) from the same pinned source, for test fixtures and ground truth.
# Never shipped. Output: build/tools/bin/{ffmpeg,ffprobe}
source "$(dirname "$0")/lib/common.sh"
"$ROOT/scripts/build-ffmpeg.sh" macos host-tools
mkdir -p "$BUILD/tools/bin"
for t in ffmpeg ffprobe; do cp "$BUILD/install/macos-host-tools/bin/$t" "$BUILD/tools/bin/$t"; done
log "host tools ready: $("$BUILD/tools/bin/ffmpeg" -version | head -1)"
