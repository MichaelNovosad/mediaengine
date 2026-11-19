import AVFoundation
import Foundation

extension PlaybackSession {
    /// A player for the file, whichever way the engine plays it: AVPlayer (``AVPlayerController``) for native files and for
    /// files the engine remuxes, the engine's own decoders (``SoftwareController``) for video Apple cannot decode. The
    /// result follows the ``PlaybackController`` protocol, so the app's code does not depend on which one it got; use
    /// ``PlaybackController/path`` to know.
    ///
    /// ```swift
    /// let session = try await PlaybackSession(url: fileURL)
    /// let player = try await session.makeController()
    /// player.play()
    /// ```
    @MainActor
    public func makeController() async throws -> any PlaybackController {
        let plan = info.playbackPlan
        switch plan.path {
        case .unsupported:
            throw MediaError.unsupported(detail: plan.blockingReason?.detail ?? "unsupported media")
        case .software:
            return try await SoftwareController.make(session: self)
        case .native, .remux:
            let item = try await makePlayerItem()
            return AVPlayerController(session: self, item: item, path: plan.path)
        }
    }

    /// An item that plays the sound of the file through AVPlayer (the engine's HLS stream without the video), for the
    /// software path, which draws the pictures itself. `nil` when the file has no audio the system can play.
    @MainActor
    func makeAudioItem() async throws -> AVPlayerItem? {
        guard !ServedTracks(info: info, externalAudio: externalAudio).audio.isEmpty else { return nil }
        let remux = try await startRemux()
        let server = try await startServer(for: remux)
        let item = AVPlayerItem(url: server.masterURL)
        // Only a little ahead: every piece of sound it asks for makes the engine read the whole stream around it, picture included, and
        // AVPlayer's own choice took it minutes ahead of the film (2026-11-19: Lost in Translation read at 3.6 times its own rate). From a
        // network source no further than the picture reader can follow from the shared read cache: 20 s of a 5 MB/s film did not fit,
        // and the picture reader fetched every byte again (2026-11-19).
        item.preferredForwardBufferDuration = min(Self.soundForwardBuffer, remux.soundLead)
        return attach(item)
    }

    /// Seconds of sound the engine's own player buffers ahead of the playhead (a hint AVPlayer follows for streams like this one).
    static let soundForwardBuffer: TimeInterval = 20
}
