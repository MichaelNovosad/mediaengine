import Foundation

/// Reads subtitle files (SubRip, WebVTT, ASS/SSA) into the same cues that embedded tracks produce.
enum SubtitleFileParser {
    enum Format: String { case subRip, webVTT, ass }

    struct Result {
        var format: Format
        var cues: [SubtitleCue]
    }

    /// The format, from the content first (a `WEBVTT` line, an ASS section) and the file extension second.
    static func format(of text: String, fileExtension: String) -> Format? {
        let head = text.prefix(4096).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("WEBVTT") { return .webVTT }
        if head.contains("[Script Info]") || head.contains("[Events]") { return .ass }
        if head.contains("-->") { return fileExtension.lowercased() == "vtt" ? .webVTT : .subRip }
        switch fileExtension.lowercased() {
        case "srt": return .subRip
        case "vtt": return .webVTT
        case "ass", "ssa": return .ass
        default: return nil
        }
    }

    static func parse(_ text: String, fileExtension: String) -> Result? {
        guard let format = format(of: text, fileExtension: fileExtension) else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let cues: [SubtitleCue]
        switch format {
        case .subRip: cues = subRip(normalized)
        case .webVTT: cues = webVTT(normalized)
        case .ass: cues = ass(normalized)
        }
        return Result(format: format, cues: cues.sorted { ($0.start, $0.end) < ($1.start, $1.end) })
    }

    // MARK: SubRip

    static func subRip(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var timing: (start: Double, end: Double)?
        var lines: [String] = []

        func finish() {
            defer { timing = nil; lines = [] }
            guard let timing else { return }
            if let cue = SubtitleText.cue(codec: "subrip", data: Data(lines.joined(separator: "\n").utf8), start: timing.start,
                                          duration: timing.end - timing.start) {
                cues.append(cue)
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("-->"), let parsed = timingLine(line) {
                // A cue that follows without a blank line: the last text line was its index.
                if timing != nil, let last = lines.last, last.allSatisfy(\.isNumber) { lines.removeLast() }
                finish()
                timing = parsed
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                finish()
            } else if timing != nil {
                lines.append(String(line))
            }
        }
        finish()
        return cues
    }

    // MARK: WebVTT

    static func webVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            guard let first = lines.first, !first.hasPrefix("WEBVTT"), !first.hasPrefix("NOTE"), !first.hasPrefix("STYLE"),
                  !first.hasPrefix("REGION"), let arrow = lines.firstIndex(where: { $0.contains("-->") }),
                  let timing = timingLine(Substring(lines[arrow])) else { continue }
            // Karaoke-style timestamp tags carry no text; entities become characters (kept apart from tags until the end).
            let payload = lines[(arrow + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: #"<\d+:\d+(:\d+)?\.\d+>"#, with: "", options: .regularExpression)
            let plain = decodeEntities(payload)
            guard var cue = SubtitleText.cue(codec: "subrip", data: Data(plain.utf8), start: timing.start, duration: timing.end - timing.start) else { continue }
            cue.text = cue.text.replacingOccurrences(of: "\u{1}", with: "&lt;").replacingOccurrences(of: "\u{2}", with: "&gt;")
            cue.settings = cueSettings(inTimingLine: lines[arrow])
            cues.append(cue)
        }
        return cues
    }

    /// Keeps the placement settings AVPlayer understands, dropping anything unknown or malformed.
    static func cueSettings(inTimingLine line: String) -> String {
        guard let arrow = line.range(of: "-->") else { return "" }
        let afterArrow = line[arrow.upperBound...].split(separator: " ", omittingEmptySubsequences: true).dropFirst()
        return afterArrow.filter { token in
            token.range(of: #"^(line|position|align):[A-Za-z0-9%.,-]+$"#, options: .regularExpression) != nil
        }.joined(separator: " ")
    }

    /// `&lt;` and `&gt;` become markers so that they are not taken for tags; the caller turns them back into entities.
    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "\u{1}").replacingOccurrences(of: "&gt;", with: "\u{2}")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}").replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: ASS / SSA

    static func ass(_ text: String) -> [SubtitleCue] {
        let header = ASSHeader(text.components(separatedBy: "[Events]").first ?? text)
        var format: [String] = []
        var inEvents = false
        var cues: [SubtitleCue] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.hasPrefix("Format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.hasPrefix("Dialogue:"), !format.isEmpty {
                let fields = line.dropFirst(9).split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
                guard fields.count == format.count else { continue }
                func field(_ name: String) -> String { format.firstIndex(of: name).map { fields[$0] } ?? "" }
                guard let start = timestamp(field("start")), let end = timestamp(field("end")), end > start else { continue }
                let layer = field("layer").isEmpty ? "0" : field("layer")
                // The shape Matroska stores: ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
                let event = ["0", layer, field("style"), field("name"), field("marginl"), field("marginr"), field("marginv"),
                             field("effect"), field("text")].joined(separator: ",")
                if let cue = SubtitleText.cue(codec: "ass", data: Data(event.utf8), start: start, duration: end - start, header: header) {
                    cues.append(cue)
                }
            }
        }
        return cues
    }

    // MARK: Times

    /// `00:01:02,500 --> 00:01:04,000 X1:0 ...`
    static func timingLine(_ line: Substring) -> (start: Double, end: Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let start = timestamp(parts[0].trimmingCharacters(in: .whitespaces)),
              let endText = parts[1].split(separator: " ", omittingEmptySubsequences: true).first,
              let end = timestamp(String(endText)), end > start else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm` or ASS `H:MM:SS.cc`.
    static func timestamp(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let seconds = Double(parts[parts.count - 1]), seconds >= 0, seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes >= 0 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, hours >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
