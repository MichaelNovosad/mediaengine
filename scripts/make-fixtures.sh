#!/bin/bash
# Generates tiny deterministic-in-structure test videos (Fixtures/*.mkv) with the developer-only host ffmpeg.
# Needs scripts/build-host-tools.sh first. Files stay far below 2 MB so they may be committed.
source "$(dirname "$0")/lib/common.sh"
FF="$BUILD/tools/bin/ffmpeg"; [ -x "$FF" ] || die "run scripts/build-host-tools.sh first"
cd "$ROOT/Fixtures"

log "fixture-basic.mkv  (H.264 + AAC + FLAC + SRT + 2 chapters)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=3" \
  -i src/subtitle-en.srt -i src/chapters.ffmeta \
  -map 0:v -map 1:a -map 2:a -map 3:s -map_chapters 4 \
  -c:v h264_videotoolbox -b:v 400k -g 25 -pix_fmt yuv420p \
  -c:a:0 aac_at -b:a:0 96k -c:a:1 flac -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="English AAC" \
  -metadata:s:a:1 language=jpn -metadata:s:a:1 title="Japanese FLAC" \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
  -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 default \
  -metadata title="MediaEngine fixture basic" \
  -f matroska fixture-basic.mkv

log "fixture-hevc.mkv  (HEVC + AC-3 stereo)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=3" \
  -map 0:v -map 1:a \
  -c:v hevc_videotoolbox -b:v 400k -g 25 -pix_fmt yuv420p -tag:v hvc1 \
  -c:a ac3 -b:a 192k -ac 2 \
  -metadata:s:a:0 language=eng \
  -f matroska fixture-hevc.mkv


log "fixture-hdr10.mkv  (HEVC Main10 BT.2020/PQ + E-AC-3 5.1)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=220:sample_rate=48000:duration=3" \
  -map 0:v -map 1:a \
  -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le -b:v 600k -g 25 -tag:v hvc1 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
  -c:a eac3 -b:a 384k -ac 6 \
  -metadata:s:a:0 language=eng \
  -f matroska .tmp-hdr10.mkv
# The VideoToolbox encoder drops primaries/transfer, so tag them in a stream-copy pass: in the HEVC bitstream
# (VUI) and in the Matroska Colour element.
"$FF" -v error -y -i .tmp-hdr10.mkv -map 0 -c copy \
  -bsf:v "hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9:video_full_range_flag=0" \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
  -f matroska fixture-hdr10.mkv

log "fixture-hlg.mkv  (HEVC Main10 BT.2020/HLG + AAC)"
"$FF" -v error -y -i .tmp-hdr10.mkv -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=3" \
  -map 0:v -map 1:a -c:v copy -c:a aac_at -b:a 128k -ac 2 -metadata:s:a:0 language=eng \
  -bsf:v "hevc_metadata=colour_primaries=9:transfer_characteristics=18:matrix_coefficients=9:video_full_range_flag=0" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -color_range tv \
  -f matroska fixture-hlg.mkv
rm -f .tmp-hdr10.mkv

log "fixture-licensed-audio.mkv  (H.264 + DTS + TrueHD)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=262:sample_rate=48000:duration=3" \
  -f lavfi -i "sine=frequency=523:sample_rate=48000:duration=3" \
  -map 0:v -map 1:a -map 2:a \
  -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p \
  -c:a:0 dca -strict -2 -b:a:0 768k -ac 2 -c:a:1 truehd -strict -2 -ac 2 \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=eng \
  -f matroska fixture-licensed-audio.mkv

log "fixture-flac24.mkv  (H.264 + FLAC 24-bit stereo 44.1 kHz)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=1000:sample_rate=44100:duration=3" \
  -map 0:v -map 1:a \
  -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p \
  -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 -ac 2 \
  -metadata:s:a:0 language=eng \
  -f matroska fixture-flac24.mkv

log "src/cover.jpg"
"$FF" -v error -y -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 -pix_fmt yuvj420p -c:v mjpeg src/cover.jpg

log "fixture-anime.mkv  (H.264, jpn+eng AAC, ASS dialogue + forced signs ASS, font + cover attachments, OP/ED chapters)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=3" \
  -i src/dialogue.ass -i src/signs.ass -i src/chapters-anime.ffmeta \
  -attach src/FakeFont.ttf -metadata:s:t:0 mimetype=application/x-truetype-font \
  -attach src/cover.jpg -metadata:s:t:1 mimetype=image/jpeg \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s -map_chapters 5 \
  -c:v h264_videotoolbox -b:v 400k -g 25 -pix_fmt yuv420p \
  -c:a aac_at -b:a 96k -c:s copy \
  -metadata:s:a:0 language=jpn -metadata:s:a:0 title="Japanese" \
  -metadata:s:a:1 language=eng -metadata:s:a:1 title="English dub" \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="Dialogue" \
  -metadata:s:s:1 language=eng -metadata:s:s:1 title="Signs and Songs" \
  -disposition:a:0 default -disposition:a:1 0 -disposition:s:0 default -disposition:s:1 forced \
  -f matroska fixture-anime.mkv

log "ground truth (ffprobe JSON, committed next to the fixtures)"
mkdir -p ground-truth
for f in fixture-*.mkv; do
  "$BUILD/tools/bin/ffprobe" -v error -show_format -show_streams -show_chapters -of json "$f" > "ground-truth/${f%.mkv}.json"
done

ls -l *.mkv
