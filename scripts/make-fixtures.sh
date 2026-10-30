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

log "fixture-speech.mkv  (a spoken sentence as FLAC sound, made silently with the Mac's say command, for the subtitles-from-speech tests)"
speech_dir="$(mktemp -d)"
say -v Samantha -o "$speech_dir/speech.wav" --data-format=LEI16@22050 \
  "Good evening. This movie has subtitles that were made on this device. They are automatic and may contain mistakes."
"$FF" -v error -y -stream_loop -1 -i fixture-basic.mkv -i "$speech_dir/speech.wav" -map 0:v:0 -map 1:a:0 -c:v copy -c:a flac -shortest -f matroska fixture-speech.mkv
rm -rf "$speech_dir"

log "fixture-native.mp4  (the same picture and AAC sound in an MP4, which the system plays by itself)"
"$FF" -v error -y -i fixture-basic.mkv -map 0:v:0 -map 0:a:0 -c copy -movflags +faststart fixture-native.mp4

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

log "fixture-opus-vorbis.mkv  (14 s: H.264 + Opus stereo 48 kHz + Vorbis stereo 44.1 kHz, spans three segments)"
# Pink noise has unique content at every instant, so any misalignment or glitch at a segment boundary shows up.
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=14" \
  -f lavfi -i "anoisesrc=color=pink:seed=7:sample_rate=48000:amplitude=0.25:duration=14" \
  -f lavfi -i "anoisesrc=color=brown:seed=11:sample_rate=44100:amplitude=0.25:duration=14" \
  -map 0:v -map 1:a -map 2:a \
  -c:v h264_videotoolbox -b:v 250k -g 25 -pix_fmt yuv420p \
  -c:a:0 opus -strict -2 -b:a:0 96k -ac:a:0 2 -c:a:1 vorbis -strict -2 -b:a:1 96k -ac:a:1 2 \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="Opus" -metadata:s:a:1 language=jpn -metadata:s:a:1 title="Vorbis" \
  -f matroska fixture-opus-vorbis.mkv

log "fixture-bframes.mkv  (10 s: H.264 High with B-frames + AAC; Matroska has no decode timestamps for the first reordered frames)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=10" \
  -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=10" \
  -map 0:v -map 1:a \
  -c:v h264_videotoolbox -b:v 300k -g 25 -profile:v high -bf 2 -pix_fmt yuv420p \
  -c:a aac_at -b:a 96k -metadata:s:a:0 language=eng \
  -f matroska fixture-bframes.mkv

log "fixture-subs-long.mkv  (14 s: H.264 + AAC + SRT with cues that span the 6-second segment boundaries)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=14" \
  -f lavfi -i "sine=frequency=550:sample_rate=48000:duration=14" \
  -i src/subtitle-long.srt \
  -map 0:v -map 1:a -map 2:s \
  -c:v h264_videotoolbox -b:v 250k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
  -f matroska fixture-subs-long.mkv

log "fixture-multi.mkv  (3 s: four audio tracks incl. two English and a duplicate title, three subtitle tracks incl. SDH and forced)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" \
  -f lavfi -i "sine=frequency=300:sample_rate=48000:duration=3" \
  -f lavfi -i "sine=frequency=400:sample_rate=48000:duration=3" \
  -f lavfi -i "sine=frequency=500:sample_rate=48000:duration=3" \
  -f lavfi -i "sine=frequency=600:sample_rate=48000:duration=3" \
  -i src/subtitle-en.srt -i src/subtitle-sdh.srt -i src/subtitle-ja.srt \
  -map 0:v -map 1:a -map 2:a -map 3:a -map 4:a -map 5:s -map 6:s -map 7:s \
  -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="Main" \
  -metadata:s:a:1 language=eng -metadata:s:a:1 title="Director commentary" \
  -metadata:s:a:2 language=jpn -metadata:s:a:2 title="Japanese" \
  -metadata:s:a:3 language=eng -metadata:s:a:3 title="Main" \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
  -metadata:s:s:1 language=eng -metadata:s:s:1 title="English SDH" \
  -metadata:s:s:2 language=jpn -metadata:s:s:2 title="Signs" \
  -disposition:a:0 default -disposition:a:1 comment -disposition:a:2 0 -disposition:a:3 0 \
  -disposition:s:0 default -disposition:s:1 hearing_impaired -disposition:s:2 forced \
  -f matroska fixture-multi.mkv

log "audio/ext-*  (external audio files: m4a/AAC, aac/ADTS, flac, ac3, mka/Opus; 3 s of a 700 Hz sine, mono)"
mkdir -p audio
SINE="sine=frequency=700:sample_rate=48000:duration=3"
"$FF" -v error -y -f lavfi -i "$SINE" -c:a aac_at -b:a 64k -metadata:s:a:0 language=eng -f mp4 audio/ext-aac.m4a
"$FF" -v error -y -f lavfi -i "$SINE" -c:a aac_at -b:a 64k -f adts audio/ext-aac.aac
"$FF" -v error -y -f lavfi -i "$SINE" -c:a flac audio/ext-flac.flac
"$FF" -v error -y -f lavfi -i "$SINE" -c:a ac3 -b:a 96k -f ac3 audio/ext-ac3.ac3
"$FF" -v error -y -f lavfi -i "$SINE" -c:a opus -strict -2 -b:a 48k -metadata:s:a:0 language=jpn -metadata:s:a:0 title="Japanese dub" -f matroska audio/ext-opus.mka

log "fixture-ordered.mkv, fixture-ordered-missing.mkv, fixture-linked-opening.mkv  (ordered chapters that play a separate file; scripts/make-ordered-fixtures.py patches the bytes)"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=4" -f lavfi -i "sine=frequency=550:sample_rate=48000:duration=4" -i src/chapters-placeholder.ffmeta \
  -i src/ordered-main.ass -attach src/BlockFont.ttf -metadata:s:t:0 mimetype=application/x-truetype-font -metadata:s:t:0 filename=BlockFont.ttf \
  -map 0:v -map 1:a -map 3:s -map_chapters 2 -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng -f matroska "$BUILD/work/ordered-base.mkv"
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=2" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" -i src/ordered-opening.ass \
  -map 0:v -map 1:a -map 2:s -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng -f matroska "$BUILD/work/linked-base.mkv"
python3 -I ../scripts/make-ordered-fixtures.py "$BUILD/work/ordered-base.mkv" "$BUILD/work/linked-base.mkv" \
  fixture-ordered.mkv fixture-ordered-missing.mkv fixture-linked-opening.mkv

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

log "fixture-ass-fx.mkv  (6 s: H.264 + AAC + an ASS track with a karaoke line, plus the generated block font as an attachment)"
python3 -I ../scripts/make-block-font.py src/BlockFont.ttf >/dev/null
"$FF" -v error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -i src/fx.ass \
  -attach src/BlockFont.ttf -metadata:s:t:0 mimetype=application/x-truetype-font -metadata:s:t:0 filename=BlockFont.ttf \
  -map 0:v -map 1:a -map 2:s \
  -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -c:s copy \
  -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng -metadata:s:s:0 title="Effects" \
  -f matroska fixture-ass-fx.mkv

log "fixture-bitmap.mkv  (6 s: H.264 + AAC + picture subtitles: PGS, VobSub and DVB, all showing the same red box twice)"
python3 -I ../scripts/make-bitmap-subs.py src >/dev/null
"$FF" -v error -y -copyts \
  -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=6" \
  -i src/bitmap.sup -i src/bitmap.idx -i src/bitmap.idx \
  -map 0:v -map 1:a -map 2:s -map 3:s -map 4:s \
  -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -c:s:0 copy -c:s:1 copy -c:s:2 dvbsub \
  -metadata:s:a:0 language=eng \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="PGS" \
  -metadata:s:s:1 language=jpn -metadata:s:s:1 title="VobSub" \
  -metadata:s:s:2 language=fre -metadata:s:s:2 title="DVB" \
  -f matroska fixture-bitmap.mkv

log "legacy containers (extended profile): AVI/Xvid, AVI/H.264, FLV, RealMedia, WMV, MPEG-2, OGM"
LEGACY_SRC=(-f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3")
"$FF" -v error -y "${LEGACY_SRC[@]}" -c:v mpeg4 -vtag XVID -qscale:v 4 -g 25 -c:a ac3 -b:a 96k -metadata:s:a:0 language=eng -f avi fixture-avi-xvid.avi
"$FF" -v error -y "${LEGACY_SRC[@]}" -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -f avi fixture-avi-h264.avi
"$FF" -v error -y "${LEGACY_SRC[@]}" -c:v flv -qscale:v 4 -g 25 -c:a aac_at -b:a 64k -f flv fixture-flv.flv
"$FF" -v error -y "${LEGACY_SRC[@]}" -c:v rv20 -b:v 400k -g 25 -c:a ac3 -b:a 96k -f rm fixture-realmedia.rm
"$FF" -v error -y "${LEGACY_SRC[@]}" -c:v wmv2 -b:v 400k -g 25 -c:a wmav2 -b:a 64k -f asf fixture-wmv.wmv
"$FF" -v error -y "${LEGACY_SRC[@]}" -c:v mpeg2video -b:v 800k -g 12 -c:a mp2 -b:a 128k -f mpeg fixture-mpeg2.mpg
python3 -I ../scripts/make-ogm.py fixture-avi-xvid.avi fixture-ogm.ogm
# 14 s of small video and three audio tracks in legacy audio codecs (WMA, MP2, MS ADPCM), for the segment-by-segment audio tests
"$FF" -v error -y -f lavfi -i "testsrc2=size=160x90:rate=10:duration=14" -f lavfi -i "sine=frequency=330:sample_rate=44100:duration=14" \
  -f lavfi -i "sine=frequency=550:sample_rate=44100:duration=14" -f lavfi -i "sine=frequency=770:sample_rate=44100:duration=14" \
  -filter_complex "[1:a]aformat=channel_layouts=stereo[a1];[2:a]aformat=channel_layouts=stereo[a2];[3:a]aformat=channel_layouts=stereo[a3]" \
  -map 0:v -map "[a1]" -map "[a2]" -map "[a3]" -c:v mpeg4 -qscale:v 8 -g 10 -c:a:0 wmav2 -b:a:0 96k -c:a:1 mp2 -b:a:1 128k -c:a:2 adpcm_ms \
  -metadata:s:a:0 title="WMA" -metadata:s:a:1 title="MP2" -metadata:s:a:2 title="ADPCM" -f avi fixture-avi-audio.avi
"$FF" -v error -y "${LEGACY_SRC[@]}" -c:v h264_videotoolbox -b:v 300k -g 25 -pix_fmt yuv420p -c:a aac_at -b:a 64k -f mpegts fixture-ts.ts   # core container: H.264 in Annex B form, AAC with ADTS headers

# Interlaced pictures (two fields captured 1/50 s apart, woven into one frame) and a non-square pixel aspect ratio (ANM-7).
# `weave` is an LGPL filter; the GPL-only `interlace` and `tinterlace` filters are not in our host tools.
log "interlaced MPEG-2 (top field first and bottom field first) and an anamorphic MPEG-4 file in Matroska"
for order in top bottom; do
  "$FF" -v error -y -f lavfi -i "testsrc2=size=320x240:rate=50:duration=1.5" -vf "scale=320:120:flags=bilinear,weave=first_field=$order,setsar=1" \
    -c:v mpeg2video -flags +ildct+ilme -b:v 900k -g 12 -f mpeg "fixture-interlaced-$([ $order = top ] && echo tff || echo bff).mpg"
done
"$FF" -v error -y -f lavfi -i "testsrc2=size=360x288:rate=25:duration=2" -vf "setsar=16/11" -c:v mpeg4 -qscale:v 5 -g 25 -f matroska fixture-anamorphic.mkv

log "ground truth (ffprobe JSON, committed next to the fixtures)"
mkdir -p ground-truth
for f in fixture-*.*; do
  case "$f" in *.json) continue ;; esac
  "$BUILD/tools/bin/ffprobe" -v error -show_format -show_streams -show_chapters -of json "$f" > "ground-truth/${f%.*}.json"
done

ls -l *.mkv
