import Foundation
import Testing
@testable import MediaEngine

@Suite("Subtitle text")
struct SubtitleTextTests {
    @Test("SubRip keeps italic, bold and underline, drops other tags and escapes the rest")
    func subrip() {
        #expect(SubtitleText.fromMarkup("Hello, <i>world</i>!") == "Hello, <i>world</i>!")
        #expect(SubtitleText.fromMarkup("<B>bold</B> <u>under</u>") == "<b>bold</b> <u>under</u>")
        #expect(SubtitleText.fromMarkup("<font color=\"#ff0000\">red</font> text") == "red text")
        #expect(SubtitleText.fromMarkup("{\\an8}top line") == "top line")
        #expect(SubtitleText.fromMarkup("a < b & c > d") == "a &lt; b &amp; c &gt; d")
        #expect(SubtitleText.fromMarkup("one\r\n\r\ntwo\r\n") == "one\ntwo")
        #expect(SubtitleText.fromMarkup("  \n ").isEmpty)
        #expect(SubtitleText.fromMarkup("こんにちは — second line, UTF-8.") == "こんにちは — second line, UTF-8.")
    }

    @Test("ASS events: text after the eighth comma, line breaks, switches and drawings")
    func ass() {
        func event(_ text: String) -> String { "0,0,Default,,0,0,0,,\(text)" }
        #expect(SubtitleText.fromASSEvent(event("Dialogue one, styled.")) == "Dialogue one, styled.")
        #expect(SubtitleText.fromASSEvent(event("{\\i1}Dialogue two{\\i0}, italic.")) == "<i>Dialogue two</i>, italic.")
        #expect(SubtitleText.fromASSEvent(event("{\\pos(320,60)\\fad(100,100)}SIGN: Station")) == "SIGN: Station")
        #expect(SubtitleText.fromASSEvent(event("{\\k20}Kara{\\k30}oke {\\k25}line")) == "Karaoke line")
        #expect(SubtitleText.fromASSEvent(event("first\\Nsecond\\nthird")) == "first\nsecond\nthird")
        #expect(SubtitleText.fromASSEvent(event("a\\hb")) == "a\u{00A0}b")
        #expect(SubtitleText.fromASSEvent(event("{\\b1}bold{\\b0} and {\\u1}underlined")) == "<b>bold</b> and <u>underlined</u>")   // open tag closed at the end
        #expect(SubtitleText.fromASSEvent(event("{\\p1}m 0 0 l 100 0 100 100{\\p0}")).isEmpty)
        #expect(SubtitleText.fromASSEvent(event("visible{\\p1}m 0 0 l 1 1{\\p0} again")) == "visible again")
        #expect(SubtitleText.fromASSEvent(event("5 < 6 & 7")) == "5 &lt; 6 &amp; 7")
        #expect(SubtitleText.fromASSEvent("not an event").isEmpty)
        #expect(SubtitleText.fromASSEvent(event("")).isEmpty)
    }

    @Test("packets become cues with their times; empty or zero-length ones are dropped")
    func cues() {
        let cue = SubtitleText.cue(codec: "subrip", data: Data("Hi".utf8), start: 1.5, duration: 2)
        #expect(cue == SubtitleCue(start: 1.5, end: 3.5, text: "Hi"))
        #expect(SubtitleText.cue(codec: "subrip", data: Data("Hi".utf8), start: 1, duration: 0) == nil)
        #expect(SubtitleText.cue(codec: "subrip", data: Data("<i></i>".utf8), start: 1, duration: 1) == nil)
        #expect(SubtitleText.cue(codec: "subrip", data: Data([0xFF, 0xFE, 0xFD]), start: 1, duration: 1) == nil)
        #expect(SubtitleText.cue(codec: "ass", data: Data("0,0,Default,,0,0,0,,Yo".utf8), start: 0, duration: 1)?.text == "Yo")
        #expect(SubtitleText.cue(codec: "webvtt", data: Data(" Plain cue \n".utf8), start: 0, duration: 1)?.text == "Plain cue")
        #expect(SubtitleText.canConvert(codec: "subrip") && SubtitleText.canConvert(codec: "ass"))
        #expect(!SubtitleText.canConvert(codec: "hdmv_pgs_subtitle") && !SubtitleText.canConvert(codec: "dvd_subtitle"))
    }

    @Test("WebVTT segments repeat cues that span a boundary and shift times onto the media timeline")
    func webvtt() {
        let cues = [SubtitleCue(start: 1, end: 3, text: "early"), SubtitleCue(start: 5, end: 8, text: "spans"),
                    SubtitleCue(start: 9, end: 10, text: "late")]
        let first = WebVTT.segment(cues: cues, start: 0, end: 6, shift: 0.5)
        #expect(first.hasPrefix("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"))
        #expect(first.contains("00:00:01.500 --> 00:00:03.500\nearly\n"))
        #expect(first.contains("00:00:05.500 --> 00:00:08.500\nspans\n"))
        #expect(!first.contains("late"))
        let second = WebVTT.segment(cues: cues, start: 6, end: 12, shift: 0.5)
        #expect(second.contains("spans") && second.contains("late") && !second.contains("early"))
        #expect(WebVTT.segment(cues: cues, start: 20, end: 26, shift: 0) == "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n")
        #expect(WebVTT.timestamp(3_723.4567) == "01:02:03.457")
        #expect(WebVTT.timestamp(-1) == "00:00:00.000")
    }
}

@Suite("Subtitle placement")
struct SubtitlePlacementTests {
    private let signs = ASSHeader("""
        [Script Info]
        PlayResX: 640
        PlayResY: 360

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,FakeFont,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
        Style: Sign,FakeFont,36,&H0000FFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,2,0,8,10,10,10,1
        """)

    private func settings(_ style: String, _ text: String, header: ASSHeader? = nil) -> String {
        SubtitleText.cueSettings(forASSEvent: (style, text), header: header ?? signs)
    }

    @Test("the header gives the script resolution and each style's alignment")
    func header() {
        #expect(signs.playResX == 640 && signs.playResY == 360)
        #expect(signs.alignments == ["Default": 2, "Sign": 8])
        let bare = ASSHeader("")
        #expect(bare.playResX == 384 && bare.playResY == 288 && bare.alignments.isEmpty)
    }

    @Test("bottom centre is the default and needs no settings")
    func defaultPlacement() {
        #expect(settings("Default", "plain").isEmpty)
        #expect(settings("Default", "{\\i1}italic{\\i0}").isEmpty)
        #expect(settings("Unknown style", "text").isEmpty)
    }

    @Test("a style's alignment and \\an move the cue to the top, middle or a side")
    func alignment() {
        #expect(settings("Sign", "top by style") == "line:6%,start")
        #expect(settings("Default", "{\\an8}top") == "line:6%,start")
        #expect(settings("Default", "{\\an7}top left") == "line:6%,start position:5%,line-left align:left")
        #expect(settings("Default", "{\\an6}middle right") == "line:50%,center position:95%,line-right align:right")
        #expect(settings("Default", "{\\an1}bottom left") == "position:5%,line-left align:left")
        #expect(settings("Default", "{\\an5}middle") == "line:50%,center")
        #expect(settings("Sign", "{\\an2}overrides the style").isEmpty)
        #expect(settings("Default", "{\\an12}out of range").isEmpty)
    }

    @Test("\\pos becomes a percentage of the script resolution, anchored the way the alignment says")
    func position() {
        #expect(settings("Sign", "{\\pos(320,60)\\fad(100,100)}SIGN") == "line:17%,start position:50%,center align:center")
        #expect(settings("Default", "{\\an5\\pos(100,100)}x", header: ASSHeader()) == "line:35%,center position:26%,center align:center")
        #expect(settings("Default", "{\\an1\\pos(0,360)}corner") == "line:100%,end position:0%,line-left align:left")
        #expect(settings("Default", "{\\pos(900,-20)}outside") == "line:0%,end position:100%,center align:center")      // clamped
    }

    @Test("settings end up on the cue timing line of the WebVTT segment")
    func inSegment() {
        let cue = SubtitleText.cue(codec: "ass", data: Data("0,0,Sign,,0,0,0,,{\\pos(320,60)}SIGN".utf8), start: 0.2, duration: 1.2, header: signs)
        #expect(cue?.settings == "line:17%,start position:50%,center align:center")
        let vtt = WebVTT.segment(cues: [cue!], start: 0, end: 6, shift: 0)
        #expect(vtt.contains("00:00:00.200 --> 00:00:01.400 line:17%,start position:50%,center align:center\nSIGN"))
    }
}

@Suite("Subtitle renditions")
struct SubtitleRenditionTests {
    private func session(_ name: String) async throws -> RemuxSession {
        let info = try await Fixture.probe(name)
        return try RemuxSession(source: FileByteSource(url: Fixture.url(name)), info: info, cancellation: CancellationFlag())
    }
    private func text(_ session: RemuxSession, _ path: String) throws -> String {
        String(decoding: try #require(try session.resource(path: path)).data, as: UTF8.self)
    }

    @Test("an SRT track appears in the master playlist and its WebVTT segment carries the cues")
    func srt() async throws {
        let session = try await session("fixture-basic")
        let master = try text(session, "master.m3u8")
        #expect(master.contains("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"subs-3.m3u8\""))
        #expect(master.contains("SUBTITLES=\"subs\""))
        let playlist = try text(session, "subs-3.m3u8")
        #expect(playlist.contains("#EXT-X-ENDLIST") && playlist.contains("subs-3-0.vtt") && !playlist.contains("EXT-X-MAP"))
        let resource = try #require(try session.resource(path: "subs-3-0.vtt"))
        #expect(resource.contentType == "text/vtt")
        let vtt = String(decoding: resource.data, as: UTF8.self)
        let first = WebVTT.timestamp(0.2 + session.mediaShift), second = WebVTT.timestamp(1.6 + session.mediaShift)
        #expect(vtt.contains("\(first) --> \(WebVTT.timestamp(1.4 + session.mediaShift))\nHello, subtitle one."), "\(vtt)")
        #expect(vtt.contains("\(second) --> ") && vtt.contains("こんにちは — second line, UTF-8."))
    }

    @Test("ASS tracks keep their flags; styling is reduced to italic, bold and underline")
    func ass() async throws {
        let session = try await session("fixture-anime")
        let master = try text(session, "master.m3u8")
        #expect(master.contains("NAME=\"Dialogue - [English]\"") && master.contains("NAME=\"Signs and Songs - [English]\""))
        #expect(master.contains("NAME=\"Signs and Songs - [English]\",LANGUAGE=\"en\",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES"))
        let dialogue = String(decoding: try #require(try session.resource(path: "subs-3-0.vtt")).data, as: UTF8.self)
        #expect(dialogue.contains("Dialogue one, styled.") && dialogue.contains("<i>Dialogue two</i>, italic."))
        let signs = String(decoding: try #require(try session.resource(path: "subs-4-0.vtt")).data, as: UTF8.self)
        #expect(signs.contains("SIGN: Station") && signs.contains("Karaoke line"))
    }

    @Test("unknown tracks and segments are not served, and files without text subtitles have no group")
    func unknown() async throws {
        let basic = try await session("fixture-basic")
        #expect(try basic.resource(path: "subs-99.m3u8") == nil)
        #expect(try basic.resource(path: "subs-3-99.vtt") == nil)
        #expect(try basic.resource(path: "subs-3-x.vtt") == nil)
        let hevc = try await session("fixture-hevc")
        #expect(!(try text(hevc, "master.m3u8")).contains("SUBTITLES"))
    }

    @Test("a long file gets one WebVTT segment per video segment")
    func segments() async throws {
        let basic = try await session("fixture-basic")
        let playlist = try text(basic, "subs-3.m3u8")
        #expect(playlist.components(separatedBy: "#EXTINF").count - 1 == basic.plan.segments.count)
    }

    private func vtt(_ session: RemuxSession, _ segment: Int) throws -> String {
        try text(session, "subs-2-\(segment).vtt")
    }

    @Test("cues that span segment boundaries appear in every segment they overlap, wherever the player starts")
    func spanning() async throws {
        // Segments of the 14 s file: [0, 6), [6, 12), [12, 14).
        let session = try await session("fixture-subs-long")
        #expect(session.plan.segments.count == 3)

        // Random access: the last segment first, on a fresh session.
        let last = try vtt(session, 2)
        #expect(last.contains("<i>long sign</i>"), "a cue that started in the first window shows up in the last segment:\n\(last)")
        #expect(last.contains("\nlast\n") && !last.contains("early") && !last.contains("crosses"))

        let middle = try vtt(session, 1)
        #expect(middle.contains("<i>long sign</i>") && middle.contains("crosses the first boundary"))
        #expect(middle.contains("starts just before the boundary"), "5.95-6.5 s overlaps [6, 12)")
        #expect(middle.contains("\nlast\n") && !middle.contains("early"))

        let first = try vtt(session, 0)
        #expect(first.contains("early") && first.contains("<i>long sign</i>") && first.contains("crosses the first boundary"))
        #expect(first.contains("starts just before the boundary") && !first.contains("\nlast\n"))
    }

    @Test("asking in any order gives the same text as asking in order")
    func orderDoesNotMatter() async throws {
        let sequential = try await session("fixture-subs-long")
        let expected = try (0..<3).map { try vtt(sequential, $0) }
        for order in [[2, 0, 1], [1, 2, 0], [2, 1, 0]] {
            let other = try await session("fixture-subs-long")
            var got = [String](repeating: "", count: 3)
            for index in order { got[index] = try vtt(other, index) }
            #expect(got == expected, "order \(order)")
        }
    }

    @Test("subtitles are read from the windows next to the one asked for, not from the whole file")
    func readsOnlyNearbyWindows() async throws {
        let session = try await session("fixture-subs-long")
        #expect(session.scannedSubtitleWindows.isEmpty)
        _ = try vtt(session, 0)
        #expect(session.scannedSubtitleWindows == [0, 1], "segment 0 needs its own window and the next one")
        _ = try vtt(session, 0)
        #expect(session.scannedSubtitleWindows == [0, 1], "asking again reads nothing new")
    }
}
