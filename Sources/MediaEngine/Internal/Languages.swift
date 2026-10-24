import Foundation

/// Turns the language tags found in media files into `Locale.Language`.
///
/// Matroska and MP4 use ISO 639-2 codes. Foundation understands the terminology form (`deu`, `fra`,
/// `zho`) but not the bibliographic form (`ger`, `fre`, `chi`) that many files still use.
enum LanguageCodes {
    private static let bibliographicToTerminology: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
        "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
        "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]
    /// "Undetermined", "multiple", "no linguistic content", "uncoded".
    private static let notALanguage: Set<String> = ["und", "mul", "zxx", "mis"]

    static func language(from tag: String?) -> Locale.Language? {
        guard let trimmed = tag?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        var code = trimmed
        if code.count == 3 {
            code = code.lowercased()
            if notALanguage.contains(code) { return nil }
            if code >= "qaa" && code <= "qtz" { return nil }          // reserved for private use
            code = bibliographicToTerminology[code] ?? code
        }
        let language = Locale.Language(identifier: code)
        guard let languageCode = language.languageCode, languageCode.identifier != "und" else { return nil }
        return language
    }
}
