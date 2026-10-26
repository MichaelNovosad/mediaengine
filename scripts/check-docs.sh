#!/bin/bash
# API-10: the DocC documentation (symbol docs, the "Play an MKV in five minutes" tutorial, the articles) builds without warnings.
# The archive ends up in build/DerivedData-docs/Build/Products/Debug/MediaEngine.doccarchive (open it in Xcode, or publish it).
source "$(dirname "$0")/lib/common.sh"
log="$BUILD/logs/docbuild.log"; mkdir -p "$BUILD/logs"
cd "$ROOT"
xcodebuild docbuild -scheme MediaEngine -destination "generic/platform=macOS" ARCHS=arm64 -derivedDataPath "$BUILD/DerivedData-docs" > "$log" 2>&1 \
  || { tail -30 "$log"; die "documentation build failed (see $log)"; }
warnings="$(grep -E 'warning:' "$log" | grep -v '(in target' | sort -u || true)"
if [ -n "$warnings" ]; then printf '%s\n' "$warnings" | sed "s|$ROOT/||" >&2; die "documentation has warnings"; fi
archive="$(find "$BUILD/DerivedData-docs/Build/Products" -name '*.doccarchive' -maxdepth 3 | head -1)"
[ -n "$archive" ] || die "no doccarchive produced"
[ -d "$archive/data/tutorials" ] && ls "$archive/data/tutorials" | grep -q . || die "the tutorial is missing from the documentation archive"
log "documentation builds without warnings: $archive"
