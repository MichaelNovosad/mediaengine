---
name: engine-disc-folders
description: Work on DVD (VIDEO_TS) and Blu-ray (BDMV) folders in MediaEngine and Eiga - a DVD title played as one film from its VOB files, IFO structure, time map, chapters, DVD subtitles and palette, track languages from IFO and CLPI files, PGS in transport streams, Blu-ray folders as macOS packages, opening a disc from the device, a drive or the server. Use when a disc film opens partly, shows a wrong length or no track names, jumps wrongly, or its subtitles do not draw, and before building Blu-ray playlists (MPLS) or the keyframe map from clip files (EGA-121).
---

# DVD and Blu-ray folders

The format books are licensed and were not read: everything here comes from public descriptions of the layouts, checked against the
owner's discs on the share (Häxan, Az ember tragédiája, Labyrinth, Lost in Translation, Yi Yi). Every read is bounds-checked. Treat
layout details as **believed** until a real disc agrees, and say so. Encrypted discs (CSS) are never handled; libdvdnav/libdvdread are
GPL and excluded.

## DVD: a title as one film (engine)

- `DVDStructure.read(videoManager:titleSet:)` (public) reads `VIDEO_TS.IFO` and each `VTS_xx_0.IFO`: titles in the disc's order, each
  with its title set, length (sum of its cells), chapter starts, cells in play order (sector ranges in the title set's stream files read
  as one; angle 1 only), the subtitle palette (16 colours, YCrCb), the time map (step and sectors), `subtitleStreams`, `pictureHeight`.
  `mainTitle` is the longest. Names: `streamFileNames(titleSet:)`, `informationFileName(titleSet:)`.
- `DVDTitleByteSource(title:files:)` (public) reads a title's cells out of the set's `VTS_xx_1…n.VOB` as one byte stream;
  `DVDTitleLayout` places cells and seek points.
- `PacketReader` switches to a DVD mode for such a source: each cell's start comes from its navigation pack (`vobu_s_ptm`); a cell whose
  timestamps run on keeps its offset, one that jumps starts where the one before ended; 33-bit timestamps are unwrapped; seeks go by
  byte to the last time-map point at or before the time; the keyframe list is the time map.
- **Found on real discs:** timestamps run on across cells, and the cells' listed times drift from them (Häxan: +0.8 s by 14 min, +6 s at
  the end); time-map entry n is at (n + 1) × the step. A single VOB opened alone gave Häxan 14 h and froze: open the title instead.
- **Subtitles:** a program stream shows a subtitle stream only with its first subtitle, so the title's subtitle streams are made from
  the IFO before FFmpeg looks (`FormatContext.prepareDVDSubtitles`), with the disc's palette as RGB setup text
  (`DVDTitleLayout.subtitleSetup`, canvas 720 × 576/480). A subtitle spanning several packets is joined by `PacketReader` (its first two
  bytes give the size): FFmpeg's parser does that only for streams its demuxer made, and the later packets have no timestamp.
- **Languages:** `DiscInfo.languages(dvdTitleInfo:)` maps the set's sound and subtitle languages to program-stream ids (AC-3 0x80+n,
  DTS 0x88+n, LPCM 0xA0+n, MPEG 0x1C0+n, subtitles 0x20+n) through the first program chain's control words (16:9 takes the "wide"
  subtitle stream); `titleInfoLocation(forStream:)` finds `VTS_01_0.IFO` for `VTS_01_1.VOB`.
- **Program-stream traps:** later VOB files show streams only near their end, which a quick reopening does not read: check
  `PacketSource.hasStream` before using a stream number from the probe; header samples with a repeated decode time are left out of
  the init segment (`InitSegmentBuilder`), or FFmpeg's MP4 muxer refuses the stream.

## Blu-ray

- Streams `BDMV/STREAM/*.m2ts` carry no languages: `DiscInfo.languages(blurayClipInfo:)` reads `BDMV/CLIPINF/<same name>.clpi`
  (`clipInfoLocation(forStream:)`), keyed by PID (`Track.containerID`), passed in with `PlaybackSession(url:/source:trackLanguages:)`.
- **PGS in a transport stream**: each segment of a display set is its own packet with its own time. `BitmapBackend.add` decodes a
  window's packets **in file order**; sorted by time, the composition came after the palette and wiped it ("Invalid palette id 0").
- Jumps go by byte position (`PacketReader.interpolatedSeek`, skill `engine-software-player`). **Planned (EGA-121):** the clip file also
  holds a map of keyframe positions (believed: the EP map in its CPI part); with it a jump would go straight to a keyframe.
- Not built: playlists (`BDMV/PLAYLIST/*.mpls`: a film made of several clips), menus (BD-J, Java: not possible).

## In the app (PlayerApp)

- `NetworkSources/DVDFolder.swift`: a VOB of a title set opens the set's longest title (`titleSource(forLocalStream:)` needs the folder
  readable: an imported folder or a Mac folder; `titleSource(forStream:server:)` lists the server folder once, downloads the IFOs and
  hands the VOBs as deferred SMB sources that connect at their first read).
- `PlayerCore/LibraryFolders.swift`: macOS counts a `BDMV` folder as a package (`public.avchd-collection`), so the import looks inside
  disc packages (`isDiscPackage`); a DVD folder is entered by the first file of the title set that holds the most.
- A movie of an imported folder opens through the folder's access (`AppModel.folderAccess(for:)`): a bookmark of the stream file alone
  cannot read the IFO or CLPI next to it, and then the film opens partly and its tracks are named "Audio 2", "Subtitles 6".
  `MovieOrigin.discLanguages` logs which (category `files`: "Disc: languages for N tracks…" or why none).

## Checking

Play the owner's discs from the share with skill `engine-share-check` (title length and chapters against the time map, start at 0,
jumps landing where asked, subtitles drawn and switched, languages named). Unit tests (owner's word): `DiscInfoTests`. Open on
2026-11-17: whether Yi Yi's `00000.m2ts` still stays at 0:00 at the start (seen once on 2026-11-12).
