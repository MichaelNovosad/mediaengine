#!/bin/bash
# Writes build/BUILD-INFO.txt: what an LGPL source offer needs (exact versions, configure lines of every binary, tool versions).
# Called by scripts/build-all.sh; can be run alone after the slices are built. Part of the source pack (scripts/make-source-pack.sh).
source "$(dirname "$0")/lib/common.sh"
info="$BUILD/BUILD-INFO.txt"
patches="$(find "$ROOT/third_party/patches" -name '*.diff' 2>/dev/null | wc -l | tr -d ' ')"
{
  echo "MediaEngine build information"
  echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "clang: $(xcrun clang --version | head -1)"
  echo "meson: $(meson --version 2>/dev/null || echo n/a), ninja: $(ninja --version 2>/dev/null || echo n/a), cmake: $(cmake --version 2>/dev/null | head -1 || echo n/a), python: $(python3 --version 2>&1)"
  echo
  echo "Sources (third_party/sources.lock; the archives are in the source pack next to this file):"
  grep -v '^#' "$ROOT/third_party/sources.lock" | awk -F'\t' '{print "  " $1 " " $2 "  sha256 " $4 "  " $3}'
  echo
  echo "Patches applied to the sources: $patches (none means the binaries are built from the unmodified archives)"
  echo
  echo "Binaries:"
  echo "  FFmpegLGPL.xcframework           FFmpeg $(lock_field ffmpeg 2), LGPL-2.1-or-later, profile core; dynamic framework, replaceable (see REPLACING-FFMPEG.md)"
  echo "  FFmpegLGPL-extended.xcframework  the same FFmpeg with the extended profile and dav1d $(lock_field dav1d 2) (BSD-2-Clause) linked in"
  echo "  FFmpegLGPL-extended-plus.xcframework  the extended variant plus dtsCore (the DTS core only, patched) and the fallbacks for what Apple refuses: h264Software, hevcSoftware, audioFallback"
  echo "  LibASS.xcframework               libass $(lock_field libass 2) ISC, FreeType $(lock_field freetype 2) FTL, HarfBuzz $(lock_field harfbuzz 2) MIT, FriBidi $(lock_field fribidi 2) LGPL-2.1; built by scripts/build-subtitle-libs.sh"
  echo
  for variant in $VARIANTS; do
    for s in $SLICES; do
      echo "FFmpeg configure line, $variant, slice $s:"
      if [ -f "$BUILD/install/$s-$variant/config.h" ]; then
        grep -m1 'FFMPEG_CONFIGURATION' "$BUILD/install/$s-$variant/config.h" | sed 's/^#define FFMPEG_CONFIGURATION //' | sed 's/^/  /'
      else
        echo "  (not built)"          # check-source-pack.sh fails on this, as it should
      fi
      echo
    done
  done
  for s in $SLICES; do
    echo "dav1d build, slice $s:"
    sed 's/^/  /' "$BUILD/install/dav1d-$s/BUILD-CONFIG.txt" 2>/dev/null || echo "  (not built)"
    echo
  done
  echo "Subtitle libraries, FFmpeg and dav1d are built by scripts/build-subtitle-libs.sh, scripts/build-ffmpeg.sh and scripts/build-dav1d.sh (in the pack);"
  echo "the frameworks are linked by scripts/package-xcframework.sh and scripts/package-subtitle-xcframework.sh."
} > "$info"
cp "$BUILD/install/macos-core/LICENSE-REPORT.md" "$BUILD/LICENSE-REPORT-core.md" 2>/dev/null || true
cp "$BUILD/install/macos-core+extended/LICENSE-REPORT.md" "$BUILD/LICENSE-REPORT-extended.md" 2>/dev/null || true
cp "$BUILD/install/macos-core+extended+dtsCore+h264Software+hevcSoftware+audioFallback/LICENSE-REPORT.md" "$BUILD/LICENSE-REPORT-extended-plus.md" 2>/dev/null || true
log "BUILD-INFO.txt written ($(wc -l < "$info" | tr -d ' ') lines)"
