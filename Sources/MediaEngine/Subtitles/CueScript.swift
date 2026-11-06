import Foundation

/// Text subtitles (SubRip, WebVTT, Timed Text) as an ASS script, so the engine's overlay renderer can draw every kind of
/// text track the same way. Used when the system player does not show them (the software path) or when the host asks
/// the engine to draw them. Styling is a plain, readable default: white text with a dark outline at the bottom.
enum CueScript {
    /// Script header with one style; PlayRes 1920 x 1080 so the font size means "points on a full-HD frame".
    static let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080
    WrapStyle: 0
    ScaledBorderAndShadow: yes
    YCbCr Matrix: None

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Helvetica,58,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,80,80,50,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

    /// A whole script for cues that are known up front (external files).
    static func script(cues: [SubtitleCue]) -> String {
        var lines = [header.trimmingCharacters(in: .newlines)]
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            lines.append("Dialogue: 0,\(time(cue.start)),\(time(max(cue.end, cue.start + 0.01))),Default,,0,0,0,,\(assText(fromCue: cue.text))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One Matroska-style event block (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`) for a cue text.
    static func eventData(text: String, readOrder: Int) -> Data {
        Data("\(readOrder),0,Default,,0,0,0,,\(assText(fromCue: text))".utf8)
    }

    /// WebVTT-style cue text (`<i>`, `<b>`, `<u>`, escaped entities, newlines) as ASS text.
    static func assText(fromCue text: String) -> String {
        // Entities first, then the characters that mean something in ASS (a brace starts an override block), then the tags.
        var result = text.replacingOccurrences(of: "&lt;", with: "\u{1}").replacingOccurrences(of: "&gt;", with: "\u{2}")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
        result = result.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        for (from, to) in [("<i>", "{\\i1}"), ("</i>", "{\\i0}"), ("<b>", "{\\b1}"), ("</b>", "{\\b0}"), ("<u>", "{\\u1}"), ("</u>", "{\\u0}")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        result = result.replacingOccurrences(of: "\u{1}", with: "<").replacingOccurrences(of: "\u{2}", with: ">")
        return result.replacingOccurrences(of: "\r\n", with: "\\N").replacingOccurrences(of: "\n", with: "\\N")
    }

    /// `H:MM:SS.cc`
    static func time(_ seconds: Double) -> String {
        let centiseconds = Int((max(seconds, 0) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", centiseconds / 360_000, centiseconds / 6000 % 60, centiseconds / 100 % 60, centiseconds % 100)
    }
}

/// Blocks of a text track turned into ASS events as they are read.
final class CueScriptEventSource: OverlayEventSource {
    private let base: any OverlayEventSource
    private let codec: String

    init(base: any OverlayEventSource, codec: String) { self.base = base; self.codec = codec }

    func events(from: Double, to: Double) throws -> [OverlayEvent] {
        Self.convert(try base.events(from: from, to: to), codec: codec)
    }

    /// Blocks of a `codec` text track as ASS events (also for the blocks the remuxer hands over, ``OverlayFeedView``).
    static func convert(_ events: [OverlayEvent], codec: String) -> [OverlayEvent] {
        events.compactMap { event in
            guard let cue = SubtitleText.cue(codec: codec, data: event.data, start: event.start, duration: event.duration) else { return nil }
            // Blocks are told apart by their content (start, duration, bytes): the ReadOrder is only a tie-break for libass.
            return OverlayEvent(data: CueScript.eventData(text: cue.text, readOrder: Int(event.start * 100)), start: event.start, duration: event.duration)
        }
    }
}
