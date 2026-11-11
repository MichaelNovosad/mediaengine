import CoreGraphics
internal import FFmpegLGPL
import Foundation

extension PlaybackSession {
    /// The subtitle tracks the engine can draw itself, over the video, with ``makeSubtitleRenderer(for:)``: every ASS/SSA
    /// track (embedded or from a file added with ``add(_:)-(SubtitleTrack)``), which the system player can show only
    /// as plain text, and the picture tracks (PGS, VobSub, DVB), which it cannot show at all
    /// (``TrackChoice/isBitmap``). Titles are the same as in ``subtitleChoices``.
    public var overlayChoices: [TrackChoice] {
        let (tracks, titles, served) = overlayTracks()
        let bitmaps = Set(tracks.filter { $0.subtitle?.format == .bitmap }.map(\.id))
        return tracks.map { track in
            TrackChoice(id: track.id, kind: .subtitle, title: titles[track.id] ?? "", language: track.language, codec: track.codec.displayName,
                        isDefault: track.isDefault, isForced: track.isForced, isHearingImpaired: track.isHearingImpaired,
                        isCommentary: false, isExternal: served.externalSubtitleIDs.contains(track.id), isBitmap: bitmaps.contains(track.id))
        }
    }

    /// Makes a renderer for one of ``overlayChoices``. Fonts attached to the file are used before the system's.
    ///
    /// Create it before or after the player item; the renderer follows the item's time because you give it the player's
    /// time in ``SubtitleRenderer/frame(at:size:)``.
    public func makeSubtitleRenderer(for choice: TrackChoice) async throws -> SubtitleRenderer {
        let (tracks, _, served) = overlayTracks()
        guard choice.kind == .subtitle, let track = tracks.first(where: { $0.id == choice.id }) else {
            throw MediaError.unsupported(detail: "the engine cannot draw the track \"\(choice.title)\" itself")
        }
        if state.withLock({ $0.isClosed }) { throw MediaError.cancelled }
        let isExternal = served.externalSubtitleIDs.contains(track.id)
        let isBitmap = track.subtitle?.format == .bitmap
        let codecName = track.codec.name
        let isCueText = !isExternal && !isBitmap && !["ass", "ssa"].contains(codecName)
        // SubRip, WebVTT and Timed Text are drawn in a plain style with a system font: they do not wait for the file's attached fonts.
        let fonts = isCueText ? [] : await loadFonts()
        let videoSize = info.videoTracks.first?.video.map { CGSize(width: $0.width, height: $0.height) }
        let shift: @Sendable () -> Double = { [weak self] in self?.state.withLock { $0.remux?.mediaShift } ?? 0 }

        if isExternal {
            let index = track.id - ServedTracks.externalSubtitleBase
            let files = externalSubtitles
            guard files.indices.contains(index), let script = files[index].assScript else {
                throw MediaError.unsupported(detail: "only ASS and SSA subtitle files can be drawn by the engine")
            }
            guard let backend = ASSBackend(script: script, fonts: fonts, videoSize: videoSize) else {
                throw MediaError.engine(detail: "libass could not read the script")
            }
            let delay = files[index].delay
            return SubtitleRenderer(backend: backend, loader: nil, cancellation: cancellation, offset: { shift() + delay })
        }

        let byteSource = source.byteSource, info = info, cancellation = cancellation
        let linked = state.withLock { $0.linkedSources }
        let streamIndex = track.id
        // While the player plays the file through the remuxer, the blocks come from its reading (the file is not read twice:
        // for a movie on a server that second download made blocks late or lost them). A play list reads its parts itself.
        let feed: @Sendable () -> (any OverlayFeedSource)? = { [weak self] in
            guard info.orderedChapters == nil, let shared = self?.state.withLock({ $0.remux?.overlayFeed }),
                  shared.streams.contains(streamIndex) else { return nil }
            return OverlayFeedView(feed: shared, stream: streamIndex, cueCodec: isCueText ? codecName : nil)
        }
        let video = info.videoTracks.first?.id, audio = info.audioTracks.first?.id
        let anchor = video ?? audio ?? streamIndex, marker = audio ?? video ?? streamIndex
        // The stream's blocks as read from the file itself (or a play list).
        let reading: @Sendable (any PacketSource) -> any OverlayEventSource = { source in
            let loader = OverlayEventLoader(source: source, stream: streamIndex, anchor: anchor, marker: marker, cancellation: cancellation)
            return isCueText ? CueScriptEventSource(base: loader, codec: codecName) : loader
        }
        // After a seek the renderer reads what the player did not: on a server that read shares the connection with the player, so it
        // reaches back only as far as most lines last.
        let local = byteSource is FileByteSource || byteSource is DataByteSource
        let seekLookback = local ? SubtitleRenderer.lookback : 8

        // While the remuxer plays the file, its reading has the stream's header and blocks: the renderer starts without opening the file,
        // and opens it only if a stretch must be read from it (after a jump). Each choice of a subtitle track used to open the file again,
        // which for a movie on a server read its header and every attached font over the network first (the owner, 2026-11-11).
        if info.orderedChapters == nil, let shared = state.withLock({ $0.remux?.overlayFeed }), shared.streams.contains(streamIndex),
           let parameters = shared.parameters[streamIndex] {
            return try await Self.offMainThread {
                let backend = try Self.makeOverlayBackend(parameters: parameters.pointer, isBitmap: isBitmap, codecName: codecName,
                                                          fonts: fonts, videoSize: videoSize)
                let loader = DeferredEventSource { try reading(PacketReader(source: byteSource, cancellation: cancellation)) }
                return SubtitleRenderer(backend: backend, loader: loader, feed: feed, seekLookback: seekLookback, readsOverNetwork: !local,
                                        cancellation: cancellation, offset: shift)
            }
        }
        return try await Self.offMainThread {
            let source: any PacketSource
            if let ordered = info.orderedChapters {
                source = try Self.makeTimeline(main: byteSource, info: info, ordered: ordered, linked: linked,
                                               overlay: (streamIndex, marker == streamIndex ? nil : marker), cancellation: cancellation).reader
            } else {
                source = try PacketReader(source: byteSource, cancellation: cancellation)
            }
            let backend = try Self.makeOverlayBackend(parameters: source.parameters(streamIndex), isBitmap: isBitmap, codecName: codecName,
                                                      fonts: fonts, videoSize: videoSize)
            return SubtitleRenderer(backend: backend, loader: reading(source), feed: feed, seekLookback: seekLookback, readsOverNetwork: !local,
                                    cancellation: cancellation, offset: shift)
        }
    }

    /// The backend that draws one of the file's own subtitle streams, set up from its codec parameters.
    private static func makeOverlayBackend(parameters: UnsafeMutablePointer<AVCodecParameters>, isBitmap: Bool, codecName: String,
                                           fonts: [(name: String, data: Data)], videoSize: CGSize?) throws -> any OverlayBackend {
        if isBitmap {
            guard let bitmap = BitmapBackend(parameters: parameters, videoSize: videoSize) else {
                throw MediaError.unsupported(detail: "no decoder for this picture subtitle format")
            }
            return bitmap
        }
        if ["ass", "ssa"].contains(codecName) {
            let codec = parameters.pointee
            let header = codec.extradata.map { Data(bytes: $0, count: Int(codec.extradata_size)) } ?? Data()
            guard let ass = ASSBackend(header: header, fonts: fonts, videoSize: videoSize) else {
                throw MediaError.engine(detail: "libass could not read the script header")
            }
            return ass
        }
        // SubRip, WebVTT and Timed Text: drawn in a plain default style through the same renderer.
        guard let ass = ASSBackend(header: Data(CueScript.header.utf8), fonts: fonts, videoSize: videoSize) else {
            throw MediaError.engine(detail: "libass could not start")
        }
        return ass
    }

    /// Runs `work` on a background queue (libass set-up, opening a file) and returns its result.
    private static func offMainThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: Internals

    /// Text formats the overlay can draw: ASS/SSA with their own styling, the others in a plain default style.
    static let overlayTextCodecs: Set<String> = ["ass", "ssa", "subrip", "srt", "webvtt", "mov_text", "text"]

    /// The file's own subtitle streams the overlay can draw, text and picture, whose blocks the remuxer keeps for it.
    static func overlayStreams(of info: MediaInfo) -> (text: Set<Int>, pictures: Set<Int>) {
        let treatments = Dictionary(uniqueKeysWithValues: info.playbackPlan.tracks.map { ($0.trackID, $0.treatment) })
        let pictures = info.subtitleTracks.filter { $0.subtitle?.format == .bitmap && treatments[$0.id] == .bitmapOverlay }
        let text = info.subtitleTracks.filter { $0.subtitle?.format != .bitmap && overlayTextCodecs.contains($0.codec.name) }
        return (Set(text.map(\.id)), Set(pictures.map(\.id)))
    }

    private func overlayTracks() -> (tracks: [Track], titles: [Int: String], served: ServedTracks) {
        let served = ServedTracks(info: info, externalSubtitles: externalSubtitles, externalAudio: externalAudio)
        let treatments = Dictionary(uniqueKeysWithValues: info.playbackPlan.tracks.map { ($0.trackID, $0.treatment) })
        let files = externalSubtitles
        let text = served.subtitles.filter { track in
            if served.externalSubtitleIDs.contains(track.id) {
                let index = track.id - ServedTracks.externalSubtitleBase
                return files.indices.contains(index) && files[index].assScript != nil
            }
            return Self.overlayTextCodecs.contains(track.codec.name)
        }
        let bitmaps = info.subtitleTracks.filter { $0.subtitle?.format == .bitmap && treatments[$0.id] == .bitmapOverlay }
        // Names are made unique over the text tracks the player lists plus the picture tracks, so a track has the same
        // title here as in `subtitleChoices`.
        let titles = ServedTracks.titles(for: served.subtitles + bitmaps, fallback: "Subtitles")
        return (text + bitmaps, titles, served)
    }

    /// The fonts attached to the file, by file name: read once per session, and started as soon as the player item is made when the
    /// file has subtitles the engine draws (``startReadingFonts()``), so that choosing such a track does not wait for another opening
    /// of the file over the network (the owner, 2026-11-08: subtitles came with a delay).
    func loadFonts() async -> [(name: String, data: Data)] {
        await startReadingFonts().value
    }

    /// The one reading of the attached fonts, started now if it has not been yet.
    @discardableResult
    func startReadingFonts() -> Task<[(name: String, data: Data)], Never> {
        state.withLock { state in
            if let reading = state.fonts { return reading }
            let reading = Task { await self.readFonts() }
            state.fonts = reading
            return reading
        }
    }

    private func readFonts() async -> [(name: String, data: Data)] {
        let attachments = info.attachments.filter { $0.kind == .font }
        guard !attachments.isEmpty else { return [] }
        let read = await source.data(of: attachments)                  // one opening of the file for all of them
        return attachments.compactMap { attachment in
            guard let data = read[attachment.id], !data.isEmpty else { return nil }
            return (attachment.filename ?? "font-\(attachment.id)", data)
        }
    }
}

extension PlaybackSession {
    /// Whether a sound track can be turned into sound for speech recognition (``extractSpeechAudio(of:to:progress:)``).
    public func canExtractSpeechAudio(of choice: TrackChoice) -> Bool {
        guard choice.kind == .audio, !choice.isExternal, let track = info.tracks.first(where: { $0.id == choice.id }) else { return false }
        return SpeechAudioExtractor.canDecode(track.codec.name)
    }

    /// Decodes a sound track of the video file to mono 16 kHz 16-bit sound in a CAF file at `url`, which is what the system's speech
    /// recognition takes. It reads the whole track (a film takes a minute or two); `progress` gets 0 to 1. A surround track is mixed down to
    /// mono. Cancelling the task stops it.
    public func extractSpeechAudio(of choice: TrackChoice, to url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard canExtractSpeechAudio(of: choice), let track = info.tracks.first(where: { $0.id == choice.id }) else {
            throw MediaError.unsupported(detail: "this sound track cannot be turned into sound for speech recognition")
        }
        let byteSource = source.byteSource
        let name = track.codec.name
        let stream = choice.id
        let flag = CancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try SpeechAudioExtractor.extract(from: byteSource, stream: stream, codecName: name, to: url, cancellation: flag, progress: progress) })
                }
            }
        } onCancel: { flag.cancel() }
    }
}
