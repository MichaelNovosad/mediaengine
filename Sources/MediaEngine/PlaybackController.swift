import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Where a player is in its life.
public enum PlaybackState: Sendable, Equatable {
    /// Opening the file and getting the first picture ready.
    case loading
    /// Ready to play from the current time.
    case ready
    case playing
    case paused
    /// Played to the end; ``PlaybackController/play()`` starts again from the beginning.
    case ended
    /// Could not continue; see ``PlaybackController/error``.
    case failed
}

/// The one interface to a player, whichever way the engine plays the file: through AVPlayer (``AVPlayerController``:
/// native files, and MKV and others remuxed for the system player) or with the engine's own decoders
/// (``SoftwareController``: codecs Apple cannot decode). An app written against this protocol does not care which
/// one it got; ``PlaybackSession/makeController()`` picks it. State is `@Observable`, so SwiftUI views follow it.
///
/// ```swift
/// let session = try await PlaybackSession(url: fileURL)
/// let controller = try await session.makeController()
/// controller.play()
/// ```
@MainActor
public protocol PlaybackController: AnyObject, Observable {
    var session: PlaybackSession { get }
    /// `.native` and `.remux` play through AVPlayer, `.software` with the engine's decoders.
    var path: PlaybackPath { get }
    var state: PlaybackState { get }
    /// What went wrong, when ``state`` is `.failed`.
    var error: MediaError? { get }
    /// Seconds into the film (updated ten times a second while playing).
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    /// 0 while paused, otherwise the playback speed.
    var rate: Float { get }
    /// Silences the sound without pausing (a mute button). Observable; applies at once.
    var isMuted: Bool { get set }

    func play()
    func pause()
    /// Plays at another speed (0.5 to 2); the player is paused with 0.
    func setRate(_ rate: Float)
    /// Moves to a time; returns when the picture is there.
    func seek(to time: TimeInterval) async
    /// The current time ten times a second, from the moment of the call until the controller is closed.
    var timeUpdates: AsyncStream<TimeInterval> { get }

    var audioChoices: [TrackChoice] { get }
    /// Subtitle tracks this player can show: the system player's text tracks, and tracks the engine draws itself
    /// (picture subtitles; everything in the software path).
    var subtitleChoices: [TrackChoice] { get }
    /// Switches to an audio or subtitle track.
    func select(_ choice: TrackChoice) async throws
    func deselectSubtitles() async throws
    /// What to draw over the video for subtitles the engine renders itself (`nil` when none is selected or the system
    /// player shows them). `size` is the video area on screen, in pixels.
    func subtitleFrame(size: CGSize) -> SubtitleFrame?
    /// The size and text colour the viewer wants for the subtitles the engine draws (see ``SubtitleAppearance``); it holds for every track
    /// that is chosen later too.
    var subtitleAppearance: SubtitleAppearance { get set }
    /// Seconds by which the viewer wants the subtitles that the engine draws later (negative: earlier); it holds for every track that is
    /// chosen later too. Subtitles that the system player draws itself (a plain MP4's own) are not moved.
    var subtitleDelay: TimeInterval { get set }

    /// Stops playback and releases the file.
    func close()
}

extension PlaybackController {
    public var timeUpdates: AsyncStream<TimeInterval> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                while !Task.isCancelled, let controller = self {
                    continuation.yield(controller.currentTime)
                    if controller.state == .ended { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Plays through AVPlayer: native files, and files the engine remuxes (`path` says which). ``player`` is the plain
/// `AVPlayer` for `AVPlayerViewController`, `AVPlayerView` or `VideoPlayer`.
@MainActor @Observable
public final class AVPlayerController: PlaybackController {
    public let session: PlaybackSession
    public let path: PlaybackPath
    public let player: AVPlayer
    public let item: AVPlayerItem
    /// A layer showing the picture, for ``MediaVideoView`` (no controls); use ``player`` with `AVPlayerViewController` for the system controls.
    public let videoLayer: AVPlayerLayer
    public private(set) var state: PlaybackState = .loading
    public private(set) var error: MediaError?
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var rate: Float = 0
    public var isMuted = false { didSet { player.isMuted = isMuted } }
    public var duration: TimeInterval? { session.duration }
    /// ASS tracks play through the system player as plain WebVTT text. Turn this on to have the engine draw them with
    /// their full styling instead (see ``subtitleFrame(size:)``).
    public var drawsASSItself = false
    public var subtitleAppearance = SubtitleAppearance.standard { didSet { overlay?.appearance = subtitleAppearance } }
    public var subtitleDelay: TimeInterval = 0 { didSet { overlay?.delay = subtitleDelay } }

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var overlay: SubtitleRenderer?
    /// 0 while the person has paused, otherwise the speed that is playing.
    @ObservationIgnored private var wantedRate: Float = 1
    /// The speed chosen with `setRate` (0.5 to 2), applied whenever playback starts.
    @ObservationIgnored private var speed: Float = 1

    init(session: PlaybackSession, item: AVPlayerItem, path: PlaybackPath) {
        self.session = session
        self.item = item
        self.path = path
        player = AVPlayer(playerItem: item)
        videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = .resizeAspect
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled, let controller = self {
                controller.refresh()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    deinit { ticker?.cancel() }

    private func refresh() {
        currentTime = max(item.currentTime().seconds.isFinite ? item.currentTime().seconds : 0, 0)
        rate = player.rate
        switch item.status {
        case .failed:
            if state != .failed { error = MediaError.engine(detail: item.error.map { "\($0)" } ?? "the player failed"); state = .failed }
        case .readyToPlay:
            let finished = (duration.map { currentTime >= $0 - 0.1 } ?? false) && player.rate == 0 && state != .ready
            if finished || (state == .playing && player.rate == 0 && item.duration.isNumeric && item.currentTime() >= item.duration - CMTime(value: 1, timescale: 10)) {
                state = .ended
            } else if state == .loading { state = .ready }
            else if state == .playing, player.timeControlStatus == .paused, wantedRate == 0 { state = .paused }
        default: break
        }
    }

    public func play() {
        guard state != .failed else { return }
        if state == .ended { Task { await seek(to: 0); play() }; return }
        // The speed the person chose (1 unless `setRate` said otherwise), also after a pause: `wantedRate` is 0 while paused.
        wantedRate = speed
        player.rate = speed
        state = .playing
    }

    public func pause() {
        player.pause()
        wantedRate = 0
        if state == .playing { state = .paused }
    }

    public func setRate(_ rate: Float) {
        if rate == 0 { pause(); return }
        speed = min(max(rate, 0.5), 2)
        if state == .playing { wantedRate = speed; player.rate = speed }
    }

    public func seek(to time: TimeInterval) async {
        let target = min(max(time, 0), duration ?? .greatestFiniteMagnitude)
        await item.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        if state == .ended { state = .paused }
    }

    public var audioChoices: [TrackChoice] { session.audioChoices }
    public var subtitleChoices: [TrackChoice] {
        let system = session.subtitleChoices
        let overlayIDs = Set(session.overlayChoices.map(\.id))
        let engineOnly = session.overlayChoices.filter { $0.isBitmap && !system.map(\.id).contains($0.id) }
        _ = overlayIDs
        return system + engineOnly
    }

    public func select(_ choice: TrackChoice) async throws {
        if choice.kind == .audio { try await session.select(choice, on: item); return }
        overlay?.close(); overlay = nil
        let systemIDs = Set(session.subtitleChoices.map(\.id))
        let engineDraws = choice.isBitmap || (drawsASSItself && session.overlayChoices.contains { $0.id == choice.id })
        if engineDraws {
            try await session.deselectSubtitles(on: item)
            let renderer = try await session.makeSubtitleRenderer(for: choice)
            try? await renderer.prepare(at: currentTime)
            renderer.appearance = subtitleAppearance
            renderer.delay = subtitleDelay
            overlay = renderer
        } else if systemIDs.contains(choice.id) {
            try await session.select(choice, on: item)
        } else {
            throw MediaError.unsupported(detail: "the track \"\(choice.title)\" cannot be shown")
        }
    }

    public func deselectSubtitles() async throws {
        overlay?.close(); overlay = nil
        try await session.deselectSubtitles(on: item)
    }

    public func subtitleFrame(size: CGSize) -> SubtitleFrame? {
        guard let overlay else { return nil }
        // The item's own clock rather than `currentTime`, which is refreshed every 100 ms: lines then start and end on time.
        let now = item.currentTime().seconds
        return overlay.frame(at: now.isFinite ? max(now, 0) : currentTime, size: size)
    }

    public func close() {
        ticker?.cancel()
        player.pause()
        overlay?.close()
        session.close()
    }
}
