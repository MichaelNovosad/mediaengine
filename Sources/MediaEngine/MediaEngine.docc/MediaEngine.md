# ``MediaEngine``

Play Matroska, WebM and other files that AVFoundation cannot open: with the system player whenever possible, with the
engine's own decoders when needed.

## Overview

MediaEngine opens a file, tells you what is in it and how it can be played, and hands you either a plain `AVPlayerItem`
(MKV and WebM with H.264, HEVC or AV1 video are repackaged on the fly, so the system controls, AirPlay, Picture in Picture and HDR
keep working) or a software player for formats Apple cannot decode. It is built on FFmpeg under the LGPL, linked dynamically.

```swift
import MediaEngine

let session = try await PlaybackSession(url: fileURL)   // probes and chooses the best path
let item = try await session.makePlayerItem()            // plain AVPlayerItem
player.replaceCurrentItem(with: item)                    // AVPlayerViewController / VideoPlayer
```

## Topics

### Essentials

- <doc:PlayAnMKV>
- <doc:ChoosingThePlaybackPath>
- ``PlaybackSession``
- ``MediaSource``
- ``MediaInfo``

### Playing

- ``PlaybackController``
- ``AVPlayerController``
- ``SoftwareController``
- ``MediaVideoView``
- ``PlaybackState``
- ``Deinterlacing``

### Finding out what a file needs

- ``PlaybackPlan``
- ``PlaybackPath``
- ``TrackPlan``
- ``TrackTreatment``
- ``UnavailableReason``
- ``CodecProfile``
- <doc:OptionalCodecModules>

### Tracks, chapters and subtitles

- ``Track``
- ``TrackChoice``
- ``TrackPreferences``
- ``Chapter``
- ``OrderedChapters``
- ``LinkedSegment``
- ``SubtitleTrack``
- ``AudioTrack``
- ``SubtitleRenderer``
- ``SubtitleFrame``
- ``SubtitleImage``
- ``TextEncoding``

### What is in a file

- ``Container``
- ``Codec``
- ``VideoDetails``
- ``AudioDetails``
- ``SubtitleDetails``
- ``Attachment``
- ``HDRFormat``

### Bringing your own storage

- ``ByteSource``
- ``FileByteSource``
- ``DataByteSource``
- ``HTTPByteSource``

### Errors

- ``MediaError``

### Licences and the build

- <doc:LicencesAndNotices>
- ``MediaEngine/MediaEngine``
- ``Acknowledgement``
