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
        #expect(master.contains("NAME=\"Dialogue\"") && master.contains("NAME=\"Signs and Songs\""))
        #expect(master.contains("NAME=\"Signs and Songs\",LANGUAGE=\"en\",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES"))
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
}
