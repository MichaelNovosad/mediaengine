#!/bin/bash
# Downloads the official decoder conformance vectors (libvpx: VP8 and VP9; libaom: AV1) with their per-frame MD5 files into
# build/conformance/, verifies each file against third_party/conformance.lock (SHA-256), and remuxes the IVF ones to Matroska
# (stream copy, so the packets stay bit-identical) because the engine has no IVF demuxer.
# usage: scripts/fetch-conformance.sh            (offline once the files are cached)
#        scripts/fetch-conformance.sh --update   rewrites the lock file from what was downloaded (review the diff!)
# The vectors are test data of the codec projects; they stay in the git-ignored build folder and are never committed.
source "$(dirname "$0")/lib/common.sh"

lock="$ROOT/third_party/conformance.lock"
raw="$BUILD/conformance/raw"; out="$BUILD/conformance/mkv"
VP="https://storage.googleapis.com/downloads.webmproject.org/test_data/libvpx"
AOM="https://storage.googleapis.com/aom-test-data"
mkdir -p "$raw" "$out"

# The vectors we use: every VP8 comprehensive stream, a spread of VP9 (sizes, scaling, intra-only, show-existing-frame,
# tiles, 4:2:2 / 4:4:0 / 4:4:4, 10 and 12 bit) and of AV1 (sizes, 8/10 bit, film grain, scalability, reference scaling).
list() {
  for i in 001 002 003 004 005 006 007 008 009 010 011 012 013 014 015 016 017 018; do echo "$VP/vp80-00-comprehensive-$i.ivf"; done
  for n in vp80-01-intra-1400 vp80-02-inter-1402 vp80-03-segmentation-1401 vp80-04-partitions-1404 vp80-05-sharpness-1428; do echo "$VP/$n.ivf"; done
  for n in vp90-2-00-quantizer-00 vp90-2-00-quantizer-63 vp90-2-01-sharpness-1 vp90-2-02-size-08x08 vp90-2-02-size-66x66 \
           vp90-2-03-size-196x196 vp90-2-03-deltaq vp90-2-06-bilinear vp90-2-07-frame_parallel vp90-2-08-tile-4x4 vp90-2-09-aq2 \
           vp90-2-10-show-existing-frame vp90-2-11-size-351x287 vp90-2-13-largescaling vp90-2-15-segkey vp90-2-16-intra-only \
           vp90-2-19-skip vp90-2-20-big_superframe-01 vp91-2-04-yuv440 vp91-2-04-yuv422 vp91-2-04-yuv444 vp92-2-20-10bit-yuv420 \
           vp92-2-20-12bit-yuv420 vp93-2-20-10bit-yuv422 vp93-2-20-12bit-yuv444; do echo "$VP/$n.webm"; done
  for n in av1-1-b8-00-quantizer-00 av1-1-b8-00-quantizer-63 av1-1-b10-00-quantizer-00 av1-1-b8-01-size-16x16 av1-1-b8-01-size-66x66 \
           av1-1-b8-01-size-196x196 av1-1-b8-02-allintra av1-1-b8-04-cdfupdate av1-1-b8-05-mv av1-1-b8-06-mfmv \
           av1-1-b8-23-film_grain-50 av1-1-b10-23-film_grain-50 av1-1-b8-22-svc-L1T2 av1-1-b8-22-svc-L2T1; do echo "$AOM/$n.ivf"; done
  for n in av1-1-b8-03-sizeup av1-1-b8-03-sizedown; do echo "$AOM/$n.mkv"; done
}

update=false; [ "${1:-}" = "--update" ] && update=true
newlock="$BUILD/conformance/conformance.lock.new"; : > "$newlock"
for url in $(list); do
  for suffix in "" ".md5"; do
    file="$raw/$(basename "$url")$suffix"
    if [ ! -f "$file" ]; then
      log "download $(basename "$file")"
      curl -fL --silent --show-error -o "$file.part" "$url$suffix" && mv "$file.part" "$file"
    fi
    sha="$(shasum -a 256 "$file" | awk '{print $1}')"
    printf '%s\t%s\n' "$(basename "$file")" "$sha" >> "$newlock"
    if ! $update; then
      want="$(awk -F'\t' -v n="$(basename "$file")" '$1==n {print $2}' "$lock" 2>/dev/null)"
      [ -n "$want" ] || die "$(basename "$file") is not in third_party/conformance.lock (run with --update and review)"
      [ "$want" = "$sha" ] || die "$(basename "$file"): SHA-256 mismatch (expected $want, got $sha)"
    fi
  done
done
if $update; then
  { echo "# Pinned conformance vectors (name, SHA-256). Verified by scripts/fetch-conformance.sh; the .md5 files are the publishers' per-frame decoder output."; cat "$newlock"; } > "$lock"
  log "conformance.lock rewritten"
fi

# IVF → Matroska (stream copy). Needs the host tools (build/tools/bin/ffmpeg).
ffmpeg="$BUILD/tools/bin/ffmpeg"
for url in $(list); do
  name="$(basename "$url")"
  case "$name" in
    *.ivf) target="$out/${name%.ivf}.mkv"
      if [ ! -f "$target" ] || [ "$target" -ot "$raw/$name" ]; then
        [ -x "$ffmpeg" ] || die "host tools missing (scripts/build-host-tools.sh)"
        "$ffmpeg" -v error -y -i "$raw/$name" -c copy -f matroska "$target"
      fi ;;
    *) cp -n "$raw/$name" "$out/$name" 2>/dev/null || true ;;
  esac
  cp -f "$raw/$name.md5" "$out/${name%.*}.md5"
done
log "conformance vectors ready: $(ls "$out"/*.md5 | wc -l | tr -d ' ') streams in build/conformance/mkv"
