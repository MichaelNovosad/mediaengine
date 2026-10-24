# MediaEngine acceptance criteria

Tick a box only with evidence (test name, log, screenshot path, or a device result from the owner).
Tags: `[auto]` automated test or script, `[sim]` simulator, `[device]` real hardware by the owner, `[lawyer]` needs legal review, `[manual]` judgement.
Milestones: E0 build system and license skeleton · E1 probe, I/O and core Swift types · E2 remux to AVPlayer (the first MKV plays) · E3 subtitles and tracks · E4 software decode, renderer, PiP · E5 packaging, docs, sample app, distribution rehearsal · E6 1.0 release pack.
**Gate: PlayerApp starts after E3.** E4 and E5 run alongside the app's early milestones.

## Definition of done (every milestone)

- [ ] `scripts/verify.sh` passes: package builds and tests for iOS, iPadOS (simulator), macOS and visionOS (simulator) with zero warnings. `[auto]`
- [ ] License check passes (no GPL, no nonfree; see LIC-1). `[auto]`
- [ ] Public API is documented; DocC builds without warnings. `[auto]`
- [ ] Fixture corpus tests pass; nothing crashes under the sanitizers. `[auto]`

## BLD: building FFmpeg and its dependencies

- [x] BLD-1 One command (`scripts/build-all.sh`) builds every library for five slices: iOS device, iOS simulator, macOS, visionOS device, visionOS simulator. All arm64 only. From pinned source archives checked by SHA-256. (E0) **Evidence (2026-10-24):** `scripts/build-all.sh`: five arm64 slices from the SHA-256- and signature-verified FFmpeg 9.0.2 archive; clean rebuild took 2 min 21 s.
- [x] BLD-2 FFmpeg configured with `--disable-gpl --disable-nonfree --disable-programs --disable-doc --disable-autodetect --enable-audiotoolbox` (plus `--enable-videotoolbox` only in profiles that need it) and an explicit allow-list of demuxers, muxers, parsers, bitstream filters, decoders and encoders per profile. Version pinned (FFmpeg 9.0.x is current; 8.1.x is the fallback, decided after E-S1). (E0) **Evidence (2026-10-24):** `profiles/core.json` → `scripts/gen-config.py` → configure; `avformat_configuration()` shows no gpl/nonfree/version3 (test `configurationIsClean`).
- [x] BLD-3 Output is dynamic frameworks packaged as XCFrameworks (one framework or a few, decided in E-S1), with correct `@rpath` install names, `Info.plist`, `MinimumOSVersion`, `PrivacyInfo.xcprivacy`; only the public `av*`/`sw*` symbols exported. (E0) **Evidence (2026-10-24):** One framework `FFmpegLGPL` (2.7-2.8 MB per slice) in `build/FFmpegLGPL.xcframework`; `@rpath` install names, Info.plist, PrivacyInfo.xcprivacy; 983 exported symbols, all `av*`/`swr*`; links only system libraries.
- [ ] BLD-4 Frameworks are code-signed; an empty sample app that embeds them passes App Store validation for iOS, macOS and visionOS without warnings. `[auto]` (E5)
- [x] BLD-5 Profiles are declared as data in `profiles/*.json` (`core`, `extended`, `licensedAudio`); the build script generates both the configure flags and the license report from them. (E0) **Evidence (2026-10-24):** `profiles/{core,extended,licensedAudio,host-tools}.json` drive configure flags and `LICENSE-REPORT.md`.
- [ ] BLD-6 Size budget per slice (initial targets, calibrate in E0): `core` at most 8 MB, `core + extended + subtitles` at most 20 MB. (E0, E5)
- [x] BLD-7 `scripts/bootstrap.sh` lists and installs the build tools through Homebrew, no sudo, only after the owner approves. A full clean build takes under 30 minutes on this Mac; incremental builds are fast. (E0) **Evidence (2026-10-24):** `scripts/bootstrap.sh [--install]`; clean build 2 min 21 s (target 30 min). Tools installed 2026-10-24 with owner approval.
- [ ] BLD-8 Debug symbols (dSYMs) are produced and archived for every release. (E6)
- [ ] BLD-9 Optional dependencies are built only for the traits that need them: dav1d (AV1 software), libass with FreeType (FTL option), HarfBuzz and FriBidi (subtitles), libdovi (Dolby Vision profile 7 conversion). (E3, E4; moved from E0, see D-E11)

## LIC: licensing and compliance

- [x] LIC-1 `avutil_license()`, `avcodec_license()` and `avformat_license()` report LGPL 2.1 or later in every slice; a script fails the build if GPL strings or symbols of x264, x265, fdk-aac or other GPL/nonfree code appear. `[auto]` (E0) **Evidence (2026-10-24):** `scripts/check-licenses.sh` passes on all slices and fails on a tampered build.
- [ ] LIC-2 Dynamic linking only. A documented, tested procedure shows a customer rebuilding or replacing the FFmpeg framework and running the sample app against it. `[auto]` (E5)
- [ ] LIC-3 Every release ships a **source pack**: exact FFmpeg and dependency sources, our patches as diffs, and a `BUILD-INFO.txt` with the configure lines and tool versions, stored next to the binaries. (E5)
- [ ] LIC-4 Generated `ThirdPartyNotices` (component, version, license, source URL, checksum) is included in the package and available at runtime as structured data (`MediaEngine.acknowledgements`) so host apps can show it. `[auto]` (E5)
- [ ] LIC-5 EULA template drafted: does not forbid reverse engineering for debugging modifications to the LGPL parts, states the product uses FFmpeg under LGPLv2.1 and does not own it, spells "FFmpeg" correctly; attribution text for download pages and About screens. `[lawyer]` (E5)
- [ ] LIC-6 Patent profile document: every codec in each profile with its royalty status and licensing pool where known, and a statement that the integrator is responsible for patent licences in the profiles they enable. `core` avoids software decoders of pooled codecs; those live in `extended`/`licensedAudio`. **Launch default (RESEARCH.md §3.2):** Apple's decoders plus royalty-free or expired codecs only; VC-1, DTS/TrueHD and Dolby Vision 7 conversion are off until a lawyer clears them; H.264 Hi10P is out of scope. The document also covers trademark use (Dolby, DTS, Atmos names and logos). `[lawyer]` (E5)
- [ ] LIC-7 Decision D-E1 (license of our Swift layer) is made before E6, and the repository carries the matching `LICENSE` files. `[manual]` (E6)

## API: a Swift-friendly interface

Quick start, required to work exactly like this (E2):

```swift
import MediaEngine

let session = try await PlaybackSession(url: fileURL)   // probes and chooses the best path
let item = try await session.makePlayerItem()            // plain AVPlayerItem
player.replaceCurrentItem(with: item)                    // AVPlayerViewController / VideoPlayer
```

- [ ] API-1 The quick start above works with an MKV file in the sample app on iOS, macOS and visionOS, with no other setup (no bridging header, build phase, manual embed or framework search path). `[auto]` (E2)
- [x] API-2 Public API exposes no C types, raw pointers or FFmpeg identifiers; it uses Foundation, AVFoundation, CoreMedia and CoreGraphics types and `Locale.Language` for languages. `[auto]` (E1) **Evidence (2026-10-24):** `internal import FFmpegLGPL` everywhere; `scripts/check-public-api.sh` fails on public imports or FFmpeg types in public declarations; public model uses Foundation types and `Locale.Language`.
- [x] API-3 Swift 6 strict concurrency: public types are `Sendable` where sensible, sessions are actors or `@MainActor`, ThreadSanitizer is clean. `[auto]` (E1) **Evidence (2026-10-24):** Swift 6 mode; `swift test --sanitize=thread` passes all 46 tests (no data races).
- [x] API-4 `async`/`await` and `AsyncSequence` first; operations are cancellable and stop within 100 ms of cancellation. `[auto]` (E1) **Evidence (2026-10-24):** Tests `cancelledBeforeStart`, `cancelledDuringReads` (stops in under 500 ms) and the HTTP `cancellation` test.
- [x] API-5 One typed `MediaError` with stable cases, a plain-language `errorDescription` safe to show users and a technical `debugDescription`. (E1) **Evidence (2026-10-24):** `MediaError` with plain-language `errorDescription` (test `errorDescriptions`: no paths) and `debugDescription`.
- [ ] API-6 State is `@Observable` where a UI needs it. `MediaVideoView` wraps the software renderer for SwiftUI, UIKit and AppKit. (E4)
- [ ] API-7 A shared `PlaybackController` protocol (play, pause, seek, rate, current time stream, track selection) is implemented by both the AVPlayer path and the software path so apps can switch paths without changing UI code. (E4)
- [ ] API-8 SwiftPM **traits** switch optional features on and off (`Subtitles` on by default; `SoftwareDecoding`, `LicensedAudio`, `DolbyVision` opt-in), so unused binaries are not linked or embedded. Compile-time switching is proven (E0); swapping binaries needs the plug-in design in D-E11. (E4)
- [ ] API-9 Semantic versioning and an API-stability policy; breaking changes are detected with `swift package diagnose-api-breaking-changes` from 1.0. `[auto]` (E6)
- [ ] API-10 DocC for every public symbol, a "Play an MKV in five minutes" tutorial and a conceptual article on choosing the playback path. `[auto]` (E5)
- [x] API-11 Logging through `os.Logger`, privacy-safe by default, with an optional log handler. (E1) **Evidence (2026-10-24):** `os.Logger` (subsystem `dev.mediaengine`); FFmpeg's own log routed to it privately via a C callback; no stderr noise in test runs.
- [ ] API-12 At least four sessions open at the same time (iPad multi-window) without interference or shared mutable global state. `[auto]` (E2)

## PRB: probing

- [x] PRB-1 `MediaSource.probe()` returns `MediaInfo` in under 500 ms for a local file of any size (headers and index only). It includes container, duration, bitrate, title, tags, tracks, chapters and attachments. (E1) **Evidence (2026-10-24):** `MediaSource.probe()` under 500 ms for every fixture and for a source reporting 60 GB (test `sameResultEverywhere`); reads headers and the first packets only.
- [ ] PRB-2 Per track: type, codec name, profile and level, resolution, frame rate, bit depth, color primaries/transfer/matrix, HDR format (HDR10, HDR10+, HLG, Dolby Vision profile), audio channels/layout/sample rate, language (BCP-47), title and flags (default, forced, SDH, commentary). (E1) **Progress (2026-10-24):** Done for codec, profile, level, resolution, frame rate, bit depth, chroma, colour, HDR10/HLG, rotation, channels/layout, sample rate, language, titles, flags. **Not yet verified:** Dolby Vision (code reads the configuration record; no fixture), HDR10+ (not detected: it lives in the bitstream).
- [x] PRB-3 `info.playbackPlan` states per track which path will be used (native, remux, software, unsupported) and why; `info.requiredProfile` (and the per-track equivalent) names the codec profile needed, so an app can gate features without the package knowing about purchases. (E1) **Evidence (2026-10-24):** `PlaybackPlan` and `requiredProfile`: 12 planner tests plus fixture assertions (DTS/TrueHD report `.licensedAudio` and a silence warning; Hi10P reports out of scope).
- [x] PRB-4 Output matches `ffprobe` ground truth on the whole fixture corpus. `[auto]` (E1) **Evidence (2026-10-24):** `GroundTruthTests` compare every fixture with committed ffprobe JSON (`Fixtures/ground-truth/`); `scripts/check-ground-truth.sh` proves the JSON is real current ffprobe output.

## IO: byte sources

- [x] IO-1 `ByteSource` protocol (random-access read, length, optional prefetch hint, cancellation) lets the host supply SMB, WebDAV or any custom reader. Built-in sources for file URLs (including security-scoped URLs and files over 60 GB) and HTTP(S) with range requests. (E1) **Evidence (2026-10-24):** `ByteSource`, `DataByteSource`, `FileByteSource` (positional reads, security-scoped aware), `HTTPByteSource` (range requests); 60 GB reported size tested. Security-scoped URLs are untested until a device run (E2).
- [x] IO-2 A configurable read-ahead cache; network errors retry with backoff and surface as `MediaError`, never as a hang. `[auto]` (E1) **Evidence (2026-10-24):** HTTP chunk cache with read-ahead, retry with backoff on timeouts/5xx, permanent errors and missing range support surfaced as `MediaError`, `cancelPendingReads()` aborts blocked reads (HTTP tests).
- [ ] IO-3 The network-source work in PlayerApp (M8) needs no change to the package other than a `ByteSource` implementation. `[manual]` (E5)

## RMX: remux to AVPlayer

- [ ] RMX-1 `makePlayerItem()` plays MKV/WebM with H.264, HEVC (including HDR10 and HLG, and Dolby Vision 5 and 8 once RMX-11 is cleared) and hardware-decodable AV1, with AAC, AC-3, E-AC-3 (Atmos preserved), ALAC, FLAC, Opus and MP3 audio, inside `AVPlayerViewController` and `AVPlayerView`, with the system controls. `[sim]` `[device]` (E2)
- [ ] RMX-2 Audio AVPlayer cannot decode (Vorbis, PCM variants, and with `LicensedAudio` DTS and TrueHD) is decoded by the engine and re-encoded to AAC with Apple's AudioToolbox encoder, keeping up to 7.1 channels. (E2, E4)
- [ ] RMX-3 All audio tracks appear in the system audio menu as `AVMediaSelectionOption`s (HLS alternate renditions); only the selected one is processed. (E2)
- [ ] RMX-4 Text subtitle tracks (SRT, ASS/SSA, WebVTT, tx3g) appear in the system subtitle menu as WebVTT renditions. ASS styling is reduced to what WebVTT can express; full styling uses the overlay path (SUB-2). (E3)
- [ ] RMX-5 Seeking works to any position through the index; resume after seek within 500 ms on local files; files with a missing or broken index fall back to a scan. (E2)
- [ ] RMX-6 Time to first frame at most 1.5 s on a physical iPhone for a local 5 GB file (initial target, calibrate after E-S3). `[device]` (E2)
- [ ] RMX-7 Memory stays under a fixed budget (initial target 150 MB) during playback of any file; segment generation is on demand with bounded lookahead. `[auto]` (E2)
- [ ] RMX-8 Chapters appear in the system UI; title and cover-art attachment populate `externalMetadata` for Now Playing. (E3)
- [ ] RMX-9 Transport options: `.resourceLoader` (custom scheme) and `.loopbackServer`; `.lanServer` is added only if E-S4 proves AirPlay needs it. The server binds to loopback (or the specific interface while AirPlaying), uses a random port and an unguessable per-session path, serves only the open session and stops when the session ends. `[auto]` (E2)
- [ ] RMX-10 AirPlay behavior per transport is recorded (E-S4) and exposed as `session.airPlaySupport` so the host UI can react. `[device]` (E2)
- [ ] RMX-11 Dolby Vision signaling is correct for profiles 5 and 8; profile 7 is converted to 8.1 when the `DolbyVision` trait is on, otherwise falls back to the HDR10 base layer. Visible in `playbackPlan`. Dolby Vision signaling and any profile 7 conversion stay off until the legal review in LIC-6 clears them; until then Dolby Vision files play through their HDR10 base layer where one exists and `playbackPlan` states what is lost. `[device]` `[lawyer]` (E2)
- [ ] RMX-12 Variable frame rate, B-frame reordering and negative timestamps are handled; audio/video sync stays within 40 ms over a 3-hour file. `[auto]` (E2)
- [ ] RMX-13 Truncated or damaged files play what they can and never crash. `[auto]` (E2)

## SWD: software decode path

- [ ] SWD-1 `makeSoftwarePlayer()` decodes with FFmpeg (VideoToolbox whenever the codec and profile allow) and renders `CMSampleBuffer`s with `AVSampleBufferDisplayLayer`; audio goes through `AVSampleBufferAudioRenderer` and a render synchronizer for sync. (E4)
- [ ] SWD-2 Picture in Picture through `AVPictureInPictureController`'s sample-buffer content source on iOS, iPadOS and macOS; known macOS PiP scaling problems are tested. `[device]` (E4)
- [ ] SWD-3 Codecs in the `extended` profile: VP8/VP9, AV1 (dav1d), MPEG-2, MPEG-4 ASP, WMV (VC-1 stays off until legal clearance). H.264 is never software-decoded (Hi10P is out of scope). 1080p24 VP9 plays without dropped frames on an iPhone 15-class device (initial target; thermals checked in E-S6). `[device]` (E4)
- [ ] SWD-4 HDR content keeps 10-bit buffers and color attachments so the system tone-maps correctly. `[device]` (E4)
- [ ] SWD-5 Frame pacing and dropped-frame counters are exposed for diagnostics. (E4)

## SUB: subtitles

- [ ] SUB-1 Decodes text subtitles (SubRip, ASS/SSA, WebVTT, tx3g) and bitmap subtitles (PGS, DVB, VobSub) from containers. (E3)
- [ ] SUB-2 ASS/SSA rendered by libass into positioned bitmaps for a given time and video size, including fonts embedded in the container, CoreText font lookup, CJK and Indic fallback, and bidirectional text (HarfBuzz, FriBidi). `SubtitleOverlayView` draws them in sync with the controller's time. (E3)
- [ ] SUB-3 External subtitle files load through `SubtitleTrack(url:)`: SRT, WebVTT, ASS/SSA, plus text variants as time allows; delay offset supported. (E3)
- [ ] SUB-4 Encoding detection for external text files: UTF-8/16 with or without BOM, Windows-1250/1251/1252, ISO-8859-x, KOI8-R/U, GBK/GB18030, Big5, Shift-JIS, EUC-JP, EUC-KR; at least 95% correct on a fixture set covering Russian, Ukrainian, Chinese, Japanese, Korean and Western European; manual override API. `[auto]` (E3)
- [ ] SUB-5 External subtitles convert to WebVTT for the AVPlayer path. Whether they stay visible in PiP and over AirPlay is recorded per mechanism (feeds PlayerApp spike S2). `[device]` (E3)

## AUD: audio

- [ ] AUD-1 External audio files (`.mka .ac3 .eac3 .dts .aac .m4a .flac .mp3`) attach to a session with a sync offset on both paths. (E3)
- [ ] AUD-2 DTS, DTS-HD and TrueHD decoding exist only in the `LicensedAudio` module. Without it, such tracks are reported as unsupported with a clear reason, and the other tracks still play. (E4)
- [ ] AUD-3 5.1/7.1 content downmixes correctly to stereo and headphones; channel layouts are reported accurately. `[device]` (E4)

## PLT: platforms

- [x] PLT-1 `Package.swift` declares iOS 27, macOS 27 and visionOS 27 only. tvOS is never declared. (E0) **Evidence (2026-10-24):** `Package.swift` declares iOS 27, macOS 27, visionOS 27 only.
- [x] PLT-2 Builds and tests run on iOS and iPadOS simulators (including the iPhone Duo simulators), on macOS, and on the visionOS simulator. The visionOS 27.0 simulator runtime is installed. `[sim]` (E0) **Evidence (2026-10-24):** `scripts/verify.sh`: macOS, iPhone 18 Pro Max, iPad Air 13-inch (M4), iPhone Duo and Apple Vision Pro simulators, 6 tests each, zero warnings (1 min 47 s).
- [ ] PLT-3 visionOS is simulator-verified only. Release notes and the README state that visionOS has not been verified on hardware until a tester with a headset has run the device script. `[manual]` (E6)
- [ ] PLT-4 No code assumes a screen size or idiom; views adapt to containers (iPhone Duo, iPad windows, Mac windows, visionOS windows). `[sim]` (E4)
- [ ] PLT-5 Mac Catalyst is unsupported and documented as such. (E5)

## PRF: performance, robustness, security

- [ ] PRF-1 Benchmark suite (probe time, first frame, seek, CPU, memory, throughput) with stored baselines; a regression over 10% fails the check. `[auto]` (E2 onwards)
- [ ] PRF-2 Demux wrapper is fuzzed and run under AddressSanitizer, UBSan and TSan; at least 200 malformed samples (mutations of the corpus) cause no crash or hang. `[auto]` (E2)
- [ ] PRF-3 No leaks after 100 open/close cycles; an idle session uses essentially no CPU. `[auto]` (E2)
- [ ] PRF-4 A 60 GB file opens and seeks within the targets of RMX-5. `[device]` (E2)
- [x] PRF-5 Security: no network listeners except the session server in RMX-9, no file access beyond the opened source, FFmpeg's protocol list limited to what we expose (no `concat`, `file`, `subfile` surprises from container-referenced URLs). `[auto]` (E1) **Evidence (2026-10-24):** `SecurityTests`: no protocols compiled in (read or write), `file:`/`http:`/`concat:`/`subfile` locations cannot be opened, demuxer allow-list, no decoders for pooled codecs.
- [ ] PRF-6 Process for FFmpeg security fixes: monitor FFmpeg releases and advisories, rebuild, ship a patch release; target 14 days for critical fixes. `[manual]` (E6)

## DOC: documentation and sample

- [ ] DOC-1 README with the quick start, platform and license summary, and a link to DocC. (E5)
- [ ] DOC-2 Sample app (iOS, macOS, visionOS) shows: pick file → play, track switching, external subtitles and audio, software path, PiP, AirPlay, profile gating, acknowledgements screen. (E5)
- [ ] DOC-3 Integration guide: gating features with `requiredProfile`, choosing traits, size impact, App Store submission notes, how to replace the FFmpeg framework (LGPL), troubleshooting. (E5)
- [ ] DOC-4 `CHANGELOG`, versioning policy and support policy (supported OS versions, response times). (E6)

## DST: distribution and selling

- [ ] DST-1 Releases are XCFramework-based Swift packages with checksums, signed, with semantic versions and a changelog. `[auto]` (E6)
- [ ] DST-2 One delivery channel is chosen and rehearsed end to end on a clean Mac and a fresh user account: a customer receives access, adds the package in Xcode, builds the sample, and updates to a new version. Candidates and risks are in RESEARCH.md §4 (D-E2). `[manual]` (E-S5, E5)
- [ ] DST-3 No runtime license checks or DRM in the library (they conflict with LGPL expectations and annoy integrators); access control happens at delivery (D-E3). `[manual]` (E5)
- [ ] DST-4 Commercial wrapper: the EULA, price tiers, refund and support policies, security-contact address and vulnerability-disclosure policy are drafted. Seller entity, VAT/merchant-of-record and liability questions are reviewed with an accountant/lawyer (D-E4, D-E5). `[lawyer]` (E6)
- [ ] DST-5 The sales page carries the required FFmpeg attribution and the source-pack link on every page with a download. `[manual]` (E6)

## ANM: anime and fansub compatibility

Anime releases stress exactly what users expect a good MKV player to get right.

- [ ] ANM-1 Fixture corpus of anime-style files (generated, or supplied by the owner): HEVC 10-bit + FLAC + ASS with embedded fonts; H.264 8-bit + AAC + ASS; dual audio (Japanese, English) with a "signs and songs" subtitle track; OP/ED chapter markers; variable frame rate; interlaced or telecined DVD-resolution video with non-square pixels; ordered chapters with linked segments; Xvid AVI; OGM; RMVB. `[auto]` (E1 onwards) **Progress (2026-10-24):** Fixtures so far: H.264 + two ASS tracks (one forced) + font and cover attachments + OP/ED chapters, HEVC Main 10 HDR10, DTS/TrueHD, FLAC. Still missing: variable frame rate, interlaced/telecined, ordered chapters, Xvid AVI, OGM, RMVB.
- [ ] ANM-2 **Ordered chapters and linked segments** are implemented by the engine (FFmpeg does not support them): editions play in their stored order, including segments in sibling files when the host grants access to the folder; a missing segment is reported to the user instead of silently skipping content. `[auto]` (E3)
- [ ] ANM-3 ASS fidelity: karaoke, `\clip`, vector drawings, blur, rotation, font attachments and font fallback render like the libass reference on the same frames (image-diff threshold agreed in E-S8). `[auto]` (E3)
- [ ] ANM-4 Chapter titles and types are exposed so an app can offer "Skip Opening/Ending", and track metadata supports per-series preferences ("Japanese audio, English subtitles", "signs and songs only"). (E3)
- [ ] ANM-5 FLAC stays lossless on the AVPlayer path (decode, then Apple's ALAC encoder); a test proves the samples are bit-identical. (E2)
- [ ] ANM-6 H.264 High 10 (Hi10P) is out of scope by owner decision (2026-10-24): such files report an unsupported video format with a clear reason, and the engine ships no software H.264 decoder. HEVC 10-bit (hardware) with heavy ASS plays smoothly on a physical iPhone and on a Mac. `[device]` (E2)
- [ ] ANM-7 Interlaced and telecined content: field order, pulldown flags and pixel aspect ratio are honored; deinterlacing uses Apple frameworks or our own code, never FFmpeg's GPL filters (such as `yadif`), which would make the build GPL. `[auto]` (E4)
- [ ] ANM-8 Legacy anime containers (AVI/Xvid, OGM, RMVB, FLV) are in `extended` and reported by `playbackPlan`; they are the natural Pro formats. (E4)

## Spikes (time-boxed; each ends with a written result in docs/)

- [x] E-S1 Build FFmpeg 9.0.x (LGPL, minimal) for macOS arm64, iOS simulator and visionOS simulator; wrap as XCFramework; call `avformat_open_input` from a tiny Swift package on an MKV fixture; decide one framework or several, and 9.0 vs 8.1. **Evidence (2026-10-24):** Result: FFmpeg 9.0.2 builds as LGPL for all five slices; one merged dynamic framework works; Swift opens and demuxes MKV (H.264/AAC/FLAC/SRT/chapters; HEVC/AC-3) through custom I/O with no H.264/HEVC/AC-3 decoder compiled in. Decision: single framework, FFmpeg 9.0.x.
- [ ] E-S2 SwiftPM traits with binary targets and conditional dependencies on Swift 6.4: unused binaries not linked or embedded; Xcode auto-embeds the dynamic frameworks. **Partial result (2026-10-24):** traits reach the code as compile-time conditions for four combinations (`scripts/check-traits.sh`). Traits are additive only, so they cannot replace the core binary with a bigger one; see D-E11. Auto-embedding is untested until a sample app exists (E5).
- [ ] E-S3 Remux to fragmented MP4 over HLS into AVPlayer on macOS first: H.264+AAC, then HEVC HDR10 + E-AC-3. Learn AVPlayer's strictness (codec tags, init segments, DV boxes). Calibrate RMX-5/6/7.
- [ ] E-S4 AirPlay of that stream on a real Apple TV or HomePod: resource-loader vs loopback server vs LAN-reachable server; what works, what needs the Local Network permission. `[device]`
- [ ] E-S5 Private-distribution rehearsal: private repo plus binary target on a clean Mac; compare Git-hosted source+binary, authenticated binary hosting and a package registry. Community reports say authenticated binary downloads in SwiftPM are fragile. `[manual]`
- [ ] E-S6 Software path: VP9 and AV1 (dav1d) decode, sample-buffer rendering and PiP on the real iPhone; battery and thermals. `[device]`
- [ ] E-S7 libdovi (Rust) for visionOS: the visionOS targets are Tier 3 in Rust. Either build it or drop Dolby Vision 7 conversion on visionOS.
- [ ] E-S8 libass with the CoreText font provider on all platforms, embedded fonts, CJK/Indic/RTL samples.

## Open decisions

| ID | Decision | Default until answered |
|---|---|---|
| D-E1 | License model of our Swift layer: proprietary EULA, source-available, or open source | Proprietary EULA over LGPL FFmpeg binaries |
| D-E2 | Delivery channel: private Git repo, authenticated binary hosting, or a Swift package registry | Decided by E-S5 |
| D-E3 | Runtime license checks | None |
| D-E4 | Selling entity and payment stack (merchant of record for VAT) | Decide before E6 |
| D-E5 | Pricing and tiers (indie, studio, enterprise) | Decide before E6 |
| D-E6 | Product name (must not contain "FFmpeg"; check trademarks and package names) | Placeholder `MediaEngine` |
| D-E7 | FFmpeg branch: 9.0.x or 8.1.x | **Decided: 9.0.x** (9.0.2 builds and passes all tests; E-S1, 2026-10-24) |
| D-E8 | Which codecs go in `core`, `extended`, `licensedAudio` | Draft in `profiles/`, reviewed by a lawyer |
| D-E9 | Approve downloading the visionOS simulator runtime | Approved and installed 2026-10-24 (visionOS 27.0, Apple Vision Pro simulator) |
| D-E11 | How optional codec profiles are packaged. Traits are additive only, so they cannot swap the core binary for a bigger one. Candidate: each optional profile is a separate self-contained framework with hidden internal symbols and a small C interface that the engine calls (plug-in pattern); alternative: one SwiftPM product per profile variant | Decide in E4 after a spike |
| D-E10 | Approve installing build tools (meson, ninja, cmake, Rust, gpg) | Approved and installed 2026-10-24 |
