# Choosing the playback path

Every file takes one of four paths. The engine decides when the file is opened; your app only has to use what it gets.

## The four paths

| ``PlaybackPath`` | When | What you get |
|---|---|---|
| `native` | AVFoundation plays the file as it is (MP4, MOV, M4V, MPEG-TS with H.264/HEVC) | an `AVPlayerItem` for the file itself |
| `remux` | Matroska, WebM or AVI with video Apple decodes (H.264, HEVC, AV1 on chips with a decoder); audio may be converted | an `AVPlayerItem` backed by a local HLS stream the engine makes on the fly |
| `software` | video Apple cannot decode (MPEG-2, Xvid, VP8, VP9, WMV, Flash video, RealVideo; AV1 on older chips) | a ``SoftwareController``: the engine decodes and draws, AVPlayer plays the sound |
| `unsupported` | the file needs something this build does not contain | ``PlaybackPlan/blockingReason`` says what |

`native` and `remux` give the person the system player: lock screen controls, AirPlay, Picture in Picture, subtitle and audio menus,
HDR. `software` gives you the picture in a layer (``MediaVideoView``) and you draw the controls.

## One call for all of them

```swift
let session = try await PlaybackSession(url: fileURL)
let player = try await session.makeController()          // a PlaybackController, whatever the path
```

``PlaybackController`` has the same properties and methods for both players (state, time, rate, seek, audio and subtitle choices).
If you want the system player's own UI, use `makePlayerItem()` instead, which fails for the `software` path.

## Reading the plan before you play

``MediaInfo/playbackPlan`` lists, per track, whether the engine passes it through, converts it (for example FLAC to lossless ALAC),
decodes it itself, or cannot play it. ``MediaInfo/requiredProfile`` is the union of the optional modules the file needs; use it to
decide, for example, whether to offer an upgrade (see <doc:OptionalCodecModules>).

Files that are cut off (an unfinished download) report ``MediaInfo/isIncomplete``. Show that instead of the duration in the header.
