import AVFoundation
import Foundation
import Testing
@testable import MediaEngine

@Suite("Track choices")
struct TrackChoiceTests {
    private func choices(_ name: String) async throws -> (audio: [TrackChoice], subtitles: [TrackChoice]) {
        ServedTracks(info: try await Fixture.probe(name)).choices()
    }

    @Test("names are unique among the tracks of a kind, falling back to the language and then a number")
    func uniqueNames() {
        func track(_ id: Int, _ title: String?, _ language: String?) -> Track {
            var track = makeTrack(id: id, kind: .audio, codec: "aac")
            track.title = title
            track.language = language.map { Locale.Language(identifier: $0) }
            return track
        }
        let titles = ServedTracks.titles(for: [track(1, "Main", "en"), track(2, "Main", "en"), track(3, "Main", "en"), track(4, nil, "ja"),
                                               track(5, nil, "ja"), track(6, "  ", nil), track(7, "Commentary", "en")], fallback: "Audio")
        #expect(titles[1] == "Main - [English]" && titles[2] == "Main (2) - [English]" && titles[3] == "Main (3) - [English]")
        #expect(titles[4] == Locale.current.localizedString(forIdentifier: "ja") && titles[5] == "\(titles[4]!) (2)")
        #expect(titles[6] == "Audio 6" && titles[7] == "Commentary - [English]")
        #expect(Set(titles.values).count == titles.count)
    }

    @Test("the multi-track fixture lists what the player can play, with flags and unique names")
    func fixture() async throws {
        let (audio, subtitles) = try await choices("fixture-multi")
        #expect(audio.map(\.id) == [1, 2, 3, 4] && audio.map(\.title) == ["Main - [English]", "Director commentary - [English]", "Japanese", "Main (2) - [English]"])
        #expect(audio.map { $0.language?.languageCode?.identifier } == ["en", "en", "ja", "en"])
        #expect(audio.map(\.isDefault) == [true, false, false, false] && audio.map(\.isCommentary) == [false, true, false, false])
        #expect(audio.allSatisfy { $0.kind == .audio && $0.codec == "AAC" })
        #expect(subtitles.map(\.id) == [5, 6, 7] && subtitles.map(\.title) == ["English", "English SDH", "Signs - [Japanese]"])
        #expect(subtitles.map(\.isHearingImpaired) == [false, true, false] && subtitles.map(\.isForced) == [false, false, true])
        #expect(subtitles.allSatisfy { $0.kind == .subtitle && $0.codec == "SubRip" })
    }

    @Test("tracks the engine cannot play are not offered")
    func unplayable() async throws {
        let (audio, _) = try await choices("fixture-licensed-audio")      // DTS and TrueHD, both behind the licensed module
        #expect(audio.isEmpty)
        let (flac, _) = try await choices("fixture-basic")
        #expect(flac.map(\.title) == ["English AAC", "Japanese FLAC"], "FLAC is played, transcoded")
    }

    @Test("the playlists use exactly the names the choices carry")
    func playlistNames() async throws {
        let info = try await Fixture.probe("fixture-multi")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-multi")), info: info, cancellation: CancellationFlag())
        let master = String(decoding: try #require(try session.resource(path: "master.m3u8")).data, as: UTF8.self)
        let (audio, subtitles) = try await choices("fixture-multi")
        for choice in audio + subtitles {
            let type = choice.kind == .audio ? "AUDIO" : "SUBTITLES"
            #expect(master.contains("TYPE=\(type),") && master.contains("NAME=\"\(choice.title)\""), "\(choice.title) in the master playlist")
        }
        let names = master.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
            .compactMap { $0.components(separatedBy: "NAME=\"").dropFirst().first?.components(separatedBy: "\"").first }
        #expect(Set(names).count == names.count && names.count == 4, "\(names)")
    }

    @Test("choices and preferences survive a JSON round trip")
    func codable() async throws {
        let (audio, _) = try await choices("fixture-multi")
        let data = try JSONEncoder().encode(audio)
        #expect(try JSONDecoder().decode([TrackChoice].self, from: data) == audio)
        let preferences = TrackPreferences(audioLanguages: ["ja"], subtitleLanguages: ["en"], subtitles: .forcedOnly, prefersHearingImpaired: true)
        #expect(try JSONDecoder().decode(TrackPreferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }
}

@Suite("Track preferences")
struct TrackPreferenceTests {
    private func pick(_ preferences: TrackPreferences) async throws -> (audio: Int?, subtitle: Int?) {
        let (audio, subtitles) = ServedTracks(info: try await Fixture.probe("fixture-multi")).choices()
        let picked = preferences.pick(audio: audio, subtitles: subtitles)
        return (picked.audio?.id, picked.subtitle?.id)
    }

    @Test("Japanese audio with English subtitles")
    func japaneseWithEnglish() async throws {
        let result = try await pick(TrackPreferences(audioLanguages: ["ja", "en"], subtitleLanguages: ["en"]))
        #expect(result.audio == 3 && result.subtitle == 5, "plain English dialogue, not the SDH track")
    }

    @Test("a viewer who prefers subtitles for the hard of hearing gets them")
    func hearingImpaired() async throws {
        let result = try await pick(TrackPreferences(audioLanguages: ["en"], subtitleLanguages: ["en"], prefersHearingImpaired: true))
        #expect(result.audio == 1 && result.subtitle == 6)
    }

    @Test("the programme track wins over commentary, the default flag decides without a language, other languages fall back")
    func audioChoice() async throws {
        #expect(try await pick(TrackPreferences(audioLanguages: ["en-GB"])).audio == 1, "region ignored, commentary skipped")
        #expect(try await pick(TrackPreferences()).audio == 1, "the default track")
        #expect(try await pick(TrackPreferences(audioLanguages: ["fr", "de"])).audio == 1, "nothing matches: the default")
        #expect(try await pick(TrackPreferences(audioLanguages: ["xx-invalid-!"])).audio == 1)
    }

    @Test("signs and songs only: forced tracks in the audio's or a preferred language")
    func forcedOnly() async throws {
        #expect(try await pick(TrackPreferences(audioLanguages: ["ja"], subtitles: .forcedOnly)).subtitle == 7)
        #expect(try await pick(TrackPreferences(audioLanguages: ["en"], subtitles: .forcedOnly)).subtitle == nil, "the forced track is Japanese")
        #expect(try await pick(TrackPreferences(audioLanguages: ["en"], subtitleLanguages: ["ja"], subtitles: .forcedOnly)).subtitle == 7)
    }

    @Test("no subtitles, and a language the file lacks")
    func off() async throws {
        #expect(try await pick(TrackPreferences(audioLanguages: ["ja"], subtitleLanguages: ["en"], subtitles: .off)).subtitle == nil)
        #expect(try await pick(TrackPreferences(subtitleLanguages: ["fr"])).subtitle == nil)
        #expect(try await pick(TrackPreferences()).subtitle == 5, "no preference: the file's default subtitle")
    }

    @Test("nothing to choose from gives nothing")
    func empty() {
        let picked = TrackPreferences(audioLanguages: ["ja"]).pick(audio: [], subtitles: [])
        #expect(picked.audio == nil && picked.subtitle == nil)
    }
}

#if os(macOS)
@MainActor
@Suite("Track selection in AVPlayer", .serialized)
struct TrackSelectionTests {
    private func open() async throws -> (PlaybackSession, AVPlayerItem, AVPlayer) {
        let session = try await PlaybackSession(url: Fixture.url("fixture-multi"))
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")
        return (session, item, player)
    }

    @Test("tracks of one language can be told apart and selected, which the system menu cannot do")
    func sameLanguage() async throws {
        let (session, item, player) = try await open()
        defer { session.close() }
        player.play()
        for choice in session.audioChoices {
            try await session.select(choice, on: item)
            let selected = await session.selectedChoice(of: .audio, on: item)
            #expect(selected == choice, "asked for \(choice.title), got \(String(describing: selected?.title))")
        }
        // The two tracks called "Main" are different tracks: the second is "Main (2)".
        try await session.select(session.audioChoices[3], on: item)
        #expect(await session.selectedChoice(of: .audio, on: item)?.id == 4)
        let before = item.currentTime().seconds
        #expect(await waitUntil(8) { item.currentTime().seconds > before + 0.5 }, "playback goes on after switching")
        #expect(item.error == nil)
        player.pause()
    }

    @Test("subtitles can be selected, switched and turned off")
    func subtitles() async throws {
        let (session, item, player) = try await open()
        defer { session.close() }
        _ = player
        for choice in session.subtitleChoices {
            try await session.select(choice, on: item)
            #expect(await session.selectedChoice(of: .subtitle, on: item) == choice, "\(choice.title)")
        }
        try await session.deselectSubtitles(on: item)
        #expect(await session.selectedChoice(of: .subtitle, on: item) == nil)
    }

    @Test("preferences select audio and subtitles together")
    func preferences() async throws {
        let (session, item, player) = try await open()
        defer { session.close() }
        _ = player
        try await session.apply(TrackPreferences(audioLanguages: ["ja"], subtitleLanguages: ["en"]), to: item)
        #expect(await session.selectedChoice(of: .audio, on: item)?.title == "Japanese")
        #expect(await session.selectedChoice(of: .subtitle, on: item)?.title == "English")
        try await session.apply(TrackPreferences(audioLanguages: ["en"], subtitles: .off), to: item)
        #expect(await session.selectedChoice(of: .audio, on: item)?.title == "Main - [English]")
        #expect(await session.selectedChoice(of: .subtitle, on: item) == nil)
    }

    @Test("a choice that belongs to another file is refused")
    func foreign() async throws {
        let (session, item, player) = try await open()
        defer { session.close() }
        _ = player
        let stranger = TrackChoice(id: 99, kind: .audio, title: "Not here", language: nil, codec: "AAC", isDefault: false,
                                   isForced: false, isHearingImpaired: false, isCommentary: false)
        await #expect(throws: MediaError.self) { try await session.select(stranger, on: item) }
    }
}
#endif
