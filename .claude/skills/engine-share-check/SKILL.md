---
name: engine-share-check
description: Check playback of the owner's real films on the mounted SMB share through the engine with a temporary, muted program - start, jumps, sound and subtitle switches, picture rate, piece build times - and read the system log of the owner's own runs. Use when the owner reports that a film from the share or the server stutters, freezes, does not start, jumps slowly, loses sound or subtitles, or when a playback fix must be measured on a real file before reporting it done.
---

# Checking real films from the share

Unit tests use tiny fixtures; the owner's problems come from 30 GB Blu-ray streams, DVDs and 4-hour MKVs on a router's USB disk. This is
how to measure them through the engine without the app, without sound and without leaving anything behind.

## Ground rules (owner)

- The share is read **only through the Finder mount** `/Volumes/tplinkwifi.net`, read-only. Never take, type or ask for the server
  password; if it is not mounted, ask the owner to mount it in Finder (memory: shares-mounted-not-passwords).
- Every player is **muted** (`controller.isMuted = true`) and nothing plays through the speakers.
- Build at background priority (`taskpolicy -b nice -n 19 swift build`). A short run of the program itself may run at normal priority
  when speed is what is measured (background priority puts it on an efficiency core: VC-1 decoded 2 pictures a second there, 24 at
  normal priority). Say so in the report.
- Temporary files live in the engine's git-ignored `build/` folder, never in the source tree or `/tmp`.

## First: the owner's own run

Before writing any program, read what the app logged:

```bash
/usr/bin/log show --last 1h --style compact --info \
  --predicate '(process == "Eiga") AND (subsystem == "dev.mediaengine" OR subsystem == "dev.novosad.eigaplayer") AND category != "ffmpeg"'
```

(`/usr/bin/log`: zsh's `log` is a builtin.) What the lines mean:

- `index`: "Pieces of about N s: link X MB/s, movie Y MB/s" (the plan), "Piece N built in M ms [ahead] [after a jump]" (only the
  first ones, those after a jump and any over 1 s are logged), "read ahead stopped", "Sound track N: the player asked for its playlist"
  (a sound switch), "Sound of piece N, track T: converted in M ms" (slow conversions).
- `player`: "Software video from T s: first picture … after M ms (reader positioned in …, N packets read on the way)" (the engine's
  own player after a start or jump), "Sound joins the picture at …" (a sound that stopped or drifted), AVPlayer's own error log:
  `-12889 No response for media file in N s` means AVPlayer gave up on a piece after about its own length.
- `dev.novosad.eigaplayer`: `opening` (step times), `smb` (connections), `files` (disc languages found or why not).

Piece times tell most of it: a piece must be built well within its own duration, or the player stalls.

## The temporary program

`build/<name>/Package.swift` (executable, `platforms: [.macOS("26.0")]`, dependency `.package(path: "../..")`, Swift 6 mode) and
`Sources/<Name>/main.swift`. Build and run it **with `--package-path`, never `cd` into the folder**: a folder that was the session's
working directory cannot be deleted afterwards (a safety check refuses it; on 2026-11-17 `build/vc1diag` had to be left to the owner).

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer
D=$PWD/build/sharecheck
MEDIAENGINE_PROFILE=extended-plus taskpolicy -b nice -n 19 swift build --package-path "$D" > build/logs/sharecheck-build.log 2>&1
B=$(MEDIAENGINE_PROFILE=extended-plus swift build --package-path "$D" --show-bin-path)
MEDIAENGINE_PROFILE=extended-plus timeout 150 "$B/ShareCheck" "/Volumes/tplinkwifi.net/<film>" 1800 9000
```

`MEDIAENGINE_PROFILE=extended-plus` is the variant the app links (VC-1, DTS core, the fallback decoders); without it the core variant
plans many films as unsupported.

What the program does (main actor, `setvbuf(stdout, nil, _IONBF, 0)`, `await run(); exit(0)`):

1. Open the session. To behave like Eiga's own SMB connection, wrap the file in a byte source that is not a `FileByteSource` (the
   remuxer treats `FileByteSource` as local: other piece sizes, no link measurement):
   ```swift
   final class NetworkLike: ByteSource, @unchecked Sendable {
       let file: FileByteSource
       let meter = Mutex(ThroughputMeter())
       init(url: URL) throws { file = try FileByteSource(url: url) }
       var length: Int64? { file.length }
       var throughput: Double? { meter.withLock { $0.bytesPerSecond } }
       func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
           let began = Date(); let n = try file.read(at: offset, into: buffer)
           meter.withLock { $0.record(bytes: n, seconds: Date().timeIntervalSince(began)) }; return n
       }
   }
   let session = try await PlaybackSession(source: MediaSource(byteSource: try NetworkLike(url: url)))
   ```
2. `makeController()`, mute, `seek(to:)` a start time, `play()`.
3. Every 0.5 to 2 s print `currentTime`, `state` and, for `SoftwareController`, `statistics` (decoded, displayed, dropped). Count the
   time the clock did not move while playing.
4. Switch sound (`audioChoices`, `select`) and subtitles (`subtitleChoices`, `select`; read `subtitleFrame(size:)` and compare what
   an app that redraws only on `changed` would show with what the engine has), jump with `seek(to:)` and time it.
5. Afterwards read the log of the program: `--predicate 'process == "<Name>" AND subsystem == "dev.mediaengine"'`.

To see where time goes, take a stack sample while it plays: `sample <pid> 5 -file build/logs/<name>-sample.txt`, then read the
"Sort by top of stack" part and the feeding thread's call graph (on 2026-11-17 it showed 90 % of the picture thread in a Swift loop
of `PixelBufferConverter`).

## Pitfalls

- **macOS caches what it read from the mount.** A second run over the same part of a film is much faster (pieces in 20 ms). Measure
  jumps and starts in parts of the film never read before (other positions on each run), and say which runs were cached.
- The Finder mount has the system's cache; Eiga's own SMB client does not. A result through the mount is better than the app over the
  server will be when two readers read the same file (the engine's own player). Say so.
- A debug build of the engine is several times slower in Swift loops than a release build; the app run from Xcode is a debug build.
- Clean up when done: delete `build/<name>` and its logs (unless a run failed and the logs explain it), stop anything still running
  (`pgrep -fl <Name>`).

## Report

Numbers, not impressions: pictures a second and dropped, seconds without movement, jump times, piece build times against piece
lengths, which film and which part, cached or not, normal or background priority, debug build. List what was not checked: an iPhone,
Eiga's own SMB client, a release build, by ear.
