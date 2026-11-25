# MediaEngine: progress and handoff

**How to use (any new session or window):** read `CLAUDE.md`, then this file, then continue from "Right now". The owner can add tasks at any time: record each one under "Backlog" first (with the date), then work on it. After every finished step, update this file (move the task, add evidence, refresh "Right now" and "Handoff notes"). Update it before ending a turn so an interrupted session loses nothing.

## Right now

- **2026-11-18: the AVPlayer path's picture layer is made only when a view asks for it** (an AVFoundation deadlock found in the app's
  tests; Done 2026-11-18). Exported to `dist/package` (extended-plus).
- **2026-11-17 (night, committed since: `c071398`, `5b7ea9e`): visionOS left out; VC-1 plays.** visionOS: no slices, platform, samples or simulator runs on
  `main`; the `visionos` branch (at `441dcf6`, local) keeps the state before. `extended-plus` repackaged with three slices, licence check
  passed, exported to `dist/package` (the app's copy was still the one of 2026-11-12 without VC-1: the owner's "VC-1 needs an optional
  module"). Lost in Translation then fell behind and stopped after jumps; fixed the same night (RESEARCH 31): 24 pictures a second in a
  debug build, jumps of 2 to 3 s over the share. Compiled (engine with tests, the app for macOS and the iOS simulator); no test run.
  Left: a jump still waits about 2 s for the sound, which the software path reads a second time (the direct player would end that).
  Details: Done 2026-11-17 (night, two entries).
- **2026-11-12 (committed without compiling, at the app owner's word; the owner builds and tests):** Apple first: H.264, HEVC, AAC,
  AC-3 and E-AC-3 go to an engine decoder only when this device's Apple decoder refuses the stream; Dolby Vision 5 and 8 go to Apple as
  Dolby Vision; the DTS core (patched FFmpeg); `MediaEngine.disabledProfiles` for country rules; the variant `extended-plus`. RESEARCH
  3.2 points 6 to 8. Compiled earlier in the day for the DTS/Hi10P part only; the Apple-first and Dolby Vision code is not compiled;
  no test run, nothing played. Open: the core macOS install folder (empty since 2026-11-04; `scripts/build-ffmpeg.sh macos core`), test
  files for Hi10P, HEVC 4:2:2 and Dolby Vision, the device check (app Jira EGA-102). Details: Done 2026-11-12 (two entries).
- **State on 2026-11-08 (evening), everything committed (`6641e9c`, `6347151`, `195d700`; not pushed): network playback for the app (Eiga 0.2.0).** In one day, driven by the owner's movies on an SMB share (a router's USB disk): time-grid pieces for files without a usable index (`RemuxSession`, `MatroskaSeeker`); pieces sized by the measured link speed; remembered probes (`ProbeStore`); in-band SPS/PPS kept once a stream changes them (`AnnexB`, `PacketReader.inBandSets`: Blu-ray files lost their picture after the first GOP); transport and program streams seek a few frames early (`seeksByDecodeTime`); Blu-ray clip-file languages (`DiscInfo`, `Track.containerID`, `PlaybackSession(…trackLanguages:)`); a fragment cache answered without waiting for builds, with separate budgets for picture (48 MB) and sound of every track (24 MB); read-ahead that gives way to a jump; the loopback server notices a client that hung up (`ConnectionWatch`) and builds nothing for a request the player left for another piece; `playImmediately` at start, resume and after a jump; the item lets go before the server stops; the item's error log in the system log (category `player`); cover pictures sized from their header before FFmpeg's probe; fonts read once per session. Evidence and reasoning: RESEARCH sections 28 to 30. **Compiled only**: no test was run or written for any of it (the owner's rule), and the owner tests the app next.
- **Next (owner's call):** the owner tries Eiga 0.2.0 against the share; if start, jumps and sound switches are still clearly worse than VLC, the plan is a direct player (the engine hands packets to `AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer`, no HLS), starting with a one-week spike: the app's `docs/OWN_PLAYER.md`. Open in the engine: DVD `.IFO` languages built 2026-11-10 (not checked against a real disc); a written analysis the owner asked for (the app's `docs/OWN_PLAYER.md` covers the player side); the libraries are still built for macOS/iOS 27.0 (linker warning; rebuild needs the owner's go).

- **Four movies over SMB (2026-11-08, the app's owner: no picture in one, stuck after jumps in two; not committed).** From the system log: movie 1 (MPEG-TS) decoded only its first group of pictures, then every frame failed in the hardware decoder with slice syntax errors; cause: the stream changes its PPS (same id, new content) again and again, which `AnnexB.convert` dropped (confirmed in the file on the owner's mounted share); now kept in the samples once a stream changes them (`PacketReader.inBandSets`); the engine's pieces of that file now decode in VideoToolbox, start and 12:02. Movies 2 and 3 (Matroska, 10.4 s pieces of 27 MB): the player gives up on a piece after about its own length ("-15628" with a cancelled request); requests for built fragments waited behind builds on the serial queue, read-ahead held up jumps, and the 48 MB cache dropped audio the player had not fetched, so whole pieces were read again. Now: `FragmentCache` (answered without waiting for the queue; keeps the piece just built and the one asked for last), read-ahead stops for a jump (`GaveWay`), subtitle requests over a network read only their own window, and the opening logs its step times. RESEARCH section 30. Compiled (engine; the app for macOS, started 7 s); no test; not played again. **Later the same day (owner mounted the share; owner: "fix and commit"):** cause of movie 1 confirmed in the file (Labyrinth: PPS id 0 rewritten again and again); the engine's pieces decode in VideoToolbox. Lawrence of Arabia (silent, black after jumps): all its sound is DTS (held back, D-3); the jump waited for a piece the player had cancelled: the loopback server now notices a client that hangs up (`ConnectionWatch`) and the session builds nothing for it (`isAbandoned`, `liveWaiters`). Review fixes: warm-up seek near a known keyframe only, probe look-up off the cooperative pool, checks every 16 packets, unused `EBML.float` removed. A check of all 138 files on the share (temporary diagnostic, removed): 62 fine, 42 refused as the plan says (VC-1, DTS-only and the like), 31 VOB/AVI flagged by a harness mistake (decoder drained instead of flushed: re-check pending), 2 Blu-ray extras (1080i, deep B-frames) failed because transport-stream seeks land after the piece's keyframe: now seeking a few frames early (`seeksByDecodeTime`). Compiled only; the re-check of the VOB files and the extras with the fix, and the written analysis for the owner, are still to do. **Then (2026-11-08, evening, committed):** Blu-ray languages: `DiscInfo.languages(blurayClipInfo:)` reads a clip information file (`BDMV/CLIPINF/*.clpi`), `Track.containerID` (the stream's PID or stream id), `PlaybackSession(url:/source:trackLanguages:)` fills the languages a stream leaves out (Blu-ray `.m2ts` streams carry none; checked by hand on three discs on the owner's share); DVD `.IFO` languages are not done. A request the player abandoned is built anyway unless the player went to another piece (the 2-second give-up of a slow piece made it rebuild at once). **Then (2026-11-08, late, not committed):** `AVPlayerController.close` lets go of the item before the server stops (requests to a stopped server: 'Connection refused'); the loopback server sends nothing to a client that hung up ('Connection reset by peer', 'Broken pipe'); the item's error log goes to the system log (category `player`); cover pictures get their size from their JPEG or PNG header before FFmpeg's analysis (`ImageHeader`, `FormatContext.measureAttachedPictures`), so a file with a cover is no longer read to the probe limit. Compiled only. **Then (2026-11-08, committed):** `AVPlayerController` starts, resumes and goes on after a jump with `playImmediately(atRate:)`; the fragment cache keeps sound fragments of every track under a budget of their own (24 MB) so a sound switch finds them; attached fonts are read once per session and started with the player item. The app's `docs/OWN_PLAYER.md` sets out the engine work for a direct player (Apple's sample-buffer renderers instead of the HLS remux). Compiled only.
- **Loading over a network (2026-11-08, the app's owner: "implement 1 to 7, continue fully"; not committed).** Pieces sized by the link speed (`ByteSource.throughput`, `ThroughputMeter`, `RemuxSession.pieceTarget`: what loads in about a second, 2 to 6 s), quick re-openings without FFmpeg's end-of-file duration estimate, keyframes of transport streams indexed as they are read, fonts read with one opening, `ProbeStore` (probe results of network sources kept), four HTTP chunks in flight, timing lines in the log. The owner's big movie is an MPEG transport stream (`.m2ts`), not Matroska. RESEARCH section 29. Compiled only (engine; the app for three platforms).
- **Files without a usable index (2026-11-07, the app's owner: a 19.1 GB MKV over SMB read in full before playing; committed 2026-11-07).** `MatroskaLayout`, `MatroskaClusterIndex` (index from the cluster headers through `ByteSource.readSparse`), `KeyframeIndexStore` (kept per file in Caches, adopted by every `PacketReader`), `PacketReader.addKeyframes`, the seek to the end skipped without Cues for the video track, progress through `PlaybackSession.observePreparation(_:)`, the chapter reader stops at the first cluster. RESEARCH section 28. Compiled without warnings; no test written or run; no file without Cues tried. **Second round (2026-11-07):** the owner's file has Cues for the video, rejected for one gap over a minute, and was read in full again; now the file's own index is always the base and only the stretches it leaves out are read (`RemuxSession.gaps`, `readGaps`), the hop runs only without Cues for the video, and the log says how big the gaps are and why the hop stopped (RESEARCH 28, second round). Compiled only, without tests (the owner: "let's fix it without tests"); committed 2026-11-07. **Third round (2026-11-07, owner chose "option 3", not committed):** without a complete index the pieces lie on a time grid and nothing is read at opening; jumps find a cluster with `MatroskaSeeker` (RESEARCH 28, third round). Compiled only.
- **Overlay subtitles from the remuxer's reading (2026-11-06, the app's owner: "a server-side movie could ignore some subtitles and others could apply with a delay"; committed 2026-11-06).** Cause: `SubtitleRenderer` read the file a second time through its own `PacketReader` on the same byte source, a minute at a time (15 s back, 45 s ahead), only to find its blocks; for a movie on SMB or WebDAV that downloaded most of the movie again, and the two readers took turns with the byte source's chunk cache and read-ahead, so a window of blocks arrived seconds after its first lines began (shown late) or after they ended (never shown). Now `RemuxSession.buildWindow` keeps the blocks of every subtitle stream the overlay can draw (`PlaybackSession.overlayStreams(of:)`) in an `OverlayFeed`, per window, and the renderer takes them from there (`OverlayFeedView`; SubRip/WebVTT/Timed Text converted like `CueScriptEventSource`). It reads the file itself only for what will not come that way (`OverlayFeed.lost`: windows the player skipped (a seek), windows forgotten or kept without this stream, windows more than 10 s ahead of the playhead), never while the player still waits for the window at the playhead, and on its own queue (`readQueue`), so such a read never holds up taking the player's windows. After a seek it reads back 8 s for files on a server (15 s for local files), since that read shares the connection with the player. Memory: text streams are kept for every window (24 MB at most for all, oldest windows go first); picture streams only while a renderer watches them, else for the last 16 windows (`pictureHistory`). PGS after a seek: the windows after a read are given to the decoder again behind it, and a display that decoded empty (it reused a picture not yet seen) is replaced by a later decode with pictures (`BitmapBackend.empty`). Coverage is a set of time ranges (`TimeRanges`), so jumping back to a part read before reads nothing; a failed read waits 1 s before the next try. This covers the AVPlayer path and the software path when the file has sound the system plays (its sound is a remux too); without a remuxer (native files, a software movie without such sound, before the first player item) and for play lists of several files it reads the file as before. Both controllers' `subtitleFrame(size:)` use the player's own clock instead of `currentTime` (refreshed every 100 ms), so lines start and end on time. Compiled only (see the report); no test run or written (the owner's rule), and no existing test reaches the new path (no subtitle test makes a player item).
- **Minimum 26.0 (2026-11-04, the app's owner):** `Package.swift`, the samples and `MIN_OS` say 26.0. The only engine code that needed 27 was the software video path's `AVSampleBufferVideoRenderer.Receiver` (`synchronizer.sampleBufferReceiver(adding:)`): `SoftwareVideoPipeline.Sink` keeps it on 27 and newer and uses the renderer's classic calls on 26 (`addRenderer`, `isReadyForMoreMediaData`, `enqueue`, `flush(removingDisplayedImage:completionHandler:)`). Compiled through the app for macOS (and iOS and visionOS, see the app's PROGRESS); no test run; the classic path has not played a movie yet (needs a 26 system). **The libraries (FFmpeg, LibASS) are still built for 27.0**: the linker warns until they are rebuilt with `MIN_OS` 26.0.
- **App-driven addition (2026-10-31, not committed):** `HTTPByteSource.open(…, delegate:)` takes a `URLSessionDelegate` that answers the session's challenges for every range request: the app's WebDAV client uses it for a home server's own certificate that the person trusted once (pinned by its SHA-256 fingerprint) and for HTTP Digest sign-in. Default `nil`: nothing changes for other callers. Compiled (`swift build`); no test run (the owner's rule of 2026-10-30); no new engine test (the behaviour is the app's delegate).
- **App-driven additions (2026-10-29 and 30; committed 2026-10-30, not pushed):** (1) track names carry the language (`TrackTitle`: "Name - [Language]", one source for the app's lists and the HLS rendition names); (2) `SubtitleAppearance` (size 0.5 to 2.5 and a text colour, through libass's font scale and selective colour override: `SubtitleRenderer.appearance`, `PlaybackController.subtitleAppearance`) and `subtitleDelay` for every subtitle the engine draws (`SubtitleRenderer.delay`, `PlaybackController.subtitleDelay`); (3) `AudioTrack(source:name:...stream:)` and `PlaybackSession.audioTrack(like:delay:title:)`: a copy of one of the video's own sound tracks that starts later or earlier, played like a separate sound file; (4) `PlaybackSession.canExtractSpeechAudio(of:)` and `extractSpeechAudio(of:to:progress:)` (`SpeechAudioExtractor`: FFmpeg decoders for FLAC, Opus, Vorbis, MP3, ALAC, PCM; AudioToolbox through `AVAudioConverter` for AAC, AC-3, E-AC-3; mono 16 kHz CAF); (5) the frameworks' privacy manifests declare the file-timestamp category (reason 3B52.1) in `package-xcframework.sh` and `package-subtitle-xcframework.sh`; (6) fixtures `fixture-native.mp4` and `fixture-speech.mkv` (the latter made with the Mac's `say`). Tests: `SubtitleAppearanceTests`, `SpeechAudioTests`, `ExternalAudioTests.copyOfOwnTrack`, `TrackTitleTests`. The audio tap for an equalizer is not called for the remuxed (HLS) path (the app's RESEARCH 13.1); decoding AAC and AC-3 for it is the open question.
- Milestone: **the engine is finished for version 1 (2026-10-26)**: E0 to E4 are done and verified, E5/E6 release readiness is in place, and the fillers that matter for v1 are done. What is left needs the owner, a lawyer, an Apple account or devices and is listed under "Deferred after v1" below. **PlayerApp M0 may start**, in its own git repository (owner's order); the engine work is committed (`4f3905d`, 2026-10-26).
- What the engine can do: MKV, WebM, MP4, MPEG-TS and legacy containers (AVI, FLV, RealMedia, OGM, ASF, MPEG-PS) probe, plan and play through AVPlayer (remux over local HLS) or through the software player (MPEG-1/2/4, WMV, Flash video, RealVideo, VP8, VP9, AV1 with dav1d; own deinterlacer; pixel aspect ratio) behind one `PlaybackController`; lossless audio conversion; text subtitles as WebVTT; full ASS and picture subtitles through `SubtitleRenderer`; chapters, ordered chapters, track choices, external subtitle and audio files; `MediaEngine.acknowledgements`; DocC with tutorial; two sample apps. Maps: handoff notes below and RESEARCH.md sections 22 to 28.
- Verified (full `scripts/verify.sh`, 2026-10-26, exit 0, 10 min 50 s, step times in `build/verify-logs/summary.txt`): sources and acknowledgements up to date, licence check (core, extended, LibASS), source pack and framework swap, API hygiene, ground truth for 28 fixtures, DocC without warnings, build without warnings, macOS in three passes (unit 19 s, playback 86 s one suite after another, isolated 6 s), the extended variant (unit tests including 64 conformance streams, software player, legacy containers in AVPlayer), package traits, QuickStart and Player samples for macOS, iOS and visionOS, and 287 tests on the iPhone, iPad, iPhone Duo and visionOS simulators. Sanitizers (2026-10-26, run before the load rule below): `check-sanitized.sh all` passed (AddressSanitizer with instrumented FFmpeg, ThreadSanitizer, UBSan, core variant); the extended variant's decoder, conformance, converter and deinterlacer tests passed under AddressSanitizer; the software player under ThreadSanitizer reported no race (its frame-count assertions are relaxed under sanitizers). The benchmark gate matched its baseline (3 runs).
- **Open issues and items that need devices, real files, a lawyer or the owner:** see "Deferred after v1". Highlights: AirPlay and PiP (RMX-10, SWD-2, E-S4), phone performance (RMX-6, SWD-3, E-S6), HDR10 over HLS (E-S3), visionOS on a headset (PLT-3), licence decision D-E1 and the lawyer's review (LIC-5 to LIC-7), real anime and 4K PGS files.
- Next actions: the app is under way in its own repository, `~/Documents/Development/PlayerApp` (M0 done, M1 next); engine work from here is driven by what the app needs (the owner's decisions and the deferred list above).
- Waiting on the owner: nothing blocking the app. Decisions in the handoff notes (D-E1, support terms). Useful when convenient: one real HDR10 MKV clip, a few big real MKVs (an anime release with heavy typesetting, a 4K PGS rip), an hour with a Mac, iPhone and Apple TV for the AirPlay spike.

## Task board

### In progress
- Between steps. Candidates in "Up next".

### Plan for 2026-10-25 (prepared 2026-10-24 at the owner's request; do the tasks in this order)

Ground rules for the day: start with `CLAUDE.md`, this file and the skills in `.claude/skills/`; `scripts/verify.sh` before calling anything done; docs updated after each task (skill `engine-finish-step`); commit only when asked, no Claude trailer.

**T1. Byte-bounded segments (RMX-7): DONE 2026-10-25** (cap 24 MB by time and by index position, mmap-backed fragments; 4K 44 Mbps 304 MB -> 101 MB, RMX-7 ticked; see RESEARCH.md section 15). Original brief:
- Why: a segment holds 6 s of video, so memory scales with bitrate: 137 MB peak at 13 Mbps 1080p, and one UHD remux segment alone is 45-75 MB (target 150 MB total).
- Steps: (1) `PacketReader`: next to `keyframeTimestamps`, return each keyframe's byte position (`avformat_index_get_entry(...).pointee.pos`). (2) `SegmentPlan.make(keyframes:duration:target:maxBytes:)`: cut at a keyframe when the segment is at least `target` seconds long OR its byte span (position delta, audio included) reaches the cap (start with 24 MB), never inside a GOP; the scan fallback adds up packet sizes instead. (3) Check `HLSPlaylists` (`EXT-X-TARGETDURATION` must stay at or above the longest segment). (4) Measure again; only if the peak is still too high, hand packets over to `FragmentWriter` so they are freed while the fragment is written. (5) Generate an 80 Mbps file (`h264_videotoolbox -b:v 80M`, 1080p or 4K, 60 s, B-frames; recipe in skill `engine-benchmark`) and run `BenchmarkTests` on it.
- Done when: unit tests for the byte cap (segments tile, never shorter than one GOP, time-only behaviour unchanged when the cap is not reached), `fragmentsAreComplete` and the AVPlayer end-to-end tests still pass, the 80 Mbps file stays under 150 MB growth, RMX-7 ticked with the numbers, `scripts/verify.sh` passes.
- Watch out: files without Cue positions fall back to time-only cutting plus the packet-size scan; keep the 48 MB cache budget in mind (it must hold at least the current and next segment).

**T2. `.resourceLoader` transport (RMX-9): DONE 2026-10-25 as a negative result** (AVPlayer refuses HLS media segments from a resource loader, "custom url not redirect"; no transport built, RMX-9 ticked for the loopback server; RESEARCH.md section 16). Original brief:
- Steps: public `PlaybackSession.Transport` (`.loopbackServer` stays the default, `.resourceLoader` new) and `makePlayerItem(transport:)`. Custom URL scheme per session with an unguessable host, an `AVAssetResourceLoaderDelegate` on its own queue that answers content-information and data requests (ranges) from the same `ResourceProvider` the server uses, cancels and finishes pending requests on `close()`.
- Tests: run the AVPlayer end-to-end suite for both transports; with `.resourceLoader` no listener may exist (assert via the server type); closing the session finishes outstanding loading requests.
- Done when: both transports pass play/seek/finish, API documented with a plain statement of what AirPlay is expected to do (unverified until E-S4), RMX-9 ticked for the automatable part.
- Risk: AVPlayer might refuse HLS through a custom scheme in the 27 SDK. If so, record the exact failure in `docs/RESEARCH.md` and keep loopback as the only transport; RMX-9 then states the finding.

**T3. E3 kickoff: design note and two spikes: DONE 2026-10-25** (S1 passed and is in the tree, S2 result: the system menu cannot show track titles; design and sub-milestones E3.1-E3.6 in RESEARCH.md section 17). Original brief: E3 covers SUB-1..5, RMX-4 (text subtitles as WebVTT renditions), RMX-8 (chapters, Now Playing metadata), AUD-1 (external audio), ANM-2 and ANM-4 (ordered chapters, chapter types) and the same-language track names; PlayerApp M0 starts after it.
- Spike S1: text subtitles (SRT, ASS dialogue stripped of override tags) from the core decoders into a WebVTT HLS rendition (segment per 6 s, `X-TIMESTAMP-MAP`), proven by an end-to-end check that `item.asset.loadMediaSelectionGroup(for: .legible)` lists the track and a cue shows at the right time (use the existing `fixture-basic` SRT and `fixture-anime` ASS).
- Spike S2: telling apart two audio tracks of the same language in the system menu (AVFoundation shows the language name only): try HLS `NAME`, `CHARACTERISTICS`, `LANGUAGE` variants and record what the menu actually shows.
- Write `docs/RESEARCH.md` section 17 (E3 design: sub-milestones E3.1 text subtitles, E3.2 chapters and metadata, E3.3 external subtitle/audio files with encoding detection, E3.4 libass overlay for full ASS, E3.5 ordered chapters) and refine the E3 criteria. **Ask the owner before fetching new third-party sources** for E3.4 (libass ISC, FreeType FTL, HarfBuzz MIT, FriBidi LGPL; BLD-9, E-S8): list licenses and pins first.
- Done when: both spikes have a written result and a test (passing, or a recorded known issue with the reason), E3 sub-milestones are in the board.

**T4. Filler if time remains (each 1-2 hours, independent):**
- Stored benchmark baselines (PRF-1): `Benchmarks/baseline-*.json` plus `scripts/bench.sh` that fails on a regression over 10%.
- Truncation hint: compare the Matroska Segment size from the header with the file length to flag a cut-off download and avoid showing the header duration as the real one (only if it stays small).
- A libFuzzer harness on the demux wrapper (`-sanitize=fuzzer`) with the fixtures as seed corpus.

**Owner side (nothing here blocks tomorrow):**
- Real files in `TestMedia/` (gitignored): one HDR10 clip (30-60 s), two or three big real MKVs (H.264 or HEVC, ASS subtitles, several audio tracks; anime source if possible). I run the benchmarks and the PQ-over-HLS check on them.
- To measure on hardware (RMX-6, ANM-6, AirPlay E-S4, HDR10 on a phone) a small device harness app is needed. Choose how to build it: XcodeGen (needs your OK to install it; PlayerApp M0 plans it anyway), a hand-made Xcode project, or a Swift Playgrounds-style app package. I would add it right after T2 once you answer; one hour with Mac, iPhone and Apple TV or HomePod on the same Wi-Fi then covers the AirPlay spike.
- Decisions still open: D-E11 (packaging of optional codec profiles, due in E4), the PlayerApp decisions D-1..D-12, Apple Developer Program enrolment, legal review of the codec modules and the EULA.

### Up next after tomorrow (ordered)
1. E3.1 leftovers (needs real files): WebVTT block additions, forced/SDH flags on real MKVs, SSA v4 layouts
2. E4.2 software player (decode, render, A/V sync, `PlaybackController`, `MediaVideoView`), E4.3 AV1 (dav1d) and VP8/VP9 fixtures, E4.4 deinterlacing and pulldown
3. AirPlay spike E-S4 on real devices (RMX-10); HDR10/PQ over HLS (RMX-1, RMX-11) with a real clip; device harness (owner decision pending)
4. Ordered chapters whose parts have different codec configuration (`EXT-X-DISCONTINUITY` + new `EXT-X-MAP` per part; needs real files)
5. Variable-frame-rate and deep-pyramid real files (RMX-12)

### Backlog (owner requests, newest last)
- 2026-10-24 Prepare tasks for tomorrow: done, see "Plan for 2026-10-25" above.
- 2026-10-26 **Owner's work order** (also in the project memory). (1) Optimise the test runs and tooling so checks are fast and reliable; commit that myself as soon as it is done. (2) Then finish everything left in the engine, one part at a time, reporting after each part without asking to commit and waiting for "continue": **E4** (own decoders for royalty-free/expired codecs, AV1 software decoding with dav1d, deinterlacing and pulldown ANM-7, legacy containers AVI/Xvid, OGM, RMVB, FLV ANM-8, software renderer and shared `PlaybackController` API-6/API-7, packaging decision for optional codec modules D-E11); **E5/E6** (tested procedure for swapping the FFmpeg framework LIC-2, source pack and `BUILD-INFO` LIC-3, notices at runtime LIC-4, patent profile document LIC-6, five-line quick start on all three platforms API-1, licence of the Swift layer LIC-7); **fillers** (stored benchmark baselines PRF-1, truncated-download hint, libFuzzer harness, libunibreak, overlay split into bands if 4K shows it is slow, ordered-chapter parts with other video settings, the ASan play-list flake if it returns). (3) Only when the engine is completely finished (confirmed by the owner on 2026-10-26: the whole list first), start the app **in a separate git project** (its own repository in `~/Documents/Development/PlayerApp`, not a branch of this one; this supersedes the earlier "separate remote branch" wording; the owner asked for the repository to be created at that point, which is the one allowed exception to "work only inside the MediaEngine folder"). Ask for the GitHub repository when it is time to add a remote.

- 2026-11-06 (the app's owner) **"When we use a server-side movie, it could ignore some subtitles and some others that are presented could apply with a delay. Fix it."** Status: built (see Right now), committed 2026-11-06.

- 2026-11-07 (the app's owner) **"A 19.1 GB movie on a shared folder loads for about 2 minutes; load step by step like streaming services."** Status: suggestions given; then the owner said "fix it" and "commit after you're done": **built and committed 2026-11-07** (RESEARCH section 28). Engine findings from the code: a Matroska file without Cues is read to its end by FFmpeg's seek when `PacketReader.keyframeIndex` seeks to the end to load the index (FFmpeg 9.0.2 `matroskadec.c` 4518 to 4527), and `RemuxSession.scan` reads the whole file when the keyframe list looks incomplete or the duration is missing; `HTTPByteSource` fetches 512 KB at a time with one chunk read ahead. Not measured.

- 2026-11-08 (the app's owner) **"One movie played sound but no picture; the next stuck after a jump to a part and no other part played; the third took one jump and stuck on the next; the fourth jumped easily. All over SMB. Check the logs, find what is missing, the best solutions and what could be added."** Status: causes found in the log and fixed in the engine (RESEARCH section 30), compiled only, not committed. Further steps named there: stop asked-for builds the player abandoned (loopback server sees the closed connection), an interpolation seek for transport streams, several SMB requests in flight.

- 2026-11-11 (the app's owner) **"Subtitles of a movie from the server don't apply immediately. It works immediately for Audio, but not for
  Subtitles: they apply with a strange delay, as if they are downloaded each time I apply them."** Status: cause found and fixed (see Done,
  2026-11-11), compiled, not committed, not tried on the share.

- 2026-11-12 (the app's owner) **"From now on we ignore the DTS and anime format restriction"**, then **"only DTS, not their new DTS-HD or
  DTS:X"**. Decided in the chat: the DTS core only (DTS-HD and DTS:X tracks play their core), H.264 Hi10P in, both free in the app, the
  DTS-HD code removed from the binary (RESEARCH 3.2 point 6, decisions log). Status: **recorded, nothing built.** Engine part of the plan:
  opt-in profiles for the DTS core and for H.264 (never `core`), a patch in `third_party/patches` that leaves out XLL, LBR and the
  extension substream and forces core-only decoding, `availableProfiles` detection, the planner (DTS to ALAC, the H.264 profiles Apple
  does not decode to the software path), `SecurityTests.noPooledDecoders` and the planner tests updated, the patent profile document and
  acknowledgements regenerated, the source pack with the patch, then the rebuild (`build-all.sh`, heavy: only when the owner says it is a
  good moment). Waits for the owner's go. Then (owner) "do it one by one without a question": **built 2026-11-12, see Done.**
  Then (owner) "investigate where this patent works; if it is US only, block DTS there until it expires; the same for Hi10P":
  findings in RESEARCH 3.2 point 7; built `MediaEngine.disabledProfiles` (the app blocks DTS in the US App Store until 2027-02-07);
  H.264 is not US-only (pool patents in about 100 countries), the owner decides.

- 2026-11-12 (the app's owner) **"H.264, HEVC, AAC, AC-3, E-AC-3, Dolby Vision should be included 100%. Make it Apple first and then
  with a fallback to ours. Review existing restrictions that you applied because of old data."** Plan: the app's
  `docs/APPLE_FIRST_PLAN.md`; review: RESEARCH 3.2 point 8. Status: **built, committed without compiling** (the owner's word), see
  Done 2026-11-12 (Apple first).

- 2026-11-17 (the app's owner) **"Lost in Translation don't run, why? We should have a possibility to play it"**, then
  **"Yes, switch it on"** (VC-1, as for DTS: risk accepted, not a legal clearance). Plan: an opt-in profile `vc1Software` in
  `extended-plus`, FFmpeg rebuilt, the film played muted from the share. Status: see Done 2026-11-17 (VC-1).

- 2026-11-17 (the app's owner) **"Exclude visionOS completely from this release … I don't want anything to be built for it right now
  (just create a separate branch that will hold changes related to it but do not update it until I tell you to). We will continue to
  work in main branch on iOS, iPadOS and macOS."** Status: see Done 2026-11-17 (visionOS out).

- 2026-11-19 (the app's owner, testing on the iPad) **Lost in Translation: "laggy, and subtitles stuck and were present on every movie
  fragment after each switch; they disappeared only when I moved progress to the starting position."** Status: the subtitles fixed (see
  Done 2026-11-19); the lag not addressed (the app's `docs/PLAN_2026-11-18.md` section 2 is the plan; the owner decides).

- 2026-11-19 (the app's owner) **"Do shared read cache, then EGA-121, EGA-120"** (then the app's tickets, one by one, a commit each).
  The read cache: one film's readers (the software player's picture reader, the remuxer's sound, picture-subtitle readers) share what
  was read from a network source, so the film is read once (the app's `docs/PLAN_2026-11-18.md` section 2). Status: the read cache
  done (Done 2026-11-19, Jira EGA-125); EGA-121 and EGA-120 done (Done 2026-11-19); the rest is app work.

- 2026-10-26 **v1 scope rule** (owner): "cover everything; if something requires too much effort for our case, ignore it, we need to release v1". Applied from E4.2 on: the remaining engine list runs without stopping between parts (the owner commits when they like); anything judged too costly for v1 is not built and is listed under "Deferred after v1" below with the reason.

### Deferred after v1 (decided while working; revisit after the release)
Decided while finishing the engine (2026-10-26), each judged too costly for version 1 or impossible without devices, a lawyer or another
toolchain; none blocks the release.
- **Software path:** VideoToolbox hardware decoding (MPEG-2/4 are cheap on the CPU; VP9 hardware only on some chips); Picture in Picture and
  AirPlay of the software player (`AVPictureInPictureController` sample-buffer content source, `[device]`); a play list (ordered chapters)
  in the software player; the 4:2:2/4:4:4 10-bit buffer formats and HDR pictures on a real display (made and tested, not looked at); RGB-coded
  VP9/AV1; 12-bit sources are shown with 10 bits.
- **Pictures:** inverse telecine of hard-telecined film, double-rate (bob) and motion-compensated deinterlacing; the deinterlacer is untested on
  real broadcast files and unmeasured on a phone (5 ms per 1080 picture on an M1 Max).
- **Audio:** Windows Media Audio and RealAudio (frames reach across packets; the segment-by-segment conversion needs another alignment); their
  decoders are left out, such files report an unavailable audio track.
- **Codecs not built:** VC-1/WMV3 (legal), DTS/TrueHD (`licensedAudio`, legal), Dolby Vision profile 7 conversion (libdovi, Rust Tier 3 on
  visionOS, E-S7), a software H.264 decoder (Hi10P is out of scope). RealVideo 3/4 and VP6 are compiled in but have no test file (the host
  encoders for them do not exist).
- **Remux path:** ordered-chapter parts whose video settings differ (`EXT-X-DISCONTINUITY` with a new `EXT-X-MAP` per part; needs real files);
  variable-frame-rate and deep-pyramid real files (RMX-12); HDR10 over HLS with a real clip; WebVTT block additions and forced/SDH flags on real
  files (E3.1 leftovers).
- **Tooling:** a libFuzzer harness (Xcode's toolchain has no libFuzzer runtime; the 756 mutated files per run remain), libass overlay bands
  (measured: the heaviest effects scene renders in 2 to 5 ms at 1080p and 4K, no need), the ASan flake in `PlayListPlaybackTests` (not seen again in 5
  runs; the failure message now carries the player's reason).
- **Release process (owner, lawyer, Apple account):** EULA (LIC-5), licence decision D-E1 (LIC-7), lawyer review of `docs/PATENT_PROFILES.md`
  (LIC-6), code signing and App Store validation of an app that embeds the frameworks (BLD-4), dSYM archive per release (BLD-8), delivery
  channel rehearsal (E-S5, DST-1 to DST-5), support terms (DOC-4, PRF-6), the first `diagnose-api-breaking-changes` run (API-9), AirPlay and
  Picture in Picture on devices (E-S4, RMX-10, SWD-2), phone performance (RMX-6, SWD-3, E-S6), visionOS on a headset (PLT-3).

### Done (newest first; date, what, evidence)
- 2026-11-25 **The local server listens again after the system took its socket** (the app's owner: "after about 30 minutes in the
  background a film won't continue until it is restarted"). iOS may take the listening sockets of an app that stays suspended (Apple's
  TN2277, "Networking and Multitasking"); AVPlayer then reaches nothing at the item's address. `LoopbackServer` now watches its listener
  after the start: one that fails or is cancelled by anyone but `stop()` is made again on the same port (at most three times a minute,
  logged in category `player`), so the item's address stays valid; `revive()` does the same on request, and the public
  `PlaybackSession.reconnect()` lets the app ask for it when it comes back (`false` when it could not: the app sets the film up again).
  **Evidence:** `LoopbackServerTests.listensAgain` (the listener taken away under the server: listening again by itself, the same address
  answers; `revive()` when listening; a stopped server is not brought back) with the server and session suites (7 + 21 tests, the three
  known issues as before); exported (`extended-plus`). **Not checked:** on an iPhone after a real suspension (the simulator does not take
  sockets); whether iOS reports the loss to `NWListener` as a failure or a cancellation (both are handled) is believed, not seen.
- 2026-11-23 **Sound through the processor changes without a new session** (the app's owner: "the equalizer always freezes sound and
  image when I change it… change the audio wave without this freeze and never affect the image"). Cause: a processor was fixed for a
  session (the original tracks were converted through it), so the app made a new session for every change. Now `RemuxSession` serves
  each sound track the processor reaches twice more (`addCopies`, ids from 1,000,000; `soundCopySlots` 2), through it, as ALAC, beside the
  original as the file has it (the original no longer goes through the processor). The copies are in the master playlist with
  `AUTOSELECT=NO` (`HLSPlaylists.AudioRendition.autoselect`, `soundCopyName`); the default track's copy is the default rendition when
  the sound goes through the processor from the start (`setDefaultCopySlot`). A copy's fragments are converted from the packets kept for
  its track (`pendingKey`; tracks with copies keep their packets even when the original is passed through; their warm-up counts in
  `prerollWindows`); `forgetCopies(slot:)` drops a slot's fragments on the build queue. Public: `PlaybackSession.processesSound`,
  `applySoundProcessing(_:on:)` (the next slot forgotten and selected: AVPlayer switches the sound rendition, the picture goes on),
  `select(_:on:)` choosing the copy while processing, `selectedChoice(of:on:)` mapping a copy to its track, and
  `PlaybackController.applySoundProcessing(_:)` (AVPlayer path: its item; the engine's own player: its sound item, which rejoins the
  picture as after a switch of track). **Evidence:** `SoundProcessorTests.copies` (two copies per reached track, `AUTOSELECT=NO`; the
  original as the file has it; a gain changed and its slot forgotten: the copy built afresh has it, the other slot keeps its own until
  forgotten; the default copy in the master) and `SoundProcessorPlaybackTests` (`plays`: the copy plays from the start; `switchesLive`:
  on, a change and off while AVPlayer plays fixture-subs-long, the item's time keeps moving and no error) with the remux, conversion,
  track selection, added sound, jump and AVPlayer end-to-end suites (77 + 6 tests, the 3 known issues as before); exported
  (`extended-plus`). **Not checked:** by ear; how long the sound pauses at a switch on a device or over a network (believed: about one
  piece's fetch).
- 2026-11-20 **Speech from 5.1 sound** (the app's owner: "if 5.1 is fixable, fix it"). The speech extractor's AudioToolbox path (AAC,
  AC-3, E-AC-3) made its compressed format without a channel layout, which AVFoundation refuses for more than two channels ("this sound
  has no usable format"), and converted to stereo, which drops the centre channel where films keep their dialogue. Now 5.1 and 7.1 get
  a layout (`SystemDecoder.layoutTag`), every channel is decoded and mixed to mono at 1/√n each. New fixture `fixture-speech-51.mkv`
  (`make-fixtures.sh`: the speech sentence as 5.1 AC-3, the voice in the centre only; 663 KB). **Evidence:** `SpeechAudioTests.decodes`
  with it failed before ("no usable format") and passes now (mono 16 kHz, the right length, not silent), with the suite's other tests.
- 2026-11-20 **A jump prepared while the finger rests on the progress bar** (the app's Jira EGA-124). Public:
  `PlaybackSession.prepareJump(to:)`. `RemuxSession.prepare(at:)` builds the piece that holds the time on its own serial queue with its
  own reader (no other reading of the file, no other connection), so the player's request after the release finds it built: one place
  at a time, a newer call stopping an older build within 16 packets (`buildWindow(…superseded:)`), a read-ahead of the place being played
  giving way to it (it would hold up the queue for seconds over a network), the player's request for a piece that is not built stopping
  it; the prepared piece is kept in the fragment cache until the player asks for it or another place is prepared
  (`FragmentCache.held`), and its sound converted for the track the player asked for last (`lastSoundAsked`). Nothing is read for a
  piece built already. For a file the system plays itself there is no remuxer and nothing happens; for the engine's own player it
  prepares the sound (the picture reader starts where it jumps; the still's read of the keyframe warms the shared cache there).
  **Evidence:** `JumpPreparationTests` (a prepared piece is built before the request, which then builds nothing; with reads slowed
  once the session is open, a newer place stops the older build and only the newer piece is built) with the remux, AVPlayer
  end-to-end, segment plan, shared read cache, software player and preview suites. **Not measured:** a jump after resting against a
  tapped jump on a film over the server (the share was not mounted on 2026-11-20).
- 2026-11-20 **Converted sound three times faster where it was lossy anyway** (the app's Jira EGA-123). **The ticket's cause was not
  the cause:** it blamed the converter's sample buffers (each encoded frame removed from their front), but `encodeFrames` runs after
  every packet, so a buffer never holds more than one ALAC frame and a packet; a stack sample of 5.1 DTS being converted (temporary probe,
  debug build, normal priority, M1 Max: 60 s of six-channel tones with noise made with the host `dca` encoder in `build/`, removed) put
  four fifths of the time in FFmpeg's ALAC encoder (`write_element`, `encode_scalar`, `lpc_compute_autocorr_c`), a sixth in the DTS
  decoder, the buffer copies at 1.5 % and the engine's own code under 3 %. Measured per 10 s piece: ALAC level 2 (FFmpeg's default) 125 ms
  and 6.7 MB, level 1 116 ms and 6.9 MB, level 0 (samples stored as they are, still lossless) 39 ms and 8.4 MB. Now
  `AudioTranscoder.compressionLevel(codec:channels:sampleRate:bitDepth:)`: level 0 for sound that was lossy to begin with (DTS, AC-3,
  E-AC-3, AAC, Opus, Vorbis, MP2, MP3) up to 1 MiB a second (the encoder writes a sample deeper than 16 bits with 24: 5.1 at 48 kHz is
  864 KB), level 2 for the rest (lossless sources, E-AC-3 7.1). The same piece: **42 ms** (was 125). Bigger sound pieces: the sound
  cache (24 MB) holds fewer, and one that leaves it is converted again from the kept packets in about 40 ms. "Convert only the chosen
  track" held already: a read-ahead converts only the track the player asked for, the others stay as packets until asked. Every
  conversion is logged now (category `index`, info; notice above 300 ms): "Sound of piece N, track T: S s converted in M ms".
  **Evidence:** `AudioTranscodeTests` (new: `compressionLevels`, `dtsStored`: the fixture's DTS converted at level 0 decodes to the same
  samples as the DTS itself within one 16-bit step; Opus and Vorbis warm-up and FLAC bit-exact unchanged) with the external audio (Apple's
  decoder reads converted Opus), AVPlayer end-to-end, sound processor, remux, legacy audio and software player suites: 73 tests one suite
  after another, all passing except the known `ExternalAudioTests.refusing` (it still expects DTS refused). **Not measured:** Lawrence of
  Arabia and Brazil from the share (not mounted on 2026-11-20), an iPhone.
- 2026-11-20 **A still of the place a jump goes to** (the app's Jira EGA-122). Public: `PlaybackSession.previewPicture(at:)` returns a
  `PreviewPicture` (a `CGImage` in the stream's own pixels, at most 1920 on its longest side, and its time), `preparePreviews()` opens its
  reader in the background. `PreviewMaker` (internal): one `PacketReader` of its own, kept for the session (later jumps only seek), on a
  serial queue; a newer call or a cancelled task makes the older one give up between packets; reads go through the session's source, so a
  network film's shared read cache serves them. The keyframe: the first one met in files whose seeks land on the keyframe at or before the
  time (Matroska, MP4); in MPEG transport and program streams (and DVD titles), which seek by decode time, the last one at or before the time
  within a second of it, and when the seek landed past it (found on `fixture-ts`: a second jump found nothing) once more from three
  seconds earlier; otherwise the first after the time within two seconds; at most 3000 packets or 24 MB. Decoded by VideoToolbox for H.264
  and HEVC straight to scaled BGRA (`AppleDecoding.formatDescription`, now shared with the "does Apple decode it" check: from `avcC`/`hvcC`,
  or from Annex B parameter sets with four-byte lengths as `PacketReader` hands them out), else by the build's own decoder (flushed, one
  packet, drained) and a pixel transfer to BGRA; `VTCreateCGImageFromCVPixelBuffer`. Not for play lists of several files. One log line per
  still (category `player`, info). **Evidence:** `PreviewPictureTests` 7 (Matroska H.264, HEVC and B-frames: the keyframe at or before each
  of nine times, 640 × 360, not flat; MPEG-TS twice (Annex B parameter sets); MPEG-2 through the build's decoder; a network-like source
  through the shared cache reads less than the file; prepared in advance; nothing after close; sizes); measured in those tests at
  background priority beside other tests: the first still of a session 150 to 180 ms (opening its reader), later ones 10 to 50 ms, 1 to 3
  packets read (26 and 73 in the transport stream); the core variant builds without warnings; exported. **Not measured:** a film on the
  share (not mounted on 2026-11-20), an iPhone or iPad. **Found, older:** `PlaybackPlannerTests.hevcRext` and `audioFallback` (written
  2026-11-12, never run until now) fail because the tests' `everything` capabilities lack `.hevcSoftware` and `.audioFallback`; the planner
  itself is as intended. Not changed here.
- 2026-11-20 **Enhanced Quality: Apple's super-resolution scaler in the engine's own player** (the app's Jira EGA-108).
  `PictureEnhancer` (internal): VideoToolbox's `VTFrameProcessor` with `VTLowLatencySuperResolutionScalerConfiguration` at the largest
  factor up to 2, a pool of output buffers, attachments carried over (`CVBufferPropagateAttachments`), a picture it cannot take shown as
  it is (logged); `SoftwareVideoPipeline.setEnhancing`, `Statistics.enhanced`; public `SoftwareController.enhancesPicture`,
  `canEnhancePicture`, `Statistics.enhancedFrames`. Measured first (the app's RESEARCH 17): 1.4 to 3.3 ms a picture on the M1 Max;
  8-bit 4:2:0 only, both sides multiples of 16 (640 × 360 fails every picture with -19730 although the scaler offers factors for it:
  found by trying, now part of `PictureEnhancer.scale`); the temporal noise filter is not supported on that Mac. **Evidence:**
  `PictureEnhancerTests` (320 × 240 comes back 2× with its attachments; BGRA and 640 × 360 refused; 4K has no factor) and
  `SoftwarePipelineTests.enhanced` (every picture of `fixture-interlaced-tff` shown through the scaler, played to its end) with the
  software player suites; exported. Not looked at by eye; no iPhone or iPad. The iOS Simulator SDK leaves the frame processors out
  (`#if ! TARGET_OS_SIMULATOR`): there `PictureEnhancer` offers nothing (fixed in a second commit after the first broke the simulator build).
- 2026-11-20 **`PlaybackController.allowedAudioSpatialization`** (the app's Jira EGA-106): which sound the system may render as spatial
  audio, set on the item that plays the sound: `AVPlayerController` forwards to its item, `SoftwareController` to its sound item (the
  picture has no sound of its own). Looked up in the iOS 27 SDK: on iPhone, iPad and Mac an app chooses only this
  (`AVPlayerItem.allowedAudioSpatializationFormats`); fixed or head-tracked (`AVAudioSession.setIntendedSpatialExperience`) is
  `API_UNAVAILABLE(ios, macos)`, visionOS only. **Evidence:** `SpatializationTests` (fixture-basic through AVPlayer, fixture-mpeg2
  through the engine's own player: none, then multichannel, read back from the item) and `VideoLayerTests`; exported. Not heard: needs
  AirPods.
- 2026-11-19 **A sound processor for the served sound: the equalizer for Matroska** (the app's Jira EGA-100). Public: `SoundProcessor`
  (`makeStage(sampleRate:channels:)`), `SoundStage` (`process(_:frames:)`, planar float in place), `PlaybackSession.soundProcessor` (set
  before the first item or controller; the remuxer is built with it) and `soundProcessorReaches(_:)`. With a processor, `RemuxSession`
  converts to ALAC every audio output it reaches (`SoundProcessing.route`): tracks converted anyway (the processor between the decoder and
  the encoder), AAC-LC with 1, 2 or 6 channels decoded by AudioToolbox (`SystemAACDecoder` in `AudioTranscoder`), AC-3 and E-AC-3 by the
  build's own decoders (`audioFallback`); each piece gets a fresh stage and at least 0.2 s of warm-up (`SoundProcessing.warmUp`, run
  through the stage and thrown away). **Measured before choosing** (temporary program in `build/eqprobe`, removed): AudioToolbox decodes
  AAC in step with its packets (97 packets: 97 × 1024 samples, first sound where FFmpeg's decoder has it) and gives 5.1 as L R C LFE Ls Rs
  (FFmpeg's order) whatever layout the input format names (a compressed format of more than two channels needs one to exist); for AC-3
  and E-AC-3 it trims 256 samples at the start and gives 288 fewer at the end even after a flush, so pieces decoded one at a time would
  leave a gap at every join: those go to FFmpeg's decoders (their patents are marked expired in `profiles/audioFallback.json`), not
  Apple's: an exception to Apple first, only while a processor is set. HE-AAC (delay not measured), MP3 and AAC with more than six
  channels are not reached (they play as they are). Also found: the speech extractor's `SystemDecoder` makes its compressed format
  without a layout, which AVFoundation refuses for more than two channels: 5.1 AAC and AC-3 cannot be made into subtitles that way
  (not changed here). **Evidence:** `SoundProcessorTests` 3 (AAC pieces with their warm-up join into the whole within one 16-bit step, one
  millisecond apart at most as Matroska's times are; a gain of one half halves the FLAC samples, the warm-up adds no samples but runs
  through the stage; which tracks are reached) and `SoundProcessorPlaybackTests` 1 (AVPlayer plays fixture-basic with its AAC served
  through a processor; in the playback pass), the converter and session suites (30); core and `extended-plus` build without warnings;
  `check-public-api.sh` passes; exported. **Not run:** DocC check, the whole verify. **Found, older:**
  `ExternalAudioTests.refusing` fails on `extended-plus`: it expects `fixture-licensed-audio` (DTS and TrueHD) refused, and the DTS core
  plays since 2026-11-12.
- 2026-11-19 **`SoftwareController.setPictureSuspended(_:)`** (the app's Jira EGA-112): the picture is neither decoded nor drawn, the
  sound and the clock go on, a jump moves only the sound and the clock; turned off, the picture starts again where the clock stands
  (`pipeline.start(at:)`). For a host that keeps the sound playing off screen: the picture layer the system stops in the background
  otherwise ended the picture for good (the pipeline stops on a failed renderer). **Evidence:** `SoftwareControllerPlaybackTests.
  pictureSuspended` (the clock goes on, nothing decoded while suspended, pictures again after) and the suite (11, with
  `MEDIAENGINE_TEST_PATIENCE=4` at background priority: without it the speed checks of three other tests fail at that priority, as
  the handoff notes say). Exported.
- 2026-11-19 **`ByteSource.notePlaying()`** (the app's Jira EGA-120): called again and again while a film plays, never while paused
  (`AVPlayerController.refresh` when the rate is not 0, `SoftwareController.tick` while playing, through `PlaybackSession.notePlaying`
  and the shared read cache); the default does nothing. The app's SMB source keeps its connection while the calls come. **Evidence:**
  `SharedReadCacheTests.playingIsNoted` (a film from a network source: notes while it plays, none once paused) and the cache and
  software player suites (19). Exported.
- 2026-11-19 **Blu-ray keyframes from the clip file** (the app's Jira EGA-121). `DiscInfo.entryPoints(blurayClipInfo:)` reads a clip
  information file's entry-point map (layout as libbluray reads it, recalled, then checked: below); `DiscInfo.Facts` (languages and
  entry points), `DiscInfo.facts(blurayClipInfo:)`, `facts(forStream:read:)`; `PlaybackSession(url:disc:)` and `(source:disc:)` (the
  `trackLanguages:` ones stay). The session checks the map at eight entries spread over the film, one 192-byte packet each read straight
  from the source (`DiscInfo.agrees`: a PES start of the video PID whose time, rounded down to 512 ticks, is the entry's), and only then
  keeps it for the file (`KeyframeIndexStore.rememberEntryPoints`, memory only); every `PacketReader` of that file adopts it into
  FFmpeg's index (times never before the file's start, 33-bit wrap) and jumps by byte straight to the keyframe at or before the time;
  the remuxer then finds a complete index and cuts its pieces at the real keyframes instead of a time grid. **Evidence:** the layout
  checked with a scratch script on six Blu-ray folders of the owner's share: on five, 80 of 80 entries looked at (45 of 45 on short
  clips) start a picture of PID 0x1011 whose time rounded down to 512 ticks is the entry's (the map keeps only the time's upper bits);
  on the sixth (a re-released Wizard of Oz) the map no longer fits its stream after entry 10, which is why the check exists.
  `BlurayEntryPointTests` 4 (round trip of a written map with grouped coarse entries and a 33-bit time; a stream made from `fixture-ts`
  with its own map: adopted, three keyframes in the reader's index at their offsets, a jump lands on the keyframe at or before the time;
  a map one packet off is left out; the packet check) and the disc, probe, keyframe and read cache suites (34). From the share through the
  engine (temporary program, muted, debug build): Labyrinth "Disc: 7954 keyframes from the clip file, checked at 8 of them", "Index: 7956
  keyframes from the file … 0 gaps over a minute", pieces at real keyframes (without the clip file: "No complete index … time grid");
  the Wizard of Oz "do not fit the stream (entry 917): not used", then plays as before. **Not faster jumps by themselves:** the jumps took
  2.6 to 4.6 s with the map and 2.9 to 4.1 s without, almost all of it the first piece after the jump (25 MB of a part never read, at the
  router's speed through the mount; the pieces were 5.9 s long because the link was measured from macOS's cache). Exported; the app
  passes the facts and built for the Mac and the iOS simulator.
- 2026-11-19 **A network film is read once for all of its readers** (the app's owner: "Do shared read cache"; the app's
  `docs/PLAN_2026-11-18.md` section 2). `SharedReadCache` (internal, `IO/`): `PlaybackSession` puts it between a network source (not a
  `FileByteSource` or `DataByteSource`) and everything that reads it, the probe included; each FFmpeg opening (`AVIOBridge`) is a reader
  (`register`, `unregister`, its last read's end is its place); chunks of 1 MB, 96 MB while two or more readers read in the last 20 s, 16 MB
  otherwise; what every active reader is past goes first, then the least recently used; one fetch per chunk however many readers miss it;
  `readSparse` goes straight to the source; `close` frees it. A DVD title behind the cache is still found
  (`SharedReadCache.underlying`, three places). The sound must not run further ahead than the cache holds: `RemuxSession.soundLead`
  (the shared room's three quarters as time at the film's byte rate, less one piece, 6 to 30 s) limits the read-ahead and the sound
  item's forward buffer (`min(soundForwardBuffer, soundLead)`); the first measurement showed why: with only the read-ahead capped,
  AVPlayer's own 20 s buffer kept the sound about 137 MB ahead and the picture reader still fetched everything again (10.9 MB/s asked).
  **Evidence:** `SharedReadCacheTests` 8 (two readers 3 MB apart fetch every byte once in 4 MB, where plain LRU would need 6; one reader
  keeps little; a stale or gone reader holds nothing back; concurrent misses fetch once; chunk ends, end of file, sparse reads; the
  sound's lead; the session wraps a network source and not a file; the software player reads a network film once: under 1.15 times the
  file, against 3.3 times with the cache switched off (2,487,472 bytes for 748,620)), the segment plan and byte source suites (28 on
  core), the hardening, probe, session, subtitle renderer, picture subtitle, disc and external audio suites (89, 3 known issues), the
  software player suite on `extended-plus` (18 with the cache tests); **Lost in Translation from the share** (temporary program, muted,
  normal priority, debug build, a source like Eiga's server connection counting what it is asked, 60 s from 72 min, a part not read
  before): **5.34 MB/s asked, 5.34 distinct, film 5.29 MB/s** (12.3 asked before today's work), the film moved 60.5 s without a stall,
  one sound join (the start after the jump). Exported; the app built for the Mac and the iOS simulator. **Not checked:** Eiga's own SMB
  client, the iPad and iPhone, a release build, by ear. The app's Jira EGA-125 (in Testing).
- 2026-11-19 **The engine's own player no longer reads minutes ahead; the subtitle fix checked on the film** (the app's owner mounted
  the share: "add and use shared folder"). Measured with a temporary program (muted, normal priority, debug build, through a byte
  source like Eiga's server connection that counts every byte asked for; Lost in Translation `00010.m2ts`, 30.8 GB, 5.0 MB/s on
  average). **Read-ahead:** in 60 s of steady play the session asked for 28.1 MB/s, 18.0 MB/s of it distinct: the sound remux built
  pieces about four minutes ahead of the film, as its read-ahead counted from AVPlayer's requests and the sound-only AVPlayer buffers far
  ahead on its own, and every piece of sound means reading the whole transport stream around it. Now
  `RemuxSession.soundReadAheadEnd(after:segments:playhead:)` stops 30 s past the film's playhead (`notePlayhead`), and the sound item
  asks AVPlayer for 20 s (`preferredForwardBufferDuration`, `PlaybackSession.soundForwardBuffer`). Same stretch after: **12.3 MB/s
  asked, 5.6 MB/s distinct**, 24 pictures a second, none dropped. Left: the double read (picture reader and sound remux, ratio about
  2.2): over Eiga's SMB client without a system cache still above the owner's router's best (about 10 MB/s) — the shared read cache of
  the app's `docs/PLAN_2026-11-18.md` section 2. **Subtitles (Done below):** three jumps made while a line showed, 0 of 232 samples
  afterwards showed it; the lines seen after the jumps (none, 10, none) equal what the track holds there read straight from the file
  (none, 10, none). **Evidence:** `SegmentPlanTests.soundReadAhead` (new), the remux, keyframe, buffer and picture-subtitle suites
  (31 tests); exported; the app built for the iOS simulator and the Mac. **Not checked:** the iPad, Eiga's own SMB client, a release
  build. Track names read "Subtitles 4" to "7": the `.m2ts` was opened alone, without its folder's clip information.
- 2026-11-19 **A Blu-ray subtitle line no longer comes back after every jump** (the app's owner, testing on the iPad: Lost in
  Translation's subtitles "stuck and were present on every movie fragment after each switch; they disappeared only when I moved progress
  to the starting position"). Cause, read in FFmpeg 9.0.2's `pgssubdec.c` and reproduced with the fixture's own segments: the PGS
  decoder has no flush, so its last composition, palettes and pictures survive `avcodec_flush_buffers`; in a Blu-ray transport stream
  every segment is a block of its own, and a window after a jump begins in the middle of a display set, whose end segment then drew the
  composition remembered from before the jump at the new time (and, keyed by that time, kept the real subtitle there out). A jump to the
  start reads from the file's beginning, which begins cleanly. Also: a PGS line has no end of its own and lasted until the next display
  even when the clear that ended it lay in a stretch never read (a jump away from it). `BitmapBackend`: for PGS, after an end segment
  and after a break of more than 3 s (`setSpread`; the decoder is then opened afresh from a copy of the parameters), segments are passed
  over until a display set begins with its composition segment; a display's time is the decoder's (the composition's) instead of the
  block's; `OverlayBackend.render(at:size:loaded:)` gets the renderer's coverage, and a picture without an end is drawn only while the
  stretch from its start to now has been read. DVD and DVB are unchanged except for that last rule. **Evidence:**
  `BitmapSubtitleTests` (new: `jumpIntoTheMiddleOfADisplaySet` (with the first, incomplete attempt it failed exactly as the film did:
  the old picture at the new time), `openEndedOnlyOverWhatWasRead`, `segmentBySegment`) and the overlay, renderer, libass and golden
  suites pass (47 tests); exported (`extended-plus`); the app built for the iOS simulator and the Mac. **Not checked:** Lost in
  Translation itself (the share was not mounted), a device. **Not addressed:** the lag on the iPad (the app's `docs/PLAN_2026-11-18.md`
  section 2: the double read over Eiga's own SMB client, and VC-1 on one core).
- 2026-11-18 **`MediaEngine.cacheSize()` and `clearCache()`** (for the app's Settings > Storage, Jira EGA-113). What the engine keeps in
  `Caches/MediaEngine` (descriptions of files read over a network, `ProbeStore`; keyframe maps, `KeyframeIndexStore`) can now be measured
  and forgotten, in memory and on disk (`removeAll()` on both stores); files are probed and indexed again at their next opening.
  **Evidence:** `CacheTests` 2 (a kept keyframe map counted and forgotten; folder sizes) and `VideoLayerTests` pass; exported
  (extended-plus); the app built for macOS and the iOS simulator against it.
- 2026-11-18 **`AVPlayerController.videoLayer` is made on first use** (the app's review 2026-11-18, N1; the app's owner: "Fix N1
  first"). The app's queue test `PlayQueuePlaybackTests.plays` hung in a deadlock inside AVFoundation (sampled twice): the main
  thread, in AVPlayer's own rate-change callback, held `com.apple.avplayer.ivars` and waited for the CoreMedia player queue, while that
  queue told an `AVPlayerLayer` about a new presentation size (`_updateReadyForDisplay`, `_cachedPresentationSizeOfCurrentItem`) and
  the layer waited for `avplayer.ivars`. The only layer in that test was the one every `AVPlayerController` made in its init, which
  the app never shows (it draws AVPlayer films with its own layer on the Mac and `AVPlayerViewController` on iOS; `MediaVideoView` is
  the only user). It is now made the first time `videoLayer` is read (`MediaVideoLayerHost.layer(for:)`), so a controller nothing shows
  has no layer watching its player. **Evidence:** `VideoLayerTests` (new: no layer until asked, the same one after, on the controller's
  player) and `QuickStartTests` pass (3 tests); exported (`export-package.sh extended-plus`); in the app `PlayQueuePlaybackTests.plays`
  passed 5 of 5 runs (it hung in 3 of 3 on the code before today and 3 of 3 before this change), the whole queue suite (5),
  `PlaybackThroughAppTests` (3), `ControlsTests` (8) and `EndAndSystemMenuTests` (4) pass; the app built for macOS and the iOS
  simulator. **Not covered:** the app's own layers (Mac) and `AVPlayerViewController` (iOS) still watch the film that is shown, as
  they must; whether the same race can reach them on a device is not known (no test shows a view).
- 2026-11-17 (night, very last) **Pieces read once again; the sound kept around the playhead** (the app's owner: "it plays a few
  seconds and then is stuck", "loads the sound as if it never loaded before", "10 November was better"). `buildWindow` takes a converted
  track's pre-roll from the window before when it is in memory and otherwise reads from a keyframe at most 1 s earlier
  (`prerollReach`), instead of the keyframe before the pre-roll (a whole 10 s piece in Lawrence of Arabia, since DTS is converted);
  `RemuxSession.notePlayhead` (called by both controllers through `PlaybackSession.notePlayhead`) anchors the trimming of the stored
  sound; a conversion over 0.3 s is logged. RESEARCH 33. **Evidence** (temporary program, network-like source, muted): Lawrence's 10 s
  pieces in about 2 s (the owner's log: 2.5 to 5.2 s), no stall in steady playback, a switch and a jump play on; Lost in Translation
  without a stall in 40 s. Compiled. **Not run:** any test; not tried with Eiga's SMB client or on an iPhone. The temporary program's
  folder `build/vc1diag` is still there (a safety check refused its removal): delete it by hand.
- 2026-11-17 (night, last) **The engine's own player: sound read and converted 30 s ahead, every sound track kept in memory, the
  picture never waits for the sound, the sound joins the picture with a seek** (the app's owner: "fix and implement improves now").
  `RemuxSession`: `readAhead` builds and converts up to `soundLookahead` (30 s) for sessions without video (one piece with video),
  gives way to a request that only needs converting (`requestWaiting`); `pendingTranscodes` kept under `soundPacketBudget` (48 MB,
  `trimPendingTranscodes`), not dropped after conversion, cleared on `close`. `OverlayFeed.pictureHistory` 16 → 128 windows (within its
  24 MB). `SoftwareController`: no hold of the picture for the sound; small drifts the picture follows, larger ones and a stopped sound
  are joined by `joinSound` (pause, exact seek ahead of the picture, start on the host time; lead from the last seek's time); log lines
  "Sound joins the picture…" (category `player`). RESEARCH 32. **Evidence** (temporary program, muted, from the share, debug build):
  Lost in Translation, two sound switches: the picture 24 a second without a drop, the new track's pieces in 24 to 26 ms from memory,
  one join each, in step after; a jump of 3.9 s into a part never read; Labyrinth through AVPlayer: switches and a jump play on.
  **Left:** after a jump into a part never read, three or four sound drop-outs in the first 15 to 20 s (two readers on one link); an
  AVPlayer-path switch still stops the film about 0.8 s (AVPlayer's own). **Not run:** any test; not tried in the app, on an iPhone,
  with Eiga's SMB client, by ear. The temporary program's folder `build/vc1diag` is still there (git-ignored): its removal was refused
  by a safety check because the session had used it as a working folder; delete it by hand.
- 2026-11-17 (late night) **A new subtitle renderer's first frame counts as changed** (the app's owner: Lost in Translation's subtitles
  "stuck with the first title"). After a switch of subtitle track the new renderer's first empty frames said `changed = false`, so a
  host that redraws on `changed` (the app) kept the old track's line until the new track showed one. `SubtitleRenderer.frame(at:size:)`
  now reports its first frame as changed. Evidence (temporary program, muted, from the share): switches 4 → 5 → 7 at 10:00, no frame
  where the engine and an app redrawing on `changed` differ (before: the old line stayed 2 s and more). Engine compiled, exported.
  **Open from the same request** (owner: sound sticks and jumps, especially after a jump; switch sound without stopping the picture;
  keep every sound and subtitle track in memory while playing, cleared on close): the log shows the remux reads only one sound piece
  ahead (`RemuxSession.readAhead`, `number + 1`) and converts DTS only when AVPlayer asks (`fragment(for:)`), pieces take 1.1 to 2.6 s
  for 4.8 s (5 s right after a jump), and the raw packets of the other sound tracks are kept for 2 windows only (`pendingTranscodes`).
  Plan: read and convert several pieces ahead, keep the raw packets of every sound track (and the picture subtitles) under a memory
  budget for the session, never hold the picture for the sound. Not started.
- 2026-11-17 (night) **VC-1 plays in the software player; jumps in transport streams land near the target** (the app's owner: "Yes,
  fix it here", after the check below). `PixelBufferConverter`: 8-bit 4:2:0 chroma interleaved by vImage
  (`vImageConvert_PlanarToChunky8`), the other per-sample loops as `while` loops with masking shifts (a debug build ran the generic range
  iterator for every sample: 90 % of the feeding thread); `SoftwareVideoDecoder.receive(discardingBefore:lateBefore:)` passes over
  pictures that are already late before converting them (counted as dropped, `takeSkippedLate()`); `PacketReader.interpolatedSeek`
  closes in from both sides and lands 2 to 5 s before the target (it accepted a landing two minutes early); `SoftwareController` leaves
  the clocks alone while a jump is under way (`seeking`, `seekGeneration`; play, pause and speed during a jump are kept for its end);
  one log line per start or jump of the software player (category `player`: time to the first picture, the reader's jump, packets on
  the way). RESEARCH 31. **Evidence** (temporary program, muted, from the owner's share, normal priority, debug build, removed
  afterwards): Lost in Translation 24 pictures a second, none dropped (was 16 a second, 183 of 197 dropped); jumps to 62 % and 85 % in
  2.7 and 3.1 s, then 24 a second (were 34 to 68 s, then none shown); The Neverending Story (VC-1 in Matroska) 24 a second, jumps 2.1
  and 2.6 s; Labyrinth (H.264 through AVPlayer, the jump code shared) plays after jumps of 2.3 and 2.9 s. `swift build --build-tests`
  (145 s) without new warnings; the app built for macOS and the iOS simulator against the exported copy. **Not run:** any test (the
  10-bit and regridding paths of the converter changed: `ConformanceTests`, `SoftwarePipelineTests`, `InterlaceTests` cover them);
  not tried: a release build, an iPhone, the app itself, Eiga's own SMB client, by ear.
- 2026-11-17 (night) **visionOS out of this release; the app's engine with VC-1** (the app's owner, Backlog 2026-11-17). Removed on
  `main`: the two visionOS slices (`SLICES` in `scripts/lib/common.sh`, the slice tables of `package-xcframework.sh`,
  `package-subtitle-xcframework.sh`), `.visionOS` in `Package.swift` and both samples, the visionOS sample and simulator steps
  (`check-samples.sh`, `verify.sh --sims`), the runtime check in `bootstrap.sh`, `visionOS 27` in three `#available` checks
  (`SoftwareVideoPipeline`); docs (CLAUDE.md, README, CHANGELOG, INTEGRATION, REPLACING-FFMPEG, criteria BLD-1, BLD-4, API-1, PLT-1 to
  PLT-4, DOC-2, E-S7, the three skills). Branch `visionos` at `441dcf6` (local, not pushed) keeps the state before. **Evidence:**
  `package-xcframework.sh` for `extended-plus` (46 s, three slices); `MEDIAENGINE_VARIANTS=… check-licenses.sh` passed for macos, ios,
  ios-simulator; `export-package.sh extended-plus` (the copy's framework has "SMPTE VC-1" and "Windows Media Video 9", the manifest
  declares iOS and macOS only); `swift build --build-tests` (62 s), only the known linker warnings (core FFmpeg and LibASS built for
  27.0). The core, extended, address and LibASS frameworks still carry the visionOS slices of their last build (not rebuilt; they lose
  them at the next rebuild). No test run.
  **Lost in Translation** (`BDMV/STREAM/00010.m2ts` on the share, muted, a temporary program in `build/vc1diag`): opens (0.1 s, 2.5 s
  the first time), plan software, VC-1 Advanced 1920×1080 at 23.976, three DTS tracks to ALAC, four PGS tracks. **Does not play
  properly:** at normal priority (debug build) about 16 pictures a second are decoded, so after 14 shown pictures every one is late and
  dropped (183 of 197 in 12 s); after a jump to 40 % (0.7 s) no picture is decoded in the next 10 s. At background priority: about 2
  pictures a second, and the jump took 68 s (it decodes from the keyframe before the target). FFmpeg 9.0.2's VC-1 decoder has no
  threading (`vc1dec.c` 1403: `AV_CODEC_CAP_DR1 | AV_CODEC_CAP_DELAY`), so it decodes on one core. **Not known yet:** how much is the
  debug build (pixel conversion, deinterlacer) against FFmpeg itself (a release build was not measured), whether the pictures are
  interlaced (the host `ffprobe` has no VC-1 decoder), why nothing is decoded after a jump. Logs: `build/logs/vc1-diag-run*.log`.
- 2026-11-17 (evening) **VC-1 switched on** (the app's owner: "Lost in Translation don't run", then "Yes, switch it on"; risk
  accepted like the DTS core, not a legal clearance; RESEARCH 3.2 point 9). Apple has no VC-1 decoder (no VC-1 codec type in the SDK's
  `CMFormatDescription.h`), so it is always ours: `profiles/vc1Software.json` (FFmpeg `vc1`, `wmv3`, the `vc1` parser),
  `CodecProfile.vc1Software` (detected from the binary), the planner sends `vc1` and `wmv3` video to the software path (was
  `pendingLegalClearance`); the `extended-plus` variant gains it (`scripts/lib/common.sh`, `build-all.sh`, `write-build-info.sh`,
  `export-package.sh`, `gen-patent-profiles.py`; `docs/PATENT_PROFILES.md` regenerated, DocC and INTEGRATION updated);
  `PlaybackPlannerTests.legacyVideo` and `SecurityTests.noPooledDecoders` expect the new rule (written, not run). Evidence so far:
  `swift build` (core variant) passes; the FFmpeg rebuild of `extended-plus` was running when the owner said "commit": the macOS slice
  contains `ff_vc1_decoder` and `ff_wmv3_decoder` and no TrueHD (`nm`), its licence report lists both as accepted-risk. **Not yet:**
  the other slices and the package, `check-licenses.sh`, the film played. No test run.
- 2026-11-17 (late) **Blu-ray subtitles, jumps in transport streams, the VLC-style sound switch** (the app's owner: Labyrinth's
  subtitles do not change or show, its first opening did not start, every jump waits a second or two; "do as VLC: continue the
  video while the audio changes"). (1) `BitmapBackend.add` decodes a window's packets in file order: it sorted them by time, and in
  a transport stream each PGS segment is its own packet with its own time, so the composition came after the palette and wiped it
  ("Invalid palette id 0"); no Blu-ray subtitle was drawn. (2) `PacketReader.interpolatedSeek`: in MPEG transport and program
  streams without a known keyframe within 20 s before the time, a jump goes by byte position from the average byte rate (a guess 6 s
  early, checked and stepped back), and a seek for a stream that is not video searches the file's default stream: FFmpeg's search
  read packet after packet (a subtitle reader's jump in a 27 GB stream read for minutes). (3) `PacketReader(durationHint:)`: the
  session's length for readers opened quickly (they do not measure it), passed by the remuxer, the subtitle readers and the software
  player. (4) `SoftwareController.tick`: a sound player that stopped (after a sound switch) is brought back in at the picture's
  time while the picture goes on, as VLC does, instead of holding the picture. Evidence on the owner's share (temporary programs,
  removed): the subtitle reader's jump to 10:00 takes no measurable time; Labyrinth's Russian (2), English and English (2)
  subtitles draw (4, 4 and 16 lines between 9:50 and 11:20) and switch during playback; a jump played again after 1.4 s; in the
  owner's own run with the byte-position jump, pieces after jumps were built in 120 to 140 ms (were 1.7 to 5.2 s). Not checked:
  the VLC-style switch by ear; an iPhone; from the server.
- 2026-11-17 **DVD subtitles and track switching** (the app's owner, after trying part 3: "subtitles aren't seen", then "subtitles
  and audio don't change", then "switching audio during playback mutes until a jump"; the owner then: "it works correctly now").
  (1) A DVD title's subtitle streams are made from the information files before FFmpeg's first look
  (`FormatContext.prepareDVDSubtitles`, `DVDStructure.Title.subtitleStreams`, `pictureHeight`), with the disc's colours as the
  decoder's setup text (`DVDTitleLayout.subtitleSetup`, YCrCb to RGB): a program stream shows a subtitle stream only with its
  first subtitle. (2) `PacketReader` joins a DVD subtitle that spans several packets (FFmpeg's parser runs only in streams its
  demuxer made, and the later packets have no timestamp, so they were dropped). (3) The software player's sound-only master
  playlist names the audio group on its variant (`HLSPlaylists.master`): before, the first sound track went on playing whatever was
  chosen. (4) `SoftwareController.tick` starts the sound again when AVPlayer stopped by itself (it does not wait to minimise stalls,
  and after a switch it ran out of data and stayed silent). The remux logs when the player asks for a sound track's playlist.
  Checked with the owner's discs on the Mac (temporary programs, removed) and by the owner on the device. No unit test.
- 2026-11-17 **A DVD title plays as one film; the frozen DVD picture** (part 2 of EGA-117 with EGA-14; not committed).
  `DVDTitleByteSource` (public: a title's cells out of its title set's stream files, read as one file) and `DVDTitleLayout`
  (cells in that byte stream, seek points from the time map, a placement per cell). `PacketReader` switches to a DVD mode for
  such a source: packets go on the title's timeline (each cell's start from its navigation pack, `vobu_s_ptm`; a cell whose
  timestamps run on from the cell before keeps its offset, one that jumps starts where the one before ends; 33-bit timestamps
  unwrapped), seeks go by byte to the last time-map point at or before the time, the keyframe list is the time map, the file's
  own start is not taken off. The prober takes the title's length and chapters (on the title's timeline). Found on two real discs:
  timestamps run on across cells, and the cells' listed times drift from them (Häxan: +0.8 s by 14 min, +6 s at the end, so
  105.2 min instead of 105.1); time-map entry n is at (n+1) × the step (checked against the navigation packs).
  **The frozen picture** (the owner: "they play audio but the video is stuck"): at normal priority a VOB decoded 134 pictures in
  9 s and showed 12; a stack sample put 83 % of the picture thread in `Deinterlacer.clean`; a release build showed 266 of 269, so
  it is the unoptimised deinterlacer of a debug build (Xcode runs) falling behind and every late picture being dropped. Now: after
  a late picture the next 50 are converted without deinterlacing (`SoftwareVideoDecoder.skipDeinterlacing`), and pictures before a
  seek target are not converted at all (`receive(discardingBefore:)`). Evidence (temporary program, debug build, normal priority,
  the files on the mounted share read through `DVDTitleByteSource`, removed afterwards): Häxan 105.2 min, 22 chapters; Az ember
  tragédiája 159.4 min, 16 chapters; both play from 0 (142 to 175 of about 150 pictures shown in 6 s) and after jumps to 30 min,
  the last minute and back to 5 min (100 to 120 pictures in the next 4 s, the time where it was asked). **Not checked:** the sound
  across cell boundaries by ear, an iPhone, a server source; no unit test. Next: the app (part 3).
- 2026-11-17 **DVD structure reader, part 1 of a DVD title played as one film** (the app's owner chose "full film first": Jira
  EGA-117 with EGA-14). `DVDStructure` (public): from `VIDEO_TS.IFO` and each `VTS_xx_0.IFO`, the titles in the disc's order, each
  with its title set, length (sum of its cells), chapter starts (chapter table, then program map), cells in play order with their
  sector range in the title set's stream files read as one (angle 1 only), the subtitle palette (16 colours, YCrCb) and the time map
  (step and sectors, for jumps); `mainTitle` (the longest), `streamFileNames(titleSet:)`, `informationFileName(titleSet:)`. Layout
  from public descriptions of DVD-Video (the format book is licensed and was not read); every read bounds-checked. `swift build`
  without errors or warnings. **Checked against two real discs on the owner's share** (a temporary program, removed): every title's
  cells cover its title set's stream files exactly (Häxan's film: sectors 0 to 2,382,286 of 2,382,287 in `VTS_02_1` to `_5`; Az ember
  tragédiája: 0 to 3,539,680 of 3,539,681 in `VTS_01_1` to `_7`; titles that share a set split it without gap or overlap); the lengths
  agree with the time maps (Häxan 105.1 min = 1,578 entries of 4 s; Az ember 159.4 min = 1,912 of 5 s) and with what the engine
  measured on 2026-11-12 (Häxan's 4.5 min intro = 273 s); main titles: Häxan 105.1 min with 22 chapters (the owner saw 14 h),
  Az ember 159.4 min with 16; the extras: Häxan's 1968 version 76.6 min, an 8.2 min extra, Az ember 22.8, 2.2 and 0.2 min; palettes
  look like YCrCb (white `EB8080`, black `108080`). No test written or run. Next parts: a byte source that reads a title set's VOB files as one, and a packet reader that plays a title's cells on
  one timeline (length, start, jumps from the time map); then the app.
- 2026-11-12 (late) **DVD parts open** (the app's owner: Az ember tragédiája and Häxan do not run on iOS). Two causes, found by
  playing the owner's VOB files muted through the engine with a temporary diagnostic program (removed): (1) the later VOB files of a
  title (`VTS_01_5`, `VTS_01_6`) show their DVD subtitle streams only near the end of the file, which the quick reopening does not read
  (`ffprobe` with and without the duration estimate: 5 subtitle streams against none), the crash fixed by `hasStream` the same evening;
  (2) such a file starts with AC-3 packets that share a decode time, and `InitSegmentBuilder.build` handed them to FFmpeg's MP4 muxer,
  which refused them ("non monotonically increasing dts"), so the opening failed; the samples only describe the stream, so one whose
  decode time does not move forward is now left out. Evidence (macOS, the files read through a byte source that looks like a server's):
  all 11 VOB files of Az ember tragédiája start, play 8 s and jump to 600 s. Also fixed: the build error of the evening (a closure
  captured `self` before the session was set up). Not tested on an iPhone; no unit test.
- 2026-11-12 **DTS 5.1 with side surrounds opens; no crash on a stream the reopened file lacks** (the app's owner: Lawrence of Arabia
  and Brazil did not start, two crashes on an iPhone). (1) `AudioTranscoder.encoderLayout`: FFmpeg's ALAC encoder refuses "5.1(side)",
  the layout the DTS decoder reports, so every movie with such a track failed to open ("ALAC encoder failed to open: Invalid
  argument", seen by opening the owner's files with the engine); now the source layout when the encoder takes it, else the encoder's
  layout with the same number of channels (`avcodec_get_supported_config`), the resampler moving side to back. (2)
  `PacketSource.hasStream`: `RemuxSession.init` copied the parameters of an overlay stream the reopened file did not have (crash
  reports: a bad pointer in `avcodec_parameters_copy`, then a nil stream in `PacketReader.parameters`), as an MPEG program stream shows
  a stream only once read and the quick reopening skips the end of the file; now checked for overlay parameters, ASS headers, the
  served tracks after the start is read (an error instead of a crash), the renderer's fallback (one full reopening, then an error) and
  speech extraction. The app removed its DTS country rule the same evening (`MediaEngine.disabledProfiles` stays, unused). **Not
  compiled, not tested** (the owner's word); exported to `dist/package` for the app.
- 2026-11-12 **A source's connection closes with its session** (the app's owner: switching movies quickly left SMB connections
  open; not committed). `ByteSource.close()` (protocol requirement with a default that does nothing), called by
  `PlaybackSession.close()` for the source the session was made from (each session is made from its own source in the app) and by the
  new `AudioTrack.close()` (the app closes a movie's sound files with the movie). Before, `close()` only cancelled pending reads and an
  SMB source connected again at the next read. Compiled through the app's PlayerCore package (see the app's PROGRESS); no test run.
- 2026-11-12 **Apple first, the engine's decoders as the fallback; Dolby Vision 5 and 8 through Apple** (the app's owner, Backlog
  2026-11-12; committed without compiling at the owner's word). `Internal/AppleDecoding.swift` (a `VTDecompressionSession` for the
  stream's own `avcC`/`hvcC` outside H.264 66/77/88/100 and HEVC 1/2/3; AudioToolbox's decoder list; AAC Main/SSR/LTP not Apple's
  [believe]; `VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)`), `Codec.appleDecodes` (public, filled by the prober),
  planner: H.264 and HEVC pass through when Apple decodes, else `h264Software` / new `hevcSoftware` (HEVC profile 4) on the software
  path, else unsupported; AAC/AC-3/E-AC-3 pass through unless Apple cannot play them, then ALAC through new `audioFallback`; Dolby
  Vision 5 unsupported on a device without Dolby Vision (`DeviceCapabilities.dolbyVision`); the probe cache key gains the Dolby Vision
  flag and "apple1". Remux: `InitSegmentBuilder` keeps `dvcC`/`dvvC` (FFmpeg's unofficial strictness) for profiles 5 and 8 when the
  device decodes Dolby Vision, `dvh1` sample entry for 5; the master playlist declares `dvh1.05.LL`, or `SUPPLEMENTAL-CODECS`
  `dvh1.08.LL/db1p`/`db4h`, and `VIDEO-RANGE` from the base layer (Dolby Vision used to be declared SDR). `AudioTranscoder` pre-roll
  for dts, aac, ac3, eac3 (DTS was planned for conversion but `canTranscode` lacked it, so `TrackChoices` would have dropped DTS
  tracks). Profiles `hevcSoftware.json`, `audioFallback.json` (aac `accepted-risk`, ac3 and eac3 `expired`), MPEG-4 Part 2 status with
  two sources; the variant renamed `extended-plus` (core + extended + dtsCore + h264Software + hevcSoftware + audioFallback) in every
  script, the DocC article, INTEGRATION, PATENT_PROFILES (regenerated, `--check` passes). Tests written, not run:
  `PlaybackPlannerTests.hevcRext`, `hi10pThroughApple`, `audioFallback`, `dolbyVision`; `SecurityTests.noPooledDecoders`. Measured
  before (M1 Max, macOS 27.2): Apple's hardware decodes Hi10P (RESEARCH 3.3). **Not compiled, not tested, nothing played**; no Dolby
  Vision, HEVC 4:2:2 or Hi10P test file here.
- 2026-11-12 **The DTS core and H.264 Hi10P as opt-in profiles, and a run-time switch for modules** (the app's owner, Backlog 2026-11-12;
  not committed). `third_party/patches/ffmpeg-0001-dts-core-only.diff` (the `dca` decoder keeps only the DTS core: `dca_xll.o` and
  `dca_lbr.o` leave the decoder, their DSP routines leave `dcadsp.c`, the extension parsers leave `dca_core.c`, the `core_only` option is
  gone because it is always on; two XLL coefficient tables stay in the shared `dcadata.c`, numbers without code), applied by
  `scripts/fetch-sources.sh` (re-extracts when the patch set changes; `.patches` stamp). Profiles `dtsCore` and `h264Software`
  (status `accepted-risk`), `licensedAudio` is TrueHD only. Variant `core+extended+dtsCore+h264Software` =
  `build/FFmpegLGPL-extended-dts-h264.xcframework` (`VARIANTS` and `variant_suffix` in `scripts/lib/common.sh`, used by
  `package-xcframework.sh`, `check-licenses.sh`, `write-build-info.sh`, `check-source-pack.sh`; `build-all.sh` builds it;
  `export-package.sh extended-dts-h264`). `CodecProfile.dtsCore`, `.h264Software`; planner: DTS to ALAC needing `.dtsCore`, DTS Express
  (profile 70) unsupported, H.264 profiles 110/122/244/44 to the software path needing `.h264Software`, other non-Apple H.264 profiles
  `unsupportedProfile`; `MediaEngine.disabledProfiles` (thread-safe, `availableProfiles` leaves them out; the probe cache's key already
  contains the profiles); speech extraction takes DTS when `.dtsCore` is there. Licence check: no DTS extension log texts in any framework.
  Docs: PATENT_PROFILES regenerated (`accepted-risk`, exception point 6), NOTICES, acknowledgements (FFmpeg notice names the change and
  its date, LGPL 2.1 section 2), REPLACING-FFMPEG, INTEGRATION, DocC, README, RESEARCH 3.2 points 6 and 7. **Evidence:** the patch
  applies to the pinned archive (dry run and `fetch-sources.sh`); the variant built for five slices (2026-11-12, background priority)
  and packaged; `check-licenses.sh` passes for it on five slices (`MEDIAENGINE_VARIANTS=core+extended+dtsCore+h264Software`); the macOS
  `libavcodec.a` has the `dca` and `h264` decoders and no XLL or LBR code; `swift build --build-tests` without errors or warnings;
  `check-public-api.sh`, `gen-patent-profiles.py --check`, `gen-acknowledgements.py --check` pass. **Not run:** every test (the owner's
  rule; tests changed: `SecurityTests.noPooledDecoders` (also: no `core_only` option), `PlaybackPlannerTests.hi10p`, `dtsOnly`,
  `dtsExpress`, `ProbeTests.licensedAudio`); no DTS or Hi10P file decoded yet (no Hi10P fixture can be made here: no 10-bit H.264
  encoder without GPL x264). **Found, older:** the core macOS slice's install folder is empty since a core rebuild was stopped on
  2026-11-04 16:19 during `configure`, so `check-licenses.sh` (all variants) and the source pack fail until
  `scripts/build-ffmpeg.sh macos core` runs again (the shipped `FFmpegLGPL.xcframework` of 2026-10-30 is intact);
  `write-build-info.sh` now writes "(not built)" for a missing slice instead of stopping.
- 2026-11-11 **A subtitle track of a server movie is shown as soon as it is chosen** (the app's owner, Backlog 2026-11-11). Cause, read in
  the code: every choice of a track the engine draws went through `makeSubtitleRenderer`, which opened a new `PacketReader` on the movie's
  byte source only to read the stream's header and keep a reader at hand. For a movie on SMB that is a whole opening over the network:
  the Matroska header and every attached font (FFmpeg's Matroska demuxer reads attachments in its header), then the controller's
  `prepare(at:)` waited for a read of the 8 s before the playhead when the player had jumped there. Audio switches are an HLS media
  selection, which reads nothing. Now: the remuxer copies the codec parameters of every overlay stream when it opens the file
  (`StreamParameters`, held by `OverlayFeed.parameters`); while the feed exists the renderer is set up from them and its file reader is a
  `DeferredEventSource`, opened only when a stretch must be read from the file (after a jump); `AVPlayerController` and
  `SoftwareController` call `SubtitleRenderer.prepareForChoice(at:)`, which for a file on a server takes the feed's windows and does not
  wait for a read of the file (lines that began before a jump follow in the background); SubRip, WebVTT and Timed Text tracks no longer
  wait for the attached fonts (they are drawn in Helvetica). Play lists (ordered chapters) and sessions without a remuxer work as before.
  `swift build` (core) without warnings; the app compiled against the exported extended package (see the app's PROGRESS). **Not run:** no
  test written or run (the owner's rule), not tried against the share.
- 2026-11-10 **DVD track languages** (the app's owner: "Do all 9"; item 8 of the app's `docs/REVIEW_2026-11-10.md`). `DiscInfo.languages(dvdTitleInfo:)`
  reads a title set's information file (`VIDEO_TS/VTS_xx_0.IFO`): the sound streams' and subtitle streams' two-letter languages, mapped to
  the program stream's ids (`Track.containerID`: AC-3 0x80+n, DTS 0x88+n, LPCM 0xA0+n, MPEG 0x1C0+n, subtitles 0x20+n) through the first
  program chain's control words (a 16:9 title takes the "wide" subtitle stream); `titleInfoLocation(forStream:)` finds `VTS_01_0.IFO` for
  `VTS_01_1.VOB`; `languages(forStream:read:)` does Blu-ray or DVD for a caller that reads the file next to the stream. Layout taken from
  libdvdread's `ifo_types.h` as I remember it (**believed, not checked against a real disc here**: the owner's share was not mounted); a
  unit test with a file built from that layout follows. Compiled; the app uses it for VOBs on the device and on a server.
- 2026-10-31 **`HTTPByteSource` takes a session delegate** (for the app's WebDAV: pinned self-signed certificates and Digest sign-in): see Right now.
- 2026-10-27 **`scripts/export-package.sh [core|extended]`** (not committed): the exported package's manifest now defaults to the variant named (default `core`; `MEDIAENGINE_PROFILE` still overrides); PlayerApp asks for `extended` so that one manifest serves `swift test`, Xcode and its scripts.
- 2026-10-27 **Fix: resuming after a pause played at half speed** (`AVPlayerController`; found while building the app's own controls; not committed). `play()` took `max(wantedRate, 0.5)` and `pause()` sets `wantedRate` to 0, so every resume ran at 0.5x. Now the chosen speed is kept apart (`speed`) and applies at every start. Regression test `SoftwareControllerPlaybackTests.resumeKeepsSpeed` (resume at 1, a chosen 1.5 kept over a pause, a speed chosen while paused does not start playback).
- 2026-10-26 **E4.1 extended profile, variant binaries (D-E11) and legacy containers** (not committed yet). Decision D-E11 (assistant, owner may overrule): optional profiles are variant binaries with the same module name, picked at package level (`MEDIAENGINE_PROFILE=extended`, `build/FFmpegLGPL-extended.xcframework`), `MediaEngine.availableProfiles` detected from the linked FFmpeg. Extended profile: RealMedia demuxer and decoders for MPEG-1/2/4, MS MPEG-4, WMV1/2, H.263 family, Flash video, VP6, RealVideo 1-4, VP8, VP9, Theora, WMA, MP2, ADPCM, RealAudio (statuses in `profiles/extended.json`); core demuxes AVI, FLV, ASF, Ogg and MPEG ES, and the plan reports those containers (and Ogg with video) as needing the extended module (ANM-8). New fixtures: AVI/Xvid, AVI/H.264, FLV, RealMedia (RealVideo 2), WMV, MPEG-2, OGM (`scripts/make-ogm.py`), MPEG-TS. Found while playing an AVI with H.264: Annex B video, ADTS audio in TS and files that do not start at zero were not handled; `PacketReader` now converts them (`AnnexB.swift`, `originTicks`), so MPEG-TS and AVI/H.264 play, seek and finish in AVPlayer. Also fixed: raw demuxers misreading a RealMedia file as AC-3 audio, FLV's fake 44.1 kHz stereo AAC header, MPEG-PS video probed as MP3 without the `mpegvideo` demuxer. Evidence: `ExtendedProfileTests` (both builds; decoding of 6 legacy formats in the extended one), `PlaybackPlannerTests`, `LegacyContainerPlaybackTests`, `AVPlayerEndToEndTests` and `RemuxTests` with `fixture-ts`, ground truth for 24 fixtures, `check-licenses.sh` for both variants (extended framework 5.2 MB vs core 2.9 MB). RESEARCH.md section 24. Progress: ANM-8, SWD-3, ANM-1, API-8, BLD-6; D-E11 decided.
- 2026-10-26 **E4.2 software player, `PlaybackController`, `MediaVideoView`** (not committed yet). Video the system cannot decode is decoded by FFmpeg (`SoftwareVideoDecoder`), converted to `CVPixelBuffer`s with colour attachments (`PixelBufferConverter`) and drawn by an `AVSampleBufferDisplayLayer` on an `AVSampleBufferRenderSynchronizer`; the sound is AVPlayer's, started on the same host time and corrected every 100 ms (`SoftwareController`). One protocol, `PlaybackController` (`AVPlayerController` for native and remuxed files, `SoftwareController` for the software path, picked by `PlaybackSession.makeController()`), `MediaVideoView` for SwiftUI plus UIKit/AppKit hosts, text subtitles through the libass overlay in the software path (`CueScript`). New: MP2 and ADPCM audio conversion (extended). WMA and RealAudio are unavailable in v1 (their frames reach across packets). Evidence: `SoftwareControllerPlaybackTests` (six legacy formats play to the end in step, pause, seek, speed), `SoftwarePipelineTests`, `LegacyAudioTests`, RESEARCH.md section 25. Progress: API-6, API-7, SWD-1, SWD-5 ticked or advanced.
- 2026-10-26 **E4.3 AV1 (dav1d), VP8/VP9 and conformance vectors** (not committed yet). dav1d 1.5.4 pinned and built for the five slices (`scripts/build-dav1d.sh`), linked into the extended variant, BSD text inside the framework, licence check extended; AV1 plans to software when the device has no hardware decoder (`MEDIAENGINE_DISABLE_HARDWARE_AV1=1` forces it). `PixelBufferConverter` takes every planar YUV format up to 16 bit (4:2:0/4:2:2/4:4:4 8 and 10 bit kept, others widened or cut to 10 bit, grey, range from the frame). 64 official libvpx and libaom vectors (`scripts/fetch-conformance.sh`, `build/conformance`, pinned in `third_party/conformance.lock`) decode bit-exact per frame (`ConformanceTests`); seven play to the end through the software player. Host tools gained the `ivf` demuxer/muxer and `vp8` parser. Evidence and what is not covered: RESEARCH.md section 26. Progress: SWD-3, BLD-9.
- 2026-10-26 **E4.4 deinterlacing, pulldown, pixel aspect ratio** (not committed yet). `Deinterlacer` (own code: keeps the field captured first, replaces comb teeth of the other field by edge-directed interpolation, 8 and 10 bit, 5 ms per 1080 picture worst case) behind `SoftwareController.deinterlacing` (`.automatic` default, `.off`); soft-telecine durations from `repeat_pict` when the file gives none; the container's pixel aspect ratio wins over the bitstream's and reaches the pixel buffer and format description. New fixtures `fixture-interlaced-tff.mpg`, `fixture-interlaced-bff.mpg`, `fixture-anamorphic.mkv` (host tools got `weave`, `separatefields`, `telecine`, `setfield`). Evidence: `InterlaceTests`, `InterlacedPlaybackTests`, RESEARCH.md section 27. Progress: ANM-7 ticked. Deferred: inverse telecine, bob.
- 2026-10-26 **E5/E6 release readiness: licences, notices, source pack, samples** (not committed yet). LIC-2: `docs/REPLACING-FFMPEG.md`, `Samples/SwapProbe`, `scripts/test-framework-swap.sh` (core framework replaced by the extended one under the same executable). LIC-3: `scripts/make-source-pack.sh`, `scripts/write-build-info.sh`, `scripts/check-source-pack.sh`, `third_party/patches/`. LIC-4: `MediaEngine.acknowledgements` (generated, tested against the pins). LIC-6: `docs/PATENT_PROFILES.md` generated from the profiles (draft for a lawyer). LIC-7: `docs/DECISION_D-E1_LICENSE.md` (owner decision; the repo's `LICENSE` is still MIT). API-1: `Samples/QuickStart` (SwiftUI app, builds for macOS, iOS and visionOS via `scripts/check-samples.sh`) and `QuickStartTests` (the five lines on every platform). Ticked: LIC-2, LIC-3, LIC-4. Open: LIC-6 and LIC-7 (lawyer, owner).
- 2026-10-26 **Fillers and release documents** (not committed yet). Cut-off Matroska downloads are flagged (`MediaInfo.isIncomplete` plus a note; the segment size in the header against the file length). libunibreak 8.0 (zlib licence, pinned by SHA-256) is built into `LibASS.framework` and switched on per track (`ASS_FEATURE_WRAP_UNICODE`): long Japanese, Chinese and Korean lines wrap (`ASSRenderTests.cjkWraps`); golden frames unchanged. Benchmark gate with a stored baseline (`scripts/bench.sh`, `Benchmarks/baseline.json`, PRF-1). DocC catalog with tutorial and articles (`scripts/check-docs.sh`, zero warnings; API-10), `docs/INTEGRATION.md`, `docs/VERSIONING.md`, `CHANGELOG.md`, `Samples/Player` (DOC-2). Measured: the heaviest ASS scene renders in at most 5 ms at 1080p and 4K, so overlay bands are not needed. Not possible here: libFuzzer harness (no runtime in the toolchain). Ticked: API-10, DOC-1, DOC-2, DOC-3, PRF-1, PLT-5.
- 2026-10-26 **Test-run optimisation: fast, reliable checks** (owner's request; committed by the assistant as asked). Measured first: the 244 ordinary tests take 13 s, the 19 real-time AVPlayer tests 41 s, and the old trait check ran the whole suite four times. Now: three passes (unit, playback alone on the machine, isolated; `scripts/lib/tests.sh`), `scripts/check.sh` (build with zero warnings + unit tests, 14 s), `scripts/verify.sh --quick` (about 1 min), `scripts/verify.sh` (4 min 12 s, was 7 min 40 s: trait check runs only the one trait test per combination with a warm cache per combination, the four simulators build once per platform and run side by side), `scripts/verify.sh --deep` (adds the sanitizers), per-step timings printed and saved in `build/verify-logs/summary.txt`, `scripts/check-sanitized.sh [address|thread|undefined|all]` with a cache per sanitizer and the playback suites stretched by `MEDIAENGINE_TEST_PATIENCE`, `scripts/flake-hunt.sh` (failure counts per test), git hooks in `scripts/hooks` (pre-commit quick check, pre-push `verify --quick`; installed by the owner with `scripts/install-hooks.sh`, which sets `core.hooksPath`), one shared `waitUntil` in `TestSupport.swift`, one seeded `SplitMix64` for all fuzz tests. **Real bug found on the way:** the all-traits unit run crashed once ("Not enough bits to represent the passed value"): the Matroska chapter parser converted a damaged `SeekPosition` with `Int64(value)` and added element sizes without overflow checks, and its fuzz test used the system random generator, so it hit that one run in four; fixed, fuzzed with a fixed seed, `EBMLTests.hugeNumbers` reproduces the trap on the old code (RESEARCH.md section 22).
- 2026-10-25 **E3.5 full ASS and picture subtitles on the overlay path** (committed 2026-10-25). libass 0.17.5, FreeType 2.14.3 (FTL), HarfBuzz 14.6.0 and FriBidi 1.0.16 (owner approved the four components, pins with SHA-256 and, for libass and FreeType, signatures) built for five slices into `LibASS.framework` (`scripts/build-subtitle-libs.sh`, `package-subtitle-xcframework.sh`; exports only `ass_*`; `check-licenses.sh` and `check-public-api.sh` extended; `third_party/NOTICES.md` carries the FreeType credit). API: `overlayChoices`, `makeSubtitleRenderer(for:)`, `SubtitleRenderer.frame(at:size:)` / `prepare(at:)` / `close()`, `SubtitleFrame`, `SubtitleImage`, `TrackChoice.isBitmap`. Evidence: `ASSRenderTests` (17: attached fonts, karaoke, clip, drawings, blur, rotation, fades, motion, scaling, CJK fallback, Devanagari, Hebrew order), `SubtitleRendererTests` (choices, container and file tracks, windows, play lists), `BitmapSubtitleTests` (PGS, VobSub, DVB), `GoldenFrameTests` (8 recorded frames), `ExclusiveTests.noOverlayLeaks`; new fixtures `fixture-ass-fx.mkv`, `fixture-bitmap.mkv`, `Fixtures/src/BlockFont.ttf` and subtitle tracks in the ordered-chapter fixtures; host ffmpeg gained the picture-subtitle components. Bugs found: libass drops blocks with a repeated ReadOrder (restarts in every file of a play list), `-fvisibility=hidden` empties the export list, the message callback's `va_list`. RESEARCH.md section 23. Ticked: SUB-1, SUB-2, ANM-3, E-S8; progress on BLD-9.
- 2026-10-25 **E3.6 ordered chapters and linked segments** (committed 2026-10-25). `Matroska/EBML.swift`, `MatroskaChapters.swift`, `OrderedChapters`, `TimelineReader` (a `PacketSource`), `RemuxSession(packetSource:)`, `PlaybackSession.playList` / `missingSegments` / `incompatibleSegments` / `chapters` / `duration` / `locateSegments(in:)` / `link(_:to:)`. Evidence: `OrderedChaptersTests`, `EBMLTests` (including the huge-size regression), `TimelineReaderTests` (packets identical to the sources, seeking, keyframes, incompatible and missing parts), `PlayListSessionTests`, `PlayListPlaybackTests` (AVPlayer plays, seeks across the joins and finishes the 6 s timeline of three parts from two files). Bug found by the trait runs and fixed: a damaged file could claim a terabyte-sized element and crash the reader (reads are capped and checked against the source). RESEARCH.md section 22. Ticked: ANM-2.
- 2026-10-25 **T3 E3 kickoff** (committed 2026-10-25). Spike S1: SubRip and ASS tracks served as WebVTT renditions (`SubtitleText`, `WebVTT`, `subs-ID.m3u8`, `subs-ID-N.vtt`), AVPlayer lists them and delivers cues in step with the video (`SubtitleTextTests`, `SubtitleRenditionTests`, `AVPlayerEndToEndTests.subtitleCues`). Spike S2: the system audio menu cannot show track titles; decision and API plan in RESEARCH.md section 17 (design note, sub-milestones E3.1-E3.6). Progress on RMX-4, SUB-1, RMX-3.
- 2026-10-25 **T2 `.resourceLoader` spike: not possible, recorded** (committed 2026-10-25). A delegate bridge served the master and media playlists and the init segments, then AVPlayer failed on the first media segment (CoreMedia -12881, "custom url not redirect"; content types and flags made no difference). The bridge lives on as test code (`ResourceLoaderProbe`) with the known-issue test `AVPlayerEndToEndTests.resourceLoaderLimitation`, which fails the day an SDK accepts it. Loopback server stays the only transport. Ticked: RMX-9 (RESEARCH.md section 16).
- 2026-10-25 **E3.4 external subtitle and audio files** (committed 2026-10-25). `TextEncoding` and a deterministic detector (23 of 23 corpus pairs), `SubtitleTrack` (SubRip, WebVTT, ASS/SSA, filename hints, delay), `AudioTrack` (m4a, raw AAC, AC-3, FLAC, Opus in mka; delay; `EXT-X-GAP` for uncovered segments), `PlaybackSession.add(_:)`, raw ADTS timestamps and byte-index seeking in `PacketReader`, external ids in `TrackChoice` (`isExternal`). New fixtures `Fixtures/audio/*`; host tools gained the raw AC-3/E-AC-3 muxers. Bug found on the way: main windows stored empty fragments for external outputs. Evidence: `EncodingTests`, `ExternalSubtitleTests` (file, session, AVPlayer), `ExternalAudioTests`. RESEARCH.md section 21. Ticked: SUB-3, SUB-4; progress on SUB-5, AUD-1.
- 2026-10-25 **E3.3 track choices and selection** (committed 2026-10-25). `PlaybackSession.audioChoices` / `subtitleChoices` (`TrackChoice`), `select(_:on:)`, `deselectSubtitles(on:)`, `selectedChoice(of:on:)`, `apply(_:to:)` with `TrackPreferences`; unique rendition names shared by playlists and API; new fixture `fixture-multi.mkv`. Evidence: `TrackChoiceTests`, `TrackPreferenceTests`, `TrackSelectionTests` (AVPlayer switches between same-language tracks). RESEARCH.md section 20. Ticked: RMX-3, ANM-4.
- 2026-10-25 **E3.2 chapters, cover art and Now Playing metadata** (committed 2026-10-25). `Chapter.kind` and `isSkippable` (opening, ending, intro, recap, preview, credits, content), `MediaSource.data(of:)` for fonts and cover pictures, title and cover on `AVPlayerItem.externalMetadata` (iOS, visionOS). Finding: chapter markers for the system player are tvOS-only, and `externalMetadata` needs AVKit loaded (RESEARCH.md section 19). Evidence: `ChapterTests`, `AttachmentTests`, `PlayerItemMetadataTests`. Ticked: RMX-8; progress on ANM-4.
- 2026-10-25 **E3.1 subtitle cues per window and placement** (committed 2026-10-25). Also: the iPhone Duo simulator run caught a racy test (`cancelledDuringReads`, now `GatedByteSource`). Cues are recorded from the windows built for audio and video (15 s look-back, any request order, no whole-file pass); ASS `\an`/`\pos` and style alignment become WebVTT cue settings that AVPlayer honours; new fixture `fixture-subs-long.mkv`. Evidence: `SubtitlePlacementTests`, `SubtitleRenditionTests` (`spanning`, `orderDoesNotMatter`, `readsOnlyNearbyWindows`), `AVPlayerEndToEndTests.subtitlePlacement`. RESEARCH.md section 18; RMX-4 progress. macOS 135 tests.
- 2026-10-25 **T1 byte-bounded segments and mmap-backed fragments** (committed 2026-10-25). Evidence: `SegmentPlanTests` (high bitrate shortens segments, ordinary bitrate unchanged, bursts cut by index positions, huge GOP not split), `RemuxTests.sizeCap` (more segments, every packet in exactly one fragment, contiguous), `BigBufferTests`, `ExclusiveTests.fragmentsAreReturned` (fails on the old malloc output), `BenchmarkTests` on generated 1080p/4K files (growth 82/101/116 MB at 13/44/66 Mbps, AVPlayer playing in 558-629 ms). Ticked: RMX-7. macOS 115 tests, isolated pass 8.
- 2026-10-24 **Project skills added** (`.claude/skills/`: engine-verify, engine-add-fixture, engine-benchmark, engine-finish-step, engine-rebuild-ffmpeg, engine-playback-debug), listed in `CLAUDE.md`. Engine work E2.4b/E2.5 committed as `b253911`.
- 2026-10-24 **E2.5 hardening, B-frame fix and measurements** (committed in `b253911`). Evidence: `DamagedFileTests` (756 deterministic mutations per run of four fixtures through the whole remux path: no crash, no hang; a source failing after open now reports an error; `truncatedDownload` plays a file cut at 60% up to its last complete data), whole suite clean under ASan, TSan, UBSan and under ASan with an instrumented FFmpeg (`scripts/check-sanitized.sh`), `ExclusiveTests` (100 open/close cycles, idle CPU, probe speed, cancellation latency, fragment memory) and `LifetimeTests`. **Bug found by the 3-hour benchmark and fixed: files with B-frames did not open** (`ReorderModel`, `DecodeTimestampTests`, `fixture-bframes`); **memory bug fixed** (appending to a growing buffer kept 464 MB behind, now 129 MB for a 1080p 13 Mbps file; segment cache 48 MB). Numbers (M1 Max): AVPlayer playing after 464-541 ms, seek until playing again 242-393 ms, A/V offset drift 0.2-0.8 ms over 3 hours (RESEARCH.md section 14). Ticked: PRF-2, PRF-3, RMX-13; progress notes on RMX-5/6/7/12 and PRF-1. `scripts/verify.sh` passes (5 min 58 s, exit 0): macOS 108 tests (1 known issue, the PQ one), isolated pass 7 tests, iPhone / iPad / iPhone Duo / visionOS simulators 100 tests each, zero warnings.
- 2026-10-24 **E2.4b Opus and Vorbis transcoding with decoder pre-roll, and the Matroska Cues fix** (committed in `b253911`). Evidence: `AudioTranscodeTests.prerollSegments` (Vorbis sample-exact, Opus within rounding noise, cold start differs), `KeyframeIndexTests`, `startsAreAligned`, `AVPlayerEndToEndTests.crossesBoundary` (English/Japanese across a segment boundary), new fixture `fixture-opus-vorbis.mkv`. Details in RESEARCH.md section 13.
- 2026-10-24 **E2.4 audio transcoding (FLAC/PCM to ALAC), lazy per track** (committed in `d9da1c7`). Evidence: `AudioTranscodeTests` (bit-exact 16-bit mono and 24-bit stereo, segments join, timestamps contiguous, lazy), `RemuxTests` (ALAC init segments, AVFoundation decodes the ALAC renditions), `AVPlayerEndToEndTests.audioSelection`; `scripts/verify.sh` passed. Ticked: ANM-5.
- 2026-10-24 **E2.1 to E2.3 passthrough remux to AVPlayer** (committed in `d9da1c7`). Evidence: `scripts/verify.sh` passes in 3 min 4 s; `RemuxTests` (packet-exact fragments, continuous timestamps, init segment boxes, AVFoundation frame-exact decode), `LoopbackServerTests` (ranges, HEAD, 403/404/405/416, token, loopback-only), `PlaybackSessionTests` (item lifetime, close), `AVPlayerEndToEndTests` (play, seek, finish for H.264, HEVC, HLG). Server hardening part of RMX-9 verified (the `.resourceLoader` transport is still open).
- 2026-10-24 **E1 probe API and byte sources.** Evidence: `scripts/verify.sh` passes in 2 min 29 s (macOS, iPhone, iPad, iPhone Duo, visionOS simulators; 46 tests each; zero warnings); ThreadSanitizer clean; `scripts/check-public-api.sh`, `scripts/check-ground-truth.sh`. Ticked: API-2, API-3, API-4, API-5, API-11, PRB-1, PRB-3, PRB-4, IO-1, IO-2, PRF-5. PRB-2 and ANM-1 partly done (see notes in the criteria).
- 2026-10-24 **E0 build system and license skeleton.** Evidence: `scripts/verify.sh` passes in 1 min 47 s (macOS, iPhone 18 Pro Max, iPad Air 13-inch (M4), iPhone Duo, Apple Vision Pro simulators; 6 tests each; zero warnings); `scripts/build-all.sh` clean rebuild 2 min 21 s; `scripts/check-licenses.sh` passes and fails on a tampered build. Ticked in `ACCEPTANCE_CRITERIA.md`: BLD-1, 2, 3, 5, 7, LIC-1, PLT-1, PLT-2, E-S1.
- 2026-10-24 E-S1 result: FFmpeg 9.0.2 builds LGPL-clean for five slices; one merged dynamic framework `FFmpegLGPL` (2.7-2.8 MB per slice); Swift demuxes MKV through custom I/O with no H.264/HEVC/AC-3 decoder compiled in.
- 2026-10-24 E-S2 partial result: traits switch code at compile time; they cannot swap binaries. Opened D-E11.
- 2026-10-24 Fixtures: `Fixtures/fixture-basic.mkv` (H.264, AAC, FLAC, SRT, 2 chapters) and `fixture-hevc.mkv` (HEVC, AC-3), about 250 KB each, made by our own host `ffmpeg`.
- 2026-10-24 Tools installed (meson, ninja, cmake, gpg, Rust); visionOS 27.0 simulator runtime installed.

## Decisions log

| Date | Decision | By |
|---|---|---|
| 2026-10-24 | Separate package, LGPL-only FFmpeg, dynamic frameworks; platforms iOS/iPadOS/macOS/visionOS 27.0; no tvOS | Owner |
| 2026-10-24 | Licensing strategy: Apple decoders; own decoders only for royalty-free or expired codecs; remux needs no codec licence; everything else opt-in and off until a lawyer clears it | Owner |
| 2026-10-24 | **H.264 Hi10P is out of scope**: no software H.264 decoder; such files report a clear "unsupported" reason | Owner |
| 2026-10-24 | Pro package C for the app; team = Michael Novosad (Personal Team) | Owner |
| 2026-10-24 | FFmpeg 9.0.x (9.0.2 pinned) and a single merged framework `FFmpegLGPL` | Claude, from E-S1 evidence |
| 2026-10-24 | Open: D-E11 packaging of optional codec profiles (plug-in frameworks vs variant products), decided in E4 | — |
| 2026-11-12 | **The DTS core and H.264 Hi10P in, as opt-in profiles** (the app links them, free): plain DTS only, DTS-HD lossless, DTS Express and DTS:X code removed from the binary, DTS-HD tracks play their core; H.264 only for High 10, 4:2:2 and 4:4:4 on the software path. Replaces the 2026-10-24 Hi10P row for this. Risk accepted by the owner, not a legal clearance | Owner |
| 2026-11-17 | **VC-1 in, as an opt-in profile** (`vc1Software`: FFmpeg `vc1` and `wmv3`, in `extended-plus`, the app links it, free). Apple decodes no VC-1, so it is always our decoder. Risk accepted by the owner, not a legal clearance (RESEARCH 3.2 point 9); TrueHD and Dolby Vision 7 stay off | Owner (app) |
| 2026-11-17 | **visionOS is not in this release** (the app's owner, "maybe for v2"): no visionOS slices, platform, samples or simulator runs; the state of that day is kept on the `visionos` branch, not updated until the owner says so. Replaces the visionOS part of the 2026-10-24 platform row | Owner (app) |
| 2026-11-17 | **Tests alongside the implementation, a commit after each big piece without asking** (skill `commit-with-tests`): the narrow tests of the changed code run before the commit; broad checks, simulators and rebuilds still on the owner's word; never pushed. Replaces "commit only when asked" and "tests only on the owner's word" (2026-10-30) | Owner |

## Handoff notes (what a fresh session must know)

- **Diagnosing playback from the owner's runs (2026-11-08):** read the system log with `/usr/bin/log show` (zsh's `log` is a builtin), filtered by process `Eiga` or its pid. The engine writes under subsystem `dev.mediaengine`: category `index` (index found, piece plan, "Ready to play in …", "Piece N built in … ms", "read ahead stopped", "stopped: the player went to piece …", parameter-set changes), `player` (AVPlayer's own error log, documented codes), `ffmpeg` (FFmpeg's messages). The app writes `dev.novosad.eigaplayer` categories `opening` (timings of an opening) and `smb` (connection failures, retries, the server's read size; status codes only). Apple's own useful lines: `VTDecompressionSessionInvalidate … decoded N dropped M`, kernel `AppleAVD … decodeFailIdentify` (bitstream errors), `segPump … -12889 No response for media file in Ns` (AVPlayer gave up on a piece after about its length). Apple's "signalled err" codes are undocumented except -12753 (`kCMSyncError_InvalidParameter`).
- **The owner's movies:** an SMB share on the router; when the owner mounts it in Finder it is at `/Volumes/tplinkwifi.net` and can be read (never written) without a password. Never take or type the password. The host tools `build/tools/bin/ffprobe` and `ffmpeg` read files there; FFmpeg's `-map` of a cover stream reads the whole file (do not). Blu-ray folders keep languages in `BDMV/CLIPINF/*.clpi`, DVD folders in `VIDEO_TS/*.IFO`.

- Always `export DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer`. Scripts set it themselves; plain `swift`/`xcodebuild` in a shell need it. Rust lives in `/opt/homebrew/opt/rustup/bin`.
- Everyday commands: `scripts/verify.sh` (full, about 2.5 min), `scripts/verify.sh --quick` (macOS only), `scripts/build-all.sh` (rebuild frameworks and fixtures, about 2.5 min), `scripts/bootstrap.sh` (tool check), `scripts/check-traits.sh`, `scripts/check-public-api.sh`, `scripts/check-ground-truth.sh`.
- Public API so far: `MediaSource` (`init(url:)`, `init(byteSource:)`, `probe()`), `MediaInfo` and friends, `PlaybackPlan`, `CodecProfile`, `ByteSource` (+ `DataByteSource`, `FileByteSource`, `HTTPByteSource`), `MediaError`, `MediaEngine.buildInfo/availableProfiles/enabledTraits`. Sources are under `Sources/MediaEngine/` (`Internal/` holds the FFmpeg bridge, prober, extradata and language helpers).
- Test patterns: fixtures and ground-truth JSON are read through `#filePath` (works on simulators); HTTP tests use a `URLProtocol` stub (`StubServer`/`StubProtocol` in `ByteSourceTests.swift`, suite is `.serialized`); planner tests build synthetic tracks with `makeTrack`.
- Regenerating fixtures changes their bytes (VideoToolbox is not bit-reproducible): rerun `scripts/make-fixtures.sh`, which also rewrites the ground-truth JSON; commit both together.
- Audio: core now includes FFmpeg's native `alac` encoder (framework rebuilt with `scripts/build-all.sh core`). Transcoded tracks use a 1/sample-rate time base end to end; `FragmentWriter`, the init segment and `shift` follow it.
- E2 gotchas learned the hard way: (1) seeking to time 0 skips packets with negative timestamps (AAC priming), so the first window reopens the file (`PacketReader.rewind()`); (2) the MP4 muxer writes an edit list that shifts AVFoundation's timeline, so `use_editlist=0`; (3) the muxer returns `ftyp`+`moov` only (no `moof`) with `delay_moov`, which is what we use as the init segment; (4) sample durations come from dts deltas (Matroska timestamps are ms-rounded); (5) in the macOS 27 SDK `AVPlayerItem` is main-actor isolated and `AVAssetReader.add/startReading/copyNextSampleBuffer`, `AVPlayerItemVideoOutput.copyPixelBuffer`, `errorLog()` are deprecated (use `outputProvider(for:)`, `start()`, `provider.next()`, `pixelBufferAndDisplayTime(forItemTime:)`); (6) Python's `http.server` cannot listen inside the tool sandbox, `NWListener` can.
- Test hooks: `RemuxSession.masterTransform` rewrites the master playlist (for AVPlayer experiments); `ResourceProvider` lets the loopback server serve any directory or session.
- The probe plans with `DeviceCapabilities.current`: AV1 hardware support comes from VideoToolbox and may differ between simulator and device.
- The XCFramework (`build/FFmpegLGPL.xcframework`) is a build product and is git-ignored; `Package.swift` references it by path. Fresh clone: run `scripts/bootstrap.sh`, then `scripts/build-all.sh`.
- Simulators used: iPhone 18 Pro Max (iOS 27.0), iPad Air 13-inch (M4) (iOS 27.0), iPhone Duo (iOS 27.1), Apple Vision Pro (visionOS 27.0). `verify.sh` finds them by name; there are two "iPhone Duo" devices, the first is used.
- The core profile compiles no H.264/HEVC/AAC/AC-3 decoders on purpose; probing works through parsers. Do not add decoders to `core.json` without the owner and LIC-6.
- Homebrew's `ffmpeg` is GPL: never link it. Fixtures come from `scripts/build-host-tools.sh` + `scripts/make-fixtures.sh`.
- Bash 3.2 rules (macOS default): no `mapfile`, no associative arrays; avoid `grep -q` in `pipefail` pipelines (use the `has`/`lacks` helpers in `check-licenses.sh`).
- Downloaded sources live in `build/downloads/` (untrusted until SHA-256 and signature pass); builds are out of tree in `build/work/`.
- Never use the company Apple team that is signed in on this Mac. Commit only when the owner asks; no Claude co-author trailers.
- Sibling project: `~/Documents/Development/PlayerApp` (starts after this package passes E3); its own `docs/PROGRESS.md` tracks the app.
- Homebrew side effect to remember: installing meson re-linked `/opt/homebrew/bin/python3` to python@3.15.

- Test layout (2026-10-26, replaces the E2.5 note): three passes, defined in `scripts/lib/tests.sh`: **unit** (about 244 tests, 13 s, parallel), **playback** (the five real-time AVPlayer suites in `PLAYBACK_SUITES`, about 45 s, alone on the machine) and **isolated** (`MEDIAENGINE_EXCLUSIVE=1 swift test --filter ExclusiveTests`: anything that measures time, memory, descriptors or CPU lives in `ExclusiveTests`). `BenchmarkTests` run only with `MEDIAENGINE_BENCH_FILE=/path/file.mkv` (optional `MEDIAENGINE_BENCH_TRACE=1`). Shared `waitUntil` in `TestSupport.swift`; its bounds scale with `MEDIAENGINE_TEST_PATIENCE` (sanitizers: 4). Commands: `scripts/check.sh` (15 s), `scripts/verify.sh --quick|(none)|--deep`, `scripts/flake-hunt.sh`, git hooks via `scripts/install-hooks.sh`. Generate a long B-frame test file with the host ffmpeg (`build/tools/bin/ffmpeg`, `h264_videotoolbox -profile:v high -bf 2`, lavfi `testsrc2`); the one used for the numbers lived in the scratchpad and is not kept.
- Sanitizers: `scripts/check-sanitized.sh [address|thread|undefined|all]` (also `verify.sh --deep`) runs the unit and playback passes under each, with build caches of their own (`.build-sanitized`, `.build-tsan`, `.build-ubsan`, git-ignored). The address run swaps in an ASan-instrumented FFmpeg (`FFMPEG_SANITIZE=address` in build-ffmpeg.sh / package-xcframework.sh, `MEDIAENGINE_SANITIZED_FFMPEG=1` in Package.swift, output `build/FFmpegLGPL-address.xcframework`); thread and undefined cover the Swift code only. Tests detect ASan/TSan by `dlsym` (footprints are meaningless under ASan's quarantine; real-time waits are stretched).
- A test that sleeps and polls to act "while the probe is running" is racy on a loaded machine (parallel tests starve the cooperative pool for seconds; the iPhone Duo simulator run caught `cancelledDuringReads` that way). Use `GatedByteSource` (blocks the first read until the test releases it) for such cases.
- Flake hunting: loop `swift test > log` and search the logs for the failure marker (`grep "􀢄"`); grepping for "recorded an issue" misses some failures.
- Decode timestamps: Matroska has no dts; `ReorderModel` rebuilds them for video per window (sorted pts shifted by the reorder depth). Never reintroduce `dts = pts` for B-frame video. Fixtures made before this had no B-frames; `fixture-bframes.mkv` was added by running its command from `make-fixtures.sh` alone (regenerating all fixtures rewrites every file).
- Memory: build large buffers with the final size (`ByteWriter(capacity:)`) and put finished multi-megabyte outputs into `BigBuffer.make` (mmap): `malloc` keeps freed multi-megabyte blocks in the process footprint. Segment cache budget is 48 MB (`RemuxSession.init(cacheBudget:)`), segment size cap 24 MB (`maxSegmentBytes`, `MEDIAENGINE_BENCH_SEGMENT_BYTES` overrides it in benchmarks).
- Subtitles: `Remux/Subtitles.swift` (`SubtitleText`, `ASSHeader`, `WebVTT`) turns SubRip/ASS packets into cues with placement; `RemuxSession` serves `subs-ID.m3u8` and `subs-ID-N.vtt`, records cues while it builds windows (`record(subtitle:)`, `scanSubtitles(through:)`, 15 s look-back; RESEARCH.md section 18). The OS adds machine-translated subtitle options to the menu; tell ours apart by the missing title metadata.
- Known issues in the macOS run are expected: `pqKnownIssue` (HDR10 over HLS) and `resourceLoaderLimitation` (two issues, tripwire: if it starts failing as 'known issue did not occur', AVPlayer began accepting HLS segments from a resource loader).
- AVKit trap: `AVPlayerItem.externalMetadata` is an AVKit category; compiled code crashes with "unrecognized selector" unless AVKit is loaded (`PlaybackSession.describe` loads it and checks `responds(to:)`). Chapter markers (`navigationMarkerGroups`) are tvOS-only, so chapters go to the app via `MediaInfo.chapters` / `Chapter.kind`. Tests for the iOS-only parts run through `xcodebuild test -only-testing:MediaEngineTests/<Suite>` on a simulator.
- External files: `SubtitleTrack`/`AudioTrack` are added with `PlaybackSession.add(_:)` before the first item (ids 10,000+ and 20,000+ in `TrackChoice`). External audio has its own `PacketReader` and is built per request in `RemuxSession.buildExternalAudio`; main windows must skip those outputs (`mainOutputs`). Segments an audio file does not reach are `EXT-X-GAP` in its playlist: without that AVPlayer never starts or stops at the hole. Raw ADTS needs `PacketReader`'s own numbering. Encoding detection lives in `Subtitles/TextEncoding.swift`; its corpus is `Tests/MediaEngineTests/Corpus/*.txt` (excluded from the target in Package.swift).
- Ordered chapters (E3.6): `Matroska/EBML.swift` + `MatroskaChapters.swift` parse the editions (FFmpeg exposes none), `OrderedChapters` (public) is the play list (`pieces`, `available(_:)`), `TimelineReader` (a `PacketSource` like `PacketReader`) joins parts of several files with timestamps moved by `offset - start`; `RemuxSession(packetSource:)` takes it, `PlaybackSession.makeTimeline` builds it (drops files with a different video configuration and reports them). Session API: `playList`, `missingSegments`, `incompatibleSegments`, `chapters`, `duration`, `locateSegments(in:)`, `link(_:to:)`. A frame belongs to the part it starts in. Fixtures are made by `scripts/make-ordered-fixtures.py` (patches Matroska bytes: SegmentUID, Chapters); the three share codec parameters on purpose. See RESEARCH.md section 22.
- Overlay blocks from the remuxer (2026-11-06): `Subtitles/OverlayFeed.swift` (`OverlayFeed`, filled by `RemuxSession.buildWindow`; `OverlayFeedView` watches its stream while it lives; `TimeRanges`). The renderer's rules: required range `fileTime - seekLookback ... fileTime + 3` with the feed (`- 15 ... + 12` without), windows taken from `fileTime - 20 ... fileTime + 45`, a new pass when the feed's serial changes or every 0.25 s while something is missing; reads of the file on `readQueue`, one at a time. A window's coverage is its segment's time range (the last one runs to the end of the file), per stream (`Window.complete`). A new test of this path needs a session with a player item (or a stand-in `OverlayFeedSource`).
- Overlay subtitles (E3.5): `Subtitles/ASSRenderCore.swift` (libass, one library/renderer/track, composites its alpha masks into one `CGImage`), `Subtitles/OverlayBackends.swift` (`ASSBackend`, `BitmapBackend`, `OverlayEventLoader`), `SubtitleRenderer.swift` (public; windows of blocks read ahead on a queue), `PlaybackSession+Overlay.swift`. `LibASS.framework` is a second build product like `FFmpegLGPL` (rebuild: engine-rebuild-ffmpeg skill). Tests use the generated block font so no system font enters; goldens are re-recorded with `MEDIAENGINE_RECORD_GOLDEN=1` after a library update. The renderer takes the player's time and subtracts the HLS timeline shift itself.
- Variants (E4.1): core and extended are two builds of the same FFmpeg with the same module name. `scripts/build-all.sh` builds both; `Package.swift` picks the binary with `MEDIAENGINE_PROFILE=extended` (use `--scratch-path .build-extended`). Profile availability is detected at run time (`MediaEngine.availableProfiles`). Tests that need the extended binary use `.enabled(if: isExtendedBuild)`; `scripts/verify.sh` runs them. `PacketReader` hands out zero-based timestamps (`originTicks`), converts Annex B H.264/HEVC to length-prefixed NAL units, and cuts ADTS headers off AAC in MPEG-TS; read codec parameters through `PacketReader.parameters(_:)`.
- Project skills live in `.claude/skills/` (see CLAUDE.md); use them for verification, fixtures, benchmarks, rebuilds, debugging and the end-of-step ritual.

## Open questions for the owner

- None right now.

- Engine map after E4 to E6 (2026-10-26): `Sources/MediaEngine/Software/` (`SoftwareController`, `SoftwareVideoPipeline`, `SoftwareVideoDecoder`, `PixelBufferConverter`, `Deinterlacer`), `PlaybackController.swift` (+ `PlaybackSession+Controller.swift`), `MediaVideoView.swift`, `Acknowledgements.swift` and `Acknowledgements.generated.swift` (generated: `scripts/gen-acknowledgements.py`), `MediaEngine.docc`. Binaries: core `build/FFmpegLGPL.xcframework`, extended `build/FFmpegLGPL-extended.xcframework` (dav1d inside), `build/LibASS.xcframework` (libass, FreeType, HarfBuzz, FriBidi, libunibreak). Rebuild order: `fetch-sources.sh`, `build-dav1d.sh` x5, `build-ffmpeg.sh <slice> core` and `core extended` x5, `package-xcframework.sh core` and `core+extended`, `build-subtitle-libs.sh` x5, `package-subtitle-xcframework.sh` (or `build-all.sh`).
- Checks added: `fetch-conformance.sh` + `ConformanceTests` (64 vectors, extended build), `test-framework-swap.sh` (LIC-2), `check-source-pack.sh` (LIC-3), `check-docs.sh` (DocC, zero warnings), `check-samples.sh` (QuickStart and Player for three platforms), `bench.sh` (PRF-1, deep tier), `gen-patent-profiles.py --check` and `gen-acknowledgements.py --check` (inside `check.sh`).
- The playback pass runs with `--no-parallel` (suites overlapping starved each other; the play-list suite failed seeks and took 100 s instead of 12 s). A real-time test that fails once under another app's load (a browser playing video) and passes alone is that, not a regression: `scripts/flake-hunt.sh`.
- Committed: E4.1 to E6 and the fillers are in `4f3905d` (one commit, no Claude trailer); the entries above that say "not committed yet" are from before.
- Owner decisions waiting: D-E1 licence (`docs/DECISION_D-E1_LICENSE.md`; the repo's `LICENSE` is still MIT), lawyer review of `docs/PATENT_PROFILES.md`, support terms in `docs/VERSIONING.md`, the PlayerApp repository (create a separate git repository for it, ask for the GitHub remote).
- **Load rule (owner, 2026-10-26):** the owner uses this Mac for video calls while checks run, and a full verify with four simulators plus sanitizers disturbed a call. Scripts now run at background priority (`taskpolicy -b`, `nice 19`, half the cores), tests are silent (`PlaybackController.isMuted`, set in every test), simulators are opt-in (`verify.sh --sims`, one at a time, shut down afterwards), pre-push runs only `check.sh`, and heavy runs (`--sims`, `--deep`, FFmpeg builds) wait for the owner's go-ahead. Details: CLAUDE.md working rules. Timing-sensitive playback tests are slower at background priority; a single failure under load is not a regression (rerun alone).
- Verification after the load rule (2026-10-26, owner asked for one full run at background priority): `scripts/verify.sh` passed every step up to the extended playback pass, which failed because the real-time software-player tests asserted speed and the machine at background priority is slow (frames are dropped when late). Fixed: those assertions run only at full speed (`testPatience == 1`); background runs set `MEDIAENGINE_TEST_PATIENCE=4` and check correctness (order, start, end, decoded count). The extended playback pass (84 s), `check-traits.sh` (7 min) and `check-samples.sh --macos-only` then passed separately; the whole verify was not repeated end to end. Speed is gated by `scripts/bench.sh` and by running the checks with `MEDIAENGINE_FULL_SPEED=1`.
- Apps depend on the engine through a clean exported copy: `scripts/export-package.sh` writes `dist/package/MediaEngine` (Package.swift without the test target, the sources, the three XCFrameworks; incremental, seconds). Reason: Xcode lists and type-checks every file of a path dependency, and this working tree has about 95,000 files in `build/`; a build of PlayerApp spent over an hour just loading the project. Run it after every `build-all.sh`; PlayerApp's scripts run it themselves. Not yet committed in this repository.
