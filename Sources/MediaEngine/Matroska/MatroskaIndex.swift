import Foundation
import os

/// Element identifiers for the index work below.
private enum MKV {
    static let ebml: UInt32 = 0x1A45DFA3, segment: UInt32 = 0x18538067, seekHead: UInt32 = 0x114D9B74
    static let seek: UInt32 = 0x4DBB, seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
    static let info: UInt32 = 0x1549A966, timestampScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83
    static let cues: UInt32 = 0x1C53BB6B, cuePoint: UInt32 = 0xBB, cueTrackPositions: UInt32 = 0xB7, cueTrack: UInt32 = 0xF7
    static let cluster: UInt32 = 0x1F43B675, timestamp: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0, block: UInt32 = 0xA1, referenceBlock: UInt32 = 0xFB
    /// What a segment may hold at its top level, between and after its clusters (chapters, attachments, tags, void, CRC-32 too).
    static let topLevel: Set<UInt32> = [seekHead, info, tracks, cues, cluster, 0x1043A770, 0x1941A469, 0x1254C367, 0xEC, 0xBF]
}

/// What the start of a Matroska file says about where things are: the timestamp scale and duration (Info), the numbers of
/// the video tracks (Tracks), the first cluster, and whether the file's index (Cues) lists a video track.
///
/// FFmpeg loads the Cues only on the first seek, and when a file has none, or none for the video track, a seek to the end
/// reads every cluster of the file to find its keyframes; over a network that is the whole movie before the first picture.
/// This look at the file's start says so beforehand, for a few reads that the opening has already made.
struct MatroskaLayout: Sendable {
    var segmentEnd: Int64?
    var firstCluster: Int64?
    /// Nanoseconds per tick of the file's timestamps.
    var timestampScale = 1_000_000.0
    /// Seconds, when the header states it (live recordings often do not).
    var duration: Double?
    /// The track numbers of the video tracks, in the order the file lists them.
    var videoTracks: [UInt64] = []
    /// `nil` when the file has no Cues; otherwise whether its first cue points list a video track.
    var cuesListVideo: Bool?

    static func read(from source: any ByteSource) -> MatroskaLayout? {
        let reader = EBMLReader(source: source)
        guard let ebml = reader.header(at: 0), ebml.id == MKV.ebml, let ebmlSize = ebml.size else { return nil }
        let segmentOffset = Int64(ebml.headerLength).addingReportingOverflow(ebmlSize)
        guard !segmentOffset.overflow, let segment = reader.header(at: segmentOffset.partialValue), segment.id == MKV.segment else { return nil }
        let dataStart = segmentOffset.partialValue + Int64(segment.headerLength)
        var layout = MatroskaLayout()
        if let size = segment.size, case let (end, overflow) = dataStart.addingReportingOverflow(size), !overflow { layout.segmentEnd = end }

        let positions = topLevelPositions(reader, dataStart: dataStart, size: segment.size)
        layout.firstCluster = positions[MKV.cluster]

        if let at = positions[MKV.info], let info = reader.header(at: at), info.id == MKV.info, let size = info.size {
            var ticks: Double?
            for child in reader.children(from: at + Int64(info.headerLength), size: size, limit: 64) {
                let body = child.offset + Int64(child.header.headerLength), length = Int(clamping: child.header.size ?? 0)
                switch child.header.id {
                case MKV.timestampScale: if let value = reader.uint(at: body, size: length), value > 0 { layout.timestampScale = Double(value) }
                case MKV.duration: ticks = reader.float(at: body, size: length)
                default: break
                }
            }
            if let ticks, ticks.isFinite, ticks > 0 { layout.duration = ticks * layout.timestampScale / 1e9 }
        }

        if let at = positions[MKV.tracks], let tracks = reader.header(at: at), tracks.id == MKV.tracks, let size = tracks.size {
            for entry in reader.children(from: at + Int64(tracks.headerLength), size: size, limit: 256) where entry.header.id == MKV.trackEntry {
                guard let entrySize = entry.header.size else { continue }
                var number: UInt64?, type: UInt64?
                for field in reader.children(from: entry.offset + Int64(entry.header.headerLength), size: entrySize, limit: 64) {
                    let body = field.offset + Int64(field.header.headerLength), length = Int(clamping: field.header.size ?? 0)
                    if field.header.id == MKV.trackNumber { number = reader.uint(at: body, size: length) }
                    if field.header.id == MKV.trackType { type = reader.uint(at: body, size: length) }
                }
                if type == 1, let number { layout.videoTracks.append(number) }
            }
        }

        if let at = positions[MKV.cues], let cues = reader.header(at: at), cues.id == MKV.cues, let size = cues.size {
            var listsVideo = false
            for point in reader.children(from: at + Int64(cues.headerLength), size: size, limit: 8) where point.header.id == MKV.cuePoint {
                guard let pointSize = point.header.size else { continue }
                for place in reader.children(from: point.offset + Int64(point.header.headerLength), size: pointSize, limit: 16)
                where place.header.id == MKV.cueTrackPositions {
                    guard let placeSize = place.header.size else { continue }
                    for field in reader.children(from: place.offset + Int64(place.header.headerLength), size: placeSize, limit: 16)
                    where field.header.id == MKV.cueTrack {
                        let length = Int(clamping: field.header.size ?? 0)
                        if let track = reader.uint(at: field.offset + Int64(field.header.headerLength), size: length),
                           layout.videoTracks.contains(track) { listsVideo = true }
                    }
                }
            }
            layout.cuesListVideo = listsVideo
        }
        return layout
    }

    /// Where the segment's top-level elements are: the ones before the first cluster (that one included), and what the
    /// SeekHead points to (Cues usually sit after the clusters).
    private static func topLevelPositions(_ reader: EBMLReader, dataStart: Int64, size: Int64?) -> [UInt32: Int64] {
        var positions: [UInt32: Int64] = [:]
        for (header, offset) in reader.children(from: dataStart, size: size, limit: 64, stopAt: MKV.cluster) {
            if positions[header.id] == nil { positions[header.id] = offset }
            guard header.id == MKV.seekHead, let headSize = header.size else { continue }
            for entry in reader.children(from: offset + Int64(header.headerLength), size: headSize, limit: 64) where entry.header.id == MKV.seek {
                guard let entrySize = entry.header.size else { continue }
                var target: UInt32?, position: Int64?
                for field in reader.children(from: entry.offset + Int64(entry.header.headerLength), size: entrySize, limit: 8) {
                    let at = field.offset + Int64(field.header.headerLength), length = Int(clamping: field.header.size ?? 0)
                    if field.header.id == MKV.seekID, let raw = reader.bytes(at: at, count: min(length, 4)) {
                        target = raw.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    }
                    if field.header.id == MKV.seekPosition, let value = reader.uint(at: at, size: length), let relative = Int64(exactly: value),
                       case let (sum, overflow) = dataStart.addingReportingOverflow(relative), !overflow {
                        position = sum
                    }
                }
                if let target, let position, positions[target] == nil { positions[target] = position }
            }
        }
        return positions
    }
}

/// Reads element headers far apart with small requests (``ByteSource/readSparse(at:into:)``), a few kilobytes at a time,
/// so that hopping from cluster to cluster does not fetch the clusters themselves.
struct SparseEBML {
    let source: any ByteSource
    let length: Int64
    private var start: Int64 = 0
    private var window: [UInt8] = []
    static let windowSize = 8 * 1024

    init(source: any ByteSource, length: Int64) {
        self.source = source
        self.length = length
    }

    /// `count` bytes at `offset`; `nil` past the end of the file or when the source has no more.
    mutating func bytes(at offset: Int64, count: Int) throws -> [UInt8]? {
        guard count > 0, offset >= 0, count <= EBMLReader.largestRead, offset <= length - Int64(count) else { return nil }
        if offset >= start, offset + Int64(count) <= start + Int64(window.count) {
            let from = Int(offset - start)
            return Array(window[from..<(from + count)])
        }
        let wanted = Int(min(Int64(max(count, Self.windowSize)), length - offset))
        var buffer = [UInt8](repeating: 0, count: wanted)
        var filled = 0
        while filled < wanted {
            let read = try buffer.withUnsafeMutableBytes { raw in
                try source.readSparse(at: offset + Int64(filled), into: UnsafeMutableRawBufferPointer(rebasing: raw[filled...]))
            }
            if read <= 0 { break }
            filled += read
        }
        guard filled >= count else { return nil }
        start = offset
        window = Array(buffer.prefix(filled))
        return Array(window[0..<count])
    }

    /// The header of the element at `offset` (identifier, size, header length).
    mutating func header(at offset: Int64) throws -> EBMLHeader? {
        let available = Int(min(12, length - offset))
        guard available >= 2, let head = try bytes(at: offset, count: available), head[0] != 0 else { return nil }
        let idLength = head[0].leadingZeroBitCount + 1
        guard idLength <= 4, head.count > idLength, head[idLength] != 0 else { return nil }
        let id = head[0..<idLength].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let sizeLength = head[idLength].leadingZeroBitCount + 1
        guard head.count >= idLength + sizeLength else { return nil }
        var value = UInt64(head[idLength] & (0xFF >> UInt8(sizeLength)))
        for byte in head[(idLength + 1)..<(idLength + sizeLength)] { value = value << 8 | UInt64(byte) }
        let allOnes = (UInt64(1) << UInt64(7 * sizeLength)) - 1
        return EBMLHeader(id: id, size: value == allOnes ? nil : Int64(clamping: value), headerLength: idLength + sizeLength)
    }

    mutating func uint(at offset: Int64, size: Int) throws -> UInt64? {
        guard (1...8).contains(size), let raw = try bytes(at: offset, count: size) else { return nil }
        return raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// The start of a Block or SimpleBlock: track number, time relative to the cluster, flags.
    mutating func blockHeader(at offset: Int64, size: Int64) throws -> (track: UInt64, relative: Int16, flags: UInt8)? {
        let count = Int(min(size, 12))
        guard count >= 4, let raw = try bytes(at: offset, count: count), raw[0] != 0 else { return nil }
        let trackLength = raw[0].leadingZeroBitCount + 1
        guard trackLength <= 8, raw.count >= trackLength + 3 else { return nil }
        var track = UInt64(raw[0] & (0xFF >> UInt8(trackLength)))
        for byte in raw[1..<trackLength] { track = track << 8 | UInt64(byte) }
        let relative = Int16(bitPattern: UInt16(raw[trackLength]) << 8 | UInt16(raw[trackLength + 1]))
        return (track, relative, raw[trackLength + 2])
    }
}

/// A keyframe list for a Matroska file whose own index (Cues) is missing or unusable, built by hopping from cluster to cluster
/// and reading only the start of each: its time and its first video block. A few kilobytes per cluster instead of the
/// whole file. Keyframes that are not the first video block of their cluster are not found; segments are cut only at the
/// ones that are, which is where muxers start their clusters.
enum MatroskaClusterIndex {
    struct Result: Sendable {
        /// Seconds on the file's own timeline (before the engine takes the start time off).
        var keyframes: [Double]
        /// Where each keyframe's cluster starts (absolute byte offset): what a Matroska index stores, so FFmpeg can seek to it.
        var positions: [Int64]
        var duration: Double
    }

    private static let logger = Logger(subsystem: "dev.mediaengine", category: "index")

    /// `nil` when it cannot be done this way: no cluster, a cluster of unknown size (a live recording), no keyframe found.
    /// The log says which.
    static func build(source: any ByteSource, layout: MatroskaLayout, videoTrack: UInt64, frameDuration: Double,
                      cancellation: CancellationFlag, progress: (@Sendable (Double) -> Void)?) throws -> Result? {
        guard let first = layout.firstCluster, let length = source.length, length > first else {
            logger.notice("Cluster headers: no first cluster found")
            return nil
        }
        let end = min(layout.segmentEnd ?? length, length)
        var reader = SparseEBML(source: source, length: length)
        let scale = layout.timestampScale / 1e9                          // seconds per tick
        var keyframes: [Double] = [], positions: [Int64] = []
        var latest = 0.0
        var lastCluster: (offset: Int64, header: EBMLHeader)?
        var offset = first
        var reported = -1.0
        var clusters = 0, withVideo = 0
        while offset < end {
            if cancellation.isCancelled { throw MediaError.cancelled }
            guard let header = try reader.header(at: offset) else {                        // the end of what can be read
                logger.notice("Cluster headers: unreadable element at \(offset, privacy: .public) of \(length, privacy: .public)")
                break
            }
            guard MKV.topLevel.contains(header.id) else {                                  // not a top-level element: damaged here
                logger.notice("Cluster headers: unexpected element \(String(header.id, radix: 16), privacy: .public) at \(offset, privacy: .public)")
                break
            }
            guard let size = header.size else {                                            // unknown size: the next one cannot be found
                logger.notice("Cluster headers: an element of unknown size at \(offset, privacy: .public) (a live recording); cannot hop")
                return nil
            }
            if header.id == MKV.cluster {
                clusters += 1
                lastCluster = (offset, header)
                if let found = try firstVideoBlock(&reader, cluster: offset, header: header, track: videoTrack, scale: scale) {
                    withVideo += 1
                    latest = max(latest, found.time)
                    if found.isKeyframe, found.time >= (keyframes.last ?? -.infinity) {
                        keyframes.append(found.time)
                        positions.append(offset)
                    }
                }
            }
            let step = Int64(header.headerLength).addingReportingOverflow(size)
            let next = offset.addingReportingOverflow(step.partialValue)
            guard !step.overflow, !next.overflow, next.partialValue > offset else { break }
            offset = next.partialValue
            if let progress {
                let fraction = min(Double(offset - first) / Double(max(end - first, 1)), 1)
                if fraction - reported >= 0.005 { reported = fraction; progress(fraction) }
            }
        }
        logger.notice("Cluster headers: \(clusters, privacy: .public) clusters, \(withVideo, privacy: .public) with a video block of track \(videoTrack, privacy: .public), \(keyframes.count, privacy: .public) of them start with a keyframe")
        guard !keyframes.isEmpty else { return nil }
        var duration = layout.duration
        if duration == nil, let last = lastCluster {
            // No duration in the header: the last cluster's last block, plus one frame.
            let ending = try lastBlockTime(&reader, cluster: last.offset, header: last.header, scale: scale) ?? latest
            duration = max(ending, latest) + frameDuration
        }
        guard let duration, duration > 0 else { return nil }
        return Result(keyframes: keyframes, positions: positions, duration: duration)
    }

    /// The time of the cluster's first block of the video track and whether it is a keyframe.
    private static func firstVideoBlock(_ reader: inout SparseEBML, cluster: Int64, header: EBMLHeader, track: UInt64,
                                        scale: Double) throws -> (time: Double, isKeyframe: Bool)? {
        var clusterTime: Int64?
        var found: (time: Double, isKeyframe: Bool)?
        try walkBlocks(&reader, cluster: cluster, header: header, limit: 64) { child, body, size, reader in
            switch child {
            case MKV.timestamp:
                clusterTime = try reader.uint(at: body, size: Int(clamping: size)).map { Int64(clamping: $0) }
            case MKV.simpleBlock:
                if let clusterTime, let block = try reader.blockHeader(at: body, size: size), block.track == track {
                    found = (Double(clusterTime + Int64(block.relative)) * scale, block.flags & 0x80 != 0)
                }
            case MKV.blockGroup:
                if let clusterTime, let block = try groupBlock(&reader, group: body, size: size), block.track == track {
                    found = (Double(clusterTime + Int64(block.relative)) * scale, block.isKeyframe)
                }
            default: break
            }
            return found == nil
        }
        return found
    }

    /// The latest block time in a cluster, any track (the end of the file, when the header does not say).
    private static func lastBlockTime(_ reader: inout SparseEBML, cluster: Int64, header: EBMLHeader, scale: Double) throws -> Double? {
        var clusterTime: Int64?
        var latest: Double?
        try walkBlocks(&reader, cluster: cluster, header: header, limit: 20_000) { child, body, size, reader in
            switch child {
            case MKV.timestamp:
                clusterTime = try reader.uint(at: body, size: Int(clamping: size)).map { Int64(clamping: $0) }
            case MKV.simpleBlock:
                if let clusterTime, let block = try reader.blockHeader(at: body, size: size) {
                    latest = max(latest ?? 0, Double(clusterTime + Int64(block.relative)) * scale)
                }
            case MKV.blockGroup:
                if let clusterTime, let block = try groupBlock(&reader, group: body, size: size) {
                    latest = max(latest ?? 0, Double(clusterTime + Int64(block.relative)) * scale)
                }
            default: break
            }
            return true
        }
        return latest
    }

    /// Calls `visit` with each child of the cluster (identifier, where its data starts, its size) until it returns `false`.
    private static func walkBlocks(_ reader: inout SparseEBML, cluster: Int64, header: EBMLHeader, limit: Int,
                                   _ visit: (UInt32, Int64, Int64, inout SparseEBML) throws -> Bool) throws {
        guard let size = header.size else { return }
        let start = cluster + Int64(header.headerLength)
        let end = start.addingReportingOverflow(size)
        guard !end.overflow else { return }
        var offset = start
        var visited = 0
        while offset < end.partialValue, visited < limit {
            visited += 1
            guard let child = try reader.header(at: offset), let childSize = child.size else { return }
            let body = offset + Int64(child.headerLength)
            guard try visit(child.id, body, childSize, &reader) else { return }
            let next = body.addingReportingOverflow(childSize)
            guard !next.overflow, next.partialValue > offset else { return }
            offset = next.partialValue
        }
    }

    /// The Block inside a BlockGroup: its track and time, and whether it is a keyframe (a group with a ReferenceBlock is not).
    private static func groupBlock(_ reader: inout SparseEBML, group: Int64, size: Int64) throws -> (track: UInt64, relative: Int16, isKeyframe: Bool)? {
        let end = group.addingReportingOverflow(size)
        guard !end.overflow else { return nil }
        var offset = group
        var block: (track: UInt64, relative: Int16)?
        var referenced = false
        var visited = 0
        while offset < end.partialValue, visited < 16 {
            visited += 1
            guard let child = try reader.header(at: offset), let childSize = child.size else { break }
            let body = offset + Int64(child.headerLength)
            if child.id == MKV.block, let header = try reader.blockHeader(at: body, size: childSize) { block = (header.track, header.relative) }
            if child.id == MKV.referenceBlock { referenced = true }
            let next = body.addingReportingOverflow(childSize)
            guard !next.overflow, next.partialValue > offset else { break }
            offset = next.partialValue
        }
        return block.map { ($0.track, $0.relative, !referenced) }
    }
}
