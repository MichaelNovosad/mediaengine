import Foundation

/// How a DVD folder (`VIDEO_TS`) plays, from its information files: its titles, and for each the cells of its program chains in the
/// title set's stream files (`VTS_02_1.VOB`, `VTS_02_2.VOB`, …, read as one), its length, chapters, subtitle colours and time map.
/// The stream files alone do not say this: a film is cut into 1 GB files whose timestamps restart and jump between cells, so the
/// length, the start and the jumps of one file opened alone come out wrong (the app's owner, 2026-11-12: Häxan, Az ember tragédiája).
///
/// The layout is DVD-Video's as public descriptions of it give it (the format book itself is licensed; it was not read): the video
/// manager's information file (`VIDEO_TS.IFO`, header "DVDVIDEO-VMG") lists the titles at the table whose sector is at 0xC4, 12
/// bytes each (chapters at 2, title set at 6, title within the set at 7); a title set's information file (`VTS_02_0.IFO`, header
/// "DVDVIDEO-VTS") has its chapter table at the sector at 0xC8, its program chains at 0xCC and its time maps at 0xD4. Read with
/// bounds checks throughout: a damaged file gives fewer titles, never a crash.
public struct DVDStructure: Sendable, Equatable {
    public struct Title: Sendable, Equatable {
        /// The title's number in the disc's title table, from 1.
        public let number: Int
        /// The title set it plays from: its stream files are `VTS_<set>_1.VOB` and on (``DVDStructure/streamFileNames(titleSet:)``).
        public let titleSet: Int
        /// The length of the title: the sum of its cells' playback times.
        public let duration: TimeInterval
        /// Where each chapter starts on the title's timeline, in seconds, from 0.
        public let chapters: [TimeInterval]
        /// The cells in play order. Cells of other camera angles are left out (angle 1 plays).
        public let cells: [Cell]
        /// The subtitle colours of the title's first program chain: 16 entries of `0x00YYCrCb`, as the disc stores them.
        public let palette: [UInt32]
        /// Seconds between two entries of ``timeMap``; 0 when the disc has no time map for the title.
        public let timeMapStep: Int
        /// Sectors (from the start of the title set's first stream file) of the picture at every ``timeMapStep`` seconds of the
        /// title, for jumps; empty when the disc has none.
        public let timeMap: [Int]
        /// The subtitle streams the title shows (their numbers in the stream files, 0 to 31; the stream id is `0x20 +` the number),
        /// in the order the disc lists its subtitles; for a 16:9 title the streams made for a wide picture.
        public let subtitleStreams: [Int]
        /// The picture's height: 576 lines (PAL) or 480 (NTSC); its width is 720 for the subtitles' canvas.
        public let pictureHeight: Int
    }

    public struct Cell: Sendable, Equatable {
        /// First and last sector of the cell, counted from the start of the title set's first stream file (`VTS_xx_1.VOB`);
        /// a sector is 2,048 bytes.
        public let firstSector: Int
        public let lastSector: Int
        /// The cell's playback time.
        public let duration: TimeInterval
        /// Where the cell starts on the title's timeline.
        public let start: TimeInterval
    }

    /// The disc's titles in the order of its title table.
    public let titles: [Title]

    /// The film: the longest title (the main feature of nearly every disc; extras, trailers and menus' loops are shorter).
    public var mainTitle: Title? { titles.max { $0.duration < $1.duration } }

    /// The size of a sector, in bytes.
    public static let sectorSize = 2_048

    /// The names a title set's stream files can have, in order (`VTS_02_1.VOB` … `VTS_02_9.VOB`); a folder holds the first few. Match
    /// them without regard to case (some discs are copied with lower-case names).
    public static func streamFileNames(titleSet: Int) -> [String] {
        (1...9).map { String(format: "VTS_%02d_%d.VOB", titleSet, $0) }
    }

    /// The name of a title set's information file (`VTS_02_0.IFO`).
    public static func informationFileName(titleSet: Int) -> String { String(format: "VTS_%02d_0.IFO", titleSet) }

    /// Reads a disc from its video manager's information file (`VIDEO_TS.IFO`) and, through `titleSet`, the information file of each
    /// title set it names (`nil` for one that cannot be read: its titles are left out). `nil` when `videoManager` is not a DVD's.
    public static func read(videoManager: Data, titleSet: (Int) -> Data?) -> DVDStructure? {
        let manager = Bytes(videoManager)
        guard manager.has(prefix: "DVDVIDEO-VMG"), let tableSector = manager.u32(0xC4), tableSector > 0 else { return nil }
        let table = tableSector * sectorSize
        guard let count = manager.u16(table) else { return nil }
        var sets: [Int: Bytes] = [:]
        var titles: [Title] = []
        for index in 0..<min(count, 99) {
            let entry = table + 8 + index * 12
            guard let set = manager.u8(entry + 6), let titleInSet = manager.u8(entry + 7), set > 0, titleInSet > 0 else { continue }
            if sets[set] == nil, let data = titleSet(set) { sets[set] = Bytes(data) }
            guard let info = sets[set], info.has(prefix: "DVDVIDEO-VTS"),
                  let title = readTitle(number: index + 1, titleSet: set, titleInSet: titleInSet, info: info) else { continue }
            titles.append(title)
        }
        return DVDStructure(titles: titles)
    }

    /// One title from its title set's information file: the program chains its chapters name, in order, and their cells.
    private static func readTitle(number: Int, titleSet: Int, titleInSet: Int, info: Bytes) -> Title? {
        guard let chainsSector = info.u32(0xCC), chainsSector > 0, let partsSector = info.u32(0xC8), partsSector > 0 else { return nil }
        let chains = chainsSector * sectorSize
        let parts = partsSector * sectorSize

        // The chapter table: per title of the set, the chapters as (program chain, program) pairs, 4 bytes each.
        guard let titleCount = info.u16(parts), titleInSet <= titleCount, let end = info.u32(parts + 4),
              let offset = info.u32(parts + 8 + (titleInSet - 1) * 4) else { return nil }
        let nextOffset = titleInSet < titleCount ? info.u32(parts + 8 + titleInSet * 4) ?? (end + 1) : end + 1
        var chapterParts: [(chain: Int, program: Int)] = []
        var at = parts + offset
        while at + 3 < parts + nextOffset, chapterParts.count < 999, let chain = info.u16(at), let program = info.u16(at + 2) {
            chapterParts.append((chain, program))
            at += 4
        }
        guard !chapterParts.isEmpty else { return nil }

        // The program chains in chapter order (nearly always one), each read once.
        var order: [Int] = []
        for part in chapterParts where !order.contains(part.chain) { order.append(part.chain) }
        guard let chainCount = info.u16(chains) else { return nil }
        var cells: [Cell] = []
        var chapters: [TimeInterval] = []
        var palette: [UInt32] = []
        var cellStartByChain: [Int: [Int: TimeInterval]] = [:]          // chain -> cell number (from 1) -> start on the title's timeline
        var programEntryByChain: [Int: [Int: Int]] = [:]                // chain -> program number (from 1) -> entry cell number
        var elapsed: TimeInterval = 0
        // The picture (video attributes at 0x200): bits 4-5 the standard (0 NTSC, 1 PAL), bits 2-3 the shape (3: 16:9).
        let video = info.u8(0x200) ?? 0
        let wide = (video >> 2) & 3 == 3
        let pictureHeight = (video >> 4) & 3 == 1 ? 576 : 480
        var subtitleStreams: [Int] = []
        for chainNumber in order where chainNumber >= 1 && chainNumber <= chainCount {
            guard let chainOffset = info.u32(chains + 8 + (chainNumber - 1) * 8 + 4) else { continue }
            let chain = chains + chainOffset
            guard let programs = info.u8(chain + 2), let cellCount = info.u8(chain + 3),
                  let mapOffset = info.u16(chain + 0xE6), let playbackOffset = info.u16(chain + 0xE8) else { continue }
            if palette.isEmpty {
                palette = (0..<16).compactMap { info.u32(chain + 0xA4 + 4 * $0).map(UInt32.init) }
                // The subtitle control words: per subtitle of the disc's list, "available" in the top bit, then the stream for a
                // 4:3 picture (bits 24-28) and for a wide one (bits 16-20).
                for index in 0..<32 {
                    guard let word = info.u32(chain + 0x1C + 4 * index), word & 0x8000_0000 != 0 else { continue }
                    let stream = wide ? (word >> 16) & 0x1F : (word >> 24) & 0x1F
                    if !subtitleStreams.contains(stream) { subtitleStreams.append(stream) }
                }
            }
            var entries: [Int: Int] = [:]
            for program in 0..<programs { if let cell = info.u8(chain + mapOffset + program) { entries[program + 1] = cell } }
            programEntryByChain[chainNumber] = entries
            var starts: [Int: TimeInterval] = [:]
            for index in 0..<cellCount {
                let entry = chain + playbackOffset + index * 24
                guard let category = info.u8(entry), let first = info.u32(entry + 8), let last = info.u32(entry + 0x14),
                      let duration = info.time(entry + 4), last >= first else { continue }
                // Angle blocks: the first cell of a block is angle 1; the other cells of the block are other angles.
                let blockMode = category >> 6, blockType = (category >> 4) & 3
                if blockType == 1, blockMode == 2 || blockMode == 3 { continue }
                starts[index + 1] = elapsed
                cells.append(Cell(firstSector: first, lastSector: last, duration: duration, start: elapsed))
                elapsed += duration
            }
            cellStartByChain[chainNumber] = starts
        }
        guard !cells.isEmpty, elapsed > 0 else { return nil }
        for part in chapterParts {
            guard let cell = programEntryByChain[part.chain]?[part.program], let start = cellStartByChain[part.chain]?[cell] else { continue }
            if chapters.last.map({ start > $0 }) ?? true { chapters.append(start) }
        }
        if chapters.first != 0 { chapters.insert(0, at: 0) }

        // The time map of the title's (first) program chain.
        var step = 0
        var map: [Int] = []
        if let mapsSector = info.u32(0xD4), mapsSector > 0, let firstChain = order.first {
            let maps = mapsSector * sectorSize
            if let mapCount = info.u16(maps), firstChain <= mapCount, let mapOffset = info.u32(maps + 8 + (firstChain - 1) * 4) {
                let timeMap = maps + mapOffset
                if let unit = info.u8(timeMap), unit > 0, let entries = info.u16(timeMap + 2) {
                    step = unit
                    for index in 0..<min(entries, 20_000) {
                        guard let value = info.u32(timeMap + 4 + index * 4) else { break }
                        map.append(value & 0x7FFF_FFFF)
                    }
                }
            }
        }
        return Title(number: number, titleSet: titleSet, duration: elapsed, chapters: chapters, cells: cells, palette: palette,
                     timeMapStep: map.isEmpty ? 0 : step, timeMap: map, subtitleStreams: subtitleStreams, pictureHeight: pictureHeight)
    }

    /// Big-endian reads that never leave the data.
    private struct Bytes {
        let bytes: [UInt8]
        init(_ data: Data) { bytes = [UInt8](data) }
        func has(prefix: String) -> Bool { bytes.count >= prefix.utf8.count && bytes[0..<prefix.utf8.count].elementsEqual(prefix.utf8) }
        func u8(_ at: Int) -> Int? { at >= 0 && at < bytes.count ? Int(bytes[at]) : nil }
        func u16(_ at: Int) -> Int? { at >= 0 && at + 1 < bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil }
        func u32(_ at: Int) -> Int? { at >= 0 && at + 3 < bytes.count ? (0..<4).reduce(0) { $0 << 8 | Int(bytes[at + $1]) } : nil }
        /// A playback time: hours, minutes, seconds in binary-coded decimal, then frames (BCD in the low six bits) with the frame
        /// rate in the top two (1: 25 per second, 3: 30).
        func time(_ at: Int) -> TimeInterval? {
            guard let hours = u8(at), let minutes = u8(at + 1), let seconds = u8(at + 2), let frames = u8(at + 3) else { return nil }
            func bcd(_ value: Int) -> Int { (value >> 4) * 10 + (value & 0x0F) }
            let rate: Double = switch frames >> 6 { case 1: 25; case 3: 30000.0 / 1001.0; default: 0 }
            let fraction = rate > 0 ? Double(bcd(frames & 0x3F)) / rate : 0
            return TimeInterval(bcd(hours) * 3600 + bcd(minutes) * 60 + bcd(seconds)) + fraction
        }
    }
}
