import Foundation
import Testing
@testable import MediaEngine

@Suite("Track names with their language")
struct TrackTitleTests {
    private let english = Locale(identifier: "en_US")
    private func name(_ title: String, _ language: String?, in locale: Locale? = nil) -> String {
        TrackTitle.withLanguage(title, language: language.map { Locale.Language(identifier: $0) }, in: locale ?? english)
    }

    @Test("a translator's or studio's name gets the language after it, as VLC shows it")
    func studio() {
        #expect(name("LostFilm", "ru") == "LostFilm - [Russian]")
        #expect(name("Commentary", "en") == "Commentary - [English]")
        #expect(name("Dialogue", "en") == "Dialogue - [English]")
        #expect(name("Commentary (2)", "en") == "Commentary (2) - [English]")
    }

    @Test("a title that already says the language is not changed: its name in any case, its own name for itself, its name without the region")
    func alreadySaid() {
        #expect(name("English", "en") == "English")
        #expect(name("Japanese / English dub", "ja") == "Japanese / English dub")
        #expect(name("English dub", "en") == "English dub")
        #expect(name("ENGLISH 5.1", "en") == "ENGLISH 5.1")
        #expect(name("Русский дубляж", "ru") == "Русский дубляж", "the language's own name")
        #expect(name("ESPAÑOL latino", "es") == "ESPAÑOL latino", "case and accents do not matter")
        #expect(name("Portuguese", "pt-PT") == "Portuguese", "the name without the region")
    }

    @Test("a region is shown when the language has one that matters; an unknown language adds nothing")
    func regionAndUnknown() {
        #expect(name("Dublagem", "pt-PT") == "Dublagem - [Portuguese (Portugal)]")
        #expect(name("Subtitles", "zh-Hans") == "Subtitles - [Chinese]", "the default script and region are dropped")
        #expect(name("LostFilm", nil) == "LostFilm")
        #expect(name("LostFilm", "und") == "LostFilm")
    }

    @Test("the language is named in the person's own language; three-letter codes, as Matroska files carry, work; an empty title becomes the language")
    func localizedAndCodes() {
        #expect(name("Kerob", "ru", in: Locale(identifier: "de_DE")) == "Kerob - [Russisch]")
        #expect(name("Deutsch", "de", in: Locale(identifier: "de_DE")) == "Deutsch")
        #expect(name("LostFilm", "rus") == "LostFilm - [Russian]")
        #expect(name("Studio", "eng") == "Studio - [English]")
        #expect(name("", "fr") == "[French]")
    }
}
