import Foundation
import Synchronization

/// A DVD title read as one file: the cells of the title (``DVDStructure/Title/cells``), in play order, out of its title set's
/// stream files (`VTS_02_1.VOB`, `VTS_02_2.VOB`, …). A film is cut into 1 GB files and its timestamps restart and jump between
/// cells; opened through this source, the engine plays the whole title on one timeline from 0, with the title's length and
/// chapters, and jumps through the disc's time map (the app's owner, 2026-11-12: Häxan and Az ember tragédiája).
///
/// ```swift
/// let disc = DVDStructure.read(videoManager: videoTS, titleSet: { informationFile($0) })
/// let title = disc.mainTitle!
/// let files = try titleSetStreamFiles(title.titleSet).map { try FileByteSource(url: $0) }
/// let session = try await PlaybackSession(source: MediaSource(byteSource: DVDTitleByteSource(title: title, files: files)))
/// ```
public final class DVDTitleByteSource: ByteSource {
    /// The title this source plays.
    public let title: DVDStructure.Title
    let layout: DVDTitleLayout
    private let files: [any ByteSource]
    private let fileStarts: [Int64]
    private let fileLengths: [Int64]
    private let lastFile = Mutex(0)

    /// `files` are the title set's stream files in order (`VTS_xx_1.VOB` first); every one must know its length. Throws when the
    /// files do not hold the title's cells.
    public init(title: DVDStructure.Title, files: [any ByteSource]) throws {
        let lengths = files.map { $0.length ?? -1 }
        guard !files.isEmpty, !lengths.contains(where: { $0 < 0 }) else {
            throw MediaError.unreadable(detail: "the DVD's stream files are missing or their sizes are unknown")
        }
        var starts: [Int64] = []
        var total: Int64 = 0
        for length in lengths { starts.append(total); total += length }
        guard let layout = DVDTitleLayout(title: title, totalBytes: total), layout.length > 0 else {
            throw MediaError.corrupt(detail: "the DVD's stream files do not hold the title")
        }
        self.title = title
        self.layout = layout
        self.files = files
        fileStarts = starts
        fileLengths = lengths
    }

    public var length: Int64? { layout.length }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try readLogical(at: offset, into: buffer, sparse: false)
    }

    public func readSparse(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try readLogical(at: offset, into: buffer, sparse: true)
    }

    public var throughput: Double? { files[lastFile.withLock { $0 }].throughput }

    public func cancelPendingReads() { files.forEach { $0.cancelPendingReads() } }

    public func close() { files.forEach { $0.close() } }

    /// Reads from the title's cells as if they were one file.
    private func readLogical(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer, sparse: Bool) throws -> Int {
        var done = 0
        var position = offset
        while done < buffer.count, let index = layout.cellIndex(containingLogical: position) {
            let cell = layout.cells[index]
            let within = position - cell.logicalStart
            let wanted = Int(min(Int64(buffer.count - done), cell.byteLength - within))
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[done..<(done + wanted)])
            let got = try readFiles(at: cell.globalStart + within, into: slice, sparse: sparse)
            done += got
            position += Int64(got)
            if got < wanted { break }
        }
        return done
    }

    /// Reads from the title set's stream files as if they were one file.
    private func readFiles(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer, sparse: Bool) throws -> Int {
        var done = 0
        var position = offset
        while done < buffer.count, let index = fileStarts.lastIndex(where: { $0 <= position }), position < fileStarts[index] + fileLengths[index] {
            let within = position - fileStarts[index]
            let wanted = Int(min(Int64(buffer.count - done), fileLengths[index] - within))
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[done..<(done + wanted)])
            lastFile.withLock { $0 = index }
            let got = sparse ? try files[index].readSparse(at: within, into: slice) : try files[index].read(at: within, into: slice)
            guard got > 0 else { break }
            done += got
            position += Int64(got)
            if got < wanted { break }
        }
        return done
    }
}

/// Where a DVD title's cells lie in the title's own byte stream (the cells one after another) and on its timeline, its seek points
/// from the disc's time map, and each cell's first presentation time, read from the navigation pack that starts it.
final class DVDTitleLayout: Sendable {
    struct Cell: Sendable {
        let logicalStart: Int64             // in the title's byte stream
        let byteLength: Int64
        let globalStart: Int64              // in the title set's stream files read as one
        let start: TimeInterval             // on the title's timeline
        let duration: TimeInterval
        let firstSector: Int
        let lastSector: Int
    }

    let cells: [Cell]
    let length: Int64
    let duration: TimeInterval
    let chapters: [TimeInterval]
    /// The title's subtitle streams by their stream id (`0x20 +` the stream number), for ``FormatContext``.
    let subtitleStreamIDs: [Int]
    /// The subtitle colours (`0x00YYCrCb`) and the subtitles' canvas height.
    let palette: [UInt32]
    let pictureHeight: Int
    /// Places a jump can start from (the start of a video object unit): the time map's entries and every cell's start, by the
    /// disc's times (see ``titleSeekPoints(read:)`` for the title's).
    let seekPoints: [(time: TimeInterval, logical: Int64)]
    /// Per cell: its first presentation time (90 kHz, unwrapped) and what to add to its timestamps for the title's timeline.
    private let placements = Mutex<[Int: Placement]>([:])
    private let titlePoints = Mutex<[(time: TimeInterval, logical: Int64)]?>(nil)

    struct Placement: Sendable {
        let anchor: Int64
        let offset: Int64
    }

    static let ticksPerSecond: Int64 = 90_000
    private static let wrap: Int64 = 1 << 33

    init?(title: DVDStructure.Title, totalBytes: Int64) {
        let sector = Int64(DVDStructure.sectorSize)
        var cells: [Cell] = []
        var logical: Int64 = 0
        for cell in title.cells {
            let global = Int64(cell.firstSector) * sector
            let end = min((Int64(cell.lastSector) + 1) * sector, totalBytes)
            guard end > global else { continue }
            cells.append(Cell(logicalStart: logical, byteLength: end - global, globalStart: global, start: cell.start,
                              duration: cell.duration, firstSector: cell.firstSector, lastSector: cell.lastSector))
            logical += end - global
        }
        guard !cells.isEmpty else { return nil }
        self.cells = cells
        length = logical
        duration = title.duration
        chapters = title.chapters
        subtitleStreamIDs = title.subtitleStreams.map { 0x20 + $0 }
        palette = title.palette
        pictureHeight = title.pictureHeight

        var points = cells.map { (time: $0.start, logical: $0.logicalStart) }
        if title.timeMapStep > 0 {
            for (index, mapSector) in title.timeMap.enumerated() {
                guard let cell = cells.first(where: { $0.firstSector <= mapSector && mapSector <= $0.lastSector }) else { continue }
                let time = TimeInterval((index + 1) * title.timeMapStep)      // the first entry is one step in [believe: checked below]
                guard time >= cell.start, time <= cell.start + cell.duration else { continue }
                points.append((time, cell.logicalStart + Int64(mapSector - cell.firstSector) * sector))
            }
        }
        points.sort { $0.time < $1.time }
        // Keep the positions in step with the times (a map entry that disagrees with its neighbours is left out).
        var ordered: [(time: TimeInterval, logical: Int64)] = []
        for point in points where ordered.last.map({ point.logical >= $0.logical }) ?? true { ordered.append(point) }
        seekPoints = ordered
    }

    func cellIndex(containingLogical position: Int64) -> Int? {
        guard position >= 0, position < length else { return nil }
        var low = 0, high = cells.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if cells[middle].logicalStart <= position { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The last seek point at or before `seconds` of the title's timeline.
    func seekPoint(atOrBefore seconds: TimeInterval, read: (Int64, Int) -> Data?) -> (time: TimeInterval, logical: Int64) {
        let points = titleSeekPoints(read: read)
        return points.last { $0.time <= seconds } ?? points.first ?? (0, 0)
    }

    /// Where a cell's timestamps go on the title's timeline. The first cell starts at 0. A cell whose start (from its navigation
    /// pack, read once with `read`; `fallback`, its first packet's time, when it has none) follows on from the cell before it keeps
    /// that cell's offset: most films' timestamps run on across cells, and the cells' playback times in the information files drift
    /// from them by a fraction of a second per cell (Häxan: 0.8 s by 14 minutes), so placing each cell at its listed start would
    /// make the time jump back at every cell. A cell whose timestamps jump (restart, or a different clock) starts where the one
    /// before it ends. The 33-bit timestamps are unwrapped on the way.
    func placement(cell index: Int, fallback: Int64, read: (Int64, Int) -> Data?) -> Placement {
        if let known = placements.withLock({ $0[index] }) { return known }
        let navigation = read(cells[index].logicalStart, DVDStructure.sectorSize).flatMap(Self.presentationStart(navigationPack:))
        let result: Placement
        if index == 0 {
            let anchor = navigation ?? fallback
            result = Placement(anchor: anchor, offset: Int64((cells[0].start * Double(Self.ticksPerSecond)).rounded()) - anchor)
        } else {
            let previous = placement(cell: index - 1, fallback: fallback, read: read)
            let expected = previous.anchor + Int64((cells[index - 1].duration * Double(Self.ticksPerSecond)).rounded())
            let anchor = Self.unwrap(navigation ?? fallback, near: expected)
            result = abs(anchor - expected) < 2 * Self.ticksPerSecond
                ? Placement(anchor: anchor, offset: previous.offset)
                : Placement(anchor: anchor, offset: expected + previous.offset - anchor)
        }
        return placements.withLock { known in
            if let first = known[index] { return first }
            known[index] = result
            return result
        }
    }

    /// A 33-bit MPEG timestamp moved by whole wraps (about 26.5 hours of the disc's clock) to lie nearest `reference`.
    static func unwrap(_ ticks: Int64, near reference: Int64) -> Int64 {
        var value = ticks
        while value < reference - wrap / 2 { value += wrap }
        while value > reference + wrap / 2 { value -= wrap }
        return value
    }

    /// How much later than the information files' time a cell plays on the title's timeline, in seconds.
    func drift(cell index: Int, read: (Int64, Int) -> Data?) -> TimeInterval {
        let place = placement(cell: index, fallback: 0, read: read)
        return Double(place.anchor + place.offset) / Double(Self.ticksPerSecond) - cells[index].start
    }

    /// The cell that plays at a time of the information files.
    func cellIndex(atDiscTime time: TimeInterval) -> Int {
        cells.lastIndex { $0.start <= time } ?? 0
    }

    /// A time of the information files (a chapter, a time-map entry) on the title's timeline.
    func titleTime(ofDiscTime time: TimeInterval, read: (Int64, Int) -> Data?) -> TimeInterval {
        time + drift(cell: cellIndex(atDiscTime: time), read: read)
    }

    /// The title's length on its own timeline.
    func titleDuration(read: (Int64, Int) -> Data?) -> TimeInterval {
        guard let last = cells.indices.last else { return duration }
        return cells[last].start + drift(cell: last, read: read) + cells[last].duration
    }

    /// The seek points on the title's timeline (each cell's navigation pack read once).
    func titleSeekPoints(read: (Int64, Int) -> Data?) -> [(time: TimeInterval, logical: Int64)] {
        if let known = titlePoints.withLock({ $0 }) { return known }
        let points = seekPoints.map { point -> (time: TimeInterval, logical: Int64) in
            let cell = cellIndex(containingLogical: point.logical) ?? 0
            return (point.time + drift(cell: cell, read: read), point.logical)
        }
        titlePoints.withLock { $0 = points }
        return points
    }

    /// The setup text FFmpeg's DVD subtitle decoder reads (as in a VobSub `.idx`): the canvas size and the 16 colours, turned from
    /// the disc's limited-range YCrCb into RGB. Without it the decoder guesses a palette of greys.
    var subtitleSetup: String {
        func clamp(_ value: Double) -> Int { max(0, min(255, Int(value.rounded()))) }
        let colours = palette.map { entry -> String in
            let y = Double((entry >> 16) & 0xFF) - 16, cr = Double((entry >> 8) & 0xFF) - 128, cb = Double(entry & 0xFF) - 128
            let r = clamp(1.164 * y + 1.596 * cr), g = clamp(1.164 * y - 0.392 * cb - 0.813 * cr), b = clamp(1.164 * y + 2.017 * cb)
            return String(format: "%02x%02x%02x", r, g, b)
        }
        return "size: 720x\(pictureHeight)\n" + (colours.count == 16 ? "palette: \(colours.joined(separator: ", "))\n" : "")
    }

    /// Reads from any byte source, for the navigation packs.
    static func reader(_ source: any ByteSource) -> (Int64, Int) -> Data? {
        { offset, count in
            var data = Data(count: count)
            let got = (try? data.withUnsafeMutableBytes { try source.read(at: offset, into: $0) }) ?? 0
            return got > 0 ? data.prefix(got) : nil
        }
    }

    /// The start presentation time of a video object unit (`vobu_s_ptm`, 90 kHz) from its navigation pack: a pack whose
    /// private stream 2 (`00 00 01 BF`) carries the presentation control information (substream 0), where it is the fourth
    /// 32-bit field. Public descriptions of DVD-Video; checked on two discs.
    static func presentationStart(navigationPack data: Data) -> Int64? {
        let bytes = [UInt8](data)
        guard bytes.count >= 64 else { return nil }
        var at = 0
        while at + 6 + 1 + 16 < bytes.count {
            if bytes[at] == 0, bytes[at + 1] == 0, bytes[at + 2] == 1, bytes[at + 3] == 0xBF, bytes[at + 6] == 0x00 {
                let pci = at + 7
                return (0..<4).reduce(Int64(0)) { $0 << 8 | Int64(bytes[pci + 12 + $1]) }
            }
            at += 1
        }
        return nil
    }
}
