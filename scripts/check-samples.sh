#!/bin/bash
# API-1, DOC-2: the quick start needs no setup beyond the package dependency. Builds Samples/QuickStart (a complete SwiftUI app around
# the five lines) and Samples/Player (tracks, subtitles, software path, gating, licences) for macOS, an iOS simulator and a visionOS
# simulator, with nothing but the package.
# usage: scripts/check-samples.sh [--macos-only]
source "$(dirname "$0")/lib/common.sh"
logs="$BUILD/logs"; mkdir -p "$logs"
for sample in QuickStart Player; do
  cd "$ROOT/Samples/$sample"
  log "$sample for macOS"
  swift build --scratch-path "$BUILD/samples-macos-$sample" > "$logs/sample-$sample-macos.log" 2>&1 || { tail -30 "$logs/sample-$sample-macos.log"; die "macOS $sample failed"; }
  [ "${1:-}" = "--macos-only" ] && continue
  for target in "iOS Simulator:ios" "visionOS Simulator:xros"; do
    name="${target%%:*}"; short="${target##*:}"
    log "$sample for $name"
    xcodebuild build -scheme "$sample" -destination "generic/platform=$name" -derivedDataPath "$BUILD/DerivedData-sample-$sample-$short" ARCHS=arm64 \
      > "$logs/sample-$sample-$short.log" 2>&1 || { tail -30 "$logs/sample-$sample-$short.log"; die "$name $sample failed"; }
  done
done
if [ "${1:-}" = "--macos-only" ]; then log "both samples build for macOS with only the package dependency"
else log "both samples build for macOS, iOS and visionOS with only the package dependency"; fi
