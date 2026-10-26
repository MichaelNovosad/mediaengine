import CoreGraphics
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
        let fonts = await loadFonts()
        let videoSize = info.videoTracks.first?.video.map { CGSize(width: $0.width, height: $0.height) }
        let shift: @Sendable () -> Double = { [weak self] in self?.state.withLock { $0.remux?.mediaShift } ?? 0 }

        if served.externalSubtitleIDs.contains(track.id) {
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
        let isBitmap = track.subtitle?.format == .bitmap
        let codecName = track.codec.name
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let video = info.videoTracks.first?.id, audio = info.audioTracks.first?.id
                    let anchor = video ?? audio ?? streamIndex, marker = audio ?? video ?? streamIndex
                    let source: any PacketSource
                    if let ordered = info.orderedChapters {
                        source = try Self.makeTimeline(main: byteSource, info: info, ordered: ordered, linked: linked,
                                                       overlay: (streamIndex, marker == streamIndex ? nil : marker), cancellation: cancellation).reader
                    } else {
                        source = try PacketReader(source: byteSource, cancellation: cancellation)
                    }
                    let backend: any OverlayBackend
                    if isBitmap {
                        guard let bitmap = BitmapBackend(parameters: source.parameters(streamIndex), videoSize: videoSize) else {
                            throw MediaError.unsupported(detail: "no decoder for this picture subtitle format")
                        }
                        backend = bitmap
                    } else if ["ass", "ssa"].contains(codecName) {
                        let extradata = source.parameters(streamIndex).pointee
                        let header = extradata.extradata.map { Data(bytes: $0, count: Int(extradata.extradata_size)) } ?? Data()
                        guard let ass = ASSBackend(header: header, fonts: fonts, videoSize: videoSize) else {
                            throw MediaError.engine(detail: "libass could not read the script header")
                        }
                        backend = ass
                    } else {
                        // SubRip, WebVTT and Timed Text: drawn in a plain default style through the same renderer.
                        guard let ass = ASSBackend(header: Data(CueScript.header.utf8), fonts: fonts, videoSize: videoSize) else {
                            throw MediaError.engine(detail: "libass could not start")
                        }
                        backend = ass
                    }
                    var loader: any OverlayEventSource = OverlayEventLoader(source: source, stream: streamIndex, anchor: anchor, marker: marker, cancellation: cancellation)
                    if !isBitmap, !["ass", "ssa"].contains(codecName) { loader = CueScriptEventSource(base: loader, codec: codecName) }
                    return SubtitleRenderer(backend: backend, loader: loader, cancellation: cancellation, offset: shift)
                })
            }
        }
    }

    // MARK: Internals

    /// Text formats the overlay can draw: ASS/SSA with their own styling, the others in a plain default style.
    static let overlayTextCodecs: Set<String> = ["ass", "ssa", "subrip", "srt", "webvtt", "mov_text", "text"]

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

    /// The fonts attached to the file, by file name.
    private func loadFonts() async -> [(name: String, data: Data)] {
        var fonts: [(name: String, data: Data)] = []
        for attachment in info.attachments where attachment.kind == .font {
            if let data = try? await source.data(of: attachment), !data.isEmpty {
                fonts.append((attachment.filename ?? "font-\(attachment.id)", data))
            }
        }
        return fonts
    }
}
