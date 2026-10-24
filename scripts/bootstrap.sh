#!/bin/bash
# Checks the tools the build needs; with --install, installs missing ones through Homebrew (no sudo).
# usage: scripts/bootstrap.sh [--install]
source "$(dirname "$0")/lib/common.sh"
install=0; [ "${1:-}" = "--install" ] && install=1
missing=""
check() { # <label> <command> <brew formula>
  if command -v "$2" >/dev/null 2>&1; then printf '  ok       %-8s %s\n' "$1" "$(command -v "$2")"
  else printf '  MISSING  %-8s (brew install %s)\n' "$1" "$3"; missing="$missing $3"; fi
}
log "build tools"
check meson meson meson; check ninja ninja ninja; check cmake cmake cmake; check gpg gpg gnupg; check rustc rustc rustup
[ -d "$DEVELOPER_DIR" ] && echo "  ok       Xcode    $DEVELOPER_DIR" || { echo "  MISSING  Xcode 27 at $DEVELOPER_DIR"; exit 1; }
xcrun simctl list runtimes | grep -i -E 'xros|visionos' >/dev/null && echo "  ok       visionOS simulator runtime" \
  || echo "  MISSING  visionOS runtime (xcodebuild -downloadPlatform visionOS; about 7.5 GB)"
if [ -n "$missing" ]; then
  if [ "$install" -eq 1 ]; then brew install $missing; else echo "Run: scripts/bootstrap.sh --install"; exit 1; fi
fi
