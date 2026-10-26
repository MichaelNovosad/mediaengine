#!/bin/bash
# LIC-2: FFmpeg is linked dynamically, so whoever receives an app can replace FFmpegLGPL.framework with their own build.
# This proves it: a small client (Samples/SwapProbe) is built against the core framework, then the framework next to it is
# replaced with a different build (the extended variant stands in for a customer's own rebuild) and the SAME executable is run
# again, without relinking. It must see the other build's decoders. Procedure for customers: docs/REPLACING-FFMPEG.md.
# usage: scripts/test-framework-swap.sh
source "$(dirname "$0")/lib/common.sh"

scratch="$BUILD/swap"
sample="$ROOT/Samples/SwapProbe"
other="$BUILD/frameworks-extended/macos/FFmpegLGPL.framework"
[ -d "$other" ] || die "the extended framework is not built (scripts/build-all.sh)"
media="$ROOT/Fixtures/fixture-avi-xvid.avi"
mkdir -p "$BUILD/logs"

log "build the client against the core framework"
( cd "$sample" && swift build --scratch-path "$scratch" > "$BUILD/logs/swap-build.log" 2>&1 ) || { tail -20 "$BUILD/logs/swap-build.log"; die "sample build failed"; }
exe="$scratch/debug/SwapProbe"; framework="$scratch/debug/FFmpegLGPL.framework"
[ -d "$framework" ] || die "the client has no FFmpegLGPL.framework next to it"

# The executable must reference FFmpeg through the framework only.
otool -L "$exe" | grep -q 'FFmpegLGPL.framework' || die "the client does not load FFmpegLGPL.framework dynamically"
if nm -m "$exe" | grep -E 'section.*_avformat_open_input$' >/dev/null; then die "FFmpeg code is linked into the client statically"; fi
nm -m "$exe" | grep 'from FFmpegLGPL' >/dev/null || die "the client binds no FFmpeg symbol to the framework"

# What a replacement framework must export: every FFmpeg symbol the engine's own code uses. Both builds have to provide all of them.
required="$scratch/required-symbols.txt"
nm -u -j "$scratch/debug/MediaEngine.o" | grep -E '^_(av|swr)' | sort -u > "$required"
[ "$(wc -l < "$required")" -gt 50 ] || die "could not list the symbols the engine needs"
for candidate in "$framework/Versions/A/FFmpegLGPL" "$framework/FFmpegLGPL" "$other/Versions/A/FFmpegLGPL"; do
  [ -f "$candidate" ] || continue
  missing="$(comm -23 "$required" <(nm -gU -j "$candidate" | sort -u))"
  [ -z "$missing" ] || die "$(basename "$(dirname "$candidate")") lacks symbols the engine needs: $missing"
done
cp "$required" "$BUILD/REQUIRED-FFMPEG-SYMBOLS.txt"

original="$BUILD/swap/FFmpegLGPL.framework.original"
rm -rf "$original"; cp -R "$framework" "$original"
restore() { rm -rf "$framework"; cp -R "$original" "$framework"; }
trap restore EXIT

expect() { # <description> <output> <text>
  case "$2" in *"$3"*) ;; *) die "$1: expected '$3' in:
$2" ;; esac
}

before="$("$exe" "$media")"
expect "core framework" "$before" "profiles core"$'\n'
expect "core framework" "$before" "plan unsupported"
expect "core framework" "$before" "ffmpeg 9."

log "replace the framework with another build, same executable"
rm -rf "$framework"; cp -R "$other" "$framework"
codesign --force --sign - --timestamp=none "$framework" >/dev/null 2>&1
after="$("$exe" "$media")"
expect "replaced framework" "$after" "profiles core+extended"
expect "replaced framework" "$after" "plan software"
expect "replaced framework" "$after" "dav1d"

log "put the original back"
restore
codesign --force --sign - --timestamp=none "$framework" >/dev/null 2>&1
again="$("$exe" "$media")"
expect "restored framework" "$again" "profiles core"$'\n'

log "framework swap works: core -> extended -> core without relinking"
