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
for s in $SLICES; do ./scripts/build-subtitle-libs.sh "$s"; done
./scripts/package-subtitle-xcframework.sh
[ -x "$BUILD/tools/bin/ffmpeg" ] || ./scripts/build-host-tools.sh
./scripts/make-fixtures.sh >/dev/null

# BUILD-INFO.txt: what an LGPL source offer needs (exact versions, configure lines, tool versions).
info="$BUILD/BUILD-INFO.txt"
{
  echo "MediaEngine build information (profile: $profile)"
  echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "clang: $(xcrun clang --version | head -1)"
  echo
  echo "Sources (see third_party/sources.lock):"
  grep -v '^#' "$ROOT/third_party/sources.lock" | awk -F'\t' '{print "  " $1 " " $2 "  sha256 " $4 "  " $3}'
  echo
  echo "Subtitle libraries (LibASS.framework): libass $(lock_field libass 2) ISC, FreeType $(lock_field freetype 2) FTL, HarfBuzz $(lock_field harfbuzz 2) MIT, FriBidi $(lock_field fribidi 2) LGPL-2.1; built by scripts/build-subtitle-libs.sh"
  echo
  for s in $SLICES; do
    echo "Slice $s configure line:"
    grep -m1 'FFMPEG_CONFIGURATION' "$BUILD/install/$s-$profile/config.h" 2>/dev/null | sed 's/^#define FFMPEG_CONFIGURATION //' | sed 's/^/  /'
    echo
  done
} > "$info"
cp "$BUILD/install/macos-$profile/LICENSE-REPORT.md" "$BUILD/LICENSE-REPORT-$profile.md"
log "build-all done; BUILD-INFO.txt and LICENSE-REPORT-$profile.md written to build/"
