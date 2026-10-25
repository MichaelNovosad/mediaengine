---
name: engine-playback-debug
description: Debug MKV-to-AVPlayer playback in MediaEngine (HLS fragmented MP4 remux): stalls, wrong duration, A/V offset, rejected streams, audio glitches at segment boundaries, timestamp or B-frame problems. Use when AVPlayer misbehaves or a new file will not play.
---

# Debugging remux playback

Pipeline: `PacketReader` (FFmpeg demux) -> `RemuxSession` (segment plan from keyframes, windows, lazy audio transcode) -> `FragmentWriter` (own moof/mdat) + `InitSegmentBuilder` (FFmpeg MP4 muxer) -> `HLSPlaylists` -> `LoopbackServer` -> AVPlayer. Work from the inside out; each layer has a test that isolates it.

## Method

1. **Does the engine produce sound output?** `RemuxTests` pattern: build a `RemuxSession` on the file, fetch `video-init.mp4` + every `video-N.m4s` (and `audio-ID-...`), concatenate into one `.mp4`, load it with `AVURLAsset` + `AVAssetReader` (`reader.outputProvider(for:)`, `reader.start()`, `provider.next()`). If AVFoundation decodes it frame-exact and the presentation times match the file, the packaging is right and the problem is playlists or transport.
2. **Does AVPlayer accept our HLS?** `AVPlayerEndToEndTests.verifyPlayback` (macOS): ready, duration, tracks, play, seek back/forward, end. Use `RemuxSession.masterTransform` to rewrite the master playlist for experiments.
3. **Segment boundaries**: `fragmentsAreComplete` (every packet in one fragment, contiguous `tfdt`), `startsAreAligned`, `AudioTranscodeTests.segmentsJoin/prerollSegments`, and the E2E `crossesBoundary`.
4. **Timeline**: `BenchmarkTests` prints gaps between neighbouring segments and audio-minus-video start drift.

## Lessons already paid for

- Seeking to time 0 skips packets with negative timestamps (AAC priming): the first window reopens the file (`PacketReader.rewind()`); one global shift keeps every track non-negative.
- The MP4 muxer writes an edit list that shifts AVFoundation's timeline: `use_editlist=0`. With `delay_moov` it returns `ftyp`+`moov` only, which is the init segment. HEVC must be tagged `hvc1`.
- Matroska timestamps are rounded to ms: durations come from dts deltas, `tfdt` from the first packet's dts.
- **Matroska has no dts**: `ReorderModel` rebuilds them per window (`dts[i] = sorted pts[i - delay]`). Never fall back to `dts = pts` for video with B-frames (muxer error "Invalid argument").
- Matroska Cues load lazily: force a seek to the end before reading the index; `RemuxSession.looksComplete` guards it, a scan is the fallback.
- Opus/Vorbis decoders need pre-roll at a segment start (Opus 0.5 s, Vorbis 0.2 s); Opus skip-samples travel in `MediaPacket.skipStart/skipEnd`. Only lossless ALAC (native encoder) is used for transcoding: AAC would glitch every segment.
- HDR10 (PQ) over HLS is rejected by AVPlayer (CoreMedia -17223) even for FFmpeg's own HLS output; HLG and 10-bit SDR work. Open; needs a real HDR10 clip. Test: `pqKnownIssue`.
- 27 SDK: `AVPlayerItem` is `@MainActor`; use `outputProvider(for:)`, `reader.start()`, `provider.next()`, `pixelBufferAndDisplayTime(forItemTime:)`, `CVPixelBufferAttributes()` instead of the deprecated calls.
- The tool sandbox cannot run Python's `http.server`; `NWListener` works. `leaks`/`vmmap` cannot attach.
- HLS media segments cannot come from an `AVAssetResourceLoader` ("custom url not redirect", -12881); only a real network URL works, so the loopback server is the transport (RESEARCH.md section 16).
- AVFoundation's audio menu shows language names, not track titles (E3 item for same-language tracks).
