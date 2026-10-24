import Foundation

/// Rebuilds the decode timestamps of video that has B-frames.
///
/// Matroska stores presentation times only. FFmpeg derives decode times from them, but only once it has seen a few
/// packets (and again after every seek), so the first frames of a run arrive without a usable decode time. MP4 needs
/// decode times that increase and never pass the presentation time, so the remuxer restores them from the
/// presentation times of one run of packets (a segment starts at a keyframe, where decoding restarts).
///
/// The rule is the one video decoders follow: with `delay` frames of reordering, the packet decoded `delay`
/// places after another is the one shown at its time, so `dts[i] = sorted presentation times[i - delay]`. The first
/// `delay` packets come before the first presentation time and are placed one frame apart.
struct ReorderModel: Sendable, Equatable {
    /// How many frames decoding runs ahead of presentation.
    var delay: Int
    /// A typical gap between presentation times, in the stream's time base ticks.
    var frameTicks: Int64

    /// Measures a model on the packets of the first run of a stream.
    /// - Parameter declaredDelay: The decoder's own idea of its reordering depth (`video_delay`); the larger wins.
    static func measure(_ packets: [MediaPacket], declaredDelay: Int) -> ReorderModel {
        let order = Self.order(of: packets)
        let gaps = zip(order.sorted, order.sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        let ticks = gaps.isEmpty ? max(packets.first?.duration ?? 1, 1) : gaps[gaps.count / 2]
        return ReorderModel(delay: max(order.delay, declaredDelay, 0), frameTicks: ticks)
    }

    /// Replaces the decode timestamps of `packets` (decode order, starting at a keyframe) unless they are already
    /// sound: strictly increasing and never later than the presentation time.
    func repair(_ packets: inout [MediaPacket]) {
        guard packets.count > 1, !Self.areSound(packets) else { return }
        let order = Self.order(of: packets)
        let delay = max(self.delay, order.delay)
        var previous = Int64.min
        for index in packets.indices {
            var dts = index >= delay ? order.sorted[index - delay] : order.sorted[0] - Int64(delay - index) * frameTicks
            if dts <= previous { dts = previous + 1 }                    // equal presentation times: keep it strictly increasing
            packets[index].dts = dts
            previous = dts
        }
    }

    /// Presentation times in order, and the reordering depth these packets need (the most places any packet is
    /// decoded ahead of its presentation rank).
    private static func order(of packets: [MediaPacket]) -> (sorted: [Int64], delay: Int) {
        let ranked = packets.indices.sorted { packets[$0].pts != packets[$1].pts ? packets[$0].pts < packets[$1].pts : $0 < $1 }
        var delay = 0
        for (rank, index) in ranked.enumerated() { delay = max(delay, index - rank) }
        return (ranked.map { packets[$0].pts }, delay)
    }

    private static func areSound(_ packets: [MediaPacket]) -> Bool {
        var previous = Int64.min
        for packet in packets {
            if packet.dts <= previous || packet.dts > packet.pts { return false }
            previous = packet.dts
        }
        return true
    }
}
