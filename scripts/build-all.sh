#!/bin/bash
# One command: fetch and verify sources, build every slice, package the XCFramework,
# build the developer host tools, generate fixtures, and write BUILD-INFO.txt.
# usage: scripts/build-all.sh [profile]      (default: core)
source "$(dirname "$0")/lib/common.sh"
profile="${1:-core}"
cd "$ROOT"

./scripts/fetch-sources.sh
for s in $SLICES; do ./scripts/build-ffmpeg.sh "$s" "$profile"; done
./scripts/package-xcframework.sh "$profile"
# The extended variant (legacy containers and software decoders, AV1 through dav1d): another binary with the same module name.
for s in $SLICES; do ./scripts/build-dav1d.sh "$s"; done
for s in $SLICES; do ./scripts/build-ffmpeg.sh "$s" "$profile" extended; done
./scripts/package-xcframework.sh "$profile+extended"
for s in $SLICES; do ./scripts/build-subtitle-libs.sh "$s"; done
./scripts/package-subtitle-xcframework.sh
[ -x "$BUILD/tools/bin/ffmpeg" ] || ./scripts/build-host-tools.sh
./scripts/make-fixtures.sh >/dev/null

./scripts/write-build-info.sh
log "build-all done; BUILD-INFO.txt and the license reports are in build/"
