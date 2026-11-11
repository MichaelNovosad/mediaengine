import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation

/// Plays a file with the engine's own decoders: the pictures are decoded in software and shown on ``displayLayer`` (put
/// it in a view with ``MediaVideoView``), the sound comes from AVPlayer through the engine's audio stream, and the two
/// start together on the same host time and are kept in step (the picture follows the sound). Get one from
/// ``PlaybackSession/makeController()``; use it through ``PlaybackController``.
@MainActor @Observable
public final class SoftwareController: PlaybackController {
    /// What the decoder and the display have done so far.
    public struct Statistics: Sendable, Equatable {
        public var decodedFrames = 0
        /// Pictures handed to the display.
        public var displayedFrames = 0
        /// Pictures skipped because they were late when decoded: the machine could not keep up.
        public var droppedFrames = 0
    }

    public let session: PlaybackSession
    public var path: PlaybackPath { .software }
    public private(set) var state: PlaybackState = .loading
    public private(set) var error: MediaError?
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var rate: Float = 0
    public var isMuted = false { didSet { audio?.player.isMuted = isMuted } }
    public private(set) var statistics = Statistics()
    public var duration: TimeInterval? { session.duration }
    /// Shows the pictures. Give it to ``MediaVideoView`` or add it to your own layer tree.
    public let displayLayer: AVSampleBufferDisplayLayer
    /// What happens to interlaced pictures (a DVD or broadcast recording, for example). Takes effect from the next picture.
    public var deinterlacing: Deinterlacing = .automatic {
        didSet { pipeline.setDeinterlacing(deinterlacing) }
    }

    @ObservationIgnored private let pipeline: SoftwareVideoPipeline
    @ObservationIgnored private let audio: (player: AVPlayer, item: AVPlayerItem)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var overlay: SubtitleRenderer?
    public var subtitleAppearance = SubtitleAppearance.standard { didSet { overlay?.appearance = subtitleAppearance } }
    public var subtitleDelay: TimeInterval = 0 { didSet { overlay?.delay = subtitleDelay } }
    @ObservationIgnored private var wantedRate: Float = 1
    @ObservationIgnored private let videoEnded = LockedFlag()
    @ObservationIgnored private var audioFinished = false
    @ObservationIgnored private var holdingForAudio = false
    @ObservationIgnored private var closed = false

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    private init(session: PlaybackSession, pipeline: SoftwareVideoPipeline, audioItem: AVPlayerItem?) {
        self.session = session
        self.pipeline = pipeline
        displayLayer = pipeline.layer
        if let audioItem {
            let player = AVPlayer(playerItem: audioItem)
            player.automaticallyWaitsToMinimizeStalling = false
            audio = (player, audioItem)
        } else {
            audio = nil
        }
        let ended = videoEnded
        pipeline.onEnd { ended.set(true) }
    }

    deinit { ticker?.cancel() }

    static func make(session: PlaybackSession) async throws -> SoftwareController {
        guard let video = session.info.videoTracks.first else { throw MediaError.unsupported(detail: "the file has no video") }
        let byteSource = session.source.byteSource, cancellation = session.cancellation
        let reader = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PacketReader, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try PacketReader(source: byteSource, cancellation: cancellation) }) }
        }
        let pipeline = try SoftwareVideoPipeline(reader: reader, stream: video.id, frameRate: video.video?.frameRate)
        let controller = SoftwareController(session: session, pipeline: pipeline, audioItem: try await session.makeAudioItem())
        await controller.prepare()
        return controller
    }

    private func prepare() async {
        pipeline.synchronizer.setRate(0, time: .zero)
        await pipeline.start(at: 0)
        if let audio {
            let ready = await waitFor(seconds: 15) { audio.item.status != .unknown }
            if !ready || audio.item.status == .failed {
                error = MediaError.engine(detail: audio.item.error.map { "\($0)" } ?? "the sound did not start")
                state = .failed
                return
            }
        }
        state = .ready
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled, let controller = self {
                controller.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func waitFor(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Clock

    private func hostTime(after delay: Double) -> CMTime {
        CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: delay, preferredTimescale: 1_000_000))
    }

    /// Starts picture and sound together, from `currentTime`.
    private func startClocks() {
        let time = CMTime(seconds: currentTime, preferredTimescale: 90_000)
        let host = hostTime(after: 0.15)
        audio?.player.setRate(wantedRate, time: time, atHostTime: host)
        pipeline.synchronizer.setRate(wantedRate, time: time, atHostTime: host)
        rate = wantedRate
        holdingForAudio = false
    }

    private func stopClocks() {
        audio?.player.pause()
        let time = pipeline.synchronizer.currentTime()
        pipeline.synchronizer.setRate(0, time: time)
        rate = 0
    }

    /// Runs ten times a second: the time, keeping the picture with the sound, the end of the film, the counters.
    private func tick() {
        guard !closed else { return }
        let stats = pipeline.currentStatistics
        statistics = Statistics(decodedFrames: stats.decoded, displayedFrames: stats.queued, droppedFrames: stats.dropped)
        guard state == .playing else { return }
        let picture = pipeline.synchronizer.currentTime().seconds
        if let audio {
            let sound = audio.item
            if !audioFinished, let length = duration ?? Optional(sound.duration.seconds), sound.currentTime().seconds >= min(length, sound.duration.seconds) - 0.15 { audioFinished = true }
            if !audioFinished {
                if audio.player.timeControlStatus == .playing, audio.player.rate > 0 {
                    if holdingForAudio { pipeline.synchronizer.setRate(wantedRate, time: audio.player.currentTime()); holdingForAudio = false }
                    else if abs(audio.player.currentTime().seconds - picture) > 0.06 {
                        pipeline.synchronizer.setRate(wantedRate, time: audio.player.currentTime())      // the picture follows the sound
                    }
                } else if !holdingForAudio, audio.item.isPlaybackBufferEmpty {
                    pipeline.synchronizer.setRate(0, time: pipeline.synchronizer.currentTime())          // the sound is buffering: hold the picture
                    holdingForAudio = true
                }
            }
        }
        currentTime = max(pipeline.synchronizer.currentTime().seconds, 0)
        let lastPicture = pipeline.currentStatistics.lastQueuedTime
        if videoEnded.isSet, currentTime >= min(lastPicture + 0.1, duration ?? .greatestFiniteMagnitude) {
            if audio == nil || audioFinished || (duration.map { currentTime >= $0 - 0.1 } ?? false) { finish() }
        }
    }

    private func finish() {
        stopClocks()
        currentTime = duration ?? currentTime
        state = .ended
    }

    // MARK: PlaybackController

    public func play() {
        switch state {
        case .ready, .paused:
            state = .playing
            startClocks()
        case .ended:
            Task { await seek(to: 0); play() }
        default:
            break
        }
    }

    public func pause() {
        guard state == .playing else { return }
        currentTime = pipeline.synchronizer.currentTime().seconds
        stopClocks()
        state = .paused
    }

    public func setRate(_ newRate: Float) {
        if newRate == 0 { pause(); return }
        wantedRate = min(max(newRate, 0.5), 2)
        if state == .playing { startClocks() }
    }

    public func seek(to time: TimeInterval) async {
        guard state != .failed, state != .loading else { return }
        let target = min(max(time, 0), duration ?? .greatestFiniteMagnitude)
        let wasPlaying = state == .playing
        stopClocks()
        videoEnded.set(false)
        audioFinished = false
        currentTime = target
        pipeline.synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90_000))
        await pipeline.start(at: target)
        if let audio { await audio.player.seek(to: CMTime(seconds: target, preferredTimescale: 90_000), toleranceBefore: .zero, toleranceAfter: .zero) }
        if wasPlaying { state = .playing; startClocks() } else { state = .paused }
    }

    public var audioChoices: [TrackChoice] { session.audioChoices }
    public var subtitleChoices: [TrackChoice] { session.overlayChoices }

    public func select(_ choice: TrackChoice) async throws {
        if choice.kind == .audio {
            guard let audio else { throw MediaError.unsupported(detail: "the file has no sound to switch") }
            try await session.select(choice, on: audio.item)
            return
        }
        overlay?.close(); overlay = nil
        let renderer = try await session.makeSubtitleRenderer(for: choice)
        try? await renderer.prepareForChoice(at: currentTime)
        renderer.appearance = subtitleAppearance
        renderer.delay = subtitleDelay
        overlay = renderer
    }

    public func deselectSubtitles() async throws {
        overlay?.close(); overlay = nil
    }

    public func subtitleFrame(size: CGSize) -> SubtitleFrame? {
        guard let overlay else { return nil }
        // While playing, the picture clock itself rather than `currentTime`, which is refreshed every 100 ms.
        let now = state == .playing ? max(pipeline.synchronizer.currentTime().seconds, 0) : currentTime
        return overlay.frame(at: now.isFinite ? now : currentTime, size: size)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        ticker?.cancel()
        audio?.player.pause()
        overlay?.close()
        let pipeline = pipeline, session = session
        Task { await pipeline.close(); session.close() }
        state = .paused
    }

    /// How far the sound is ahead of the picture right now, in seconds (`nil` without sound). Diagnostics and tests.
    var soundLead: Double? {
        audio.map { $0.player.currentTime().seconds - pipeline.synchronizer.currentTime().seconds }
    }

    /// Makes the pictures available to tests and diagnostics.
    func onFrame(_ handler: (@Sendable (DecodedFrame) -> Void)?) { pipeline.onFrame(handler) }
}
