import Foundation

/// One audio or subtitle track the player can switch to.
///
/// The system player's menu shows only a language name, so two tracks in the same language look alike there (see
/// `docs/RESEARCH.md` section 17). A host that wants to name them builds its own picker from these choices and selects
/// with ``PlaybackSession/select(_:on:)``.
public struct TrackChoice: Sendable, Equatable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable {
        case audio, subtitle
    }

    /// The track's identifier in ``MediaInfo/tracks``.
    public var id: Int
    public var kind: Kind
    /// The name to show: the track's own title, else its language, made unique among the choices of its kind
    /// ("Commentary", "Commentary (2)").
    public var title: String
    public var language: Locale.Language?
    /// Name of the codec, for example "FLAC" or "ASS".
    public var codec: String
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var isCommentary: Bool
    /// The track comes from a separate file added with ``PlaybackSession/add(_:)-(SubtitleTrack)``, not from the video file.
    public var isExternal = false
    /// A picture track (PGS, VobSub, DVB). The system player cannot show it: draw it with
    /// ``PlaybackSession/makeSubtitleRenderer(for:)``.
    public var isBitmap = false
}

/// What a viewer wants to hear and read, for example per series: "Japanese audio, English subtitles".
public struct TrackPreferences: Sendable, Equatable, Codable {
    public enum Subtitles: String, Sendable, Codable {
        /// No subtitles.
        case off
        /// Only forced tracks (translations of foreign speech, "signs and songs").
        case forcedOnly
        /// A full dialogue track in one of ``TrackPreferences/subtitleLanguages``.
        case full
    }

    /// Languages to prefer for sound, best first, as BCP 47 identifiers ("ja", "en-US"); only the language part counts.
    public var audioLanguages: [String]
    /// Languages to prefer for subtitles, best first.
    public var subtitleLanguages: [String]
    public var subtitles: Subtitles
    /// Prefer a track made for the hard of hearing over a plain dialogue track.
    public var prefersHearingImpaired: Bool

    public init(audioLanguages: [String] = [], subtitleLanguages: [String] = [], subtitles: Subtitles = .full,
                prefersHearingImpaired: Bool = false) {
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.subtitles = subtitles
        self.prefersHearingImpaired = prefersHearingImpaired
    }

    /// The choices these preferences select among the given ones. A `nil` subtitle choice means "no subtitles".
    public func pick(audio: [TrackChoice], subtitles available: [TrackChoice]) -> (audio: TrackChoice?, subtitle: TrackChoice?) {
        let chosenAudio = pickAudio(audio)
        return (chosenAudio, pickSubtitle(available, audio: chosenAudio))
    }

    private func languageCode(_ identifier: String) -> String? { Locale.Language(identifier: identifier).languageCode?.identifier }
    private func matches(_ choice: TrackChoice, _ code: String) -> Bool { choice.language?.languageCode?.identifier == code }

    private func pickAudio(_ choices: [TrackChoice]) -> TrackChoice? {
        let programme = choices.filter { !$0.isCommentary }
        for code in audioLanguages.compactMap(languageCode) {
            if let match = programme.first(where: { matches($0, code) }) { return match }
        }
        return programme.first(where: \.isDefault) ?? programme.first ?? choices.first
    }

    private func pickSubtitle(_ choices: [TrackChoice], audio: TrackChoice?) -> TrackChoice? {
        switch subtitles {
        case .off:
            return nil
        case .forcedOnly:
            let forced = choices.filter(\.isForced)
            let wanted = (audio?.language?.languageCode?.identifier).map { [$0] } ?? []
            for code in wanted + subtitleLanguages.compactMap(languageCode) {
                if let match = forced.first(where: { matches($0, code) }) { return match }
            }
            return nil
        case .full:
            let dialogue = choices.filter { !$0.isForced }
            for code in subtitleLanguages.compactMap(languageCode) {
                let inLanguage = dialogue.filter { matches($0, code) }
                let preferred = inLanguage.first { $0.isHearingImpaired == prefersHearingImpaired } ?? inLanguage.first
                if let preferred { return preferred }
            }
            return subtitleLanguages.isEmpty ? dialogue.first(where: \.isDefault) : nil
        }
    }
}

/// The tracks the engine turns into renditions, in file order. The playlists and the choices both come from this, so
/// they cannot disagree.
struct ServedTracks {
    var video: Track?
    var audio: [Track]
    /// Embedded text tracks first, then the external files (whose ids are `externalSubtitleBase + index`).
    var subtitles: [Track]
    var externalSubtitleIDs: Set<Int> = []
    var externalAudioIDs: Set<Int> = []

    /// Identifiers of external subtitle files, far above any stream index.
    static let externalSubtitleBase = 10_000
    /// Identifiers of external audio files.
    static let externalAudioBase = 20_000

    init(info: MediaInfo, externalSubtitles: [SubtitleTrack] = [], externalAudio: [AudioTrack] = []) {
        let treatments = Dictionary(uniqueKeysWithValues: info.playbackPlan.tracks.map { ($0.trackID, $0.treatment) })
        video = info.videoTracks.first { treatments[$0.id] == .passthrough }
        audio = info.audioTracks.filter { track in
            switch treatments[track.id] {
            case .passthrough: true
            case .transcodeAudio(.alac): AudioTranscoder.canTranscode(track.codec.name)
            default: false
            }
        }
        subtitles = info.subtitleTracks.filter { treatments[$0.id] == .convertToWebVTT && SubtitleText.canConvert(codec: $0.codec.name) }
        for (index, file) in externalAudio.enumerated() {
            var pseudo = file.track
            pseudo.id = Self.externalAudioBase + index
            pseudo.title = file.title
            pseudo.language = file.language
            pseudo.isDefault = false
            pseudo.isForced = false
            pseudo.isCommentary = false
            externalAudioIDs.insert(pseudo.id)
            audio.append(pseudo)
        }
        for (index, file) in externalSubtitles.enumerated() {
            let id = Self.externalSubtitleBase + index
            externalSubtitleIDs.insert(id)
            subtitles.append(Track(id: id, kind: .subtitle, codec: Codec(name: "external", displayName: file.format), language: file.language,
                                   title: file.title, isDefault: false, isForced: file.isForced, isHearingImpaired: file.isHearingImpaired,
                                   isCommentary: false, bitrate: nil))
        }
    }

    /// Names that are unique among the given tracks (an HLS requirement and what selection relies on).
    static func titles(for tracks: [Track], fallback: String) -> [Int: String] {
        var seen: [String: Int] = [:]
        var result: [Int: String] = [:]
        for track in tracks {
            let own = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = (own?.isEmpty == false ? own : nil)
                ?? track.language.flatMap { Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) }
                ?? "\(fallback) \(track.id)"
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            result[track.id] = count == 1 ? base : "\(base) (\(count))"
        }
        return result
    }

    func audioTitles() -> [Int: String] { Self.titles(for: audio, fallback: "Audio") }
    func subtitleTitles() -> [Int: String] { Self.titles(for: subtitles, fallback: "Subtitles") }

    func choices() -> (audio: [TrackChoice], subtitles: [TrackChoice]) {
        func make(_ tracks: [Track], kind: TrackChoice.Kind, titles: [Int: String]) -> [TrackChoice] {
            tracks.map { track in
                TrackChoice(id: track.id, kind: kind, title: titles[track.id] ?? "", language: track.language,
                            codec: track.codec.displayName, isDefault: track.isDefault, isForced: track.isForced,
                            isHearingImpaired: track.isHearingImpaired, isCommentary: track.isCommentary,
                            isExternal: externalSubtitleIDs.contains(track.id) || externalAudioIDs.contains(track.id))
            }
        }
        return (make(audio, kind: .audio, titles: audioTitles()), make(subtitles, kind: .subtitle, titles: subtitleTitles()))
    }
}
