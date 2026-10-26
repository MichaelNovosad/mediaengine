# Changelog

All notable changes. The project follows `docs/VERSIONING.md`. Dates are the day the work was finished; nothing has been released yet.

## Unreleased (version 1.0 candidate)

### Playing
- MKV and WebM (H.264, HEVC, hardware AV1, ProRes) play through AVPlayer by repackaging to fragmented MP4 over a local HLS stream: system
  controls, AirPlay, Picture in Picture, HDR10 signalling, seeking through the index, B-frames, damaged files.
- Audio AVPlayer cannot decode (FLAC, PCM, Opus, Vorbis, MPEG audio layer II, MS and IMA ADPCM) is converted losslessly to ALAC.
- Chapters with kinds, ordered chapters and linked segments across files, cover art and Now Playing metadata, track choices and
  preferences, external subtitle and audio files, text subtitles as WebVTT.
- Full ASS (libass) and picture subtitles (PGS, VobSub, DVB) drawn by the engine through `SubtitleRenderer`; Japanese, Chinese and Korean
  subtitles wrap by Unicode line-breaking rules (libunibreak).
- `PlaybackController`, `AVPlayerController`, `SoftwareController`, `MediaVideoView`: one object for every path.
- Software player (extended variant): MPEG-1/2/4, WMV, Flash video, RealVideo, VP8, VP9 and AV1 (dav1d) decoded by the engine, own
  deinterlacer, soft telecine durations, pixel aspect ratio, 8 to 16-bit planar YUV shown as 8 or 10-bit buffers with colour attachments.
- Legacy containers: AVI, FLV, RealMedia, OGM, ASF, MPEG-PS and MPEG-TS probe, plan and play.
- `MediaInfo.isIncomplete` flags a cut-off Matroska download.

### Licences and release
- `MediaEngine.acknowledgements` (generated from the pins), source pack and `BUILD-INFO.txt`, the procedure and a test for replacing
  `FFmpegLGPL.framework`, patent profile document (draft), licence decision memo (open).
- DocC with a tutorial and articles; `Samples/QuickStart` for iOS, macOS and visionOS.

### Quality
- 64 official VP8, VP9 and AV1 conformance streams decode bit-exact; unit, playback, resource and sanitizer passes in `scripts/verify.sh`;
  benchmark baseline with a 10% regression gate.

### Known limits
- visionOS verified in the simulator only; AirPlay, Picture in Picture and phone performance not yet measured on devices.
- H.264 Hi10P is out of scope; VC-1, DTS and TrueHD, WMA and RealAudio, Dolby Vision profile 7 conversion and inverse telecine are not in
  version 1 (`docs/PROGRESS.md`, "Deferred after v1").
