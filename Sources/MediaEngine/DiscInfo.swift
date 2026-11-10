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
