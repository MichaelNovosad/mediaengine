import Foundation
import Testing
@testable import MediaEngine

@Suite("Subtitle files")
struct SubtitleFileTests {
    private func cues(_ text: String, _ ext: String = "srt") throws -> [SubtitleCue] {
        try #require(SubtitleFileParser.parse(text, fileExtension: ext)).cues
    }

    @Test("SubRip in its usual shapes")
    func subRip() throws {
        let standard = "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\n<i>Second</i>\nline two\n"
        #expect(try cues(standard) == [SubtitleCue(start: 1, end: 2.5, text: "Hello"), SubtitleCue(start: 3, end: 4, text: "<i>Second</i>\nline two")])
        let windows = standard.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try cues(windows) == cues(standard))
        #expect(try cues("00:00:01.000 --> 00:00:02.000\nNo index, dot separator\n").map(\.text) == ["No index, dot separator"])
        #expect(try cues("1\n00:00:01,000 --> 00:00:02,000 X1:100 X2:200 Y1:50 Y2:80\nWith coordinates\n").first?.end == 2)
        let glued = "1\n00:00:01,000 --> 00:00:02,000\nFirst\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n"
        #expect(try cues(glued).map(\.text) == ["First", "Second"], "no blank line between the cues: the index is not text")
        #expect(try cues("1\n00:00:05,000 --> 00:00:02,000\nbackwards\n\n2\n00:00:06,000 --> 00:00:07,000\nok\n").map(\.text) == ["ok"])
        #expect(try cues("1\n01:02:03,004 --> 01:02:05,000\nover an hour\n").first?.start == 3723.004)
        #expect(try cues("1\n00:00:01,000 --> 00:00:02,000\n{\\an8}<font color=\"red\">styled</font>\n").first?.text == "styled")
    }

    @Test("WebVTT: headers, notes, identifiers, short times, settings and entities")
    func webVTT() throws {
        let file = """
        WEBVTT - a title

        NOTE this is a comment
        and it continues

        STYLE
        ::cue { color: red }

        intro
        00:01.000 --> 00:03.500 line:10% position:50% align:middle vertical:rl bogus:1
        <v Bob>Tom &amp; Jerry &lt;3</v>

        00:00:04.000 --> 00:00:05.000
        <c.yellow>plain</c> and <i>italic</i><00:00:04.500>
        """
        let result = try cues(file, "vtt")
        #expect(result.count == 2)
        #expect(result[0] == SubtitleCue(start: 1, end: 3.5, text: "Tom &amp; Jerry &lt;3", settings: "line:10% position:50% align:middle"))
        #expect(result[1].text == "plain and <i>italic</i>" && result[1].settings.isEmpty)
    }

    @Test("ASS and SSA: the dialogue and signs scripts give what the embedded tracks give")
    func ass() async throws {
        let dialogue = try cues(try String(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/dialogue.ass"), encoding: .utf8), "ass")
        #expect(dialogue == [SubtitleCue(start: 0.2, end: 1.4, text: "Dialogue one, styled."),
                             SubtitleCue(start: 1.6, end: 2.8, text: "<i>Dialogue two</i>, italic.")])
        let signs = try cues(try String(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/signs.ass"), encoding: .utf8), "ass")
        #expect(signs.first == SubtitleCue(start: 0.2, end: 1.4, text: "SIGN: Station", settings: "line:17%,start position:50%,center align:center"))
        #expect(signs.last?.text == "Karaoke line")

        // The same scripts as embedded tracks give the same text and placement in the player's WebVTT.
        let info = try await Fixture.probe("fixture-anime")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-anime")), info: info, cancellation: CancellationFlag())
        let embedded = [String(decoding: try #require(try session.resource(path: "subs-3-0.vtt")).data, as: UTF8.self),
                        String(decoding: try #require(try session.resource(path: "subs-4-0.vtt")).data, as: UTF8.self)]
        for cue in dialogue + signs {
            let line = "\(cue.settings.isEmpty ? "" : " " + cue.settings)\n\(cue.text)"
            #expect(embedded.contains { $0.contains(line) }, "\(cue.text) as an embedded cue")
        }
        let ssa = """
        [Script Info]
        ScriptType: v4.00
        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
        Style: Default,Arial,20,16777215,65535,65535,0,0,0,1,2,2,2,10,10,10,0,1
        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,An SSA line, with a comma
        """
        #expect(try cues(ssa, "ssa") == [SubtitleCue(start: 1, end: 2, text: "An SSA line, with a comma")])
    }

    @Test("the format comes from the content first and the extension second")
    func sniffing() {
        #expect(SubtitleFileParser.format(of: "WEBVTT\n\n00:01.000 --> 00:02.000\nx", fileExtension: "txt") == .webVTT)
        #expect(SubtitleFileParser.format(of: "[Script Info]\nTitle: x", fileExtension: "txt") == .ass)
        #expect(SubtitleFileParser.format(of: "1\n00:00:01,000 --> 00:00:02,000\nx", fileExtension: "txt") == .subRip)
        #expect(SubtitleFileParser.format(of: "garbage", fileExtension: "srt") == .subRip)
        #expect(SubtitleFileParser.format(of: "garbage", fileExtension: "docx") == nil)
    }

    @Test("times in every shape")
    func times() {
        #expect(SubtitleFileParser.timestamp("00:00:01,500") == 1.5)
        #expect(SubtitleFileParser.timestamp("1:02:03.45") == 3723.45)
        #expect(SubtitleFileParser.timestamp("02:03.250") == 123.25)
        #expect(SubtitleFileParser.timestamp("00:61:00") == nil || SubtitleFileParser.timestamp("00:61:00") == 3660)
        #expect(SubtitleFileParser.timestamp("00:00:75.000") == nil)
        #expect(SubtitleFileParser.timestamp("abc") == nil && SubtitleFileParser.timestamp("12") == nil)
    }
}

@Suite("Subtitle file names")
struct SubtitleFileNameTests {
    private func hints(_ name: String) -> (language: String?, forced: Bool, sdh: Bool) {
        let parsed = SubtitleFileName(name)
        return (parsed.language?.languageCode?.identifier, parsed.isForced, parsed.isHearingImpaired)
    }

    @Test("language and flags come from the end of the name")
    func hintsFromNames() {
        #expect(hints("Movie.en.srt") == ("en", false, false))
        #expect(hints("Movie.2020.1080p.eng.forced.srt") == ("en", true, false))
        #expect(hints("Show.S01E02.ru.SDH.srt") == ("ru", false, true))
        #expect(hints("Show.Ukrainian.srt") == ("uk", false, false))
        #expect(hints("Film.pt-BR.srt").language == "pt")
        #expect(hints("Film.jpn.srt").language == "ja" && hints("Film.zho.srt").language == "zh")
        #expect(hints("Film.CHI.srt").language == "zh", "case does not matter")
    }

    @Test("words in a film's name are not languages")
    func noFalseHints() {
        #expect(hints("The.Movie.srt").language == nil)
        #expect(hints("Movie.of.the.Year.srt").language == nil)
        #expect(hints("subtitle.srt") == (nil, false, false))
        #expect(hints("en.srt").language == nil, "a lone name is the film's name")
        #expect(hints("Movie.forced.srt") == (nil, true, false))
        #expect(hints("Movie.xx-yy.srt").language == nil)
    }
}

@Suite("Subtitle tracks")
struct SubtitleTrackTests {
    static let srt = "1\n00:00:01,000 --> 00:00:02,000\nПривет, мир.\n\n2\n00:00:03,000 --> 00:00:05,000\nВторая строка.\n"

    @Test("the encoding is detected and the language and flags are read from the name")
    func detection() throws {
        let bytes = try #require(TextEncoding.windows1251.encode(Self.srt))
        let track = try SubtitleTrack(data: bytes, name: "Film.ru.forced.srt")
        #expect(track.encoding == .windows1251 && track.format == "SubRip" && track.cueCount == 2)
        #expect(track.language?.languageCode?.identifier == "ru" && track.isForced && !track.isHearingImpaired)
        #expect(track.title.hasSuffix("(forced)"))
        #expect(track.shiftedCues.map(\.text) == ["Привет, мир.", "Вторая строка."])
    }

    @Test("a named encoding wins over detection, even when it is wrong")
    func manual() throws {
        let bytes = try #require(TextEncoding.windows1251.encode(Self.srt))
        let wrong = try SubtitleTrack(data: bytes, name: "x.srt", encoding: .koi8r)
        #expect(wrong.encoding == .koi8r && wrong.shiftedCues.first?.text != "Привет, мир.")
        let right = try SubtitleTrack(data: bytes, name: "x.srt", language: Locale.Language(identifier: "uk"), title: "Mine", encoding: .windows1251)
        #expect(right.title == "Mine" && right.language?.languageCode?.identifier == "uk")
        #expect(throws: MediaError.self) { _ = try SubtitleTrack(data: Data([0xFF, 0xFE, 0xFD, 0x41]), name: "x.srt", encoding: .utf8) }
    }

    @Test("a delay moves every cue; cues that end before the start are dropped")
    func delay() throws {
        let data = Data(Self.srt.utf8)
        let later = try SubtitleTrack(data: data, name: "x.srt", delay: 2.5)
        #expect(later.shiftedCues.map(\.start) == [3.5, 5.5] && later.shiftedCues.map(\.end) == [4.5, 7.5])
        let earlier = try SubtitleTrack(data: data, name: "x.srt", delay: -2.5)
        #expect(earlier.shiftedCues.count == 1 && earlier.shiftedCues[0].start == 0.5 && earlier.shiftedCues[0].end == 2.5)
        let clipped = try SubtitleTrack(data: data, name: "x.srt", delay: -1.5)
        #expect(clipped.shiftedCues.map(\.start) == [0, 1.5] && clipped.shiftedCues[0].end == 0.5, "a cue that has already begun is clipped at 0")
        #expect(try SubtitleTrack(data: data, name: "x.srt").shiftedCues == (try SubtitleTrack(data: data, name: "x.srt")).cues)
    }

    @Test("files that are not subtitles are refused with a reason")
    func refusing() throws {
        #expect(throws: MediaError.self) { _ = try SubtitleTrack(data: Data("just some text".utf8), name: "notes.txt") }
        #expect(throws: MediaError.self) { _ = try SubtitleTrack(data: Data("1\n00:00:01,000 --> 00:00:02,000\n\n".utf8), name: "empty.srt") }
        #expect(throws: MediaError.self) { _ = try SubtitleTrack(data: Data(count: SubtitleTrack.sizeLimit + 1), name: "huge.srt") }
    }

    @Test("a file is read from disk, and a missing one is reported")
    func files() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Test.pl.srt")
        try Data(TextEncoding.windows1250.encode("1\n00:00:01,000 --> 00:00:02,000\nCześć, świecie żółwiu.\n")!).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = try await SubtitleTrack(url: url)
        #expect(track.language?.languageCode?.identifier == "pl" && track.shiftedCues.first?.text == "Cześć, świecie żółwiu.")
        await #expect(throws: MediaError.self) { _ = try await SubtitleTrack(url: URL(fileURLWithPath: "/nonexistent/none.srt")) }
    }
}

@Suite("External subtitles in a session")
struct ExternalSubtitleSessionTests {
    static let russian = "1\n00:00:00,200 --> 00:00:01,400\nПривет, внешний мир.\n\n2\n00:00:01,600 --> 00:00:02,800\nВторая строка файла.\n"

    private func track(_ name: String = "Film.ru.srt", delay: TimeInterval = 0, title: String? = nil) throws -> SubtitleTrack {
        try SubtitleTrack(data: try #require(TextEncoding.windows1251.encode(Self.russian)), name: name, title: title, delay: delay)
    }

    @Test("a file shows up among the choices, flagged external, after the embedded tracks, with a unique name")
    func choices() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-multi"))
        defer { session.close() }
        let before = session.subtitleChoices
        try session.add(track(title: "English"))                         // the same name as an embedded track
        try session.add(track("Film.ja.forced.srt"))
        let after = session.subtitleChoices
        #expect(Array(after.prefix(before.count)) == before)
        #expect(after.map(\.isExternal) == [false, false, false, true, true])
        #expect(after.prefix(4).map(\.title) == ["English", "English SDH", "Signs", "English (2)"])
        #expect(after[4].isForced && after[4].language?.languageCode?.identifier == "ja" && after[4].title.hasSuffix("(forced)"))
        #expect(after[3].id == 10_000 && after[4].id == 10_001)
        #expect(Set(after.map(\.title)).count == after.count)
        #expect(session.audioChoices.allSatisfy { !$0.isExternal })
    }

    @Test("the master playlist lists the file and its segments carry the cues, shifted by the delay")
    func playlists() async throws {
        let info = try await Fixture.probe("fixture-basic")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-basic")), info: info, cancellation: CancellationFlag(),
                                       externalSubtitles: [try track(delay: 1.0)])
        let master = String(decoding: try #require(try session.resource(path: "master.m3u8")).data, as: UTF8.self)
        #expect(master.contains("URI=\"subs-10000.m3u8\""), "\(master)")
        let playlist = String(decoding: try #require(try session.resource(path: "subs-10000.m3u8")).data, as: UTF8.self)
        #expect(playlist.contains("subs-10000-0.vtt"))
        let vtt = String(decoding: try #require(try session.resource(path: "subs-10000-0.vtt")).data, as: UTF8.self)
        #expect(vtt.contains("\(WebVTT.timestamp(1.2 + session.mediaShift)) --> \(WebVTT.timestamp(2.4 + session.mediaShift))\nПривет, внешний мир."), "\(vtt)")
        #expect(try session.resource(path: "subs-10001-0.vtt") == nil)
        #expect(session.scannedSubtitleWindows.isEmpty == false, "the embedded SRT is still read from its windows")
    }

    @Test("a file for a video without subtitle tracks needs no reading of the video")
    func onlyExternal() async throws {
        let info = try await Fixture.probe("fixture-hevc")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-hevc")), info: info, cancellation: CancellationFlag(),
                                       externalSubtitles: [try track()])
        let vtt = String(decoding: try #require(try session.resource(path: "subs-10000-0.vtt")).data, as: UTF8.self)
        #expect(vtt.contains("Привет, внешний мир."))
        #expect(session.scannedSubtitleWindows.isEmpty, "nothing in the file had to be read")
    }

    @Test("files cannot be added once an item exists")
    func tooLate() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { session.close() }
        try session.add(track())
        _ = try await session.makePlayerItem()
        #expect(throws: MediaError.self) { try session.add(track()) }
        session.close()
        #expect(throws: MediaError.self) { try session.add(track()) }
    }
}

#if os(macOS)
import AVFoundation
import Synchronization

@MainActor
@Suite("External subtitles in AVPlayer", .serialized)
struct ExternalSubtitlePlayerTests {
    private final class Collector: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
        private let received = Mutex<[(time: Double, text: String)]>([])
        var texts: [String] { received.withLock { $0.map(\.text) } }
        func time(of text: String) -> Double? { received.withLock { $0.first { $0.text == text }?.time } }
        func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                           nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
            let text = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { received.withLock { $0.append((itemTime.seconds, text)) } }
        }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return condition()
    }

    @Test("a Windows-1251 Russian file is detected, offered, selected and shown on time, with a delay")
    func shows() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-hevc"))
        defer { session.close() }
        let bytes = try #require(TextEncoding.windows1251.encode(ExternalSubtitleSessionTests.russian))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Clip.ru.srt")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let track = try await SubtitleTrack(url: file, delay: 0.5)
        #expect(track.encoding == .windows1251)
        try session.add(track)

        let item = try await session.makePlayerItem()
        let collector = Collector()
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        output.suppressesPlayerRendering = true
        output.setDelegate(collector, queue: .main)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")

        let choice = try #require(session.subtitleChoices.first)
        #expect(choice.isExternal && choice.language?.languageCode?.identifier == "ru")
        try await session.select(choice, on: item)
        #expect(await session.selectedChoice(of: .subtitle, on: item) == choice)
        player.play()
        #expect(await waitUntil(8) { collector.texts.contains("Вторая строка файла.") }, "got \(collector.texts)")
        let first = try #require(collector.time(of: "Привет, внешний мир."))
        #expect(abs(first - 0.7) < 0.15, "the cue at 0.2 s plus a 0.5 s delay arrived for item time \(first)")
        player.pause()
    }
}
#endif
