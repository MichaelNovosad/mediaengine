import AVFoundation
import AVKit
import Foundation
import ObjectiveC
import Synchronization

/// Plays a file that AVFoundation cannot open on its own (MKV, WebM, ...) through AVPlayer, so the system
/// player UI, AirPlay, Picture in Picture and HDR keep working.
///
/// ```swift
/// let session = try await PlaybackSession(url: fileURL)   // probes and chooses the best path
/// let item = try await session.makePlayerItem()            // plain AVPlayerItem
/// player.replaceCurrentItem(with: item)                    // AVPlayerViewController / VideoPlayer
/// ```
///
/// The item keeps the session alive; you do not need to hold on to it separately.
public final class PlaybackSession: @unchecked Sendable {
    /// What the engine learned about the file.
    public let info: MediaInfo

    let source: MediaSource
    private let fileURL: URL?
    let cancellation = CancellationFlag()
    struct State {
        var remux: RemuxSession?
        var server: LoopbackServer?
        var externalSubtitles: [SubtitleTrack] = []
        var externalAudio: [AudioTrack] = []
        /// Files that ordered chapters play parts of, by segment identifier, and the folders whose access is kept open.
        var linkedSources: [String: MediaSource] = [:]
        var scopedFolders: [URL] = []
        var incompatible: Set<String> = []
        var isClosed = false
    }
    let state = Mutex(State())

    /// Opens a local file (security-scoped URLs from the file picker included) or an HTTP(S) address.
    public convenience init(url: URL) async throws {
        try await self.init(source: MediaSource(url: url), fileURL: url.isFileURL ? url : nil)
    }

    /// Opens any ``MediaSource``, for example one backed by a network share.
    public convenience init(source: MediaSource) async throws {
        try await self.init(source: source, fileURL: nil)
    }

    private init(source: MediaSource, fileURL: URL?) async throws {
        self.source = source
        self.fileURL = fileURL
        self.info = try await source.probe()
    }

    deinit { close() }

    /// Creates the item to give to `AVPlayer`. Starts a local server for files the system cannot read itself.
    @MainActor
    public func makePlayerItem() async throws -> AVPlayerItem {
        let plan = info.playbackPlan
        switch plan.path {
        case .unsupported:
            throw MediaError.unsupported(detail: plan.blockingReason?.detail ?? "unsupported media")
        case .software:
            throw MediaError.unsupported(detail: "software decoding is not part of this build")
        case .native:
            if let fileURL { return attach(AVPlayerItem(url: fileURL)) }
        case .remux:
            break
        }

        let remux = try await startRemux()
        let server = try await startServer(for: remux)
        let item = AVPlayerItem(url: server.masterURL)
        await describe(item)
        return attach(item)
    }

    /// Title and cover art of the file, for Now Playing and the lock screen. Files that AVFoundation plays by itself
    /// carry their own. `AVPlayerItem.externalMetadata` does not exist on macOS, where an app sets
    /// `MPNowPlayingInfoCenter` itself from ``info`` and ``MediaSource/data(of:)``. Chapters are not handed to the
    /// system player: its marker API is tvOS-only, so apps use ``MediaInfo/chapters`` and ``Chapter/kind``.
    @MainActor
    private func describe(_ item: AVPlayerItem) async {
        #if !os(macOS)
        let title = info.title ?? fileURL.map { $0.deletingPathExtension().lastPathComponent }
        var artwork: Data?
        let cover = info.attachments.first { $0.kind == .coverArt && ($0.filename ?? "").lowercased().hasPrefix("cover") }
            ?? info.attachments.first { $0.kind == .coverArt }
        if let cover { artwork = try? await source.data(of: cover) }
        // `externalMetadata` is added to AVPlayerItem by AVKit; naming a class from it makes sure the framework is loaded
        // (a process that never touched AVKit would crash with "unrecognized selector").
        Bundle(for: AVPlayerViewController.self).load()
        if item.responds(to: NSSelectorFromString("setExternalMetadata:")) {
            item.externalMetadata = PlayerItemMetadata.external(title: title, artwork: artwork)
        }
        #endif
    }

    /// Stops the local server and releases the file. The player item stops working.
    public func close() {
        let (server, remux, folders) = state.withLock { state -> (LoopbackServer?, RemuxSession?, [URL]) in
            state.isClosed = true
            defer { state.server = nil; state.remux = nil; state.scopedFolders = [] }
            return (state.server, state.remux, state.scopedFolders)
        }
        cancellation.cancel()
        server?.stop()
        remux?.close()
        folders.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    // MARK: Ordered chapters (play lists)

    /// What plays, when the file's chapters are a play list (see ``OrderedChapters``): the parts of files that are not
    /// available (or that are encoded differently from this one) are left out and the rest closes up. `nil` for
    /// ordinary files.
    public var playList: OrderedChapters? {
        guard let ordered = info.orderedChapters else { return nil }
        let (linked, bad) = state.withLock { ($0.linkedSources, $0.incompatible) }
        return ordered.available { linked[$0.uid] != nil && !bad.contains($0.uid) }
    }

    /// Files the play list needs and has not been given (yet): their parts are not played. Show this to the viewer
    /// rather than skipping the content silently.
    public var missingSegments: [LinkedSegment] {
        guard let ordered = info.orderedChapters else { return [] }
        let linked = state.withLock { $0.linkedSources }
        return ordered.segments.filter { linked[$0.uid] == nil }
    }

    /// Files that were found but cannot be joined to this one (a different resolution, codec or configuration). Known
    /// once ``makePlayerItem()`` has run.
    public var incompatibleSegments: [LinkedSegment] {
        state.withLock { $0.incompatible }.sorted().map { LinkedSegment(uid: $0) }
    }

    /// The chapters of what plays: the play list's parts when there is one, else the file's own chapters.
    public var chapters: [Chapter] {
        guard let list = playList else { return info.chapters }
        return list.pieces.map { Chapter(id: $0.id, start: $0.offset, end: $0.offset + $0.duration, title: $0.title) }
    }

    /// The length of what plays, in seconds.
    public var duration: TimeInterval? { playList?.duration ?? info.duration }

    /// Looks in a folder for the files this file's play list needs (matched by their segment identifier, not by name)
    /// and remembers them. Call before ``makePlayerItem()``. A folder the viewer picked stays accessible until the
    /// session closes. Returns the segments that were found.
    @discardableResult
    public func locateSegments(in folder: URL) async throws -> [LinkedSegment] {
        let wanted = Set(info.orderedChapters?.segments.map(\.uid) ?? [])
        guard !wanted.isEmpty else { return [] }
        try state.withLock { state in
            if state.isClosed { throw MediaError.cancelled }
            if state.remux != nil { throw MediaError.unsupported(detail: "segments must be located before the first player item is made") }
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        let found: [String: URL] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [String: URL] = [:]
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for url in files where ["mkv", "mka", "webm", "mks"].contains(url.pathExtension.lowercased()) {
                    guard let byteSource = try? FileByteSource(url: url), let uid = MatroskaChapters.read(from: byteSource)?.segmentUID else { continue }
                    let hex = LinkedSegment(data: uid).uid
                    if wanted.contains(hex), result[hex] == nil { result[hex] = url }
                }
                continuation.resume(returning: result)
            }
        }
        var segments: [LinkedSegment] = []
        for (uid, url) in found.sorted(by: { $0.key < $1.key }) {
            guard let byteSource = try? FileByteSource(url: url) else { continue }
            state.withLock { $0.linkedSources[uid] = MediaSource(byteSource: byteSource) }
            segments.append(LinkedSegment(uid: uid))
        }
        if scoped {
            if segments.isEmpty { folder.stopAccessingSecurityScopedResource() } else { state.withLock { $0.scopedFolders.append(folder) } }
        }
        return segments
    }

    /// Gives the play list the file for one segment, for example one from a network share.
    public func link(_ segment: LinkedSegment, to source: MediaSource) throws {
        try state.withLock { state in
            if state.isClosed { throw MediaError.cancelled }
            if state.remux != nil { throw MediaError.unsupported(detail: "segments must be linked before the first player item is made") }
            state.linkedSources[segment.uid] = source
        }
    }

    /// Adds a subtitle file to be shown with the video, next to the tracks inside it. It appears among
    /// ``subtitleChoices`` (with ``TrackChoice/isExternal`` set) and in the player's subtitle menu.
    ///
    /// Add files before the first ``makePlayerItem()``: the list of tracks is fixed once an item exists. To add one
    /// later, create a new session, add all files and make a new item at the current time.
    public func add(_ subtitles: SubtitleTrack) throws {
        try state.withLock { state in
            if state.isClosed { throw MediaError.cancelled }
            if state.remux != nil {
                throw MediaError.unsupported(detail: "subtitle files must be added before the first player item is made")
            }
            state.externalSubtitles.append(subtitles)
        }
    }

    /// Adds an audio file that can be played instead of the video's own sound. It appears among ``audioChoices`` (with
    /// ``TrackChoice/isExternal`` set) and in the player's audio menu. The same rule as for subtitle files applies:
    /// add it before the first ``makePlayerItem()``.
    /// A copy of one of the video file's own sound tracks that starts `delay` seconds later (negative: earlier) than the original, to line up
    /// sound that is out of step with the picture. Add it with ``add(_:)-(AudioTrack)`` before the first player item, choose it instead of
    /// the original, and give `title` to name it (it is made unique among the audio choices like any other).
    public func audioTrack(like choice: TrackChoice, delay: TimeInterval, title: String? = nil) async throws -> AudioTrack {
        guard choice.kind == .audio, !choice.isExternal else { throw MediaError.unsupported(detail: "only a sound track of the video file can be copied with a delay") }
        return try await AudioTrack(source: source, name: "audio", language: choice.language, title: title ?? choice.title, delay: delay, stream: choice.id)
    }

    public func add(_ audio: AudioTrack) throws {
        try state.withLock { state in
            if state.isClosed { throw MediaError.cancelled }
            if state.remux != nil {
                throw MediaError.unsupported(detail: "audio files must be added before the first player item is made")
            }
            state.externalAudio.append(audio)
        }
    }

    /// The audio files added so far.
    var externalAudio: [AudioTrack] { state.withLock { $0.externalAudio } }

    /// The subtitle files added so far.
    var externalSubtitles: [SubtitleTrack] { state.withLock { $0.externalSubtitles } }

    // MARK: Internals

    func startRemux() async throws -> RemuxSession {
        let existing = try state.withLock { state -> RemuxSession? in
            if state.isClosed { throw MediaError.cancelled }
            return state.remux
        }
        if let existing { return existing }

        let byteSource = source.byteSource
        let info = info
        let cancellation = cancellation
        let (external, externalAudio, linked) = state.withLock { ($0.externalSubtitles, $0.externalAudio, $0.linkedSources) }
        let (remux, bad): (RemuxSession, Set<String>) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    guard let ordered = info.orderedChapters else {
                        return (try RemuxSession(source: byteSource, info: info, cancellation: cancellation,
                                                 externalSubtitles: external, externalAudio: externalAudio), [])
                    }
                    let built = try Self.makeTimeline(main: byteSource, info: info, ordered: ordered, linked: linked, cancellation: cancellation)
                    var playInfo = info
                    playInfo.duration = built.list.duration
                    return (try RemuxSession(source: byteSource, info: playInfo, cancellation: cancellation, externalSubtitles: external,
                                             externalAudio: externalAudio, packetSource: built.reader), built.incompatible)
                })
            }
        }
        if !bad.isEmpty { state.withLock { $0.incompatible = bad } }
        let outcome = try state.withLock { state -> (RemuxSession, lost: Bool) in
            if state.isClosed { throw MediaError.cancelled }
            if let existing = state.remux { return (existing, true) }               // a concurrent call won
            state.remux = remux
            return (remux, false)
        }
        if outcome.lost { remux.close() }
        return outcome.0
    }

    func startServer(for remux: RemuxSession) async throws -> LoopbackServer {
        let existing = try state.withLock { state -> LoopbackServer? in
            if state.isClosed { throw MediaError.cancelled }
            return state.server
        }
        if let existing { return existing }
        let server = try await LoopbackServer.start(session: remux)
        let outcome = try state.withLock { state -> (LoopbackServer, lost: Bool) in
            if state.isClosed { throw MediaError.cancelled }
            if let existing = state.server { return (existing, true) }
            state.server = server
            return (server, false)
        }
        if outcome.lost { server.stop() }
        return outcome.0
    }

    /// Opens the main file and the linked files and joins the parts. Files that cannot be joined (their video is encoded
    /// differently) are dropped and the timeline is built again without them.
    static func makeTimeline(main byteSource: any ByteSource, info: MediaInfo, ordered: OrderedChapters, linked: [String: MediaSource],
                             overlay: (stream: Int, marker: Int?)? = nil, cancellation: CancellationFlag) throws -> (reader: TimelineReader, list: OrderedChapters, incompatible: Set<String>) {
        let served = ServedTracks(info: info)
        var excluded = Set<String>()
        while true {
            let list = ordered.available { linked[$0.uid] != nil && !excluded.contains($0.uid) }
            guard !list.pieces.isEmpty else { throw MediaError.unsupported(detail: "none of the parts of this play list can be played") }
            let main = try PacketReader(source: byteSource, cancellation: cancellation)
            let others = try list.segments.map { try PacketReader(source: linked[$0.uid]!.byteSource, cancellation: cancellation) }
            let parts = list.pieces.map { piece in
                TimelineReader.Part(source: piece.segment.flatMap { list.segments.firstIndex(of: $0) }.map { $0 + 1 } ?? 0,
                                    start: piece.start, end: piece.end, offset: piece.offset)
            }
            // For the overlay of one subtitle track the reader carries just that track and a cheap marker stream.
            let audio = overlay.map { [$0.marker].compactMap { $0 } } ?? served.audio.map(\.id)
            let subtitles = overlay.map { [$0.stream] } ?? served.subtitles.map(\.id)
            let reader = TimelineReader(main: main, others: others, parts: parts, video: served.video?.id, audio: audio, subtitles: subtitles)
            let bad = Set(reader.incompatible.compactMap { list.pieces[$0].segment?.uid })
            if bad.isEmpty { return (reader, list, excluded) }
            excluded.formUnion(bad)
        }
    }

    private nonisolated(unsafe) static var associationKey: UInt8 = 0

    /// Ties this session's lifetime to the item, so the server lives exactly as long as the item does.
    @MainActor
    func attach(_ item: AVPlayerItem) -> AVPlayerItem {
        objc_setAssociatedObject(item, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return item
    }
}
