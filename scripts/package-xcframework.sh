#!/bin/bash
# Links the static FFmpeg libraries of every slice into ONE dynamic framework (FFmpegLGPL),
# then bundles the five slices into build/FFmpegLGPL.xcframework.
# usage: scripts/package-xcframework.sh [profiles joined by +]      (default: core; "core+extended" makes the extended variant)
# The extended variant becomes build/FFmpegLGPL-extended.xcframework (same framework and module name inside, so Swift code
# does not change; Package.swift picks it with MEDIAENGINE_PROFILE=extended, see RESEARCH.md section 24).
# Dynamic linking keeps the LGPL promise: a customer can swap the framework for their own build.
# FFMPEG_SANITIZE=address packages the instrumented macOS slice (from build-ffmpeg.sh) as a separate
# build/FFmpegLGPL-address.xcframework for the sanitizer pass; it never touches the normal outputs.
source "$(dirname "$0")/lib/common.sh"

profile="${1:-core}"
variant=""; [ "$profile" = core ] || variant="-$(echo "$profile" | sed 's/^core+//')"
version="$(lock_field ffmpeg 2)"
FW="FFmpegLGPL"
BUNDLE_ID="dev.mediaengine.FFmpegLGPL"   # placeholder until the product name is chosen (D-E6)
san="${FFMPEG_SANITIZE:-}"; san_flags=""; suffix=""
if [ -n "$san" ]; then SLICES="macos"; san_flags="-fsanitize=$san"; suffix="-$san"; fi
out="$BUILD/frameworks$variant$suffix"
rm -rf "$out" "$BUILD/dsyms$variant$suffix" "$BUILD/$FW$variant$suffix.xcframework"; mkdir -p "$out" "$BUILD/dsyms$variant$suffix"

plist() { # <slice> <min key/value lines> → Info.plist on stdout
  local platform minkey
  case "$1" in
    macos) platform=MacOSX; minkey=LSMinimumSystemVersion ;;
    ios) platform=iPhoneOS; minkey=MinimumOSVersion ;;
    ios-simulator) platform=iPhoneSimulator; minkey=MinimumOSVersion ;;
    xros) platform=XROS; minkey=MinimumOSVersion ;;
    xros-simulator) platform=XRSimulator; minkey=MinimumOSVersion ;;
  esac
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$FW</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$FW</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>$minkey</key><string>$MIN_OS</string>
</dict></plist>
EOF
}

privacy() {
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>NSPrivacyTracking</key><false/>
  <key>NSPrivacyTrackingDomains</key><array/>
  <key>NSPrivacyCollectedDataTypes</key><array/>
  <key>NSPrivacyAccessedAPITypes</key><array/>
</dict></plist>
EOF
}

make_framework() {
  local slice="$1"
  local inst="$BUILD/install/$slice-$profile$suffix"
  [ -d "$inst" ] || die "missing $inst (run scripts/build-ffmpeg.sh $slice $profile${suffix:+ with FFMPEG_SANITIZE=$san})"
  local target sysroot sdk cc fwdir content res install_name
  target="$(slice_target "$slice")"; sysroot="$(slice_sysroot "$slice")"; sdk="$(slice_sdk "$slice")"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  fwdir="$out/$slice/$FW.framework"
  if [ "$slice" = "macos" ]; then
    content="$fwdir/Versions/A"; res="$content/Resources"; install_name="@rpath/$FW.framework/Versions/A/$FW"
  else
    content="$fwdir"; res="$fwdir"; install_name="@rpath/$FW.framework/$FW"
  fi
  mkdir -p "$content/Headers" "$content/Modules" "$res"

  # Only the public av*/swr* API leaves the framework.
  local exports="$BUILD/work/exports.txt"
  mkdir -p "$BUILD/work"; printf '_av*\n_swr*\n_swresample*\n' > "$exports"

  # The extended variant carries dav1d (AV1): linked in statically, BSD-2-Clause text shipped inside the framework.
  local extra_link=""
  if python3 -I "$ROOT/scripts/gen-config.py" flags $(echo "$profile" | tr '+' ' ') | grep -qx -e '--enable-libdav1d'; then
    extra_link="-Wl,-force_load,$BUILD/install/dav1d-$slice/lib/libdav1d.a"
  fi

  log "link $FW for $slice"
  "$cc" -dynamiclib $san_flags -target "$target" -isysroot "$sysroot" \
    -install_name "$install_name" -compatibility_version 1.0.0 -current_version "$version" \
    -Wl,-force_load,"$inst/lib/libavformat.a" -Wl,-force_load,"$inst/lib/libavcodec.a" \
    -Wl,-force_load,"$inst/lib/libavutil.a" -Wl,-force_load,"$inst/lib/libswresample.a" \
    $extra_link -Wl,-exported_symbols_list,"$exports" \
    -framework AudioToolbox -framework CoreFoundation -lz -lbz2 \
    -o "$content/$FW"

  # Headers: copy, drop platform-specific ones, make includes framework-style, add umbrella + module map.
  local lib
  for lib in libavutil libavcodec libavformat libswresample; do cp -R "$inst/include/$lib" "$content/Headers/"; done
  find "$content/Headers" \( -name 'hwcontext_*.h' -o -name 'd3d1*' -o -name 'dxva2.h' -o -name 'vdpau.h' \
    -o -name 'qsv.h' -o -name 'mediacodec.h' -o -name 'jni.h' -o -name 'videotoolbox.h' \) -delete
  find "$content/Headers" -name '*.h' -exec sed -E -i '' \
    's|#[[:space:]]*include[[:space:]]+"(lib(avutil\|avcodec\|avformat\|swresample)/[^"]+)"|#include <'"$FW"'/\1>|g' {} +
  ( cd "$content/Headers"
    { echo "// Generated by scripts/package-xcframework.sh. FFmpeg $version, LGPL-2.1-or-later."
      find libavutil libavcodec libavformat libswresample -name '*.h' | sort | sed "s|.*|#include <$FW/&>|"
    } > "$FW.h" )
  cat > "$content/Modules/module.modulemap" <<EOF
framework module $FW {
    umbrella header "$FW.h"
    export *
}
EOF
  plist "$slice" > "$res/Info.plist"
  privacy > "$res/PrivacyInfo.xcprivacy"
  if [ -n "$extra_link" ]; then
    mkdir -p "$res/licenses"; cp "$BUILD/install/dav1d-$slice/licenses/dav1d-BSD-2-Clause.txt" "$res/licenses/"
  fi

  if [ "$slice" = "macos" ]; then
    ln -sfn A "$fwdir/Versions/Current"
    ln -sfn "Versions/Current/$FW" "$fwdir/$FW"
    for d in Headers Modules Resources; do ln -sfn "Versions/Current/$d" "$fwdir/$d"; done
  fi

  mkdir -p "$BUILD/dsyms$variant$suffix/$slice"
  dsymutil "$content/$FW" -o "$BUILD/dsyms$variant$suffix/$slice/$FW.framework.dSYM" 2>/dev/null || true
  [ -n "$san" ] || strip -x "$content/$FW"
  codesign --force --sign - --timestamp=none "$fwdir" >/dev/null
}

for s in $SLICES; do make_framework "$s"; done

# Smoke test: the module imports cleanly in Objective-C (macOS slice).
log "module smoke test"
printf '@import FFmpegLGPL;\nint main(void){ return avformat_version() > 0 ? 0 : 1; }\n' > "$BUILD/work/smoke.m"
xcrun --sdk macosx clang -fmodules -fsyntax-only -Werror=incomplete-umbrella -F "$out/macos" "$BUILD/work/smoke.m"

log "create xcframework"
args=""
for s in $SLICES; do args="$args -framework $out/$s/$FW.framework"; done
# shellcheck disable=SC2086
xcodebuild -create-xcframework $args -output "$BUILD/$FW$variant$suffix.xcframework" | tail -2
log "done: $BUILD/$FW$variant$suffix.xcframework"
