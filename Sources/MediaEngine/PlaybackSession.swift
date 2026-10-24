import AVFoundation
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

        let (remux, server) = try await startRemux()
        let item = AVPlayerItem(url: server.masterURL)
        _ = remux
        return attach(item)
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

    // MARK: Internals

    private func startRemux() async throws -> (RemuxSession, LoopbackServer) {
        let existing = try state.withLock { state -> (RemuxSession, LoopbackServer)? in
            if state.isClosed { throw MediaError.cancelled }
            if let remux = state.remux, let server = state.server { return (remux, server) }
            return nil
        }
        if let existing { return existing }

        let byteSource = source.byteSource
        let info = info
        let cancellation = cancellation
        let remux: RemuxSession = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try RemuxSession(source: byteSource, info: info, cancellation: cancellation) })
            }
        }
        let server = try await LoopbackServer.start(session: remux)

        let outcome = try state.withLock { state -> (RemuxSession, LoopbackServer, lost: Bool) in
            if state.isClosed { throw MediaError.cancelled }
            if let existing = state.remux, let existingServer = state.server { return (existing, existingServer, true) }   // a concurrent call won
            state.remux = remux
            state.server = server
            return (remux, server, false)
        }
        if outcome.lost { server.stop(); remux.close() }
        return (outcome.0, outcome.1)
    }

    private nonisolated(unsafe) static var associationKey: UInt8 = 0

    /// Ties this session's lifetime to the item, so the server lives exactly as long as the item does.
    @MainActor
    private func attach(_ item: AVPlayerItem) -> AVPlayerItem {
        objc_setAssociatedObject(item, &Self.associationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return item
    }
}
