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

    private let source: MediaSource
    private let fileURL: URL?
    private let cancellation = CancellationFlag()
    private struct State {
        var remux: RemuxSession?
        var server: LoopbackServer?
        var externalSubtitles: [SubtitleTrack] = []
        var externalAudio: [AudioTrack] = []
        var isClosed = false
    }
    private let state = Mutex(State())

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
        let (server, remux) = state.withLock { state -> (LoopbackServer?, RemuxSession?) in
            state.isClosed = true
            defer { state.server = nil; state.remux = nil }
            return (state.server, state.remux)
        }
        cancellation.cancel()
        server?.stop()
        remux?.close()
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

    private func startRemux() async throws -> RemuxSession {
        let existing = try state.withLock { state -> RemuxSession? in
            if state.isClosed { throw MediaError.cancelled }
            return state.remux
        }
        if let existing { return existing }

        let byteSource = source.byteSource
        let info = info
        let cancellation = cancellation
        let (external, externalAudio) = state.withLock { ($0.externalSubtitles, $0.externalAudio) }
        let remux: RemuxSession = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try RemuxSession(source: byteSource, info: info, cancellation: cancellation, externalSubtitles: external, externalAudio: externalAudio)
                })
            }
        }
        let outcome = try state.withLock { state -> (RemuxSession, lost: Bool) in
            if state.isClosed { throw MediaError.cancelled }
            if let existing = state.remux { return (existing, true) }               // a concurrent call won
            state.remux = remux
            return (remux, false)
        }
        if outcome.lost { remux.close() }
        return outcome.0
    }

    private func startServer(for remux: RemuxSession) async throws -> LoopbackServer {
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

    private nonisolated(unsafe) static var associationKey: UInt8 = 0

    /// Ties this session's lifetime to the item, so the server lives exactly as long as the item does.
    @MainActor
    private func attach(_ item: AVPlayerItem) -> AVPlayerItem {
        objc_setAssociatedObject(item, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return item
    }
}
