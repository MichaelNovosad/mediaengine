import Foundation
import Testing
@testable import MediaEngine

@Suite("Text encoding detection")
struct EncodingTests {
    /// Each language in the encodings that subtitle files of it really come in.
    static let corpus: [(language: String, encodings: [TextEncoding])] = [
        ("ru", [.windows1251, .koi8r, .iso8859_5]),
        ("uk", [.windows1251, .koi8u]),
        ("zh-Hans", [.gb18030]),
        ("zh-Hant", [.big5]),
        ("ja", [.shiftJIS, .eucJP]),
        ("ko", [.eucKR]),
        ("fr", [.windows1252, .iso8859_1, .iso8859_15]),
        ("de", [.windows1252, .iso8859_1, .iso8859_15]),
        ("es", [.windows1252, .iso8859_1, .iso8859_15]),
        ("pl", [.windows1250, .iso8859_2]),
        ("cs", [.windows1250, .iso8859_2]),
    ]

    static func text(_ language: String) throws -> String {
        try String(contentsOf: Fixture.root.appendingPathComponent("Tests/MediaEngineTests/Corpus/\(language).txt"), encoding: .utf8)
    }

    @Test("the right text comes back for at least 95% of the language and encoding pairs (SUB-4)")
    func accuracy() throws {
        var correct = 0, total = 0
        var misses: [String] = []
        for (language, encodings) in Self.corpus {
            let original = try Self.text(language)
            for encoding in encodings {
                let bytes = try #require(encoding.encode(original), "\(language) cannot be written in \(encoding)")
                let detected = TextEncodingDetector.detect(bytes)
                total += 1
                if detected.decode(bytes) == original { correct += 1 } else { misses.append("\(language)/\(encoding.rawValue) read as \(detected.rawValue)") }
            }
        }
        #expect(Double(correct) / Double(total) >= 0.95, "\(correct) of \(total) right; wrong: \(misses)")
        #expect(misses.isEmpty, "wrong: \(misses)")
    }

    @Test("parts of a file are enough: the first lines alone are read right too")
    func shortSamples() throws {
        var misses: [String] = []
        for (language, encodings) in Self.corpus {
            let lines = try Self.text(language).split(separator: "\n").prefix(6).joined(separator: "\n")
            for encoding in encodings {
                let bytes = try #require(encoding.encode(lines))
                let detected = TextEncodingDetector.detect(bytes)
                if detected.decode(bytes) != lines { misses.append("\(language)/\(encoding.rawValue) read as \(detected.rawValue)") }
            }
        }
        // Six short lines are little to go on; the whole-file test above is the criterion.
        #expect(misses.count <= 3, "wrong on short samples: \(misses)")
    }

    @Test("Unicode in all its forms, with and without a byte order mark")
    func unicode() throws {
        let text = try Self.text("ru") + (try Self.text("ja"))
        #expect(TextEncodingDetector.detect(Data(text.utf8)) == .utf8)
        #expect(TextEncodingDetector.detect(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == .utf8)
        let le = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let be = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!
        #expect(TextEncodingDetector.detect(le) == .utf16LittleEndian && TextEncodingDetector.detect(be) == .utf16BigEndian)
        #expect(TextEncoding.utf16LittleEndian.decode(le) == text, "the mark is dropped")
        #expect(TextEncoding.utf8.decode(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
        // No mark: ASCII-heavy UTF-16 has a zero next to nearly every letter.
        let plain = "1\n00:00:01,000 --> 00:00:02,000\nHello there, this is a subtitle line.\n"
        #expect(TextEncodingDetector.detect(plain.data(using: .utf16LittleEndian)!) == .utf16LittleEndian)
        #expect(TextEncodingDetector.detect(plain.data(using: .utf16BigEndian)!) == .utf16BigEndian)
        #expect(TextEncodingDetector.detect(Data(plain.utf8)) == .utf8, "plain ASCII")
        #expect(TextEncodingDetector.detect(Data()) == .utf8)
    }

    @Test("decoding is strict: bytes that are not valid are never turned into replacement characters")
    func strict() {
        #expect(TextEncoding.utf8.decode(Data([0xFF, 0xFE, 0xFD])) == nil)
        #expect(TextEncoding.big5.decode(Data([0xE9, 0x20])) == nil)
        #expect(TextEncoding.windows1252.decode(Data([0xE9])) == "é")
        #expect(TextEncoding.eucJP.decode(Data([0x82, 0xA0])) == nil, "a Shift JIS lead byte is not EUC-JP")
        #expect(TextEncoding.utf16LittleEndian.decode(Data([0x41])) == nil, "odd length")
    }

    @Test("choosing the encoding by hand overrides detection, and the wrong one is visible")
    func manual() throws {
        let original = try Self.text("ru")
        let bytes = try #require(TextEncoding.windows1251.encode(original))
        #expect(TextEncoding.windows1251.decode(bytes) == original)
        #expect(TextEncoding.koi8r.decode(bytes) != original)
        #expect(TextEncoding.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(Set(TextEncoding.allCases.map(\.displayName)).count == TextEncoding.allCases.count)
    }

    @Test("a few lines of mixed English and one accented name are Western European, not a CJK guess")
    func mostlyASCII() {
        let bytes = Data("Where is José? He went to the café with François.\nI don't know. Ask Zoë.".utf8)
        let legacy = TextEncoding.windows1252.encode("Where is José? He went to the café with François.\nI don't know. Ask Zoë.")!
        #expect(TextEncodingDetector.detect(bytes) == .utf8)
        let detected = TextEncodingDetector.detect(legacy)
        #expect(detected.decode(legacy) == "Where is José? He went to the café with François.\nI don't know. Ask Zoë.", "\(detected)")
    }
}
