import Foundation

/// One line of subtitle text with its time on the file's own timeline. `text` is ready for a WebVTT cue: it holds only
/// escaped text and the tags `<i>`, `<b>` and `<u>`.
struct SubtitleCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Turns the packets of text subtitle tracks into cues. Styling beyond italic, bold and underline is dropped (WebVTT
/// cannot express it; full ASS rendering is the job of the overlay path).
enum SubtitleText {
    static let supportedCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt"]

    static func canConvert(codec: String) -> Bool { supportedCodecs.contains(codec) }

    /// The cue for one demuxed packet, or `nil` when nothing visible is left (empty text, vector drawings only).
    static func cue(codec: String, data: Data, start: Double, duration: Double) -> SubtitleCue? {
        guard duration > 0, let raw = String(data: data, encoding: .utf8) else { return nil }
        let text: String
        switch codec {
        case "ass", "ssa": text = fromASSEvent(raw)
        case "webvtt": text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        default: text = fromMarkup(raw)
        }
        guard hasVisibleText(text) else { return nil }
        return SubtitleCue(start: start, end: start + duration, text: text)
    }

    /// Whether anything but tags and white space is left, so a cue of `<i></i>` is not shown as an empty box.
    private static func hasVisibleText(_ text: String) -> Bool {
        var inTag = false
        for character in text {
            if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag && !character.isWhitespace { return true }
        }
        return false
    }

    // MARK: SubRip

    /// SubRip text: `<i>`, `<b>`, `<u>` stay, every other tag and `{...}` block goes; the rest is escaped.
    static func fromMarkup(_ raw: String) -> String {
        var output = ""
        var characters = Array(normalizedNewlines(raw))[...]
        while let character = characters.popFirst() {
            switch character {
            case "<":
                // A tag starts with a letter or a slash right after "<"; anything else ("a < b") is just text.
                if let first = characters.first, first.isLetter || first == "/", let close = characters.firstIndex(of: ">"),
                   !characters[characters.startIndex..<close].contains("<") {
                    let tag = String(characters[characters.startIndex..<close]).lowercased().trimmingCharacters(in: .whitespaces)
                    characters = characters[(close + 1)...]
                    switch tag {
                    case "i", "b", "u": output += "<\(tag)>"
                    case "/i", "/b", "/u": output += "<\(tag)>"
                    default: break
                    }
                } else {
                    output += "&lt;"
                }
            case "{":
                if let close = characters.firstIndex(of: "}") { characters = characters[(close + 1)...] } else { output += "{" }
            default:
                output += escaped(character)
            }
        }
        return tidy(output)
    }

    // MARK: ASS / SSA

    /// An event as Matroska stores it: `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`.
    static func fromASSEvent(_ event: String) -> String {
        var commas = 0
        var index = event.startIndex
        while index < event.endIndex, commas < 8 {
            if event[index] == "," { commas += 1 }
            index = event.index(after: index)
        }
        guard commas == 8 else { return "" }
        return fromASSText(String(event[index...]))
    }

    /// ASS dialogue text: italic, bold and underline switches become tags, drawings and all other overrides are
    /// dropped, `\N` is a line break and `\h` a no-break space.
    static func fromASSText(_ text: String) -> String {
        var output = ""
        var open: [Character: Bool] = ["i": false, "b": false, "u": false]
        var drawing = false
        let characters = Array(normalizedNewlines(text))
        var index = 0

        func setTag(_ tag: Character, on: Bool) {
            guard open[tag] != on else { return }
            open[tag] = on
            output += on ? "<\(tag)>" : "</\(tag)>"
        }

        while index < characters.count {
            let character = characters[index]
            if character == "{", let close = characters[index...].firstIndex(of: "}") {
                let block = String(characters[(index + 1)..<close])
                for part in block.split(separator: "\\", omittingEmptySubsequences: true) {
                    guard let first = part.first else { continue }
                    let argument = part.dropFirst()
                    switch first {
                    case "i", "b", "u":
                        if argument.isEmpty || argument.allSatisfy(\.isNumber) { setTag(first, on: argument != "0") }
                    case "p":
                        if let level = Int(argument) { drawing = level > 0 }
                    default: break
                    }
                }
                index = close + 1
                continue
            }
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "N" || next == "n" { if !drawing { output += "\n" }; index += 2; continue }
                if next == "h" { if !drawing { output += "\u{00A0}" }; index += 2; continue }
            }
            if !drawing { output += escaped(character) }
            index += 1
        }
        for tag in ["i", "b", "u"] as [Character] { setTag(tag, on: false) }
        return tidy(output)
    }

    // MARK: Helpers

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func escaped(_ character: Character) -> String {
        switch character {
        case "&": "&amp;"
        case "<": "&lt;"
        case ">": "&gt;"
        default: String(character)
        }
    }

    /// Trims and removes blank lines, which would end a WebVTT cue.
    private static func tidy(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// WebVTT text for HLS.
enum WebVTT {
    /// One segment: the cues that overlap `[start, end)`. A cue that spans a boundary appears in both segments, as HLS
    /// requires. Times are shifted onto the media timeline of the remuxed audio and video.
    static func segment(cues: [SubtitleCue], start: Double, end: Double, shift: Double) -> String {
        var lines = ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000", ""]
        for cue in cues where cue.end > start && cue.start < end {
            lines.append("\(timestamp(cue.start + shift)) --> \(timestamp(cue.end + shift))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let milliseconds = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }
}
