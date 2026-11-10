import Foundation
import Testing
@testable import MediaEngine

/// DVD track languages from a title set's information file (2026-11-10). The files are built here from the layout libdvdread reads (no disc
/// image is in the fixtures); what a real disc says is the owner's check (the app's docs/HOW_TO_TEST.md 6d, step 18).
@Suite("Disc information")
struct DiscInfoTests {
    /// A `VTS_xx_0.IFO`: the header, the picture's shape, sound and subtitle attributes, and (when `chain` is set) a first program chain at
    /// sector 1 that maps logical tracks to streams.
    private func titleInfo(wide: Bool, audio: [(format: UInt8, language: String)], subtitles: [String],
                           chain: (audio: [Int], subtitles: [(fourByThree: Int, wide: Int)])? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: chain == nil ? 0x400 : 4096)
        bytes.replaceSubrange(0..<12, with: Array("DVDVIDEO-VTS".utf8))
        bytes[0x200] = wide ? 0x0C : 0x00                                   // display aspect 3 (16:9) or 0 (4:3)
        bytes[0x203] = UInt8(audio.count)
        for (index, track) in audio.enumerated() {
            let at = 0x204 + 8 * index
            bytes[at] = track.format << 5 | 1 << 2                          // format, "has a language"
            bytes.replaceSubrange((at + 2)..<(at + 4), with: Array(track.language.utf8))
        }
        bytes[0x255] = UInt8(subtitles.count)
        for (index, language) in subtitles.enumerated() {
            let at = 0x256 + 6 * index
            bytes[at] = 1                                                   // "has a language"
            bytes.replaceSubrange((at + 2)..<(at + 4), with: Array(language.utf8))
        }
        if let chain {
            bytes[0xCF] = 1                                                 // the program chain table at sector 1
            let table = 2048
            bytes[table + 1] = 1                                            // one program chain
            bytes[table + 15] = 16                                          // it starts 16 bytes into the table
            let pgc = table + 16
            for (index, stream) in chain.audio.enumerated() {
                bytes[pgc + 0x0C + 2 * index] = 0x80 | UInt8(stream)
            }
            for (index, streams) in chain.subtitles.enumerated() {
                let at = pgc + 0x1C + 4 * index
                bytes[at] = 0x80 | UInt8(streams.fourByThree)
                bytes[at + 1] = UInt8(streams.wide)
            }
        }
        return Data(bytes)
    }

    @Test("sound and subtitle languages by the program stream's ids, track n as stream n without a program chain")
    func plain() {
        let data = titleInfo(wide: false, audio: [(0, "en"), (0, "ru"), (6, "ja"), (4, "fr"), (2, "de")], subtitles: ["en", "fr"])
        let languages = DiscInfo.languages(dvdTitleInfo: data)
        #expect(languages[0x80]?.languageCode?.identifier == "en", "AC-3, stream 0")
        #expect(languages[0x81]?.languageCode?.identifier == "ru")
        #expect(languages[0x8A]?.languageCode?.identifier == "ja", "DTS, stream 2")
        #expect(languages[0xA3]?.languageCode?.identifier == "fr", "LPCM, stream 3")
        #expect(languages[0x1C4]?.languageCode?.identifier == "de", "MPEG sound, stream 4")
        #expect(languages[0x20]?.languageCode?.identifier == "en" && languages[0x21]?.languageCode?.identifier == "fr")
        #expect(languages.count == 7)
    }

    @Test("the first program chain decides the streams; a 16:9 title takes the wide subtitle stream, a 4:3 one the 4:3 stream")
    func chain() {
        let streams = (audio: [1, 0], subtitles: [(fourByThree: 0, wide: 2), (fourByThree: 1, wide: 3)])
        let wide = DiscInfo.languages(dvdTitleInfo: titleInfo(wide: true, audio: [(0, "en"), (0, "ru")], subtitles: ["en", "fr"], chain: streams))
        #expect(wide[0x81]?.languageCode?.identifier == "en" && wide[0x80]?.languageCode?.identifier == "ru")
        #expect(wide[0x22]?.languageCode?.identifier == "en" && wide[0x23]?.languageCode?.identifier == "fr")
        let square = DiscInfo.languages(dvdTitleInfo: titleInfo(wide: false, audio: [(0, "en")], subtitles: ["en", "fr"], chain: streams))
        #expect(square[0x20]?.languageCode?.identifier == "en" && square[0x21]?.languageCode?.identifier == "fr")
    }

    @Test("not a title set's information file, or one that names no language: nothing")
    func nothing() {
        #expect(DiscInfo.languages(dvdTitleInfo: Data("DVDVIDEO-VMG".utf8) + Data(count: 0x400)).isEmpty)
        #expect(DiscInfo.languages(dvdTitleInfo: Data(count: 10)).isEmpty)
        var unnamed = [UInt8](titleInfo(wide: false, audio: [(0, "en")], subtitles: []))
        unnamed[0x204] = 0                                                  // no "has a language"
        #expect(DiscInfo.languages(dvdTitleInfo: Data(unnamed)).isEmpty)
    }

    @Test("where the information file of a stream file is, in the stream's own spelling")
    func location() {
        let folder = URL(fileURLWithPath: "/Disc/VIDEO_TS", isDirectory: true)
        #expect(DiscInfo.titleInfoLocation(forStream: folder.appendingPathComponent("VTS_01_1.VOB"))?.lastPathComponent == "VTS_01_0.IFO")
        #expect(DiscInfo.titleInfoLocation(forStream: folder.appendingPathComponent("vts_02_3.vob"))?.lastPathComponent == "vts_02_0.ifo")
        #expect(DiscInfo.titleInfoLocation(forStream: folder.appendingPathComponent("VTS_01_0.VOB")) == nil, "the menus")
        #expect(DiscInfo.titleInfoLocation(forStream: folder.appendingPathComponent("Movie.vob")) == nil)
        #expect(DiscInfo.titleInfoLocation(forStream: folder.appendingPathComponent("VTS_01_1.mkv")) == nil)
    }

    @Test("one call for both kinds of disc reads the file next to the stream")
    func either() async {
        let data = titleInfo(wide: false, audio: [(0, "en")], subtitles: [])
        let stream = URL(fileURLWithPath: "/Disc/VIDEO_TS/VTS_01_1.VOB")
        let asked = Asked()
        let languages = await DiscInfo.languages(forStream: stream) { url in await asked.add(url.lastPathComponent); return data }
        #expect(languages[0x80]?.languageCode?.identifier == "en")
        #expect(await asked.names == ["VTS_01_0.IFO"])
        let nothing = await DiscInfo.languages(forStream: URL(fileURLWithPath: "/Movies/Film.mkv")) { _ in Data() }
        #expect(nothing.isEmpty)
    }
}

private actor Asked {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}
