internal import FFmpegLGPL
import Foundation
import Synchronization

/// A copy of one stream's codec parameters that lives as long as this object (2026-11-11): taken once from the remuxer's reader, so a
/// subtitle renderer can start (ASS styles, a picture decoder's set-up) without opening the file again. Never changed after it is made,
/// and FFmpeg only reads it (`avcodec_parameters_to_context`, the extradata), so it can be shared between threads.
final class StreamParameters: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<AVCodecParameters>

    init?(copying source: UnsafeMutablePointer<AVCodecParameters>) {
        guard let copy = avcodec_parameters_alloc() else { return nil }
        guard avcodec_parameters_copy(copy, source) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecParameters>? = copy
            avcodec_parameters_free(&pointer)
            return nil
        }
        pointer = copy
    }

    deinit {
        var copy: UnsafeMutablePointer<AVCodecParameters>? = pointer
        avcodec_parameters_free(&copy)
    }
}

/// The subtitle blocks the remuxer reads anyway (2026-11-06).
///
/// The remuxer reads every packet of a window of the file to build the player's segments, the subtitle blocks among them. The
/// overlay renderer used to read the file a second time, a minute at a time, only to find its blocks again: for a file on a
/// server that meant downloading most of the movie twice, and the second reader and the player's reads took turns with the
/// server's cache, so blocks came late (shown seconds after their start) or after their end (never shown). Now the remuxer
/// keeps the blocks of every stream the overlay can draw, per window, and the renderers take them from here
/// (``OverlayFeedView``); they read the file themselves only for what will not come this way (before a seek, or a window
/// forgotten here).
final class OverlayFeed: Sendable {
    /// The streams whose blocks are kept: every subtitle stream the overlay can draw.
    let streams: Set<Int>
    /// Their codec parameters, copied when the remuxer opened the file (see ``StreamParameters``).
    let parameters: [Int: StreamParameters]
    /// Picture streams (PGS, VobSub, DVB): their blocks are big, so those of a stream no renderer watches are kept only for the
    /// last ``pictureHistory`` windows read (enough to switch to one in the middle of a movie without reading the file).
    private let pictureStreams: Set<Int>
    /// The file times of the remuxer's windows (its segment plan), in order: every block that starts in a window's range has
    /// been seen once that window has been read.
    private let ranges: [Range<Double>]
    private let state = Mutex(State())
    /// Bytes of blocks kept at most; the windows read longest ago go first. Text tracks of a whole film take a few hundred KB.
    static let byteBudget = 24 * 1024 * 1024
    /// Windows (about six seconds each) for which the blocks of unwatched picture streams are kept.
    static let pictureHistory = 16
    /// Seconds ahead of the playhead within which a window that has not been read yet is waited for (the player reads ahead).
    static let waitHorizon = 10.0
    /// The playhead is taken this much later when windows are matched to it: a player paused a hair before a window's end
    /// (rounding) is about to play the next window, not the one it is in.
    private static let playheadSlack = 0.05

    private struct Window {
        var events: [Int: [OverlayEvent]]
        /// The streams whose blocks are all in `events` (a stream without blocks in this window is complete with none).
        var complete: Set<Int>
        var bytes: Int
    }

    private struct State {
        var held: [Int: Window] = [:]
        /// Windows read at least once (held or forgotten).
        var read = Set<Int>()
        /// Held windows, the one read longest ago first.
        var order: [Int] = []
        var bytes = 0
        var serial = 0
        /// How many renderers watch each picture stream.
        var watchers: [Int: Int] = [:]
    }

    init(textStreams: Set<Int>, pictureStreams: Set<Int>, windows: [Range<Double>], parameters: [Int: StreamParameters] = [:]) {
        streams = textStreams.union(pictureStreams)
        self.parameters = parameters
        self.pictureStreams = pictureStreams
        // The last window is read to the end of the file.
        ranges = windows.enumerated().map { $0.offset == windows.count - 1 ? $0.element.lowerBound..<Double.greatestFiniteMagnitude : $0.element }
    }

    /// Grows each time a window is read.
    var serial: Int { state.withLock { $0.serial } }

    /// A renderer draws `stream`: its picture blocks are kept from now on for every window.
    func watch(_ stream: Int) { state.withLock { $0.watchers[stream, default: 0] += 1 } }

    func unwatch(_ stream: Int) {
        state.withLock { state in
            let left = (state.watchers[stream] ?? 1) - 1
            state.watchers[stream] = left > 0 ? left : nil
        }
    }

    /// The remuxer has read window `number`; `events` are the blocks of ``streams`` it saw (in file time).
    func record(window number: Int, events: [Int: [OverlayEvent]]) {
        guard ranges.indices.contains(number) else { return }
        let bytes = Self.size(of: events)
        state.withLock { state in
            if let old = state.held.removeValue(forKey: number) {
                state.bytes -= old.bytes
                state.order.removeAll { $0 == number }
            }
            state.held[number] = Window(events: events, complete: streams, bytes: bytes)
            state.order.append(number)
            state.bytes += bytes
            state.read.insert(number)
            state.serial += 1
            // Picture blocks nobody draws: only the latest windows keep them.
            let unwatched = pictureStreams.subtracting(state.watchers.keys)
            if !unwatched.isEmpty {
                for old in state.order.dropLast(Self.pictureHistory) {
                    guard var window = state.held[old], !window.complete.isDisjoint(with: unwatched) else { continue }
                    window.complete.subtract(unwatched)
                    for stream in unwatched { window.events[stream] = nil }
                    let size = Self.size(of: window.events)
                    state.bytes -= window.bytes - size
                    window.bytes = size
                    state.held[old] = window
                }
            }
            while state.bytes > Self.byteBudget, state.order.count > 1 {
                let oldest = state.order.removeFirst()
                if let removed = state.held.removeValue(forKey: oldest) { state.bytes -= removed.bytes }
            }
        }
    }

    private static func size(of events: [Int: [OverlayEvent]]) -> Int {
        events.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count + 32 } }
    }

    /// The held windows that overlap `range` and are complete for `stream`, except those in `taken`, with its blocks.
    func windows(overlapping range: ClosedRange<Double>, stream: Int, except taken: Set<Int>) -> [OverlayFeedWindow] {
        let numbers = indices(overlapping: range)
        return state.withLock { state in
            numbers.compactMap { number in
                guard !taken.contains(number), let window = state.held[number], window.complete.contains(stream) else { return nil }
                return OverlayFeedWindow(number: number, range: closed(number), events: window.events[stream] ?? [])
            }
        }
    }

    /// The parts of `range` whose blocks of `stream` will not come here in time, so the renderer must read them itself: windows
    /// read and forgotten since (or kept without this stream), windows the player skipped (a seek), and windows too far ahead of
    /// `playhead` (file time) to wait for. Empty while the window at the playhead has not been read: the player is waiting for
    /// that one, and a read of the renderer's own would only compete with it.
    func lost(in range: ClosedRange<Double>, stream: Int, playhead: Double) -> [ClosedRange<Double>] {
        let numbers = indices(overlapping: range)
        let now = max(0, playhead + Self.playheadSlack)
        let atPlayhead = indices(overlapping: now...now).first
        return state.withLock { state in
            if let atPlayhead, !state.read.contains(atPlayhead) { return [] }
            return numbers.compactMap { number -> ClosedRange<Double>? in
                if state.held[number]?.complete.contains(stream) == true { return nil }
                let window = ranges[number]
                let skipped = window.upperBound <= now, farAhead = window.lowerBound > now + Self.waitHorizon
                guard state.read.contains(number) || skipped || farAhead else { return nil }          // the player asks for it soon
                // Whole windows (a sliver at a time would mean a read every frame), but never to the end of the file.
                return max(window.lowerBound, range.lowerBound)...min(window.upperBound, max(range.upperBound, window.lowerBound) + 30)
            }
        }
    }

    private func closed(_ number: Int) -> ClosedRange<Double> { ranges[number].lowerBound...ranges[number].upperBound }

    /// The windows whose range overlaps `range`, in order.
    private func indices(overlapping range: ClosedRange<Double>) -> [Int] {
        var low = 0, high = ranges.count
        while low < high {                                   // first window that ends after the start of `range`
            let middle = (low + high) / 2
            if ranges[middle].upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        var result: [Int] = []
        var index = low
        while index < ranges.count, ranges[index].lowerBound <= range.upperBound {
            result.append(index)
            index += 1
        }
        return result
    }
}

/// One window of an ``OverlayFeed`` as one renderer sees it.
struct OverlayFeedWindow: Sendable {
    var number: Int
    /// Every block of the stream that starts in this range is in `events`.
    var range: ClosedRange<Double>
    var events: [OverlayEvent]
}

/// Where a ``SubtitleRenderer`` gets the blocks that something else reads anyway (an ``OverlayFeedView``; a stand-in in tests).
protocol OverlayFeedSource: AnyObject, Sendable {
    /// Grows whenever there may be new windows.
    var serial: Int { get }
    /// The windows read so far that overlap `range`, except those in `taken`.
    func windows(overlapping range: ClosedRange<Double>, except taken: Set<Int>) -> [OverlayFeedWindow]
    /// The parts of `range` the renderer must read itself (see ``OverlayFeed/lost(in:stream:playhead:)``).
    func lost(in range: ClosedRange<Double>, playhead: Double) -> [ClosedRange<Double>]
}

/// One stream of an ``OverlayFeed``, with SubRip, WebVTT and Timed Text blocks turned into ASS events as the direct
/// reader's ``CueScriptEventSource`` does, so that a block from either way is the same block.
final class OverlayFeedView: OverlayFeedSource {
    private let feed: OverlayFeed
    private let stream: Int
    /// The codec of a text track drawn in the plain default style; `nil` for ASS and picture tracks.
    private let cueCodec: String?

    init(feed: OverlayFeed, stream: Int, cueCodec: String?) {
        self.feed = feed
        self.stream = stream
        self.cueCodec = cueCodec
        feed.watch(stream)
    }

    deinit { feed.unwatch(stream) }

    var serial: Int { feed.serial }

    func windows(overlapping range: ClosedRange<Double>, except taken: Set<Int>) -> [OverlayFeedWindow] {
        let windows = feed.windows(overlapping: range, stream: stream, except: taken)
        guard let cueCodec else { return windows }
        return windows.map { window in
            var converted = window
            converted.events = CueScriptEventSource.convert(window.events, codec: cueCodec)
            return converted
        }
    }

    func lost(in range: ClosedRange<Double>, playhead: Double) -> [ClosedRange<Double>] {
        feed.lost(in: range, stream: stream, playhead: playhead)
    }
}

/// Sorted, disjoint time ranges in seconds; ranges that touch are joined.
struct TimeRanges: Sendable, Equatable {
    private(set) var ranges: [ClosedRange<Double>] = []
    private static let tolerance = 0.001

    init() {}

    /// Everything from zero to the end of time.
    static let everything: TimeRanges = {
        var all = TimeRanges()
        all.insert(0...Double.greatestFiniteMagnitude)
        return all
    }()

    mutating func insert(_ range: ClosedRange<Double>) {
        var lower = range.lowerBound, upper = range.upperBound
        var kept: [ClosedRange<Double>] = []
        for existing in ranges {
            if existing.upperBound < lower - Self.tolerance || existing.lowerBound > upper + Self.tolerance {
                kept.append(existing)
            } else {
                lower = min(lower, existing.lowerBound)
                upper = max(upper, existing.upperBound)
            }
        }
        kept.append(lower...upper)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The parts of `range` that no range covers, in order.
    func missing(in range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var cursor = range.lowerBound
        for existing in ranges {
            if existing.upperBound < cursor - Self.tolerance { continue }
            if existing.lowerBound > range.upperBound { break }
            if existing.lowerBound > cursor + Self.tolerance { result.append(cursor...existing.lowerBound) }
            cursor = max(cursor, existing.upperBound)
            if cursor >= range.upperBound - Self.tolerance { return result }
        }
        if cursor < range.upperBound - Self.tolerance { result.append(cursor...range.upperBound) }
        return result
    }

    func covers(_ range: ClosedRange<Double>) -> Bool { missing(in: range).isEmpty }
}
