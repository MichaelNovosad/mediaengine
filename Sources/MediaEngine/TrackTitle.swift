import Foundation

/// A track's name with its language, the way VLC shows it: "LostFilm - [Russian]". A dubbing studio or a translator is often the only name a
/// track has, and then a menu does not tell which language it is. A name that already says the language (the fallback name is the
/// language's own) is left alone.
enum TrackTitle {
    static func withLanguage(_ title: String, language: Locale.Language?, in locale: Locale = .current) -> String {
        guard let language, let names = names(of: language, in: locale), let shown = names.first else { return title }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "[\(shown)]" }
        let says = names.contains { title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return says ? title : "\(title) - [\(shown)]"
    }

    /// The name to show first, then the other ways a title may say the same: the language without its region ("Portuguese" for "Portuguese
    /// (Brazil)") and the language's own name for itself ("русский", "Español"). Nil when the language is not known.
    private static func names(of language: Locale.Language, in locale: Locale) -> [String]? {
        let identifier = language.minimalIdentifier
        guard let code = language.languageCode?.identifier, code != "und", !identifier.isEmpty,
              let shown = locale.localizedString(forIdentifier: identifier), !shown.isEmpty,
              shown.caseInsensitiveCompare(identifier) != .orderedSame else { return nil }
        var all = [shown]
        for extra in [locale.localizedString(forLanguageCode: code), Locale(identifier: identifier).localizedString(forIdentifier: identifier),
                      Locale(identifier: code).localizedString(forLanguageCode: code)] {
            if let extra, !extra.isEmpty, !all.contains(extra) { all.append(extra) }
        }
        return all
    }
}
