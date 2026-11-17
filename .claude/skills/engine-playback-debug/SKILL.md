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
- An audio rendition that does not cover the video (a dub shorter than the film, or delayed) stalls AVPlayer unless the uncovered segments are `#EXT-X-GAP` in its playlist (version 8); empty fragments do not help. Anything that loops over `outputs` in `buildWindow` must skip external audio, which has its own reader and cache entries.
- Raw ADTS AAC has no timestamps and no durations without a decoder; `PacketReader` numbers the frames itself.
- `AVPlayerItem.externalMetadata` lives in AVKit and crashes ("unrecognized selector") if AVKit is not loaded; chapter markers for the system player are tvOS-only (RESEARCH.md section 19).
- AVFoundation's audio menu shows language names, not track titles (E3 item for same-language tracks).

## Streams that are not stored the MP4 way (found 2026-10-26)

- CoreMedia -19602 on the first segment of an MPEG-TS or AVI file with H.264: the samples are still in Annex B form. `PacketReader` converts them (`AnnexB.swift`) and puts the parameter sets into the codec parameters at open; AAC with ADTS headers is handled there too. If a new container fails the same way, check `extradata` (avcC/hvcC start with byte 1) and the first bytes of a packet (`00 00 01` = Annex B).
- A file that starts at 1.4 s instead of 0: the reader takes `format.start_time` off every timestamp (`originTicks`); look there before touching the session's shift.
- FFmpeg's parser may overwrite `sample_rate`/`ch_layout` of codec parameters while packets are read; read parameters through `PacketReader.parameters(_:)`.

## Loading over a network (2026-11-07 to 2026-11-17, the owner's share and server)

- **AVPlayer gives up on a piece after about its own length** (`-12889 No response for media file in N s`, `-15628`): a piece must be
  built well within its duration. Short pieces after long GOPs are the risky ones. Read piece times in the log (`index`: "Piece N built
  in M ms [ahead] [after a jump]") before anything else; skill `engine-share-check` for measuring on a real file.
- **Pre-roll must not re-read a GOP.** A converted track's decoder needs a little sound before the piece (`AudioTranscoder.prerollSeconds`:
  DTS, AC-3, E-AC-3 0.1 s, AAC 0.2, Vorbis 0.2, Opus 0.5). Starting the read at the video keyframe before (start - pre-roll) read the
  whole previous piece in films with 10 s GOPs (Lawrence of Arabia: every piece twice since DTS plays). `buildWindow` takes the pre-roll
  from the previous window's stored packets, else from a keyframe at most `prerollReach` (1 s) before, else the decoder starts cold.
- **The player asks far ahead of what it plays**: "the piece asked for last" (`FragmentCache.focus`) is not the playhead. What is kept
  for later (stored sound packets) is anchored to the controllers' playhead (`notePlayhead`).
- **Read-ahead:** one piece for sessions with video (big pieces, the picture's 48 MB budget); about 30 s for sound-only sessions (the
  engine's own player). A read-ahead gives way to any waiting request whose fragment is not built (`requestWaiting`).
- **A sound switch on the AVPlayer path stops the whole film about 0.8 s** even when the new track's pieces are in memory: AVPlayer's
  own wait (also with `playImmediately` right after the switch: tried, no change). Only the direct player avoids it.
- **Jumps in transport streams** go by byte position (`PacketReader.interpolatedSeek`), landing 2 to 5 s before the target; FFmpeg's
  own search reads packet after packet and took minutes in a 27 GB Blu-ray stream over a network.
- A changing PPS in a Blu-ray stream must stay in the samples (`PacketReader.inBandSets`), or the hardware decoder fails after the first
  GOP (picture lost, sound on).
- Details: RESEARCH 28 to 30, 32 and 33.
