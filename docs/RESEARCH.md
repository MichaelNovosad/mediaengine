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
