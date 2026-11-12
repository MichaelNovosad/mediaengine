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
# The variant "extended-plus": the DTS core (patched: core only) and our fallback decoders for what Apple cannot decode
# (H.264 Hi10P and 4:2:2/4:4:4, HEVC 4:2:2/4:4:4, rare AAC types, AC-3, E-AC-3); opt-in (owner, 2026-11-12).
for s in $SLICES; do ./scripts/build-ffmpeg.sh "$s" "$profile" extended dtsCore h264Software hevcSoftware audioFallback; done
./scripts/package-xcframework.sh "$profile+extended+dtsCore+h264Software+hevcSoftware+audioFallback"
for s in $SLICES; do ./scripts/build-subtitle-libs.sh "$s"; done
./scripts/package-subtitle-xcframework.sh
[ -x "$BUILD/tools/bin/ffmpeg" ] || ./scripts/build-host-tools.sh
./scripts/make-fixtures.sh >/dev/null

./scripts/write-build-info.sh
log "build-all done; BUILD-INFO.txt and the license reports are in build/"
