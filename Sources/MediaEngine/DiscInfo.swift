import Foundation

/// What a disc folder says about its streams that the stream files do not. A Blu-ray folder (`BDMV`) keeps the language of every
/// sound and subtitle track in a clip information file (`BDMV/CLIPINF/00000.clpi` for `BDMV/STREAM/00000.m2ts`), a DVD folder
/// (`VIDEO_TS`) in the title set's information file (`VTS_01_0.IFO` for `VTS_01_1.VOB`), not in the stream itself, so a stream
/// opened alone has no languages. Hand the result to ``PlaybackSession/init(source:trackLanguages:)``.
public enum DiscInfo {
    /// The languages in a Blu-ray clip information file, by stream PID (``Track/containerID``). Empty when the data is not a clip
    /// information file or names no language.
    ///
    /// The layout is the Blu-ray clip information format as libbluray reads it: the header "HDMV" with a version, the start of the
    /// program information at byte 12, then per program its streams, each a PID and a coding-information block whose first byte
    /// is its length and second the coding type; sound tracks carry their language after a format byte, picture and menu subtitles
    /// right after the type, text subtitles after a character-code byte.
    public static func languages(blurayClipInfo data: Data) -> [Int: Locale.Language] {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0..<4].elementsEqual("HDMV".utf8) else { return [:] }
        func u8(_ at: Int) -> Int? { at < bytes.count ? Int(bytes[at]) : nil }
        func u16(_ at: Int) -> Int? { at + 1 < bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil }
        func u32(_ at: Int) -> Int? { at + 3 < bytes.count ? (0..<4).reduce(0) { $0 << 8 | Int(bytes[at + $1]) } : nil }
        func text(_ at: Int) -> String? {
            guard at + 2 < bytes.count else { return nil }
            let code = String(decoding: bytes[at..<(at + 3)], as: UTF8.self)
            return code.allSatisfy(\.isLetter) ? code.lowercased() : nil
        }

        guard let start = u32(12), start > 0, let programs = u8(start + 5) else { return [:] }
        var result: [Int: Locale.Language] = [:]
        var position = start + 6
        for _ in 0..<programs {
            guard let streams = u8(position + 6) else { break }
            position += 8                                              // SPN (4), program map PID (2), streams (1), groups (1)
            for _ in 0..<streams {
                guard let pid = u16(position), let length = u8(position + 2), let type = u8(position + 3) else { return result }
                let info = position + 3                                // the coding type, then what it describes
                let code: String?
                switch type {
                case 0x03, 0x04, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0xA1, 0xA2: code = text(info + 2)   // sound
                case 0x90, 0x91: code = text(info + 1)                                                         // picture subtitles, menus
                case 0x92: code = text(info + 2)                                                               // text subtitles
                default: code = nil
                }
                if let code, let language = LanguageCodes.language(from: code) { result[pid] = language }
                position += 3 + length                                 // PID (2), length byte (1), the block
            }
        }
        return result
    }

    /// The languages in a DVD title set's information file (`VIDEO_TS/VTS_01_0.IFO` for `VTS_01_1.VOB` and the files after it), by the
    /// stream id the program stream gives each track (``Track/containerID``): AC-3 sound `0x80 + n`, DTS `0x88 + n`, LPCM `0xA0 + n`,
    /// MPEG sound `0x1C0 + n`, subtitles `0x20 + n`. Empty when the data is not a title set's information file.
    ///
    /// The layout is the DVD-Video title set information as libdvdread reads it: the header "DVDVIDEO-VTS"; at 0x200 the video
    /// attributes (the picture's shape decides which subtitle stream a 16:9 title shows); at 0x203 the number of sound streams and at
    /// 0x204 their attributes, 8 bytes each (format in the top three bits of the first byte, "has a language" in bits 3 and 2, the
    /// two-letter code in bytes 2 and 3); at 0x255 the number of subtitle streams and at 0x256 their attributes, 6 bytes each. The
    /// stream a logical track plays is in the first program chain (its sound and subtitle control words); without it, track n is stream n.
    public static func languages(dvdTitleInfo data: Data) -> [Int: Locale.Language] {
        let bytes = [UInt8](data)
        guard bytes.count >= 0x316, bytes[0..<12].elementsEqual("DVDVIDEO-VTS".utf8) else { return [:] }
        func u8(_ at: Int) -> Int? { at < bytes.count ? Int(bytes[at]) : nil }
        func u16(_ at: Int) -> Int? { at + 1 < bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil }
        func u32(_ at: Int) -> Int? { at + 3 < bytes.count ? (0..<4).reduce(0) { $0 << 8 | Int(bytes[at + $1]) } : nil }
        func code(_ at: Int) -> Locale.Language? {
            guard at + 1 < bytes.count else { return nil }
            let text = String(decoding: bytes[at..<(at + 2)], as: UTF8.self)
            guard text.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
            return LanguageCodes.language(from: text.lowercased())
        }

        // The first program chain's control words, when the file has them: which physical stream a logical track is.
        var audioStream: [Int: Int] = [:]
        var subtitleStream: [Int: Int] = [:]
        let wide = ((u8(0x200) ?? 0) >> 2) & 3 == 3                     // 16:9: the "wide" subtitle stream
        if let sector = u32(0xCC), sector > 0, let pgcCount = u16(sector * 2048), pgcCount > 0, let start = u32(sector * 2048 + 12) {
            let pgc = sector * 2048 + start
            for index in 0..<8 {
                if let word = u16(pgc + 0x0C + 2 * index), word & 0x8000 != 0 { audioStream[index] = (word >> 8) & 7 }
            }
            for index in 0..<32 {
                if let word = u32(pgc + 0x1C + 4 * index), word & 0x8000_0000 != 0 {
                    subtitleStream[index] = wide ? (word >> 16) & 0x1F : (word >> 24) & 0x1F
                }
            }
        }

        var result: [Int: Locale.Language] = [:]
        for index in 0..<min(u8(0x203) ?? 0, 8) {
            let attributes = 0x204 + 8 * index
            guard let first = u8(attributes), (first >> 2) & 3 == 1, let language = code(attributes + 2) else { continue }
            let stream = audioStream[index] ?? index
            switch first >> 5 {
            case 0: result[0x80 + stream] = language                      // AC-3
            case 2, 3: result[0x1C0 + stream] = language                  // MPEG-1, MPEG-2
            case 4: result[0xA0 + stream] = language                      // LPCM
            case 6: result[0x88 + stream] = language                      // DTS
            default: break
            }
        }
        for index in 0..<min(u8(0x255) ?? 0, 32) {
            let attributes = 0x256 + 6 * index
            guard let first = u8(attributes), first & 3 == 1, let language = code(attributes + 2) else { continue }
            result[0x20 + (subtitleStream[index] ?? index)] = language
        }
        return result
    }

    /// Where the title set's information file of a DVD stream file lies: `…/VIDEO_TS/VTS_01_0.IFO` for `…/VIDEO_TS/VTS_01_1.VOB`, or `nil`
    /// for a file that is not a title's stream file (the menus' `VTS_01_0.VOB` has its languages in the same file, but is not a movie).
    public static func titleInfoLocation(forStream url: URL) -> URL? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "vob", stem.uppercased().wholeMatch(of: /VTS_\d{2}_[1-9]/) != nil else { return nil }
        // The stream's own spelling (a copied disc may be in lower case, and a server's file names may be case-sensitive).
        let lower = url.pathExtension == "vob"
        return url.deletingLastPathComponent().appendingPathComponent(String(stem.dropLast()) + "0" + (lower ? ".ifo" : ".IFO"))
    }

    /// The languages a disc's description gives a stream file, read with `read` (a file next to it, from a folder or a server): a Blu-ray
    /// clip information file or a DVD title set's information file. Empty for any other file.
    public static func languages(forStream url: URL, read: (URL) async -> Data?) async -> [Int: Locale.Language] {
        if let clipInfo = clipInfoLocation(forStream: url), let data = await read(clipInfo) { return languages(blurayClipInfo: data) }
        if let titleInfo = titleInfoLocation(forStream: url), let data = await read(titleInfo) { return languages(dvdTitleInfo: data) }
        return [:]
    }

    /// What a disc's description says about one stream file: the languages of its tracks and, for a Blu-ray stream, where its
    /// keyframes are. Hand it to ``PlaybackSession/init(source:disc:)``.
    public struct Facts: Sendable, Equatable {
        /// By the stream's number in its container (``Track/containerID``).
        public var languages: [Int: Locale.Language]
        /// A Blu-ray stream's keyframes from its clip information file (``DiscInfo/entryPoints(blurayClipInfo:)``).
        public var entryPoints: [EntryPoint]

        public init(languages: [Int: Locale.Language] = [:], entryPoints: [EntryPoint] = []) {
            self.languages = languages
            self.entryPoints = entryPoints
        }

        public static let none = Facts()
    }

    /// A keyframe of a Blu-ray stream as its clip information file lists it (Jira EGA-121): where a picture a player can start from
    /// begins in the stream file, and its time.
    public struct EntryPoint: Sendable, Equatable {
        /// The stream it belongs to (the video's PID, ``Track/containerID``).
        public let pid: Int
        /// The picture's presentation time in 90 kHz ticks (33 bits), rounded down to a multiple of 512 ticks (5.7 ms): the map keeps
        /// only the time's upper bits.
        public let time: Int64
        /// The byte offset of the transport packet that starts the picture (its source packet number times 192).
        public let offset: Int64

        public init(pid: Int, time: Int64, offset: Int64) {
            self.pid = pid
            self.time = time
            self.offset = offset
        }
    }

    /// The keyframes a Blu-ray clip information file lists (its entry-point map), in order, for every stream it maps (usually the video
    /// alone). Empty when the data is not a clip information file or has no map.
    ///
    /// The layout is the clip information format as libbluray reads it: at byte 16 the start of the characteristic point information;
    /// there its length, then the map type in the low four bits of the second byte after it, then the map: a reserved byte, the number of
    /// streams, and per stream twelve bytes (PID 16 bits, 10 reserved, stream type 4, coarse entries 16, fine entries 18, the start of its
    /// entries 32, counted from the map). There: the start of the fine entries (32 bits), the coarse entries (8 bytes: the first fine
    /// entry it covers 18 bits, time 14 bits, source packet number 32 bits), the fine entries (4 bytes: angle change 1 bit, end position 3,
    /// time 11, source packet number 17). A keyframe's time is the coarse time without its lowest bit, shifted 19, plus the fine time
    /// shifted 9; its packet number the coarse number without its lowest 17 bits plus the fine one. Checked on 2026-11-19 against six
    /// Blu-ray folders on the owner's share: every entry looked at (80 per disc) starts a picture of the video PID whose time, rounded
    /// down to 512 ticks, is the entry's; one re-released disc's map no longer fits its stream after its tenth entry, so a player checks a
    /// map against the stream before it trusts it (``PlaybackSession`` does).
    public static func entryPoints(blurayClipInfo data: Data) -> [EntryPoint] {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, bytes[0..<4].elementsEqual("HDMV".utf8) else { return [] }
        func value(_ at: Int, _ count: Int) -> UInt64? {
            guard at >= 0, at + count <= bytes.count else { return nil }
            return (0..<count).reduce(UInt64(0)) { $0 << 8 | UInt64(bytes[at + $1]) }
        }
        guard let cpi = value(16, 4).map(Int.init), cpi > 0, let length = value(cpi, 4), length > 0,
              let type = value(cpi + 5, 1), type & 0x0F == 1, let streams = value(cpi + 7, 1) else { return [] }
        let map = cpi + 6
        var result: [EntryPoint] = []
        for stream in 0..<Int(streams) {
            let header = map + 2 + 12 * stream
            guard let first = value(header, 4), let second = value(header + 4, 4), let third = value(header + 8, 4) else { break }
            let pid = Int(first >> 16)
            let coarseCount = Int(((first & 0x3) << 14) | (second >> 18))
            let fineCount = Int(second & 0x3FFFF)
            let start = map + Int(third)
            guard coarseCount > 0, fineCount > 0, let fineStart = value(start, 4) else { continue }
            var coarse: [(fine: Int, time: UInt64, packet: UInt64)] = []
            coarse.reserveCapacity(coarseCount)
            for entry in 0..<coarseCount {
                guard let raw = value(start + 4 + 8 * entry, 8) else { break }
                coarse.append((Int(raw >> 46), (raw >> 32) & 0x3FFF, raw & 0xFFFF_FFFF))
            }
            guard !coarse.isEmpty else { continue }
            let fineBase = start + Int(fineStart)
            var current = 0
            for entry in 0..<fineCount {
                guard let raw = value(fineBase + 4 * entry, 4) else { break }
                while current + 1 < coarse.count, coarse[current + 1].fine <= entry { current += 1 }
                let time = (((coarse[current].time & ~1) << 19) + (((raw >> 17) & 0x7FF) << 9)) & ((1 << 33) - 1)
                let packet = (coarse[current].packet & ~0x1FFFF) + (raw & 0x1FFFF)
                result.append(EntryPoint(pid: pid, time: Int64(time), offset: Int64(packet) * 192))
            }
        }
        return result
    }

    /// Languages and keyframes from a Blu-ray clip information file.
    public static func facts(blurayClipInfo data: Data) -> Facts {
        Facts(languages: languages(blurayClipInfo: data), entryPoints: entryPoints(blurayClipInfo: data))
    }

    /// What a disc's description gives a stream file, read with `read` (a file next to it, from a folder or a server): from a Blu-ray
    /// clip information file its languages and keyframes, from a DVD title set's information file its languages. Nothing for any other
    /// file.
    public static func facts(forStream url: URL, read: @Sendable (URL) async -> Data?) async -> Facts {
        if let clipInfo = clipInfoLocation(forStream: url), let data = await read(clipInfo) { return facts(blurayClipInfo: data) }
        if let titleInfo = titleInfoLocation(forStream: url), let data = await read(titleInfo) { return Facts(languages: languages(dvdTitleInfo: data)) }
        return .none
    }

    /// Whether a transport packet (192 bytes of an `.m2ts` file: a 4-byte header, then the 188-byte packet) starts a picture of the
    /// entry point's stream at its time: the check a map passes before it is trusted.
    static func agrees(_ point: EntryPoint, packet: [UInt8]) -> Bool {
        guard packet.count >= 192, packet[4] == 0x47 else { return false }
        let ts = Array(packet[4...])
        let pid = Int(ts[1] & 0x1F) << 8 | Int(ts[2])
        guard pid == point.pid, ts[1] & 0x40 != 0 else { return false }
        var at = 4
        let adaptation = (ts[3] >> 4) & 0x3
        if adaptation == 2 || adaptation == 3 { at += 1 + Int(ts[4]) }
        guard adaptation != 2, at + 14 <= ts.count, ts[at] == 0, ts[at + 1] == 0, ts[at + 2] == 1, ts[at + 7] & 0x80 != 0 else { return false }
        let b = ts[(at + 9)..<(at + 14)].map(Int64.init)
        let pts = ((b[0] >> 1) & 0x7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
        return pts & ~0x1FF == point.time
    }

    /// Where the clip information file of a Blu-ray stream file lies: `…/BDMV/CLIPINF/00000.clpi` for `…/BDMV/STREAM/00000.m2ts`,
    /// or `nil` for a file outside a `BDMV/STREAM` folder.
    public static func clipInfoLocation(forStream url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent.uppercased() == "STREAM", folder.deletingLastPathComponent().lastPathComponent.uppercased() == "BDMV",
              ["m2ts", "mts"].contains(url.pathExtension.lowercased()) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return folder.deletingLastPathComponent().appendingPathComponent("CLIPINF", isDirectory: true).appendingPathComponent(name + ".clpi")
    }
}
