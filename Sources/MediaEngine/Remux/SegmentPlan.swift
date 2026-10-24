import Foundation

/// How a file is cut into HLS segments. Boundaries sit on video keyframes so every video segment
/// can be decoded on its own; audio follows the same boundaries.
struct SegmentPlan: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var index: Int
        /// Start and end in seconds on the file's own timeline.
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    var segments: [Segment]
    var totalDuration: Double

    /// Cuts `[0, duration]` at keyframes so that each segment lasts at least `target` seconds, except the last.
    /// Without keyframes (audio-only files) the timeline is cut on a fixed grid.
    static func make(keyframes: [Double], duration: Double, target: Double = 6) -> SegmentPlan {
        precondition(target > 0)
        guard duration > 0 else { return SegmentPlan(segments: [], totalDuration: 0) }

        var boundaries: [Double] = [0]
        if keyframes.isEmpty {
            var next = target
            while next < duration - 0.001 { boundaries.append(next); next += target }
        } else {
            for time in keyframes.sorted() where time - boundaries[boundaries.count - 1] >= target - 0.0005 && time < duration - 0.001 {
                boundaries.append(time)
            }
        }
        // Do not leave a sliver at the end: fold a final stub shorter than one second into the previous segment.
        if boundaries.count > 1, duration - boundaries[boundaries.count - 1] < 1 { boundaries.removeLast() }
        boundaries.append(duration)

        let segments = (0..<(boundaries.count - 1)).map {
            Segment(index: $0, start: boundaries[$0], end: boundaries[$0 + 1])
        }
        return SegmentPlan(segments: segments, totalDuration: duration)
    }

    /// The segment that contains `time` (clamped to the first or last segment).
    func segment(at time: Double) -> Segment? {
        guard let last = segments.last else { return nil }
        if time >= last.start { return last }
        return segments.last { $0.start <= max(time, 0) } ?? segments.first
    }
}
