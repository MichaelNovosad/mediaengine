#!/bin/bash
# FFmpeg must stay an implementation detail: internal imports only, no C types in public declarations.
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
bad="$(grep -rnE '^(public |package |@_exported )?import FFmpegLGPL' Sources || true)"
[ -z "$bad" ] || { echo "$bad" >&2; die "import FFmpegLGPL must be 'internal import'"; }
bad="$(grep -rnE '^(public |package |@_exported )?import LibASS' Sources || true)"
[ -z "$bad" ] || { echo "$bad" >&2; die "import LibASS must be 'internal import'"; }
ffmpeg_types='AV(FormatContext|CodecParameters|CodecContext|CodecID|Packet|IOContext|Stream|Rational|Dictionary|DictionaryEntry|Frame|InputFormat|OutputFormat|Chapter|ChannelLayout|SampleFormat|PixelFormat|PacketSideData|MasteringDisplayMetadata|ContentLightMetadata)'
leaks="$(grep -rnE "^\\s*(public|open) .*\\b(${ffmpeg_types}|ASS_[A-Za-z]+|OpaquePointer|UnsafeMutablePointer<AV|UnsafePointer<AV)" Sources || true)"
[ -z "$leaks" ] || { echo "$leaks" >&2; die "FFmpeg types appear in public API"; }
log "public API hygiene ok"
