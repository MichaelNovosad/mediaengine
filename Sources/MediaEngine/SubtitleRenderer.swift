import CoreGraphics
import Foundation
import Synchronization

/// One picture of an overlay: where to draw it and what.
public struct SubtitleImage: @unchecked Sendable {
    /// Premultiplied RGBA, in sRGB.
    public var image: CGImage
    /// Where it goes in the frame the renderer was asked for, in pixels, origin at the top left.
    public var frame: CGRect
}

/// What to draw over the video at one moment.
public struct SubtitleFrame: Sendable {
    /// The pictures, back to front. Empty when no subtitle is shown.
    public var images: [SubtitleImage]
    /// `false` when `images` is exactly what the previous call (at the same size) returned, so a host can skip redrawing.
    public var changed: Bool
    /// The size of the frame the pictures were made for.
    public var size: CGSize
}

/// Draws subtitles the system player cannot: ASS/SSA with their full styling (karaoke, rotation, blur, clips, vector
/// drawings, embedded fonts, any script the system has a font for) and picture subtitles (PGS, VobSub, DVB).
///
/// ```swift
/// let choice = session.overlayChoices.first!
/// let renderer = try await session.makeSubtitleRenderer(for: choice)
/// // On every display refresh, with the player's current time and the size of the video area on screen:
/// let frame = renderer.frame(at: player.currentTime().seconds, size: videoRect.size)
/// if frame.changed { overlayLayer.update(frame.images) }          // each image is a CGImage with its frame
/// ```
///
/// While the session plays through AVPlayer, the blocks come from the reading the session does for the player anyway, so a
/// file on a server is not downloaded twice; otherwise (and for what the player did not read: before a seek) they are read
/// from the file a window at a time, ahead of the time you ask for and on a background queue. ``frame(at:size:)`` itself
/// never waits for the file. After a seek, a few frames may come without subtitles that are about to be loaded;
/// ``prepare(at:)`` waits for what can be read when that matters (a paused frame, a screenshot).
///
/// The renderer does not move the video: turn the player's own subtitle track off (``PlaybackSession/deselectSubtitles(on:)``)
/// when you draw the same track yourself.
public final class SubtitleRenderer: @unchecked Sendable {
    /// Seconds before the requested time that are loaded (a block that began earlier and is still on screen).
    static let lookback = 15.0
    /// Seconds after the requested time that are loaded in one go.
    static let lookahead = 45.0
    /// Loading the next window starts when fewer seconds than this remain.
    static let refill = 12.0
    /// With blocks from the player's reading: seconds ahead of the requested time that must be there already.
    static let feedLead = 3.0
    /// While waiting for the player's reading, how often to look again (seconds).
    static let feedRecheck = 0.25
    /// After a failed read of the file, how long to wait before the next try (seconds).
    static let retryDelay = 1.0

    private struct State: @unchecked Sendable {
        var backend: (any OverlayBackend)?
        /// The file times for which every block that starts inside has been loaded.
        var coverage = TimeRanges()
        var loading = false
        var appearance = SubtitleAppearance.standard
        var delay = 0.0
        /// The player's reading, once the session has it (see ``OverlayFeed``).
        var feed: (any OverlayFeedSource)?
        /// Its windows already given to the backend, and its serial when it was last looked at.
        var taken = Set<Int>()
        var feedSerial = -1
        var lastPass: ContinuousClock.Instant?
        var retryAfter: ContinuousClock.Instant?
        /// A read of the file is under way on `readQueue` (with the player's reading, reads do not hold up taking its windows).
        var reading = false
        var closed: Bool { backend == nil }
    }

    private let state: Mutex<State>
    private let loader: (any OverlayEventSource)?
    /// Finds the player's reading of this track once it exists (`nil`: there is none, or not yet).
    private let findFeed: (@Sendable () -> (any OverlayFeedSource)?)?
    private let queue = DispatchQueue(label: "mediaengine.subtitle-loader", qos: .userInitiated)
    /// Where the file itself is read (`loader` is used here only).
    private let readQueue = DispatchQueue(label: "mediaengine.subtitle-reader", qos: .userInitiated)
    /// With the player's reading: how far back from the requested time the file is read when the player did not read it (after a
    /// seek). Shorter than ``lookback`` for files on a server, where that read competes with the player for the connection.
    private let seekLookback: Double
    /// Seconds to add to a file time to get the player's time (the global shift of the HLS timeline) plus the file's delay.
    private let offset: @Sendable () -> Double
    private let cancellation: CancellationFlag

    init(backend: any OverlayBackend, loader: (any OverlayEventSource)?, feed: (@Sendable () -> (any OverlayFeedSource)?)? = nil,
         seekLookback: Double = SubtitleRenderer.lookback, cancellation: CancellationFlag, offset: @escaping @Sendable () -> Double) {
        var initial = State(backend: backend)
        if loader == nil, feed == nil { initial.coverage = .everything }          // a whole script, given up front
        state = Mutex(initial)
        self.loader = loader
        findFeed = feed
        self.seekLookback = min(max(seekLookback, 0), Self.lookback)
        self.cancellation = cancellation
        self.offset = offset
    }

    deinit { close() }

    /// The pictures to draw at the player's `time` (seconds) in a frame of `size` pixels, origin top left. Pass the size
    /// of the video as it appears on screen, in pixels.
    public func frame(at time: TimeInterval, size: CGSize) -> SubtitleFrame {
        let playhead = time - offset()
        let fileTime = playhead - delay
        scheduleLoad(forFileTime: fileTime, playhead: playhead)
        let result = state.withLock { state in
            state.backend?.render(at: fileTime, size: size) ?? (images: [], changed: false)
        }
        return SubtitleFrame(images: result.images, changed: result.changed, size: size)
    }

    /// Reads the blocks around `time` now, if they are not loaded yet.
    public func prepare(at time: TimeInterval) async throws {
        guard loader != nil || findFeed != nil else { return }
        let playhead = time - offset()
        let fileTime = playhead - delay
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result { try load(forFileTime: fileTime, playhead: playhead, waitForReads: true) })
            }
        }
    }

    /// Stops reading and frees the renderer. Frames after this are empty.
    public func close() {
        let released = state.withLock { state -> (any OverlayBackend)? in
            defer { state.backend = nil; state.feed = nil }
            return state.backend
        }
        _ = released
    }

    /// Seconds by which the viewer wants every subtitle of this track later (negative: earlier), on top of the file's own delay.
    public var delay: TimeInterval {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue.isFinite ? min(max(newValue, -600), 600) : 0 } }
    }

    /// The size and text colour the viewer chose; the next frame follows it. Picture subtitles do not change.
    public var appearance: SubtitleAppearance {
        get { state.withLock { $0.appearance } }
        set {
            state.withLock { state in
                state.appearance = newValue
                state.backend?.setAppearance(newValue)
            }
        }
    }

    /// Diagnostic lines libass printed (font selection, script problems); empty for picture subtitles.
    var diagnostics: [String] { state.withLock { ($0.backend as? ASSBackend)?.core.log.all ?? [] } }

    // MARK: Loading

    /// `back` seconds before `fileTime` to `ahead` seconds after it, never before zero (a viewer's delay can put the time
    /// before the start of the file).
    private static func span(_ fileTime: Double, back: Double, ahead: Double) -> ClosedRange<Double> {
        let lower = max(0, fileTime - back)
        return lower...max(lower, fileTime + ahead)
    }

    /// The file times to have loaded when `fileTime` is on screen, reading the file.
    private static func wanted(_ fileTime: Double) -> ClosedRange<Double> { span(fileTime, back: lookback, ahead: lookahead) }

    /// The file times that must be loaded already when `fileTime` is on screen: with the player's reading only a little ahead
    /// (it reads ahead itself), without it far enough ahead that the next read of the file has time to finish.
    private func required(_ fileTime: Double, fed: Bool) -> ClosedRange<Double> {
        fed ? Self.span(fileTime, back: seekLookback, ahead: Self.feedLead) : Self.span(fileTime, back: Self.lookback, ahead: Self.refill)
    }

    /// The player's reading of this track, found once the session has started it.
    private func feed() -> (any OverlayFeedSource)? {
        guard let findFeed else { return nil }
        if let known = state.withLock({ $0.feed }) { return known }
        guard let found = findFeed() else { return nil }
        return state.withLock { state -> (any OverlayFeedSource)? in
            guard !state.closed else { return nil }
            if state.feed == nil { state.feed = found }
            return state.feed
        }
    }

    private func scheduleLoad(forFileTime fileTime: Double, playhead: Double) {
        guard loader != nil || findFeed != nil else { return }
        let feed = feed()
        let serial = feed?.serial
        let now = ContinuousClock.now
        let needs = state.withLock { state -> Bool in
            guard !state.closed, !state.loading else { return false }
            if let retry = state.retryAfter, now < retry { return false }
            var needs = !state.coverage.covers(required(fileTime, fed: feed != nil))
            if let serial {
                // New windows from the player's reading are taken at once; while waiting for one, look again now and then.
                if serial != state.feedSerial { needs = true }
                else if needs, let last = state.lastPass, now - last < .seconds(Self.feedRecheck) { needs = false }
            }
            if needs { state.loading = true }
            return needs
        }
        guard needs else { return }
        queue.async { [self] in
            do {
                try load(forFileTime: fileTime, playhead: playhead, waitForReads: false)
            } catch {
                state.withLock { $0.retryAfter = ContinuousClock.now + .seconds(Self.retryDelay) }
            }
            state.withLock { $0.loading = false }
        }
    }

    /// Takes what the player's reading has around `fileTime` and reads from the file what will not come that way. Runs on
    /// `queue`. Reads of the file run on `readQueue`; with the player's reading this returns without waiting for them unless
    /// `waitForReads` (``prepare(at:)``).
    private func load(forFileTime fileTime: Double, playhead: Double, waitForReads: Bool) throws {
        let closed = state.withLock { state in
            state.lastPass = ContinuousClock.now
            return state.closed
        }
        if closed || cancellation.isCancelled { throw MediaError.cancelled }
        let feed = feed()
        if let feed {
            // The serial is read first: a window recorded meanwhile makes the next frame look again.
            let serial = feed.serial
            let taken = state.withLock { $0.taken }
            let windows = feed.windows(overlapping: Self.span(fileTime, back: Self.lookback + 5, ahead: Self.lookahead), except: taken)
            state.withLock { state in
                state.feedSerial = serial
                guard !state.closed, !windows.isEmpty else { return }
                state.backend?.add(windows.flatMap(\.events))
                for window in windows {
                    state.taken.insert(window.number)
                    state.coverage.insert(window.range)
                }
            }
        }

        guard loader != nil else { return }
        let coverage = state.withLock { $0.coverage }
        let missing = coverage.missing(in: required(fileTime, fed: feed != nil))
        guard !missing.isEmpty else { return }
        guard let feed else {
            let reads = coverage.missing(in: Self.wanted(fileTime))
            if !reads.isEmpty { try readQueue.sync { try read(reads, then: nil) } }
            return
        }
        // Only what the player's reading will not bring in time (whole windows, each once), one read at a time.
        var pending = TimeRanges()
        for window in feed.lost(in: missing[0].lowerBound...missing[missing.count - 1].upperBound, playhead: playhead) {
            for gap in coverage.missing(in: window) { pending.insert(gap) }
        }
        let reads = pending.ranges
        guard !reads.isEmpty, state.withLock({ state -> Bool in
            guard !state.reading else { return false }
            state.reading = true
            return true
        }) else { return }
        if waitForReads {
            defer { state.withLock { $0.reading = false } }
            try readQueue.sync { try read(reads, then: feed) }
        } else {
            readQueue.async { [self] in
                do {
                    try read(reads, then: feed)
                } catch {
                    state.withLock { $0.retryAfter = ContinuousClock.now + .seconds(Self.retryDelay) }
                }
                state.withLock { $0.reading = false }
            }
        }
    }

    /// Reads `ranges` of the file and gives their blocks to the backend. Runs on `readQueue`.
    private func read(_ ranges: [ClosedRange<Double>], then feed: (any OverlayFeedSource)?) throws {
        guard let loader else { return }
        if state.withLock({ $0.closed }) || cancellation.isCancelled { throw MediaError.cancelled }
        var events: [OverlayEvent] = []
        for range in ranges { events += try loader.events(from: range.lowerBound, to: range.upperBound) }
        // A decoder that builds on the blocks before (PGS) has seen the player's windows after this part already, out of order:
        // they are given again behind it, so that a block that needs an earlier one is decoded right this time.
        if let feed, let last = ranges.last, state.withLock({ $0.backend?.decodesInOrder ?? false }) {
            events += feed.windows(overlapping: last.upperBound...(last.upperBound + 10), except: []).flatMap(\.events)
        }
        state.withLock { state in
            guard !state.closed else { return }
            state.backend?.add(events)
            for range in ranges { state.coverage.insert(range) }
        }
    }
}
