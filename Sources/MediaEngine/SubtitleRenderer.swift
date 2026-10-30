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
/// Subtitle blocks are read from the file a window at a time, ahead of the time you ask for and on a background queue;
/// ``frame(at:size:)`` itself never waits for the file. After a seek, a few frames may come without subtitles that
/// are about to be loaded; ``prepare(at:)`` waits for them when that matters (a paused frame, a screenshot).
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

    private struct State: @unchecked Sendable {
        var backend: (any OverlayBackend)?
        /// The file times for which every block that starts inside has been loaded.
        var coverage: ClosedRange<Double>?
        var loading = false
        var appearance = SubtitleAppearance.standard
        var delay = 0.0
        var closed: Bool { backend == nil }
    }

    private let state: Mutex<State>
    private let loader: (any OverlayEventSource)?
    private let queue = DispatchQueue(label: "mediaengine.subtitle-loader", qos: .userInitiated)
    /// Seconds to add to a file time to get the player's time (the global shift of the HLS timeline) plus the file's delay.
    private let offset: @Sendable () -> Double
    private let cancellation: CancellationFlag

    init(backend: any OverlayBackend, loader: (any OverlayEventSource)?, cancellation: CancellationFlag, offset: @escaping @Sendable () -> Double) {
        state = Mutex(State(backend: backend, coverage: loader == nil ? 0...Double.greatestFiniteMagnitude : nil))
        self.loader = loader
        self.cancellation = cancellation
        self.offset = offset
    }

    deinit { close() }

    /// The pictures to draw at the player's `time` (seconds) in a frame of `size` pixels, origin top left. Pass the size
    /// of the video as it appears on screen, in pixels.
    public func frame(at time: TimeInterval, size: CGSize) -> SubtitleFrame {
        let fileTime = time - offset() - delay
        scheduleLoad(forFileTime: fileTime)
        let result = state.withLock { state in
            state.backend?.render(at: fileTime, size: size) ?? (images: [], changed: false)
        }
        return SubtitleFrame(images: result.images, changed: result.changed, size: size)
    }

    /// Reads the blocks around `time` now, if they are not loaded yet.
    public func prepare(at time: TimeInterval) async throws {
        guard loader != nil else { return }
        let fileTime = time - offset() - delay
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result { try load(forFileTime: fileTime) })
            }
        }
    }

    /// Stops reading and frees the renderer. Frames after this are empty.
    public func close() {
        let released = state.withLock { state -> (any OverlayBackend)? in
            defer { state.backend = nil }
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

    /// The file times to have loaded when `fileTime` is on screen.
    private static func wanted(_ fileTime: Double) -> ClosedRange<Double> { max(0, fileTime - lookback)...(fileTime + lookahead) }

    private static func needsLoad(_ coverage: ClosedRange<Double>?, _ fileTime: Double) -> Bool {
        guard let coverage else { return true }
        let want = wanted(fileTime)
        if fileTime > coverage.upperBound || coverage.upperBound - fileTime < refill { return true }
        return want.lowerBound < coverage.lowerBound - 0.001 && coverage.lowerBound > 0
    }

    private func scheduleLoad(forFileTime fileTime: Double) {
        guard loader != nil else { return }
        let needs = state.withLock { state -> Bool in
            guard !state.closed, !state.loading, Self.needsLoad(state.coverage, fileTime) else { return false }
            state.loading = true
            return true
        }
        guard needs else { return }
        queue.async { [self] in
            defer { state.withLock { $0.loading = false } }
            try? load(forFileTime: fileTime)
        }
    }

    /// Loads what is missing around `fileTime`. Runs on `queue`.
    private func load(forFileTime fileTime: Double) throws {
        guard let loader else { return }
        let (current, closed) = state.withLock { ($0.coverage, $0.closed) }
        if closed || cancellation.isCancelled { throw MediaError.cancelled }
        guard Self.needsLoad(current, fileTime) else { return }
        let want = Self.wanted(fileTime)
        var reads: [(Double, Double)] = []
        var coverage = want
        if let current, want.upperBound >= current.lowerBound, want.lowerBound <= current.upperBound {
            if want.lowerBound < current.lowerBound { reads.append((want.lowerBound, current.lowerBound)) }
            if want.upperBound > current.upperBound { reads.append((current.upperBound, want.upperBound)) }
            coverage = min(current.lowerBound, want.lowerBound)...max(current.upperBound, want.upperBound)
        } else {
            reads.append((want.lowerBound, want.upperBound))
        }
        var events: [OverlayEvent] = []
        for read in reads { events += try loader.events(from: read.0, to: read.1) }
        state.withLock { state in
            guard !state.closed else { return }
            state.backend?.add(events)
            state.coverage = coverage
        }
    }
}
