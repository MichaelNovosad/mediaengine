import CoreFoundation
import Foundation

/// A character encoding that subtitle files come in.
public enum TextEncoding: String, Sendable, Codable, CaseIterable {
    case utf8, utf16LittleEndian, utf16BigEndian
    case windows1250, windows1251, windows1252, windows1253, windows1254
    case iso8859_1, iso8859_2, iso8859_5, iso8859_7, iso8859_9, iso8859_15
    case koi8r, koi8u
    case gb18030, big5, shiftJIS, eucJP, eucKR

    /// Name for a picker: "Windows-1251 (Cyrillic)".
    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .windows1250: "Windows-1250 (Central European)"
        case .windows1251: "Windows-1251 (Cyrillic)"
        case .windows1252: "Windows-1252 (Western European)"
        case .windows1253: "Windows-1253 (Greek)"
        case .windows1254: "Windows-1254 (Turkish)"
        case .iso8859_1: "ISO 8859-1 (Latin 1)"
        case .iso8859_2: "ISO 8859-2 (Latin 2)"
        case .iso8859_5: "ISO 8859-5 (Cyrillic)"
        case .iso8859_7: "ISO 8859-7 (Greek)"
        case .iso8859_9: "ISO 8859-9 (Turkish)"
        case .iso8859_15: "ISO 8859-15 (Latin 9)"
        case .koi8r: "KOI8-R (Russian)"
        case .koi8u: "KOI8-U (Ukrainian)"
        case .gb18030: "GB 18030 / GBK (Simplified Chinese)"
        case .big5: "Big5 (Traditional Chinese)"
        case .shiftJIS: "Shift JIS (Japanese)"
        case .eucJP: "EUC-JP (Japanese)"
        case .eucKR: "EUC-KR / CP949 (Korean)"
        }
    }

    /// CoreFoundation's number for the legacy encodings.
    fileprivate var coreFoundation: CFStringEncoding? {
        switch self {
        case .utf8, .utf16LittleEndian, .utf16BigEndian: nil
        case .windows1250: 0x0501
        case .windows1251: 0x0502
        case .windows1252: 0x0500
        case .windows1253: 0x0503
        case .windows1254: 0x0504
        case .iso8859_1: 0x0201
        case .iso8859_2: 0x0202
        case .iso8859_5: 0x0205
        case .iso8859_7: 0x0207
        case .iso8859_9: 0x0209
        case .iso8859_15: 0x020F
        case .koi8r: 0x0A02
        case .koi8u: 0x0A08
        case .gb18030: 0x0632
        case .big5: 0x0A03
        case .shiftJIS: 0x0A01
        case .eucJP: 0x0920
        case .eucKR: 0x0940
        }
    }

    /// The bytes of `text` in this encoding, or `nil` when it cannot represent every character (used by tests).
    func encode(_ text: String) -> Data? {
        switch self {
        case .utf8: return text.data(using: .utf8)
        case .utf16LittleEndian: return text.data(using: .utf16LittleEndian)
        case .utf16BigEndian: return text.data(using: .utf16BigEndian)
        default:
            guard let encoding = coreFoundation else { return nil }
            return (text as NSString).data(using: CFStringConvertEncodingToNSStringEncoding(encoding), allowLossyConversion: false)
        }
    }

    /// The text, or `nil` when the bytes are not valid in this encoding (nothing is replaced or guessed). A byte order
    /// mark at the start is dropped.
    public func decode(_ data: Data) -> String? {
        var text: String?
        switch self {
        case .utf8:
            text = String(data: data, encoding: .utf8)
        case .utf16LittleEndian, .utf16BigEndian:
            guard data.count % 2 == 0 else { return nil }
            text = String(data: data, encoding: self == .utf16LittleEndian ? .utf16LittleEndian : .utf16BigEndian)
        default:
            guard let encoding = coreFoundation else { return nil }
            text = data.withUnsafeBytes { bytes in
                CFStringCreateWithBytes(kCFAllocatorDefault, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, encoding, false) as String?
            }
        }
        guard var result = text else { return nil }
        if result.unicodeScalars.first == "\u{FEFF}" { result.unicodeScalars.removeFirst() }
        return result
    }
}

/// Finds out how a text file is encoded. Subtitle files from the internet come in whatever the author's computer used,
/// without saying so; this reads the byte order mark, accepts valid UTF-8, and otherwise decodes the bytes with every
/// legacy candidate and keeps the one whose text looks like writing (one script, sensible letter case and letter
/// frequencies, no box-drawing characters or stray symbols).
enum TextEncodingDetector {
    /// Legacy candidates in order of preference for ties.
    static let legacy: [TextEncoding] = [
        .windows1252, .iso8859_1, .iso8859_15, .windows1250, .iso8859_2, .windows1254, .iso8859_9,
        .windows1251, .koi8r, .koi8u, .iso8859_5, .windows1253, .iso8859_7,
        .gb18030, .big5, .shiftJIS, .eucJP, .eucKR,
    ]

    static func detect(_ data: Data) -> TextEncoding {
        let bytes = [UInt8](data.prefix(1 << 20))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if let unicode = utf16WithoutMark(bytes) { return unicode }
        if bytes.allSatisfy({ $0 < 0x80 }) { return .utf8 }
        if TextEncoding.utf8.decode(Data(bytes)) != nil { return .utf8 }

        var best: (encoding: TextEncoding, score: Double)?
        for encoding in legacy {
            guard let text = encoding.decode(Data(bytes)) else { continue }
            let score = Plausibility.score(text, encoding: encoding)
            if best == nil || score > best!.score + 1e-9 { best = (encoding, score) }
        }
        return best?.encoding ?? .windows1252
    }

    /// UTF-16 text without a mark has a zero byte next to nearly every ASCII character.
    private static func utf16WithoutMark(_ bytes: [UInt8]) -> TextEncoding? {
        guard bytes.count >= 8, bytes.count % 2 == 0 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            if bytes[index] == 0 { evenZeros += 1 }
            if bytes[index + 1] == 0 { oddZeros += 1 }
        }
        let pairs = bytes.count / 2
        if oddZeros * 10 > pairs * 3, evenZeros * 20 < pairs { return TextEncoding.utf16LittleEndian.decode(Data(bytes)) != nil ? .utf16LittleEndian : nil }
        if evenZeros * 10 > pairs * 3, oddZeros * 20 < pairs { return TextEncoding.utf16BigEndian.decode(Data(bytes)) != nil ? .utf16BigEndian : nil }
        return nil
    }
}

/// How much a decoded text looks like real writing, from 0 (garbage) to 1.
private enum Plausibility {
    enum Family { case latin, cyrillic, greek, cjk, other }

    // MARK: Reference data (the most common characters of each script)

    static let commonHan: Set<Character> = Set("的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工话儿者向情部正名定女问力机给等几很业最间新什打便位因重被走电四第门相次东政海口使教西再平真听世气信北少关并内加化由却代军产入先山无它所战爱"
        + "的一是不了人我在有他這中大來上國個到說們為子和你地出道也時年得就那要下以生會自著去之過家學對可她裡後小麼心多天而能好都然沒日於起還發成事只作當想看文無開手十用主行方又如前所本見經頭面公同三已老從動兩長知民樣現分將外但身些與高意進把法此實回二理美點月明其種聲全工話兒者向情部正名定女問力機給等幾很業最間新什打便位因重被走電四第門相次東政海口使教西再平真聽世氣信北少關並內加化由卻代軍產入先山無它所戰愛")
    /// Kanji of everyday Japanese dialogue (new forms such as 気 来 国 学 会 話 駅 included), so that Japanese text read
    /// as GBK, which shares the kana but not the kanji, loses.
    static let commonKanji: Set<Character> = Set("私僕君彼何今日本人間時行来見出思言話聞食生同国会学長立入自分男女子先夜明朝仕事約束電話窓開写真鍵下名心配当知考待戻駅静落着嘘結局失仲全部友達悪責任最初然少必要方法大切守戦争平和世界未来過去現在気持顔声手足目口耳頭体病院医者薬死殺助救命愛恋好嫌怖怒泣笑歩走飛乗車道町村家族父母兄弟姉妹犬猫鳥魚花木山川海空雨雪風火水土金銀石音楽歌色赤青白黒黄緑夢力正義魔神王姫騎士剣銃弾敵味方勝負運動試合練習宿題授業教室生徒一二三十年月時分半前後上中外内多少新古高低大小長短強弱早遅")
    static let commonHangul: Set<Character> = Set("이다는의에를가하지고서은도로한을으나아리어기사있수그해자대게시들정것인스제일면라과여오내전부생신미야공원동안세상소저년너말때며만더보같중니구매간주선성위관력무현울터")

    /// Letters that are rare in writing but that wrong decodings of other encodings produce a lot: Serbian and
    /// Macedonian Cyrillic (ђ ѓ ѕ ј љ њ ћ ќ ў џ) from Windows-1251 text read as ISO 8859-5.
    static let rareCyrillic: Set<Character> = Set("ђѓѕјљњћќўџЂЃЅЈЉЊЋЌЎЏѐѝЀЍ")

    /// Letters that are only common in the western European languages / the Central European ones / Turkish, with a
    /// rough share of all accented letters (not exact: only the contrast matters).
    static let western: [Character: Double] = [
        "é": 0.22, "è": 0.07, "à": 0.07, "ç": 0.03, "ê": 0.03, "â": 0.02, "î": 0.01, "ô": 0.01, "û": 0.005, "ù": 0.008,
        "ë": 0.002, "ï": 0.003, "ü": 0.09, "ö": 0.06, "ä": 0.07, "ß": 0.05, "ñ": 0.04, "á": 0.08, "í": 0.06, "ó": 0.07,
        "ú": 0.02, "ã": 0.02, "õ": 0.01, "å": 0.02, "ø": 0.01, "æ": 0.005, "œ": 0.003, "ì": 0.004, "ò": 0.004, "ÿ": 0.0005,
        "É": 0.02, "À": 0.01, "Ç": 0.004, "Ä": 0.005, "Ö": 0.005, "Ü": 0.005, "Á": 0.005, "Í": 0.003, "Ó": 0.003, "Ú": 0.002,
        "Ñ": 0.003, "Å": 0.002, "Ø": 0.001, "Æ": 0.001,
    ]
    static let central: [Character: Double] = [
        "á": 0.07, "é": 0.05, "í": 0.07, "ó": 0.04, "ú": 0.01, "ý": 0.04, "ě": 0.05, "š": 0.05, "č": 0.06, "ř": 0.04, "ž": 0.05,
        "ů": 0.02, "ď": 0.005, "ť": 0.005, "ň": 0.01, "ą": 0.06, "ć": 0.02, "ę": 0.05, "ł": 0.08, "ń": 0.02, "ś": 0.04,
        "ź": 0.005, "ż": 0.06, "ä": 0.02, "ô": 0.01, "ľ": 0.01, "ĺ": 0.001, "ŕ": 0.001, "ő": 0.01, "ű": 0.005, "ö": 0.015, "ü": 0.015,
        "Š": 0.005, "Č": 0.006, "Ž": 0.004, "Ł": 0.004, "Ś": 0.002, "Ż": 0.002, "Ř": 0.002, "Ć": 0.001, "Ą": 0.001, "Ę": 0.001,
    ]
    static let turkish: [Character: Double] = [
        "ı": 0.15, "ş": 0.07, "ğ": 0.06, "ç": 0.04, "ö": 0.04, "ü": 0.06, "İ": 0.02, "Ş": 0.005, "Ğ": 0.004, "Ç": 0.004, "Ö": 0.003, "Ü": 0.003,
        "â": 0.003, "î": 0.001, "û": 0.001,
    ]

    // MARK: Scoring

    static func score(_ text: String, encoding: TextEncoding) -> Double {
        var nonASCII = 0, letters = 0, asciiLetters = 0, neutral = 0, bad = 0
        var families: [Family: Int] = [:]
        var lower = 0, upper = 0, flips = 0
        var han = 0, hanCommon = 0, kana = 0, hangul = 0, hangulCommon = 0, rare = 0
        var accented: [Character] = []
        var previousWasLowerCyrillic = false

        for character in text {
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { continue }
            let value = scalar.value
            if value < 0x80 {
                if character.isLetter { asciiLetters += 1 }
                previousWasLowerCyrillic = false
                continue
            }
            nonASCII += 1
            if isNeutral(value) { neutral += 1; previousWasLowerCyrillic = false; continue }
            if isBad(value) { bad += 1; previousWasLowerCyrillic = false; continue }
            guard character.isLetter else { bad += 1; previousWasLowerCyrillic = false; continue }
            letters += 1
            let family = familyOf(value)
            families[family, default: 0] += 1
            switch value {
            case 0x400...0x52F, 0x370...0x3FF:
                if rareCyrillic.contains(character) { rare += 1 }
                if character.isLowercase { lower += 1; previousWasLowerCyrillic = true }
                else { upper += 1; if previousWasLowerCyrillic { flips += 1 }; previousWasLowerCyrillic = false }
            case 0x4E00...0x9FFF, 0x3400...0x4DBF:
                han += 1
                if commonHan.contains(character) || commonKanji.contains(character) { hanCommon += 1 }
                previousWasLowerCyrillic = false
            case 0x3040...0x30FF:
                kana += 1; previousWasLowerCyrillic = false
            case 0xAC00...0xD7A3:
                hangul += 1
                if commonHangul.contains(character) { hangulCommon += 1 }
                previousWasLowerCyrillic = false
            case 0xC0...0x24F, 0x1E00...0x1EFF:
                accented.append(character); previousWasLowerCyrillic = false
            default:
                previousWasLowerCyrillic = false
            }
        }
        guard nonASCII > 0, letters > 0 else { return nonASCII == 0 ? 1 : 0 }

        let dominant = families.max { $0.value < $1.value }!
        let coherence = Double(dominant.value) / Double(letters)
        var score = max(0, (Double(letters) + Double(neutral) - 3 * Double(bad)) / Double(nonASCII)) * coherence
        let nonASCIIShare = Double(letters) / Double(letters + asciiLetters)

        switch dominant.key {
        case .cyrillic, .greek:
            // Cyrillic and Greek text is nearly all non-ASCII letters; a few of them among ASCII ones is Latin text read wrongly.
            score *= min(1, max(0, (nonASCIIShare - 0.3) / 0.3))
            let cyrillic = Double(lower + upper)
            let lowerShare = Double(lower) / max(cyrillic, 1)
            score *= min(1, max(0, (lowerShare - 0.55) / 0.30))
            score *= max(0, 1 - 10 * Double(flips) / max(cyrillic, 1))
            score *= max(0, 1 - 6 * Double(rare) / max(cyrillic, 1))
        case .cjk:
            if hangul > han + kana {
                score *= min(1, Double(hangulCommon) / Double(hangul) / 0.30)
            } else if han > 0 {
                score *= min(1, Double(hanCommon) / Double(han) / 0.25)        // Chinese or Japanese: everyday characters
            }
            score *= min(1, max(0, (nonASCIIShare - 0.15) / 0.3))
        case .latin:
            // Accented letters in real Latin-script text are a few percent of all letters; Cyrillic or Greek bytes read
            // as Latin-1 turn nearly every letter into an accented one.
            let share = Double(accented.count) / Double(accented.count + asciiLetters)
            score *= min(1, max(0, 1 - (share - 0.15) / 0.25))
            score *= latinLikelihood(accented, encoding: encoding)
        default:
            break
        }
        return score
    }

    /// 0...1: how well the accented letters fit the languages the encoding is meant for.
    private static func latinLikelihood(_ letters: [Character], encoding: TextEncoding) -> Double {
        guard !letters.isEmpty else { return 1 }
        let table: [Character: Double]
        switch encoding {
        case .windows1250, .iso8859_2: table = central
        case .windows1254, .iso8859_9: table = turkish
        default: table = western
        }
        let mean = letters.reduce(0.0) { $0 + (table[$1] ?? 0.0005) } / Double(letters.count)
        return mean / (mean + 0.02)
    }

    private static func familyOf(_ value: UInt32) -> Family {
        switch value {
        case 0xC0...0x24F, 0x1E00...0x1EFF: .latin
        case 0x400...0x52F: .cyrillic
        case 0x370...0x3FF: .greek
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: .cjk
        default: .other
        }
    }

    /// Punctuation and spacing that real text contains.
    private static func isNeutral(_ value: UInt32) -> Bool {
        switch value {
        case 0xA0, 0xA1, 0xAB, 0xBB, 0xBF, 0xB7: true
        case 0x2010...0x2027, 0x2030...0x205E, 0x20AC: true
        case 0x3000...0x303F, 0xFF01...0xFF5E, 0xFF5F...0xFF60: true
        default: false
        }
    }

    /// Characters that hardly ever appear in subtitles but that wrong decodings produce.
    private static func isBad(_ value: UInt32) -> Bool {
        switch value {
        case 0xFFFD, 0x80...0x9F, 0xE000...0xF8FF: true
        case 0xA2...0xA9, 0xAC, 0xAE...0xB6, 0xB8, 0xB9, 0xBC...0xBE, 0xD7, 0xF7: true
        case 0x2190...0x23FF, 0x2500...0x27BF, 0x2116: true
        case 0xFF61...0xFF9F, 0xFE30...0xFE6F: true
        default: false
        }
    }
}
