import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import os

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
        /// Pictures shown larger and sharper by ``enhancesPicture``.
        public var enhancedFrames = 0
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
    /// Enhanced Quality: Apple's low-latency super-resolution scaler makes each picture larger and sharper on the device before it is
    /// shown (VideoToolbox's `VTFrameProcessor`), for films whose pictures it takes (``canEnhancePicture``); a picture it cannot take is
    /// shown as it is. Off by default.
    public var enhancesPicture = false {
        didSet { pipeline.setEnhancing(enhancesPicture) }
    }

    /// Whether ``enhancesPicture`` can reach this film: the device has the scaler, and the picture is 8 bits, 4:2:0, of a size the
    /// scaler takes (DVDs, 720p and the like; a full-HD picture has no factor).
    public var canEnhancePicture: Bool {
        guard let video = session.info.videoTracks.first?.video, (video.bitDepth ?? 8) <= 8, (video.chroma ?? .yuv420) == .yuv420 else {
            return false
        }
        return PictureEnhancer.scale(width: video.width, height: video.height) != nil
    }

    public var deinterlacing: Deinterlacing = .automatic {
        didSet { pipeline.setDeinterlacing(deinterlacing) }
    }

    @ObservationIgnored private let pipeline: SoftwareVideoPipeline
    @ObservationIgnored private let audio: (player: AVPlayer, item: AVPlayerItem)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var overlay: SubtitleRenderer?
    public var subtitleAppearance = SubtitleAppearance.standard { didSet { overlay?.appearance = subtitleAppearance } }
    public var subtitleDelay: TimeInterval = 0 { didSet { overlay?.delay = subtitleDelay } }
    /// For the sound, which an `AVPlayer` of its own plays (``PlaybackController/allowedAudioSpatialization``).
    public var allowedAudioSpatialization: AVAudioSpatializationFormats {
        get { audio?.item.allowedAudioSpatializationFormats ?? .monoStereoAndMultichannel }
        set { audio?.item.allowedAudioSpatializationFormats = newValue }
    }
    @ObservationIgnored private var wantedRate: Float = 1
    @ObservationIgnored private let videoEnded = LockedFlag()
    @ObservationIgnored private var audioFinished = false
    @ObservationIgnored private var lastSoundRestart = ContinuousClock.now - .seconds(10)
    /// The picture follows the sound over drifts up to this; a sound farther away (it came back late) joins the picture instead.
    private static let followLimit = 0.25
    /// A join of the sound is under way (``joinSound(_:picture:soundTime:wasPlaying:)``), and how far ahead of the picture it aims:
    /// it grows when the sound was not ready in time.
    @ObservationIgnored private var joiningSound = false
    @ObservationIgnored private var joinLead = 0.6
    private static let logger = Logger(subsystem: "dev.mediaengine", category: "player")
    @ObservationIgnored private var closed = false
    /// A jump is under way (counted, so that a jump made while another waits for its sound is the one that starts the clocks).
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var wantsToPlayAfterSeek = false

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
        let byteSource = session.source.byteSource, cancellation = session.cancellation, duration = session.info.duration
        let reader = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PacketReader, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try PacketReader(source: byteSource, cancellation: cancellation, durationHint: duration) })
            }
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
        lastSoundRestart = ContinuousClock.now            // the sound waits for its start time: not a sound that stopped
    }

    /// Brings the sound to the picture, which goes on meanwhile: the sound pauses, seeks exactly to where the picture will be a moment
    /// later, and starts on the host time at which the picture gets there. `setRate(_:time:atHostTime:)` alone does not move an
    /// HLS item that plays elsewhere: after a switch of sound track the sound went on 1.5 s behind the picture, and asking it again
    /// every second changed nothing (2026-11-17).
    private func joinSound(_ player: AVPlayer, picture: Double, soundTime: Double, wasPlaying: Bool) {
        joiningSound = true
        lastSoundRestart = ContinuousClock.now
        let generation = seekGeneration
        let target = picture + joinLead * Double(wantedRate)
        let began = ContinuousClock.now
        Self.logger.notice("Sound joins the picture at \(target, format: .fixed(precision: 2), privacy: .public) s (it was \(wasPlaying ? "playing" : "stopped", privacy: .public) at \(soundTime, format: .fixed(precision: 2), privacy: .public) s, the picture at \(picture, format: .fixed(precision: 2), privacy: .public) s)")
        player.pause()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 90_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in self?.soundSought(to: target, finished: finished, generation: generation, began: began) }
        }
    }

    private func soundSought(to target: Double, finished: Bool, generation: Int, began: ContinuousClock.Instant) {
        joiningSound = false
        guard finished, !closed, state == .playing, !seeking, generation == seekGeneration, let audio else { return }
        let took = ContinuousClock.now - began
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let wait = (target - pipeline.synchronizer.currentTime().seconds) / Double(max(wantedRate, 0.1))
        guard wait > 0.02 else {
            // The picture got there first: aim farther ahead (by what the seek took) and try again with the next tick.
            joinLead = min(max(seconds + 0.5, joinLead * 1.5), 4)
            lastSoundRestart = ContinuousClock.now - .seconds(1)
            Self.logger.notice("Sound was not ready before the picture reached \(target, format: .fixed(precision: 2), privacy: .public) s: trying again \(self.joinLead, format: .fixed(precision: 1), privacy: .public) s ahead")
            return
        }
        audio.player.setRate(wantedRate, time: CMTime(seconds: target, preferredTimescale: 90_000), atHostTime: hostTime(after: wait))
        lastSoundRestart = ContinuousClock.now
        joinLead = min(max(seconds + 0.3, 0.6), 4)             // the next join aims as far ahead as this seek needed
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
        statistics = Statistics(decodedFrames: stats.decoded, displayedFrames: stats.queued, droppedFrames: stats.dropped,
                                enhancedFrames: stats.enhanced)
        // While a jump waits for its picture reader and its sound, the clocks are the jump's: the sound player is paused for it,
        // and the rejoin below took that for a sound that stopped by itself, started both clocks from the old place, and after a
        // jump that waited 53 s for its sound the picture clock stood 54 s past the target (2026-11-17, Lost in Translation).
        guard state == .playing, !seeking else { return }
        let picture = pipeline.synchronizer.currentTime().seconds
        session.notePlayhead(picture)
        session.notePlaying()
        if let audio {
            let sound = audio.item
            if !audioFinished, let length = duration ?? Optional(sound.duration.seconds), sound.currentTime().seconds >= min(length, sound.duration.seconds) - 0.15 { audioFinished = true }
            if !audioFinished {
                // The picture never waits for the sound (the app's owner, 2026-11-17: "change audio but still play video so that audio
                // doesn't trigger a movie to stop"). While the sound plays, the picture follows it over small drifts; when the sound
                // has stopped (its data ran out, a switch of track) or came back far from the picture, the picture goes on and the
                // sound joins it where the picture is, as soon as it has data (at most once a second), as VLC does. Before, an empty
                // sound buffer held the picture, and a sound that came back behind pulled the picture back with it.
                let soundTime = audio.player.currentTime().seconds
                let playing = audio.player.timeControlStatus == .playing && audio.player.rate > 0
                if playing, abs(soundTime - picture) <= Self.followLimit {
                    if abs(soundTime - picture) > 0.06 {
                        pipeline.synchronizer.setRate(wantedRate, time: audio.player.currentTime())      // the picture follows the sound
                    }
                } else if !joiningSound, ContinuousClock.now - lastSoundRestart > .seconds(1) {
                    joinSound(audio.player, picture: picture, soundTime: soundTime, wasPlaying: playing)
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
            // During a jump the clocks wait for it; it starts them when its picture and sound are there.
            if seeking { wantsToPlayAfterSeek = true; return }
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
        if seeking { wantsToPlayAfterSeek = false; state = .paused; return }      // the jump's clocks are stopped already
        currentTime = pipeline.synchronizer.currentTime().seconds
        stopClocks()
        state = .paused
    }

    public func setRate(_ newRate: Float) {
        if newRate == 0 { pause(); return }
        wantedRate = min(max(newRate, 0.5), 2)
        if state == .playing, !seeking { startClocks() }
    }

    /// The picture is neither decoded nor drawn while this is on; the sound and the clock go on, and so does a jump (it moves the sound
    /// and the clock). For a host that keeps the sound playing while it is not on screen (the app's Jira EGA-112): a picture layer the
    /// system stops in the background would otherwise end the picture for good, and decoding nobody sees costs battery. Turned off, the
    /// picture starts again where the clock stands.
    public private(set) var isPictureSuspended = false

    public func setPictureSuspended(_ suspended: Bool) async {
        guard suspended != isPictureSuspended, state != .failed, state != .loading, !closed else { return }
        isPictureSuspended = suspended
        if suspended {
            await pipeline.stop()
        } else {
            await pipeline.start(at: max(pipeline.synchronizer.currentTime().seconds, 0))
        }
    }

    public func seek(to time: TimeInterval) async {
        guard state != .failed, state != .loading else { return }
        let target = min(max(time, 0), duration ?? .greatestFiniteMagnitude)
        // A jump made while another one waits keeps the first one's wish to play.
        let wasPlaying = state == .playing || (seeking && wantsToPlayAfterSeek)
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        joiningSound = false
        wantsToPlayAfterSeek = wasPlaying
        stopClocks()
        videoEnded.set(false)
        audioFinished = false
        currentTime = target
        pipeline.synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 90_000))
        if !isPictureSuspended { await pipeline.start(at: target) }
        if let audio { await audio.player.seek(to: CMTime(seconds: target, preferredTimescale: 90_000), toleranceBefore: .zero, toleranceAfter: .zero) }
        guard generation == seekGeneration, !closed else { return }              // a later jump took over
        seeking = false
        if wantsToPlayAfterSeek { state = .playing; startClocks() } else { state = .paused }
    }

    public var audioChoices: [TrackChoice] { session.audioChoices }
    public var subtitleChoices: [TrackChoice] { session.overlayChoices }

    /// The sound player switches to the processed copy; the picture goes on, and the sound joins it as after a switch of track.
    public func applySoundProcessing(_ processing: Bool) async throws {
        guard let audio else { return }
        try await session.applySoundProcessing(processing, on: audio.item)
    }

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
