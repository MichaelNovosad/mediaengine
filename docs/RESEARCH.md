# MediaEngine research (2026-10-24)

Tags: **[SDK]** measured on this Mac · **[web]** from web sources (links in §8) · **[know]** my own knowledge, not verified. Nothing here is legal advice.

## 1. What can be done

| Goal | Verdict | Evidence / next step |
|---|---|---|
| Own LGPL FFmpeg as XCFrameworks for iOS, macOS, visionOS | Feasible, standard cross-compilation | FFmpeg 9.0.2 is current (2026-09-18), 8.1.3 is the newest patch of the previous branch. [web] Spike E-S1 |
| Swift-friendly API, five-line quick start | Feasible | Design in the acceptance criteria; AVPlayerItem as the hand-off type |
| MKV through AVPlayer by remuxing | Plausible; community reports it working with HDR and Atmos | Anecdotal. [web] Spike E-S3. AirPlay of the result is unproven (E-S4) |
| Optional features without bloating apps (traits) | Likely; SwiftPM is 6.4 here, traits arrived in Swift 6.1 | [SDK] [know]. Spike E-S2 checks traits plus binary targets |
| visionOS | Builds: visionOS 27 SDK and simulator SDK are installed. The visionOS 27.0 simulator runtime was installed on 2026-10-24. No device available | [SDK]. Decision D-E9 |
| Dolby Vision profile 7 conversion on visionOS | Risky: the Rust visionOS targets are Tier 3 (unofficial) | [web]. Spike E-S7; may be dropped on visionOS |
| Selling it | Possible, with LGPL obligations (§2) and patent care (§3) | Needs a lawyer before the first sale |
| Private distribution through SwiftPM binary targets | Fragile: community reports problems with authenticated downloads, redirects and headers | [web]. Rehearse in E-S5 (§4) |

## 2. LGPL and selling a package built on FFmpeg

FFmpeg's own compliance checklist [web: ffmpeg.org/legal.html]:

- Link FFmpeg **dynamically**.
- Distribute the FFmpeg source that matches your binaries, a `git diff` of any changes, and a text file with the build/configure line, hosted next to the binaries.
- Build without `--enable-gpl` and `--enable-nonfree`; avoid GPL libraries such as libx264; re-check any LGPL library you add.
- EULA: remove any ban on reverse engineering; say you do not own FFmpeg and where its owners can be found; state that the program uses FFmpeg under the LGPLv2.1.
- Credit FFmpeg with a source link on every page that offers a download and in the About box; spell it "FFmpeg"; prefixes or suffixes on library names are fine, obfuscated renames are not.

What this means for a product:

- **You can sell** the Swift layer (under a license you choose), the prebuilt and tested XCFrameworks, updates, documentation, support and the profile/licensing work.
- **You cannot** prevent customers from replacing the FFmpeg part, studying it, or redistributing FFmpeg itself, and you cannot make the library refuse to run with a different build. So: no runtime license checks inside the library; control access at delivery.
- Combined, the customer's own app stays closed-source, provided FFmpeg is dynamically linked and replaceable.

Components we expect to ship, with the license each is believed to carry:

| Component | License | Source |
|---|---|---|
| FFmpeg 9.0.x | LGPL 2.1 or later when built without GPL/nonfree flags | [web] |
| dav1d 1.5.4 (AV1 software decode) | BSD-2-Clause | [web: Homebrew metadata] |
| libass 0.17.5 (ASS rendering) | ISC | [web: Homebrew metadata] |
| FreeType | FreeType License or GPLv2: choose the FreeType License | [know] |
| HarfBuzz | MIT-style | [know] |
| FriBidi | LGPL 2.1 | [know] |
| libdovi (Dolby Vision 7 to 8.1) | MIT or Apache-2.0 | [web: AetherEngine README] |

Homebrew's own `ffmpeg` formula is GPL-3.0-or-later [web], so it is only a developer tool for generating test files.

## 3. Patents (what D-3 was about)

Source code licenses (LGPL) and patents are separate things. The FFmpeg team says it does not know whether its code uses patented algorithms, that patent safety depends on your country, and that commercial products may face fees from patent holders, naming MPEG LA as actively collecting. [web: ffmpeg.org/legal.html]

Practical consequences for the engine:

- Video decoding on Apple platforms goes through VideoToolbox and audio encoding through AudioToolbox, so Apple's own licensing covers the common codecs.
- AC-3 and E-AC-3 are decoded by AVPlayer itself, not by FFmpeg.
- Software decoders for pooled codecs (H.264 for Hi10P, MPEG-4 ASP, VC-1, MPEG-2) and the DTS/TrueHD decoders are the patent-sensitive part. They are isolated in the `extended` and `licensedAudio` profiles and are separate traits, so an integrator opts in knowingly and a lawyer can review each list.
- Older forum posts say Infuse gated AC-3 and DTS audio to Pro because of licence fees. [web, dated] I could not find authoritative information on DTS or Dolby fees for FFmpeg-based decoders.

### 3.1 Why VLC does not pay, and why that does not transfer to us

- VideoLAN's position: "Neither French law nor European conventions recognize software as patentable", so it holds no software-patent licences. Its president added that VideoLAN sells nothing and earns nothing. A VideoLAN developer wrote that they never went to court on this and that end users are responsible for compliance. [web]
- That position rests on being a non-profit, EU-based, free and software-only. A paid Pro unlock and a paid SDK distributed through the App Store (including the US) have none of those protections, and patents are per country.
- Writing our own decoder does not remove patent exposure. It only removes the code-license question, because a patent covers the method, not the source code.

### 3.2 Strategy (owner question, 2026-10-24)

1. Let Apple's decoders decode (VideoToolbox, AudioToolbox, AVPlayer): H.264, HEVC, AAC, AC-3, E-AC-3, Dolby Vision. The remux path only repackages bytes. [know] A lawyer must confirm that apps using system decoders are covered.
2. Use our own decoders only for royalty-free or expired codecs: AV1, VP9, Opus, Vorbis, FLAC (pool claims exist for VP9 and AV1 [know]); MP3 and MPEG-2 (last US MPEG-2 patent expired 2018 [web]); MPEG-4 ASP (last patent reportedly expired July 2026, single source [web]); E-AC-3 (last patent reportedly expired 2026-01-30, unconfirmed [web]).
3. Isolate the rest and ship it off by default: H.264 Hi10P software decode, VC-1, DTS, DTS-HD, TrueHD (no authoritative expiry data found), Dolby Vision profile 7 conversion (highest sensitivity: forum posts say Dolby expects a licence for anything in the Dolby Vision chain; no Dolby statement found [web]).
4. Turn a module on only after a lawyer's opinion and once there is revenue to pay a licensor who asks. A lawyer may also advise on per-storefront availability, since patents are territorial.
5. Do not use Dolby, DTS or Atmos marks or logos as branding; plain descriptive mentions need review.

### 3.3 H.264 Hi10P (owner question, 2026-10-24)

**Decision (2026-10-24): the owner dropped Hi10P from scope. The engine ships no software H.264 decoder, so none of the AVC-pool questions below apply to v1; the notes stay for reference if the decision is revisited.**

- Hi10P is the High 10 profile of H.264/AVC, so it belongs to the same Via LA AVC patent pool as all H.264 decoding. It is not a separate patent family.
- Expiry: one secondary source puts the last major US patent (US 7826532) at about 2027-11-29, with other patents running into the 2030s depending on the country. [web] The owner mentioned 2040; I found nothing supporting that (it may be a mix-up with H.266/VVC). Source needed. Either way the patents are in force today.
- Apple does not decode it for us: hardware decode of Hi10P on Apple Silicon is unconfirmed, Infuse users report software fallback on M-series Macs, and VLC dropped 10-bit H.264 on macOS in 2018. [web] So Hi10P means our own software decoder, which is where our exposure starts. Plain 8-bit H.264 decoded by AVPlayer stays under Apple's licence.
- Via LA's published AVC terms list the first 100,000 units per year at $0.00; older material shows $0.20 per unit above that, $0.10 above 5 million units, and an enterprise cap of $9.75M through 2025. [web] Not confirmed: whether this applies to a free App Store app or an SDK, how units are counted, or the cap after 2025.
- Action: ask Via LA for written terms for a software player app and for an SDK, then decide D-E8 / PlayerApp D-12. Until then Hi10P stays in the `extended` profile, off by default.

### 3.4 Anime and fansub files

| Layer | What anime releases use | Where it lands in our plan |
|---|---|---|
| Containers | MKV (dominant), MP4 (simulcast rips), older AVI/Xvid, OGM, RMVB, FLV, TS/M2TS captures | MKV/MP4/TS free; AVI, OGM, RMVB, FLV in `extended` (natural Pro formats) |
| Video | H.264 8-bit (most), H.264 Hi10P (fansub standard for years), HEVC 8/10-bit, AV1, Xvid, MPEG-2 (DVD/TV), VC-1 | HEVC/H.264 8-bit by remux; AV1 on newer chips by hardware; Xvid, MPEG-2 by the software path; VC-1 off until cleared; Hi10P out of scope |
| Audio | AAC, FLAC (Blu-ray rips), Opus, AC-3/E-AC-3, DTS/TrueHD, Vorbis (old) | See §3.2; FLAC kept lossless via ALAC (ANM-5) |
| Subtitles | ASS/SSA with typesetting, karaoke and embedded fonts; SRT; PGS and VobSub from discs; "signs and songs" tracks | libass path (SUB-2, ANM-3) |
| Structure | OP/ED chapters, dual audio, variable frame rate, interlaced or telecined DVD sources, non-square pixels, **ordered chapters and linked segments** | ANM-2, ANM-4, ANM-7 |

Ordered chapters are the trap: FFmpeg's Matroska reader does not implement them (its feature request is still open) while mpv does, and the Matroska spec says players must play an ordered edition in its stored order. [web] We have to implement it ourselves. FFmpeg's deinterlacing filters such as `yadif` are GPL [know], so deinterlacing must use Apple frameworks or our own code.

## 4. Distribution options (all to be rehearsed in E-S5)

| Channel | Pros | Cons |
|---|---|---|
| Private Git repository containing `Package.swift` with local XCFramework zips | Xcode handles Git credentials well; simple versioning | Large binaries in Git (use releases or LFS); each customer needs repo access |
| `binaryTarget` with a URL on authenticated hosting | Small repo; clean releases | Community reports: `.netrc` auth, redirects and `Accept` headers are fragile; a 2024 report of a 401 on a signed XCFramework behind Artifactory. [web] |
| Swift package registry (own or hosted) | Native auth model and versioning | More infrastructure; less common. Not researched in depth |
| Zip download plus manual integration | Always works | Poor developer experience; against the "easy setup" goal |

Selling and access: a merchant of record (Paddle, Lemon Squeezy and similar) handles VAT and invoices; Stripe leaves tax to you. Access is granted by repo/registry credentials after purchase. [know] Not researched in depth.

## 5. Design notes

- **Layers:** private C bridge to the FFmpeg frameworks → `MediaCore` (probe, `ByteSource`, packets) → `MediaEngine` (sessions, remux server, software player, `PlaybackController`) → `MediaSubtitles` → optional SwiftUI/UIKit/AppKit views. Only the top layers are public.
- **Profiles as data:** `profiles/*.json` drive both the FFmpeg configure line and the license report, so what we ship and what we say we ship cannot drift.
- **Remux details to prove:** fragmented MP4 over HLS, codec tags (`hvc1`, `dvh1`), Dolby Vision config boxes, on-demand segments built from the index, alternate audio and subtitle renditions so the system menus show every track.
- **Software path:** FFmpeg demux/decode, VideoToolbox where possible, `AVSampleBufferDisplayLayer` for video, `AVSampleBufferAudioRenderer` with a render synchronizer for audio; PiP through the sample-buffer content source (reported to be fragile on macOS). [web]
- **Build host gaps:** Xcode 27.1 and clang are present; `meson`, `ninja`, `cmake`, Rust and `gpg` are not. `nasm` is not needed on arm64. macOS 27 is Apple-silicon only, so no x86_64 slices. [SDK] [know] Verify FFmpeg archives by SHA-256 since `gpg` is absent.
- **Security:** limit FFmpeg's enabled protocols so a crafted container cannot make it read other files or open URLs.

## 6. visionOS

SDK `xros27.0` and `xrsimulator27.0` are installed; the visionOS 27.0 simulator runtime (7.5 GB, with an Apple Vision Pro simulator) was installed on 2026-10-24, leaving about 37 GB of disk free. [SDK] Because nobody has a headset, visionOS stays simulator-verified; the README must say so until a tester runs the device script.

## 7. Risks

1. AirPlay of a remuxed MKV may need a LAN-reachable server or may only work as mirroring (E-S4).
2. AVPlayer is strict about HLS/fMP4; HDR and Dolby Vision signaling may take iteration (E-S3).
3. Patent exposure in the software codecs and DTS/TrueHD (profiles, lawyer).
4. Private SwiftPM delivery may force a different channel than first intended (E-S5).
5. Rust Tier 3 targets for visionOS (E-S7).
6. Ongoing cost: FFmpeg security releases need a rebuild-and-ship process (PRF-6).

## 8. Sources

- [FFmpeg legal page](https://ffmpeg.org/legal.html) · [FFmpeg downloads](https://ffmpeg.org/download.html)
- [SwiftPM binary target authentication discussions](https://forums.swift.org/t/spm-support-basic-auth-for-non-git-binary-dependency-hosts/37878?page=3) · [private GitHub release assets](https://forums.swift.org/t/swiftpm-binary-dependency-in-private-github-release/52514)
- [Rust visionOS target support](https://doc.rust-lang.org/rustc/platform-support/apple-visionos.html)
- [AetherEngine](https://github.com/superuser404notfound/AetherEngine) · [MPVKit](https://github.com/mpvkit/MPVKit) · [Emby thread on remuxing MKV to fMP4 HLS](https://emby.media/community/topic/142147-atmos-playback-now-works-with-mkv-files)
- [Fluendo on commercial FFmpeg codec licensing](https://fluendo.com/fluendo-ffmpeg-enabler) (vendor view)
- [VideoLAN legal page](https://www.videolan.org/legal.html) · [VLC and codec patents (Streaming Media)](https://www.streamingmedia.com/Articles/News/Online-Video-News/New-VLC-Player-Release-Incorporates-HEVC-and-VC9-Playback-93354.aspx) · [VideoLAN forum on commercial use](https://forum.videolan.org/viewtopic.php?p=540748)
- [MPEG-2 patent expiry (TechRepublic)](https://www.techrepublic.com/article/mpeg-2-patent-expiration-opens-door-for-royalty-free-use/) · [E-AC-3 patents (Phoronix)](https://www.phoronix.com/news/Dolby-Digital-Plus-E-AC3-2026) · [Dolby Vision licensing discussion (Emby forum)](https://emby.media/community/topic/133256-whether-emby-is-forever-dolby-licensed)
- Hi10P and anime: [Via LA AVC/H.264 program](https://www.via-la.com/licensing-programs/avc-h-264/) · [Via LA AVC briefing (2022)](https://via-la.com/wp-content/uploads/2025/09/avcweb.pdf) · [video codec patent expiry](https://braindetox.kr/en/posts/video_codec_patent_expiry.html) · [Infuse Hi10P on Apple Silicon](https://community.firecore.com/t/add-h-264-hi10p-hardware-decoding-support-on-macos/58028) · [VLC dropping 10-bit H.264 on macOS](https://mailman.videolan.org/pipermail/vlc-commits/2018-May/049780.html) · [FFmpeg ordered-chapters ticket](https://fftrac-bg.ffmpeg.org/ticket/3123) · [Matroska chapters spec](https://www.matroska.org/technical/specs/chapters/index.html)
- Local probes: `swift package --version`, `xcodebuild -showsdks`, `simctl list runtimes`, Homebrew formula metadata.

## 9. E0 findings (2026-10-24)

- **Build:** FFmpeg 9.0.2 (SHA-256 and signature verified against the release key `FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8`) builds for all five arm64 slices in about 30 s each; a clean `build-all.sh` takes 2 min 21 s. Core framework is 2.7-2.8 MB per slice and links only system libraries (AudioToolbox, CoreFoundation, libz, libbz2).
- **Single framework works:** the static libraries are force-loaded into one dynamic `FFmpegLGPL.framework`, exporting only `av*`/`swr*` (983 symbols). Public headers are copied with their `#include "libavutil/..."` lines rewritten to `<FFmpegLGPL/libavutil/...>`, which makes the Clang module import cleanly (checked with `-Werror=incomplete-umbrella`).
- **Probing needs no decoders:** with no H.264, HEVC, AC-3 or AAC decoder compiled in, `avformat_find_stream_info` still returns codecs, languages, titles, chapters and duration (parsers do the work). Pixel format and bit depth stay unspecified, so PRB-2 (bit depth, HDR) must come from our own parsing of SPS/VPS/sequence headers or from Matroska colour elements (E1).
- **Traits are additive only.** They switch Swift code at compile time (verified for four combinations) but cannot replace the core binary with a bigger one. Optional codec profiles therefore need the plug-in packaging in D-E11.
- **Pitfalls hit:** (1) FFmpeg's configure needs `--host-cc` with the macOS SDK when the toolchain clang is invoked by path; (2) `lavfi` is an input device (`--enable-indev`), and fixture generation needs the `wrapped_avframe` decoder and `ffmetadata` demuxer; (3) `grep -q` in a `pipefail` pipeline reports false failures (SIGPIPE), so scripts avoid it; (4) SwiftPM's default trait is called `default`; (5) simulator test runs read fixtures from the host filesystem through `#filePath`, which works for iOS, iPad, Duo and visionOS simulators.
- **Developer tools without Homebrew:** `scripts/build-host-tools.sh` builds `ffmpeg`/`ffprobe` from the same pinned source, using Apple's VideoToolbox and AudioToolbox encoders to make H.264/HEVC/AAC fixtures. No GPL encoder and no Homebrew ffmpeg are needed.

## 10. E1 findings (2026-10-24)

- **Probing without decoders works well.** Codec, resolution, frame rate, languages, titles, dispositions, chapters, attachments and colour tags come from FFmpeg's demuxers and parsers. Profile, level and bit depth for H.264, HEVC and AV1 come from our own reader of the `avcC`, `hvcC` and `av1C` configuration records (`Internal/Extradata.swift`), because no decoder is compiled in. Results match the committed `ffprobe` output for all five fixtures.
- **Channel layouts need a fallback.** Without a decoder, mono and stereo AAC arrive with an unspecified channel order; the probe substitutes the standard layout for the channel count so it reads "mono"/"stereo" like ffprobe.
- **Language tags need a table.** Foundation understands ISO 639-2/T codes (`deu`, `fra`, `zho`) but not the bibliographic ones many files still carry (`ger`, `fre`, `chi`), and it treats `und` oddly. `Internal/Languages.swift` maps the 20 bibliographic codes and drops `und/mul/zxx/qaa-qtz`.
- **HDR10 is detected from the Matroska colour element** (PQ transfer). Hardware encoders can drop these tags (VideoToolbox did), which the fixture script works around with a stream-copy pass. Dolby Vision is read from the configuration record when present, but no fixture exists yet; HDR10+ lives in the bitstream and is not detected.
- **Attachments appear in two shapes.** Fonts are attachment streams; images such as `cover.jpg` surface as attached-picture video streams. Both are reported as attachments, never as tracks.
- **Blocking I/O stays off Swift's thread pool.** FFmpeg's reads are synchronous, so probing runs on a GCD thread, with a cancellation flag the read callback polls and `ByteSource.cancelPendingReads()` for in-flight network requests. Cancelling a probe finishes in well under 500 ms in tests.
- **HTTP testing without a network.** A `URLProtocol` stub serves ranges, injects 503s and delays, so retries, caching, missing range support and cancellation are tested deterministically on macOS and all simulators.
- **Open for E2:** security-scoped URLs and iCloud placeholders need a device run; whether AVPlayer accepts FLAC and Opus in fragmented MP4 directly (the plan currently transcodes them); VP9 stays "software, extended profile" until VideoToolbox support is tested; AV1 hardware detection uses `VTIsHardwareDecodeSupported` (simulators may report differently from devices).

## 11. E2 findings (2026-10-24)

- **Design that works:** video-only HLS playlist plus one audio-only playlist per track (alternate renditions), fragmented MP4 segments cut at video keyframes from the Matroska index, served from a loopback server. The init segment comes from FFmpeg's MP4 muxer; media fragments (`moof`/`mdat`) are written by our own Swift code so any segment can be built alone and in any order with exact `tfdt` values.
- **Verified by AVFoundation itself:** the assembled fragmented MP4 decodes frame-exact (video) and full-length (audio) through `AVAssetReader`; AVPlayer plays, seeks and finishes through HLS for H.264, HEVC and HLG.
- **HEVC must be tagged `hvc1`** (FFmpeg defaults to `hev1`); we set the tag in the init segment.
- **No edit list.** FFmpeg wrote an `elst` with a 2 ms empty edit; AVFoundation applied it, shifted the timeline by about 42 ms and produced one extra frame. `use_editlist=0` fixes it; our fragments already carry exact timestamps.
- **Priming packets.** AAC/AC-3 streams start with packets at negative timestamps (about -44 ms). They must be kept (decoder warm-up, A/V alignment), so the whole presentation is shifted by the largest negative start (one global shift for all tracks) and the first window rewinds by reopening the file.
- **Durations from dts deltas.** Matroska timestamps are rounded to milliseconds individually; summing rounded per-frame durations would drift by tens of milliseconds per segment, dts deltas do not.
- **HDR10 over HLS is unresolved.** See PROGRESS.md. Facts: PQ is rejected by AVPlayer's HLS path, including FFmpeg's own HLS output; HLG and 10-bit SDR play; the same PQ stream plays as a local fMP4. Hypotheses to test with real HDR10 rips: SEI mastering/CLL metadata in the bitstream, 4K/level, display state.
- **Swift/SDK facts:** `AVPlayerItem` is main-actor isolated (so `makePlayerItem()` is `@MainActor`); several AVAssetReader and AVPlayerItemVideoOutput calls are deprecated in the 27 SDK.

## 12. E2.4 findings: audio transcoding (2026-10-24)

- **Lossless ALAC is the only transcode target.** AAC's encoder delay would put priming samples at the start of every independently encoded segment. ALAC has none, so each segment is decoded and encoded from scratch and the pieces join sample-exactly (tested).
- **Use FFmpeg's native ALAC encoder, not AudioToolbox's `alac_at`.** `alac_at` pads a short final frame with silence (3,456 extra samples in a 3-second test), which would stretch every segment, and rejected the 24-bit setup. The native encoder writes the short frame as is. ALAC is open (Apple released it under Apache-2.0 with a patent grant); the core profile now includes the `alac` encoder (framework size unchanged at 2.7-2.8 MB).
- **Stateless codecs only, for now.** FLAC and PCM decode from any packet; Opus and Vorbis keep state and need pre-roll (read the end of the previous segment) before their segments can be transcoded cleanly.
- **Lazy by design.** Window building keeps the source audio packets and transcodes a track only when the player requests it, so unselected tracks cost nothing.
- **AVFoundation's audio menu shows the language name** (from `LANGUAGE`), not our `NAME`; same-language tracks will look identical in the system menu.

## 13. E2.4b findings: Opus and Vorbis, and the lazy Matroska index (2026-10-24)

- **Opus and Vorbis decoders keep state, so a segment cannot be decoded cold.** The first frames after a cold start differ from the same frames in a continuous decode (overlap-add and prediction history are missing). The fix is decoder pre-roll: the window builder starts reading at the last video keyframe at or before `segment start - pre-roll`, hands the audio packets that precede the segment to the decoder, and discards the frames they produce. The output then starts at the first decoded frame that belongs to the segment.
- **Pre-roll lengths found by measurement** (`AudioTranscodeTests.prerollSegments`, comparing a segment against the same stretch of a whole-file transcode): Vorbis is sample-exact with 0.2 s (0 of 528,384 samples differ). Opus needs more: with 0.2 s some samples still differed, 0.5 s leaves 274 of 576,000 samples different, worst 256 in the 32-bit domain (about -138 dBFS, residual decoder-state noise, inaudible). The cold case (no pre-roll) differs clearly, which the test also asserts, so the test would notice if pre-roll silently stopped working. Constants: `AudioTranscoder.prerollSeconds` (opus 0.5, vorbis 0.2, everything else 0).
- **Opus carries codec delay in the container.** Matroska stores a `CodecDelay` and per-block discard padding; FFmpeg exposes them as `AV_PKT_DATA_SKIP_SAMPLES` side data on the packet. `MediaPacket.skipStart/skipEnd` carry it to the decoder, which trims the 80 ms pre-skip at the start of the file and the end padding. The pre-roll start also needs `pkt_timebase` set on the decoder so timestamps survive.
- **Where a transcoded segment starts.** Taken from the first decoded frame's pts, not from the packet pts: for Opus the packet pts is before the trimmed audio. Segment audio and video then stay aligned to within one audio frame (tested by `startsAreAligned` with a 0.12 s bound that covers video reorder delay plus the longest audio frame).
- **Matroska Cues are loaded lazily.** After `avformat_open_input` and `find_stream_info` the index at the end of the file is usually not read yet, so `av_index_search`-style keyframe lists contained only the first cluster: a 14-second file produced one segment and seeks went to the start. Fix: `PacketReader.keyframeTimestamps(stream:loadingIndexUpTo:)` first performs a seek to the end of the duration, which forces FFmpeg to read the Cues, then lists the index. `RemuxSession.looksComplete(keyframes:duration:)` sanity-checks the result (the first keyframe is within 10 s of the start and no gap, including the one to the end of the file, is longer than 60 s), and files that fail it (missing or broken Cues) fall back to a packet scan. Tests: `KeyframeIndexTests`.
- **Not yet covered:** multichannel (5.1/7.1) Opus and Vorbis (channel mapping families other than 0/1 are untested), Opus at 44.1 kHz source rates (FFmpeg decodes at 48 kHz), Vorbis with changing block sizes across the file start.

## 14. E2.5 findings: hardening, B-frames and memory (2026-10-24)

- **B-frame video did not open at all, and no fixture noticed.** Matroska stores presentation times only. FFmpeg derives decode times from them once it has seen `delay` packets (and again after every seek), so the first reordered frames arrive without one; our fallback `dts = pts` then produced a sequence that goes backwards, and the MP4 muxer refused it ("mp4 write failed: Invalid argument"). All fixtures were encoded without B-frames; the benchmark file (a generated 3-hour H.264 High file with `-bf 2`) found it. Fix: `ReorderModel` (`Remux/DecodeTimestamps.swift`) restores decode times from the presentation times of one run of packets: `dts[i] = sorted pts[i - delay]`, the first `delay` packets one frame earlier each. `delay` is the larger of what the run shows and the decoder's declared `video_delay`, measured once on the first GOP at open; every segment window is repaired with the same model. Windows built apart join to within 1 ms. The global timestamp shift now includes the negative lead of those first decode times. Tests: `DecodeTimestampTests` (single B, pyramid, invariants, joins, ties), fixture `fixture-bframes.mkv` (decodes frame-exact in AVFoundation, every presentation time preserved to 2 ms, plays/seeks/finishes in AVPlayer).
- **Memory: appending to a growing `Data` keeps the abandoned blocks.** Building a fragment by appending 300 packets to a `Data` reallocated the buffer again and again; macOS did not give the old large blocks back, so the process footprint (what jetsam counts on iOS) grew by about one segment per segment built: 464 MB after playing through a 281 MB file, with the cache holding only 36 MB. `malloc_zone_pressure_relief` did not help. Fix: size the output once (`ByteWriter(capacity:)`). Same file: 129 MB growth including the cache; the 3-hour file: 65 MB. A regression test builds 20 MB fragments 30 times and fails on the old code (574 MB added). The segment cache budget also dropped from 128 MB to 48 MB.
- **Measurements** (Apple M1 Max, 32 GB, macOS 27.0.1, local SSD; Swift code built in debug configuration by `swift test`, FFmpeg at -O2; `BenchmarkTests`):

  | | 3 h, 526 MB, 320x180, B-frames, AAC + FLAC (1365 segments) | 3 min, 281 MB, 1080p 13 Mbps, B-frames, AC-3 5.1 (24 segments) |
  |---|---|---|
  | probe / open session (index + plan) | 16 ms / 4 ms | 17 ms / 3 ms |
  | first requests (playlists, init, first segments) | 26 ms | 6 ms |
  | AVPlayer: time until playing | 464 ms | 541 ms |
  | AVPlayer: seek until playing again (median of 8, tolerance zero) | 242 ms | 393 ms |
  | build one video segment (median of 12 random seeks) | 2.7 ms | 4.6 ms |
  | build one transcoded FLAC segment | 17 ms | n/a |
  | sequential pass, all streams, per segment (mean / max) | 19.5 / 31 ms | 4.1 / 8.5 ms |
  | worst gap or overlap between neighbouring segments | 1.0 ms | 0.0 ms |
  | audio start minus video start, first 100 vs last 100 segments | -0.2 ms drift | 0.8 ms drift |
  | memory growth over a full pass (peak footprint) | 65 MB (73 MB) | 129 MB (137 MB) |

  Caveats: synthetic test pattern content, a fast Mac, not a phone. Segment memory scales with bitrate (a segment is 6 s of video): at 13 Mbps the peak is 137 MB, at UHD remux bitrates (60-100 Mbps) one segment alone is 45-75 MB and the peak would exceed the 150 MB target. Planned fix: cut segments by size as well as by time (the Matroska Cues carry byte positions), and release packets while the fragment is written. Real numbers on an iPhone need the owner's device.
- **Damaged files.** `DamagedFileTests` mutate four fixtures deterministically (756 files per run: 49 truncations, 60 header-area corruptions, 40 random flips, 40 zeroed/0xFF ranges each) and fetch every playlist and segment; nothing crashes or hangs, and at least half of the randomly damaged files still produce segments. Found and fixed on the way: a byte source that fails after the file was opened looked like a short file, because demuxers turn a failed read into end of file; `PacketReader.next()` now checks the I/O failure first and reports it. A truncated download (60% of the bytes) plays in AVPlayer up to the last complete data and stops without an error; its duration is the header's, because finding the true end would mean reading the whole file (idea: compare the Segment size declared in the header with the file length).
- **Sanitizers.** The full suite is clean under AddressSanitizer, ThreadSanitizer and UBSan. Those instrument Swift only, and the damaged-file corpus is only useful if FFmpeg's demuxers are checked too, so `scripts/check-sanitized.sh` builds an AddressSanitizer-instrumented macOS FFmpeg (`FFMPEG_SANITIZE=address`, separate `build/FFmpegLGPL-address.xcframework`, selected by `MEDIAENGINE_SANITIZED_FFMPEG=1` in `Package.swift`) and runs everything against it: clean (the framework has 42 `__asan_*` imports and is 11 MB instead of 2.9 MB). This is a mutation corpus on tiny files, not coverage-guided fuzzing; a libFuzzer harness on the demux wrapper is the next step if more assurance is wanted.
- **Timing and process-wide measurements need the process to themselves.** Tests that measure probe speed, cancellation latency, memory, descriptors or idle CPU failed intermittently once the suite grew, because other tests ran at the same time. They now live in `ExclusiveTests`, which runs only with `MEDIAENGINE_EXCLUSIVE=1` (a separate pass in `scripts/verify.sh`); the functional parts stay in the normal run. Reproducing a flake: run the suite in a loop with logs (`swift test > log`) and search for the failure marker; grepping for "recorded an issue" missed some failures.
- **Idle and leaks.** 100 open/close cycles add under 30 MB and no descriptors; an open idle session used under 50 ms of CPU in 2 s; sessions are freed after `close()` (weak-reference tests, no retain cycle between session, item and server).

## 15. Byte-bounded segments and mmap-backed fragments (2026-10-25)

- **Problem.** Segments were cut by time only (about 6 s), so their size followed the bitrate: with 44 Mbps 4K video one segment is 40 MB and a full pass peaked at 312 MB of footprint (target 150 MB); the first segment alone took 2.4 s to build before AVPlayer started playing.
- **Size-aware cutting** (`SegmentPlan.make(keyframes:positions:duration:target:maxSegmentBytes:averageBytesPerSecond:)`, cap 24 MB). Two rules, both cutting only at keyframes: (1) the target duration shrinks to `cap / average bytes per second` (file size over duration, never below 1 s), which works for every file whatever its index looks like; (2) when the index gives byte positions (Matroska Cues carry cluster positions, the scan fallback reads packet positions), a keyframe is also a cut if keeping the next GOP would push the segment past the cap, which catches bursts above the average. A single GOP above the cap is never split, so the cap is a soft limit. Low-bitrate files keep their 6-second segments (test `ordinaryBitrate`); the cap also shortens the first segment, and with it the time to first playback.
- **The allocator, again.** With the cap the 44 Mbps file still peaked at 168 MB, flat from the first segment on, so not a leak but retained heap: `malloc` keeps freed blocks of several megabytes and the footprint keeps them. Finished fragments are now written into `mmap`ed pages (`Remux/BigBuffer.swift`, used for outputs of 512 KB and up), which go back to the system the moment the last `Data` slice is released. Same file: 101 MB peak growth and 70 MB after `close()`. Tests: `fragmentsAreReturned` (fails with malloc-backed output: 0 of 52 MB came back), `BigBufferTests`.
- **Numbers** (M1 Max, synthetic test pattern, H.264 High with B-frames, AC-3 5.1; growth over a full sequential pass plus random seeks; AVPlayer playing means `currentTime` past 0.1 s):

  | file | before (time-only segments, malloc output) | time-only + mmap | cap + mmap (now) | AVPlayer playing, now |
  |---|---|---|---|---|
  | 1080p 13 Mbps, 281 MB, 3 min | 129 MB | n/a | 82 MB | 629 ms |
  | 4K 44 Mbps, 638 MB, 2 min | 304 MB | 142 MB | 101 MB | 558 ms (2437 ms before) |
  | 4K 66 Mbps, 718 MB, 90 s | n/a | 236 MB | 116 MB | 565 ms |

  Segments at 66 Mbps are one GOP (3 s, about 24 MB) long. A file with GOPs of several seconds at 100 Mbps would still exceed the target because a GOP is not split; real UHD remuxes usually have 1-2 s GOPs.
- **Making test files this fast.** `h264_videotoolbox -b:v 120M` stops at 44 Mbps on a 4K test pattern; `-q:v 90` gives 66 Mbps, `-q:v 100` switches to "High 4:4:4 Predictive" at level 6.0 (94 Mbps), which the planner correctly refuses (profile out of scope), a handy accidental check of that path.
- **Still open for RMX-7:** a phone; coverage-guided checks on bursty real files; releasing packets while a fragment is written would save another window's worth, but is not needed for the target.

## 16. Spike: HLS through `AVAssetResourceLoader` (RMX-9, 2026-10-25)

- **Question.** Can the remuxed HLS stream reach AVPlayer without a socket (a custom URL scheme served by an `AVAssetResourceLoaderDelegate`)? That would remove the loopback listener and might behave differently for AirPlay and Picture in Picture.
- **Experiment.** A delegate bridge answering content-information and byte-range requests from the same resources the loopback server serves (random scheme and 128-bit host; 7 requests for a two-track file), tried with UTI content types, MIME types and no content type, as a master playlist and as a single media playlist, with `isEntireLengthAvailableOnDemand` on and off.
- **Result: it does not work.** AVPlayer asks the delegate for everything, reads the playlists (duration 3.052 s is parsed) and takes the initialization segments, and then fails on the first media segment: `CoreMediaErrorDomain -12881`, and the item's error log says `custom url not redirect` for `video-0.m4s`. HLS media segments have to come from a real network URL; a custom-scheme loader may only answer them with a redirect. The content type made no difference.
- **Decision.** No `.resourceLoader` transport. The loopback server stays the only transport (hardening tested in `LoopbackServerTests`); a `.lanServer` variant is added only if the AirPlay spike (E-S4) shows that a device on the network needs to fetch segments itself. Serving a single progressive fragmented MP4 through the loader would avoid the restriction, but it needs the size of every fragment up front (the byte offsets live in the `sidx`/`mfra`), which means building the whole file first.
- **Kept as a tripwire.** The bridge now lives in the test target (`ResourceLoaderProbe`) and `AVPlayerEndToEndTests.resourceLoaderLimitation` expects the failure as a known issue. If a later SDK accepts media segments from a loader, that test starts failing, and the socket-free transport can be built.

## 17. E3 design note and the first two spikes (2026-10-25)

**Scope of E3** (gate for PlayerApp M0): SUB-1..5, RMX-4, RMX-8, AUD-1, ANM-2, ANM-4 and the track names in the system menu. Proposed order, each step shippable and tested on its own:

| Step | What | Notes |
|---|---|---|
| E3.1 | Text subtitles (SubRip, ASS/SSA, WebVTT) as WebVTT renditions | **Started: spike S1 passed and is in the tree** (below). Still to do: read cues per window instead of the whole file, long-cue look-back, `\an`/`\pos` as cue settings, SSA v4 events. |
| E3.2 | Chapters and Now Playing metadata (RMX-8, ANM-4) | Chapters via `AVPlayerItem.navigationMarkerGroups` (`AVNavigationMarkersGroup` of timed metadata groups); title and cover attachment via `externalMetadata`; chapter titles and types exposed in the API. Needs a spike on the 27 SDK. |
| E3.3 | Track choices API and selection (RMX-3) | `PlaybackSession` lists audio and subtitle choices (title, language, flags) and selects one on an item; see S2. |
| E3.4 | External files (SUB-3, SUB-4, SUB-5, AUD-1) | External SRT/ASS/VTT go through the same cue pipeline; encoding detection (UTF-8/16, Windows-125x, ISO-8859-x, KOI8, GBK/Big5, Shift-JIS/EUC) with a fixture set; external audio as one more rendition from a second reader with a sync offset. |
| E3.5 | Full ASS and bitmap subtitles on the overlay path (SUB-2, ANM-3, E-S8) | libass with CoreText fonts, FreeType, HarfBuzz, FriBidi, embedded fonts; PGS/DVB/VobSub bitmaps. **New third-party components: the owner is asked before anything is fetched** (licenses to confirm: libass ISC, FreeType FTL, HarfBuzz MIT, FriBidi LGPL-2.1). |
| E3.6 | Ordered chapters and linked segments (ANM-2) | A virtual timeline over ranges of several files; touches `RemuxSession` (multiple sources). Largest item; may move behind PlayerApp M0 if the owner agrees. |

**Spike S1: text subtitles as WebVTT in HLS. Passed.**
- Matroska delivers SubRip blocks as plain text with the block's time and duration, and ASS blocks as `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`. No FFmpeg subtitle decoder is needed for either: `SubtitleText` takes the text, keeps `<i>`, `<b>`, `<u>` (SubRip tags, and `\i1`/`\b1`/`\u1` switches in ASS), drops everything else (`\pos`, `\fad`, karaoke `\k`, vector drawings `\p1`), maps `\N` to a line break and `\h` to a no-break space, and escapes `&`, `<`, `>`.
- The master playlist gets one `EXT-X-MEDIA:TYPE=SUBTITLES` entry per track (`DEFAULT` from the source flag, `FORCED` from the forced flag, `CHARACTERISTICS` for hearing-impaired tracks) and `SUBTITLES="subs"` on the variant; each track has a playlist with the video's segment boundaries and one `.vtt` per segment (`X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000`, times shifted like the audio and video, cues that cross a boundary repeated in both segments).
- AVPlayer lists the track as "English" and delivers the cues (`AVPlayerItemLegibleOutput`) for the item time that equals their time in the file (0.2 s and 1.6 s, within 0.15 s): subtitles are in step with the video.
- The ASS fixture shows a forced "Signs and Songs" track as "English Forced" next to "English": the forced flag is enough to tell those two apart in the system menu.
- OS 27 adds machine-translated options to the subtitle menu for the viewer's other languages ("Russian (Russia) Translated"). They have no title metadata, which is how to tell them from ours.
- Today the cues are read from the whole file at the first request (one pass over the subtitle packets only; the reader skips other streams before copying them). Fine for the spike, too slow for a 5 GB file on a phone; E3.1 reads subtitle blocks window by window (Matroska stores them in the cluster of their start time) with a look-back for long cues.

**Spike S2: telling same-language tracks apart. Result: the system menu cannot.**

| Playlist attribute for a second English track | System menu (`displayName`) | `commonMetadata` title |
|---|---|---|
| only `NAME="English commentary"` | "English" (same as the first) | "English commentary" |
| `LANGUAGE="en-US"` and `"en-GB"` | "English (US)" / "English (UK)" | the names |
| `CHARACTERISTICS="public.accessibility.describes-video"` | "English AD" (misleading for a commentary) | the name |
| no `LANGUAGE` / `und` | "Unknown" / "Unknown language" | the name |
| `LANGUAGE="en-x-commentary"` | "English" | the name |

The menu of `AVPlayerViewController` is built from `displayName`, which comes from the language and a few characteristics, never from `NAME`; the name is available to code in `AVMediaSelectionOption.commonMetadata` (title). So the engine cannot fix the system menu without lying about languages or accessibility roles. Decision: keep honest tags; add a track choices API (E3.3) that lists title, language and flags and selects the matching `AVMediaSelectionOption` by its title; the app shows its own picker when two tracks share a language. AVPlayer also applies media selection criteria on its own (in the anime fixture it picks the English dub over the file's default Japanese track and the forced English subtitles); the choices API needs to turn that off (`appliesMediaSelectionCriteriaAutomatically`) or set criteria for per-series preferences.

## 18. E3.1 findings: subtitle cues per window and placement (2026-10-25)

- **Cues come from the windows that are built anyway.** A window reads every stream in its time range, so the subtitle packets that start there are recorded as a side effect (`RemuxSession.record(subtitle:)`, a set per track, so cues seen twice by overlapping windows are kept once). A request for subtitle segment N makes sure the windows that can hold its cues have been read: those from 15 s before the segment up to the next window (a block can sit just behind its keyframe); a request for segment 0 reads windows 0 and 1 and nothing else (`readsOnlyNearbyWindows`). The video and audio of those windows are cached for the player's next requests, so subtitles cost almost no extra I/O. This replaced the whole-file pass of the spike.
- **Long cues.** A cue shown in a segment is repeated in every segment it overlaps, and it is found as long as it started within the look-back of 15 s. The new fixture `fixture-subs-long.mkv` (14 s, three segments, an 11-second cue, cues across both boundaries and one that starts 50 ms before a boundary) checks every segment on a fresh session in any order (`spanning`, `orderDoesNotMatter`); the tests fail with a look-back of 0. A cue longer than the look-back that started before it would be missing from a late segment; real files rarely have those, and the constant is one line.
- **Placement.** ASS alignment (`\an1`..`\an9`, or the event's style in the track header) and `\pos(x,y)` (as a percentage of the script's `PlayResX/Y`, from the codec header) become WebVTT cue settings: `line:17%,start position:50%,center align:center` and so on; the usual bottom centre needs none. AVPlayer honours them: the "SIGN: Station" cue of the anime fixture arrives with `CMWritingDirectionOrthogonalLinePositionPercentage = 17` and text position 50, an unpositioned line with 100 (`subtitlePlacement`). Rotation, fades, colours, karaoke timing and drawings are still dropped.
- **Not done in E3.1:** WebVTT settings carried in Matroska block additions, tx3g/mov_text from MP4 sources (those files play natively), forced and hearing-impaired flags on real files, SSA v4 (non-plus) header layouts beyond the usual `Format:` line.

