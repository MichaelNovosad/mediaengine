import Foundation
import os
import Synchronization

/// Finds a cluster of a Matroska file at or a little before a given time, for files whose index (Cues) does not cover that
/// time: without it FFmpeg's seek reads every cluster from the last one it knows up to the target, which over a network can
/// be most of a movie. The cluster's position then goes into the demuxer's index as a seek point, so FFmpeg starts reading
/// there (and skips to the next keyframe, as with a cue).
///
/// It needs nothing from the file's header: a cluster is recognised by its identifier, a known size and its Timestamp,
/// which Matroska muxers write as its first child. The search guesses the byte position from the time (the bitrate is
/// close to even over a film), finds the next cluster there with a few large reads (``ByteSource/readSparse(at:into:)``,
/// nothing cached), narrows it down, and steps forward from cluster to cluster by their sizes, a small read each, to the last
/// one that starts at or before the target. Clusters found are shared by every reader of the same file.
final class MatroskaSeeker: Sendable {
    private static let logger = Logger(subsystem: "dev.mediaengine", category: "index")
    private static let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
    /// Clusters found so far, per file (`KeyframeIndexStore.key`), in time order: what one reader learnt helps the others.
    private static let found = Mutex<[String: [Spot]]>([:])

    struct Spot: Sendable, Equatable {
        /// Seconds on the file's own timeline (Matroska timestamps times the scale).
        var time: Double
        var position: Int64
        var size: Int64
        var headerLength: Int
    }

    private let source: any ByteSource
    private let length: Int64
    private let key: String
    /// Seconds per tick of the file's timestamps.
    private let scale: Double
    /// The file's duration in seconds, when known (an upper bound for the search).
    private let duration: Double?
    private let cancellation: CancellationFlag

    /// One large read while looking for a cluster; clusters of a film are a few megabytes apart.
    private static let window = 1 << 20
    /// Read this far at most from one guess before giving up on it.
    private static let farthest: Int64 = 48 << 20
    /// Close enough: from a cluster this much before the target, the demuxer reads on to it.
    private static let closeEnough = 8.0

    init?(source: any ByteSource, scale: Double, duration: Double?, cancellation: CancellationFlag) {
        guard let length = source.length, length > 0, scale > 0, let key = KeyframeIndexStore.key(for: source) else { return nil }
        self.source = source
        self.length = length
        self.key = key
        self.scale = scale
        self.duration = duration
        self.cancellation = cancellation
    }

    /// The last cluster that starts at or before `target` (seconds on the file's own timeline), or one at most a few
    /// seconds before it; `nil` when none can be found.
    func cluster(atOrBefore target: Double) throws -> Spot? {
        let known = Self.found.withLock { $0[key] ?? [] }
        if let best = known.last(where: { $0.time <= target }), target - best.time <= Self.closeEnough, known.contains(where: { $0.time > target }) {
            return best
        }
        var low: Spot? = known.last { $0.time <= target }
        var high: (time: Double, position: Int64) = known.first { $0.time > target }.map { ($0.time, $0.position) }
            ?? (max(duration ?? 0, target + 1), length)
        var reads = 0
        // Guess, look, narrow: until a cluster within a minute before the target is known.
        for _ in 0..<12 where low.map({ target - $0.time > 60 }) ?? true {
            let from = low.map { $0.position + Int64($0.headerLength) } ?? 0
            let lowTime = low?.time ?? 0
            guard high.position - from > Int64(Self.window), high.time > lowTime else { break }
            let fraction = min(max((target - 20 - lowTime) / (high.time - lowTime), 0.02), 0.98)
            let guess = from + Int64(Double(high.position - from) * fraction)
            guard let spot = try nextCluster(from: guess, before: high.position, reads: &reads) else {
                high = (high.time, guess)                         // no cluster between the guess and the bound: look earlier
                continue
            }
            remember(spot)
            if spot.time <= target { low = spot } else { high = (spot.time, spot.position) }
        }
        guard var current = low else {
            Self.logger.notice("Seek help: no cluster found before \(Int(target), privacy: .public) s (\(reads, privacy: .public) reads)")
            return nil
        }
        // Step forward by the clusters' sizes to the last one at or before the target.
        var steps = 0
        while steps < 2_000, let next = try following(current) {
            if cancellation.isCancelled { throw MediaError.cancelled }
            steps += 1
            remember(next)
            if next.time > target { break }
            current = next
        }
        Self.logger.notice("Seek help: cluster at \(Int(current.time), privacy: .public) s for \(Int(target), privacy: .public) s (\(reads, privacy: .public) large reads, \(steps, privacy: .public) steps)")
        return current
    }

    private func remember(_ spot: Spot) {
        Self.found.withLock { all in
            var list = all[key] ?? []
            guard !list.contains(where: { $0.position == spot.position }) else { return }
            let at = list.firstIndex { $0.time > spot.time } ?? list.count
            list.insert(spot, at: at)
            all[key] = list
        }
    }

    /// The first cluster that starts at or after `start` and before `limit`, read in large pieces.
    private func nextCluster(from start: Int64, before limit: Int64, reads: inout Int) throws -> Spot? {
        var offset = max(start, 0)
        let end = min(limit, start + Self.farthest, length)
        while offset < end {
            if cancellation.isCancelled { throw MediaError.cancelled }
            let count = Int(min(Int64(Self.window), end - offset))
            guard let buffer = try read(at: offset, count: count) else { return nil }
            reads += 1
            var index = 0
            while index + 4 <= buffer.count {
                if buffer[index] == 0x1F, buffer[index + 1] == 0x43, buffer[index + 2] == 0xB6, buffer[index + 3] == 0x75,
                   let spot = parse(buffer, at: index, base: offset), try endsWell(spot) {
                    return spot
                }
                index += 1
            }
            // The next piece overlaps a little, so that a cluster header across the edge is still seen.
            offset += Int64(max(buffer.count - 32, 1))
        }
        return nil
    }

    /// Top-level elements a segment holds: Cluster, Cues, Tags, Chapters, Attachments, SeekHead, Info, Tracks, Void, CRC-32.
    private static let topLevel: Set<UInt32> = [0x1F43B675, 0x1C53BB6B, 0x1254C367, 0x1043A770, 0x1941A469, 0x114D9B74, 0x1549A966,
                                                0x1654AE6B, 0xEC, 0xBF]

    /// A cluster found by its bytes is real when, where its size says it ends, the file ends or another top-level element
    /// begins: the same four bytes inside a picture would almost never also have that.
    private func endsWell(_ spot: Spot) throws -> Bool {
        let end = spot.position + Int64(spot.headerLength) + spot.size
        if end >= length - 1 { return end <= length + 1 }
        guard let buffer = try read(at: end, count: Int(min(16, length - end))), let header = Self.elementHeader(buffer, at: 0) else { return false }
        return Self.topLevel.contains(header.id)
    }

    /// The top-level element after `spot` that is a cluster (other elements, such as Cues or Tags, are stepped over).
    private func following(_ spot: Spot) throws -> Spot? {
        var offset = spot.position + Int64(spot.headerLength) + spot.size
        for _ in 0..<8 {
            guard offset < length, let buffer = try read(at: offset, count: Int(min(64, length - offset))), buffer.count >= 8 else { return nil }
            if Array(buffer[0..<4]) == Self.cluster { return parse(buffer, at: 0, base: offset) }
            guard let header = Self.elementHeader(buffer, at: 0), let size = header.size else { return nil }
            offset += Int64(header.length) + size
        }
        return nil
    }

    /// A cluster at `index` of `buffer` (which starts at file offset `base`): known size, and a Timestamp as its first child
    /// (after a CRC-32, if any) with a time that fits the file.
    private func parse(_ buffer: [UInt8], at index: Int, base: Int64) -> Spot? {
        guard let header = Self.elementHeader(buffer, at: index), header.id == 0x1F43B675, let size = header.size, size > 0 else { return nil }
        let position = base + Int64(index)
        guard position + Int64(header.length) + size <= length + 1 else { return nil }
        var child = index + header.length
        if child < buffer.count, buffer[child] == 0xBF, let crc = Self.elementHeader(buffer, at: child), let crcSize = crc.size {
            child += crc.length + Int(crcSize)
        }
        guard let stamp = Self.elementHeader(buffer, at: child), stamp.id == 0xE7, let stampSize = stamp.size, (1...8).contains(stampSize),
              child + stamp.length + Int(stampSize) <= buffer.count else { return nil }
        let value = buffer[(child + stamp.length)..<(child + stamp.length + Int(stampSize))].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let time = Double(value) * scale
        guard time >= 0, time <= (duration ?? .greatestFiniteMagnitude) + 600 else { return nil }
        return Spot(time: time, position: position, size: size, headerLength: header.length)
    }

    private func read(at offset: Int64, count: Int) throws -> [UInt8]? {
        guard count > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = try buffer.withUnsafeMutableBytes { raw in
                try source.readSparse(at: offset + Int64(filled), into: UnsafeMutableRawBufferPointer(rebasing: raw[filled...]))
            }
            if got <= 0 { break }
            filled += got
        }
        return filled > 0 ? Array(buffer.prefix(filled)) : nil
    }

    /// An EBML element header in a buffer: identifier, size (`nil` when unknown) and header length.
    private static func elementHeader(_ buffer: [UInt8], at index: Int) -> (id: UInt32, size: Int64?, length: Int)? {
        guard index < buffer.count, buffer[index] != 0 else { return nil }
        let idLength = buffer[index].leadingZeroBitCount + 1
        guard idLength <= 4, index + idLength < buffer.count, buffer[index + idLength] != 0 else { return nil }
        let id = buffer[index..<(index + idLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let sizeLength = buffer[index + idLength].leadingZeroBitCount + 1
        guard index + idLength + sizeLength <= buffer.count else { return nil }
        var value = UInt64(buffer[index + idLength] & (0xFF >> UInt8(sizeLength)))
        for byte in buffer[(index + idLength + 1)..<(index + idLength + sizeLength)] { value = value << 8 | UInt64(byte) }
        let allOnes = (UInt64(1) << UInt64(7 * sizeLength)) - 1
        return (id, value == allOnes ? nil : Int64(clamping: value), idLength + sizeLength)
    }
}
