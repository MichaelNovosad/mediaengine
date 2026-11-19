---
name: engine-software-player
description: Work on MediaEngine's own player (the software path - SoftwareController, SoftwareVideoPipeline, SoftwareVideoDecoder, PixelBufferConverter, Deinterlacer) for video Apple cannot decode (VC-1, MPEG-2 DVDs, MPEG-4, VP8/VP9, AV1, Hi10P fallback): picture rate, frozen or late pictures, jumps, the sound that comes from the remuxer, sound and subtitle switches, the clock rules. Use when such a film plays badly, before changing any of these files, or when a per-sample loop is added.
---

# The engine's own player (software path)

## How it is put together

- **Picture:** `SoftwareVideoPipeline` owns a `PacketReader` limited to the video stream and a `SoftwareVideoDecoder` (FFmpeg, frame
  and slice threads where the decoder has them: VC-1 has none, `vc1dec.c` 1403). Pictures become `CVPixelBuffer`s
  (`PixelBufferConverter`, bi-planar 8 or 10 bit, colour attachments), optionally deinterlaced (`Deinterlacer`), and are queued on an
  `AVSampleBufferDisplayLayer` attached to an `AVSampleBufferRenderSynchronizer`: the synchronizer is the picture clock.
- **Sound:** an `AVPlayer` playing the session's **sound-only HLS stream** from `RemuxSession` (`PlaybackSession.makeAudioItem`):
  the same remuxer as the AVPlayer path, without a video output, so DTS and the like are converted to ALAC there. The sound reader is a
  second reader of the same file (see "Two readings").
- **Clock** (`SoftwareController.tick`, 10 times a second): both clocks start together on one host time (`startClocks`).
- **Subtitles:** `SubtitleRenderer` from the session; drawn by the host from `subtitleFrame(size:)` on the picture clock.

## Rules (each one was a bug the owner saw)

1. **The picture never waits for the sound** (owner, 2026-11-17). While the sound plays, the picture follows it over drifts up to
   `followLimit` (0.25 s). A sound that stopped (data ran out, a track switch) or is farther away is brought to the picture by
   `joinSound`: pause, **exact seek** to where the picture will be `joinLead` later (0.6 to 4 s, from the last seek's time), then
   `setRate(_:time:atHostTime:)` on the host time the picture gets there. `setRate(_:time:atHostTime:)` alone starts a stopped HLS
   item but does not move it: a sound 1.45 s behind stayed behind. A start counts as a join for the once-a-second limit.
2. **During a jump the clocks belong to the jump** (`seeking`, `seekGeneration`): `tick` does nothing; play, pause and speed during a
   jump are kept for its end (`wantsToPlayAfterSeek`); a later jump wins. Without it the sound rejoin started both clocks from the old
   place and the picture ran 54 s past the target.
3. **Late pictures are skipped before conversion** (`receive(discardingBefore:lateBefore:)`, `takeSkippedLate`); pictures before a
   jump's target are never converted. A player that fell behind must catch up, not convert pictures it will drop.
4. **Deinterlacing gives way when late** (`skipDeinterlacing(next: 50)`): the Swift deinterlacer is slow in debug builds; a DVD's
   picture froze because every late picture was dropped.
5. **A new subtitle renderer's first frame counts as changed** (`SubtitleRenderer.frame`): hosts redraw only on `changed`, and the old
   track's line stayed on screen after a switch.
6. **Blu-ray subtitles (PGS) begin with their composition** (`BitmapBackend`, 2026-11-19): FFmpeg's PGS decoder has no flush and keeps
   its last composition; in a transport stream every segment is a block, so after an end segment or a jump the segments before the next
   composition are passed over. A line without an end is drawn only across stretches that were read (`render(at:size:loaded:)`). Before:
   the line on screen before a jump came back after every jump.

## Speed in debug builds

The app runs from Xcode as a debug build (`-Onone`). In per-sample code (two million samples a 1080p picture):

- No `for x in 0..<width`: the generic range iterator runs for every sample (90 % of the picture thread on 2026-11-17, 16 pictures a
  second instead of 24). Use `while` loops over pointers; masking shifts (`&<<`, `&>>`) instead of the generic `<<`.
- Prefer Accelerate (vImage), which is optimised in every build: `vImageConvert_PlanarToChunky8` interleaves the two 8-bit chroma
  planes. There is no two-channel 16-bit interleave in vImage (checked in the SDK's `Conversion.h`).
- Read 16-bit samples through `withMemoryRebound`, not `assumingMemoryBound` on bytes FFmpeg bound as `UInt8`.
- Measure before and after with a stack sample (skill `engine-share-check`), not by reasoning.

## Jumps in MPEG transport and program streams

`PacketReader.interpolatedSeek`: by byte position from the average byte rate, aimed 2 s before the target, accepted 2 to 5 s before
it, closing in from both sides (at most 8 tries). It once accepted any landing before the target and landed two minutes early (both
readers read 600 MB before showing anything). The picture reader then decodes from the first keyframe it meets and discards pictures
before the target without converting them.

## Two readings of one file

The picture reader and the remuxer each read the whole file (a transport stream interleaves everything). Through the Finder mount the
second read is mostly served by macOS's cache once the remuxer is ahead; Eiga's own SMB client has no such cache. At 5.2 MB/s (Lost in
Translation) that is about 10 MB/s at a jump, the owner's router's best. What helps on the sound side (`RemuxSession`):

- A session without video reads and converts about 30 s ahead (`soundLookahead`); a read-ahead gives way to any request whose fragment
  is not built (`requestWaiting`), also one that only needs converting (a switch).
- The source packets of every converted sound track stay in memory under `soundPacketBudget` (48 MB), trimmed around where the player
  plays (`notePlayhead`, called by both controllers), so a switch converts from memory (25 ms) instead of reading again.

Only one reading for both (the direct player, the app's `docs/OWN_PLAYER.md`) removes the double read.

## Where to look

- Log, subsystem `dev.mediaengine`, category `player`: "Software video from …" (time to the first picture, the reader's jump, packets on
  the way), "Sound joins the picture …", "Sound was not ready before the picture reached …".
- Tests (run only on the owner's word): `SoftwareControllerPlaybackTests`, `SoftwarePipelineTests`, `InterlacedPlaybackTests`,
  `ConformanceTests` (the converter, bit-exact), `LegacyContainerPlaybackTests`; extended variant (`MEDIAENGINE_PROFILE=extended`,
  `--scratch-path .build-extended`).
- History: RESEARCH 25 to 27 (built), 31 to 33 (2026-11-17: speed, jumps, sound, subtitles).
