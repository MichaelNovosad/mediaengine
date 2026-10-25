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

    /// Largest segment worth holding in memory: a segment is read, copied and written out in one piece, so peak
    /// memory is a few times this. Bitrates around 80 Mbps would otherwise make 6-second segments of 60 MB.
    static let defaultMaxSegmentBytes: Int64 = 24 * 1024 * 1024
    /// Segments are never planned shorter than this by the size rule alone (one GOP is the smallest possible cut).
    static let shortestGoal = 1.0

    /// Cuts `[0, duration]` at keyframes so that each segment lasts at least `target` seconds, except the last,
    /// and stays near `maxSegmentBytes` where the file's size allows it. Without keyframes (audio-only files) the
    /// timeline is cut on a fixed grid.
    ///
    /// - Parameters:
    ///   - positions: Byte position of each keyframe in the file (parallel to `keyframes`), when the index gives
    ///     one. A keyframe is also a cut when the segment would otherwise span more than `maxSegmentBytes`.
    ///     Matroska positions are those of clusters, so they are only as fine as the clusters are.
    ///   - averageBytesPerSecond: File size over duration. Shortens the target for high bitrates so that a
    ///     segment holds about `maxSegmentBytes`, whatever the index says.
    static func make(keyframes: [Double], positions: [Int64?]? = nil, duration: Double, target: Double = 6,
                     maxSegmentBytes: Int64 = defaultMaxSegmentBytes, averageBytesPerSecond: Double? = nil) -> SegmentPlan {
        precondition(target > 0)
        guard duration > 0 else { return SegmentPlan(segments: [], totalDuration: 0) }

        var goal = target
        if let rate = averageBytesPerSecond, rate > 0 {
            goal = max(min(target, Double(maxSegmentBytes) / rate), min(shortestGoal, target))
        }

        var boundaries: [Double] = [0]
        if keyframes.isEmpty {
            var next = goal
            while next < duration - 0.001 { boundaries.append(next); next += goal }
        } else {
            let given: [Int64?] = (positions?.count == keyframes.count) ? positions! : Array(repeating: nil, count: keyframes.count)
            let pairs = zip(keyframes, given).map { (time: $0, position: $1) }.sorted { $0.time < $1.time }
            var lastPosition = pairs.first?.position
            for (index, keyframe) in pairs.enumerated() {
                guard keyframe.time < duration - 0.001, keyframe.time > boundaries[boundaries.count - 1] + 0.0005 else { continue }
                var cut = keyframe.time - boundaries[boundaries.count - 1] >= goal - 0.0005
                if !cut, let start = lastPosition, index + 1 < pairs.count, let following = pairs[index + 1].position {
                    cut = following - start > maxSegmentBytes          // keeping this GOP would push the segment over the cap
                }
                if cut {
                    boundaries.append(keyframe.time)
                    lastPosition = keyframe.position
                }
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
