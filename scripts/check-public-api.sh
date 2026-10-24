#!/bin/bash
# FFmpeg must stay an implementation detail: internal imports only, no C types in public declarations.
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
bad="$(grep -rnE '^(public |package |@_exported )?import FFmpegLGPL' Sources || true)"
[ -z "$bad" ] || { echo "$bad" >&2; die "import FFmpegLGPL must be 'internal import'"; }
leaks="$(grep -rnE '^\s*(public|open) .*\b(AV[A-Z][A-Za-z0-9]+|OpaquePointer|UnsafeMutablePointer<AV|UnsafePointer<AV)' Sources || true)"
[ -z "$leaks" ] || { echo "$leaks" >&2; die "FFmpeg types appear in public API"; }
log "public API hygiene ok"
