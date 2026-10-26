import Foundation

/// A subtitle file that sits next to the video (or anywhere else) and is shown with it.
///
/// ```swift
/// let track = try await SubtitleTrack(url: subtitleURL)      // SRT, WebVTT, ASS/SSA; the encoding is detected
/// session.add(track)                                           // before makePlayerItem()
/// ```
///
/// The file is read when the track is created. Its text encoding is detected (UTF-8 and UTF-16, the Windows, ISO 8859
/// and KOI8 code pages, GBK/GB 18030, Big5, Shift JIS, EUC-JP and EUC-KR) unless you name one, and the language and
/// the "forced" or "SDH" flags are taken from the file name (`Movie.en.forced.srt`) unless you give them.
public struct SubtitleTrack: Sendable, Equatable {
    /// The name to show. Made unique among the player's subtitle choices.
    public var title: String
    public var language: Locale.Language?
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// Seconds added to every cue (negative: earlier), to line up a file made for another cut of the film.
    public var delay: TimeInterval
    /// The encoding the text was read with.
    public let encoding: TextEncoding
    /// The kind of file this was: "SubRip", "WebVTT" or "ASS".
    public let format: String
    /// How many cues the file holds.
    public var cueCount: Int { cues.count }

    let cues: [SubtitleCue]
    /// The whole script of an ASS/SSA file (UTF-8), for the overlay renderer (``PlaybackSession/makeSubtitleRenderer(for:)``).
    let assScript: Data?

    /// Largest file accepted (real subtitle files are well under a megabyte).
    static let sizeLimit = 16 * 1024 * 1024

    /// Reads and parses a subtitle file.
    /// - Parameters:
    ///   - url: The subtitle file (SubRip, WebVTT, ASS or SSA; picture subtitle files are not read here).
    ///   - language: Overrides the language taken from the file name.
    ///   - title: Overrides the name made from the language.
    ///   - encoding: The text encoding, when detection gets it wrong.
    ///   - delay: Seconds to shift every cue by (positive: later).
    ///   - forced: Marks the track as forced (or not); `nil` reads it from the file name.
    ///   - hearingImpaired: Marks the track as for the deaf and hard of hearing (or not); `nil` reads it from the file name.
    public init(url: URL, language: Locale.Language? = nil, title: String? = nil, encoding: TextEncoding? = nil,
                delay: TimeInterval = 0, forced: Bool? = nil, hearingImpaired: Bool? = nil) async throws {
        let data = try await Self.read(url)
        try self.init(data: data, name: url.lastPathComponent, language: language, title: title, encoding: encoding,
                      delay: delay, forced: forced, hearingImpaired: hearingImpaired)
    }

    /// Parses subtitle data you already have. `name` is the file name, which gives the extension, language and flags.
    public init(data: Data, name: String, language: Locale.Language? = nil, title: String? = nil, encoding: TextEncoding? = nil,
                delay: TimeInterval = 0, forced: Bool? = nil, hearingImpaired: Bool? = nil) throws {
        guard data.count <= Self.sizeLimit else { throw MediaError.unsupported(detail: "the subtitle file is too large") }
        let used = encoding ?? TextEncodingDetector.detect(data)
        guard let text = used.decode(data) else {
            throw MediaError.unreadable(detail: "the subtitle file is not valid \(used.displayName) text")
        }
        let fileExtension = (name as NSString).pathExtension
        guard let parsed = SubtitleFileParser.parse(text, fileExtension: fileExtension) else {
            throw MediaError.unsupported(detail: "not a subtitle file")
        }
        guard !parsed.cues.isEmpty else { throw MediaError.corrupt(detail: "no subtitles found in the file") }

        let hints = SubtitleFileName(name)
        self.language = language ?? hints.language
        self.isForced = forced ?? hints.isForced
        self.isHearingImpaired = hearingImpaired ?? hints.isHearingImpaired
        self.title = title ?? Self.defaultTitle(language: self.language, forced: self.isForced, hearingImpaired: self.isHearingImpaired, name: name)
        self.delay = delay
        self.encoding = used
        self.format = ["subRip": "SubRip", "webVTT": "WebVTT", "ass": "ASS"][parsed.format.rawValue] ?? parsed.format.rawValue
        self.cues = parsed.cues
        // The overlay renderer draws every text format; the cues of the others become a plain ASS script.
        self.assScript = self.format == "ASS" ? Data(text.utf8) : Data(CueScript.script(cues: parsed.cues).utf8)
    }

    /// The cues with the delay applied; cues that end before the start are dropped, the rest start no earlier than 0.
    var shiftedCues: [SubtitleCue] {
        guard delay != 0 else { return cues }
        return cues.compactMap { cue in
            let end = cue.end + delay
            guard end > 0 else { return nil }
            var shifted = cue
            shifted.start = max(0, cue.start + delay)
            shifted.end = end
            return shifted
        }
    }

    private static func read(_ url: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= sizeLimit else { throw MediaError.unsupported(detail: "the subtitle file is too large") }
                    continuation.resume(returning: try Data(contentsOf: url))
                } catch let error as MediaError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: MediaError.unreadable(detail: "the subtitle file could not be read"))
                }
            }
        }
    }

    private static func defaultTitle(language: Locale.Language?, forced: Bool, hearingImpaired: Bool, name: String) -> String {
        var base = language.flatMap { Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) }
            ?? ((name as NSString).deletingPathExtension as NSString).lastPathComponent
        if base.isEmpty { base = "External subtitles" }
        if forced { base += " (forced)" } else if hearingImpaired { base += " (SDH)" }
        return base
    }
}

/// What a subtitle file's name says: `Movie.Name.en.forced.srt` is English and forced. Flags are read from the end of the
/// name, and the first thing before them is the language: a two-letter code, a common three-letter code, a full English
/// name or a tag like `pt-BR`. Nothing else in the name is taken for a language, so "The.Movie.srt" has none.
struct SubtitleFileName {
    var language: Locale.Language?
    var isForced = false
    var isHearingImpaired = false

    private static let twoLetter: Set<String> = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
    private static let threeLetter: [String: String] = [
        "eng": "en", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "spa": "es", "ita": "it", "por": "pt", "rus": "ru",
        "ukr": "uk", "pol": "pl", "ces": "cs", "cze": "cs", "slk": "sk", "slo": "sk", "hun": "hu", "ron": "ro", "rum": "ro",
        "bul": "bg", "srp": "sr", "hrv": "hr", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh", "nld": "nl", "dut": "nl",
        "swe": "sv", "nor": "no", "dan": "da", "fin": "fi", "tur": "tr", "ell": "el", "gre": "el", "ara": "ar", "heb": "he",
        "hin": "hi", "tha": "th", "vie": "vi", "ind": "id", "fas": "fa", "per": "fa",
    ]
    private static let names: [String: String] = [
        "english": "en", "french": "fr", "german": "de", "spanish": "es", "italian": "it", "portuguese": "pt", "russian": "ru",
        "ukrainian": "uk", "polish": "pl", "czech": "cs", "japanese": "ja", "korean": "ko", "chinese": "zh", "dutch": "nl",
        "swedish": "sv", "norwegian": "no", "danish": "da", "finnish": "fi", "turkish": "tr", "greek": "el", "arabic": "ar",
        "hebrew": "he", "hindi": "hi", "thai": "th", "vietnamese": "vi", "indonesian": "id", "persian": "fa",
    ]
    private static let forcedWords: Set<String> = ["forced", "force", "signs", "foreign"]
    private static let hearingWords: Set<String> = ["sdh", "cc", "hearing-impaired", "hearingimpaired"]

    init(_ fileName: String) {
        var tokens = ((fileName as NSString).deletingPathExtension).split(separator: ".").map { $0.lowercased() }
        guard tokens.count > 1 else { return }               // the first token is the film's name, never a hint
        while tokens.count > 1, let last = tokens.last {
            if Self.forcedWords.contains(last) { isForced = true } else if Self.hearingWords.contains(last) { isHearingImpaired = true } else { break }
            tokens.removeLast()
        }
        guard tokens.count > 1, let candidate = tokens.last else { return }
        if candidate.count == 2, Self.twoLetter.contains(candidate) {
            language = Locale.Language(identifier: candidate)
        } else if let code = Self.threeLetter[candidate] ?? Self.names[candidate] {
            language = Locale.Language(identifier: code)
        } else if candidate.contains("-"), candidate.count <= 10, let parsed = Optional(Locale.Language(identifier: candidate)),
                  let code = parsed.languageCode?.identifier, Self.twoLetter.contains(code) {
            language = parsed
        }
    }
}
