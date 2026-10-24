#!/bin/bash
# Shared helpers. Source this file; do not execute it.
# Written for macOS /bin/bash 3.2: no associative arrays, no mapfile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
MIN_OS="27.0"
SLICES="macos ios ios-simulator xros xros-simulator"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
# rustup is keg-only on this Mac; Homebrew tools (meson, ninja, cmake, gpg) live in /opt/homebrew/bin.
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:$PATH"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

slice_sdk() {
  case "$1" in
    macos) echo macosx ;; ios) echo iphoneos ;; ios-simulator) echo iphonesimulator ;;
    xros) echo xros ;; xros-simulator) echo xrsimulator ;;
    *) die "unknown slice '$1' (expected: $SLICES)" ;;
  esac
}
slice_target() {
  case "$1" in
    macos) echo "arm64-apple-macos$MIN_OS" ;;
    ios) echo "arm64-apple-ios$MIN_OS" ;;
    ios-simulator) echo "arm64-apple-ios$MIN_OS-simulator" ;;
    xros) echo "arm64-apple-xros$MIN_OS" ;;
    xros-simulator) echo "arm64-apple-xros$MIN_OS-simulator" ;;
    *) die "unknown slice '$1'" ;;
  esac
}
slice_sysroot() { xcrun --sdk "$(slice_sdk "$1")" --show-sdk-path; }

# lock_field <name> <column 2..7>   → value from third_party/sources.lock
lock_field() {
  awk -F'\t' -v n="$1" -v c="$2" '$1==n { print $c }' "$ROOT/third_party/sources.lock"
}
jobs_count() { sysctl -n hw.logicalcpu; }
