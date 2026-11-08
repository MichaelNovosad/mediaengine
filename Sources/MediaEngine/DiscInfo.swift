import Foundation

/// What a disc folder says about its streams that the stream files do not. A Blu-ray folder (`BDMV`) keeps the language of every
/// sound and subtitle track in a clip information file (`BDMV/CLIPINF/00000.clpi` for `BDMV/STREAM/00000.m2ts`), not in the
/// transport stream itself, so a stream opened alone has no languages. Hand the result to
/// ``PlaybackSession/init(source:trackLanguages:)``.
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
