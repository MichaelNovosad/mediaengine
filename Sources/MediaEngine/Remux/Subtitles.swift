import Foundation

/// One line of subtitle text with its time on the file's own timeline. `text` is ready for a WebVTT cue: it holds only
/// escaped text and the tags `<i>`, `<b>` and `<u>`.
struct SubtitleCue: Equatable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// WebVTT cue settings (position and alignment), empty for the default bottom-centre placement.
    var settings = ""
}

/// What a track's ASS header says that cues need: the script resolution (for `\pos`) and each style's alignment.
struct ASSHeader: Equatable, Sendable {
    var playResX = 384.0
    var playResY = 288.0
    var alignments: [String: Int] = [:]

    /// Reads `[Script Info]` and `[V4+ Styles]` / `[V4 Styles]` from the track's header text.
    init(_ header: String) {
        var format: [String] = []
        for rawLine in header.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("PlayResX:"), let value = Double(line.dropFirst(9).trimmingCharacters(in: .whitespaces)), value > 0 { playResX = value }
            else if line.hasPrefix("PlayResY:"), let value = Double(line.dropFirst(9).trimmingCharacters(in: .whitespaces)), value > 0 { playResY = value }
            else if line.hasPrefix("Format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.hasPrefix("Style:"), let nameIndex = format.firstIndex(of: "name"), let alignIndex = format.firstIndex(of: "alignment") {
                let fields = line.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if fields.indices.contains(nameIndex), fields.indices.contains(alignIndex), let value = Int(fields[alignIndex]) {
                    alignments[fields[nameIndex]] = value
                }
            }
        }
    }
    init() {}
}

/// Turns the packets of text subtitle tracks into cues. Styling beyond italic, bold and underline is dropped (WebVTT
/// cannot express it; full ASS rendering is the job of the overlay path).
enum SubtitleText {
    static let supportedCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt"]

    static func canConvert(codec: String) -> Bool { supportedCodecs.contains(codec) }

    /// The cue for one demuxed packet, or `nil` when nothing visible is left (empty text, vector drawings only).
    /// - Parameter header: The track's ASS header, for the placement of ASS events.
    static func cue(codec: String, data: Data, start: Double, duration: Double, header: ASSHeader? = nil) -> SubtitleCue? {
        guard duration > 0, let raw = String(data: data, encoding: .utf8) else { return nil }
        let text: String
        var settings = ""
        switch codec {
        case "ass", "ssa":
            let event = splitASSEvent(raw)
            text = event.map { fromASSText($0.text) } ?? ""
            if let event { settings = cueSettings(forASSEvent: event, header: header ?? ASSHeader()) }
        case "webvtt": text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        default: text = fromMarkup(raw)
        }
        guard hasVisibleText(text) else { return nil }
        return SubtitleCue(start: start, end: start + duration, text: text, settings: settings)
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
        splitASSEvent(event).map { fromASSText($0.text) } ?? ""
    }

    /// The style name and the text of an event, or `nil` when it does not have the nine fields.
    static func splitASSEvent(_ event: String) -> (style: String, text: String)? {
        var fields: [Substring] = []
        var rest = event[...]
        while fields.count < 8, let comma = rest.firstIndex(of: ",") {
            fields.append(rest[..<comma])
            rest = rest[rest.index(after: comma)...]
        }
        guard fields.count == 8 else { return nil }
        return (fields[2].trimmingCharacters(in: .whitespaces), String(rest))
    }

    // MARK: Placement

    /// WebVTT settings for an event's `\anN` alignment (or its style's) and `\pos(x,y)`; empty for the usual bottom centre.
    static func cueSettings(forASSEvent event: (style: String, text: String), header: ASSHeader) -> String {
        var alignment = header.alignments[event.style] ?? 2
        var position: (x: Double, y: Double)?
        var characters = event.text[...]
        // Only the first override block counts, like the player does for placement.
        if characters.first == "{", let close = characters.firstIndex(of: "}") {
            let block = characters[characters.index(after: characters.startIndex)..<close]
            for part in block.split(separator: "\\", omittingEmptySubsequences: true) {
                if part.hasPrefix("an"), let value = Int(part.dropFirst(2)), (1...9).contains(value) { alignment = value }
                else if part.hasPrefix("pos("), let end = part.firstIndex(of: ")") {
                    let numbers = part[part.index(part.startIndex, offsetBy: 4)..<end].split(separator: ",").compactMap {
                        Double($0.trimmingCharacters(in: .whitespaces))
                    }
                    if numbers.count == 2 { position = (numbers[0], numbers[1]) }
                }
            }
            characters = characters[characters.index(after: close)...]
        }
        guard (1...9).contains(alignment) else { return "" }
        let column = (alignment - 1) % 3, row = (alignment - 1) / 3            // column: 0 left, 1 centre, 2 right; row: 0 bottom, 1 middle, 2 top
        func percent(_ value: Double) -> Int { Int(min(max(value, 0), 100).rounded()) }
        let align = ["left", "center", "right"][column]
        var settings: [String] = []
        if let position {
            settings.append("line:\(percent(position.y / header.playResY * 100))%,\(["end", "center", "start"][row])")
            settings.append("position:\(percent(position.x / header.playResX * 100))%,\(["line-left", "center", "line-right"][column])")
            settings.append("align:\(align)")
        } else {
            if row == 2 { settings.append("line:6%,start") } else if row == 1 { settings.append("line:50%,center") }
            if column != 1 { settings.append("position:\(column == 0 ? 5 : 95)%,\(column == 0 ? "line-left" : "line-right")") }
            if column != 1 { settings.append("align:\(align)") }
        }
        return settings.joined(separator: " ")
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
            lines.append("\(timestamp(cue.start + shift)) --> \(timestamp(cue.end + shift))" + (cue.settings.isEmpty ? "" : " " + cue.settings))
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
