import Foundation

/// An audio file that plays instead of the video's own sound, for example a dub (`.mka`, `.m4a`, `.flac`, `.ac3`,
/// `.eac3`, `.aac`, `.mp3`, `.opus`, ...).
///
/// ```swift
/// let dub = try await AudioTrack(url: audioURL, delay: -0.25)    // 250 ms earlier than the file says
/// try session.add(dub)                                              // before makePlayerItem()
/// ```
///
/// The file is opened and probed when the track is created. It plays through the same machinery as the video's own
/// tracks: AVPlayer-compatible audio is repackaged as it is, FLAC, Opus, Vorbis and PCM are converted to lossless ALAC
/// on demand. Audio the engine cannot play (DTS without the licensed module) is refused with a reason.
public struct AudioTrack: Sendable {
    /// The name to show. Made unique among the player's audio choices.
    public var title: String
    public var language: Locale.Language?
    /// Seconds by which this audio starts later than the video (negative: earlier), to line up a dub.
    public var delay: TimeInterval
    /// The audio's codec, for example "AAC" or "FLAC".
    public let codec: String
    /// The length of the audio file, when it says.
    public let duration: TimeInterval?

    let source: MediaSource
    /// The stream to play and what happens to it.
    let stream: Int
    let track: Track
    let transcodes: Bool

    /// Opens and probes an audio file (security-scoped URLs from the file picker included).
    public init(url: URL, language: Locale.Language? = nil, title: String? = nil, delay: TimeInterval = 0) async throws {
        try await self.init(source: MediaSource(url: url), name: url.lastPathComponent, language: language, title: title, delay: delay)
    }

    /// Probes audio from any ``MediaSource``. `name` is the file name, which gives the language when it ends in one
    /// (`Film.ru.mka`). `stream` names the audio track to play by its ``TrackChoice/id`` (the first one when `nil`): with the video
    /// file's own source it makes a copy of one of the video's tracks that can start earlier or later than the original
    /// (see ``PlaybackSession/audioTrack(like:delay:title:)``).
    public init(source: MediaSource, name: String, language: Locale.Language? = nil, title: String? = nil,
                delay: TimeInterval = 0, stream: Int? = nil) async throws {
        let info = try await source.probe()
        let audio = ServedTracks(info: info).audio
        guard let track = stream.map({ id in audio.first { $0.id == id } }) ?? audio.first else {
            let reason = info.playbackPlan.notes.first ?? "the file has no audio the player can play"
            throw MediaError.unsupported(detail: reason)
        }
        var transcodes = false
        if let treatment = info.playbackPlan.tracks.first(where: { $0.trackID == track.id })?.treatment, case .transcodeAudio = treatment {
            transcodes = true
        }
        let hinted = language ?? track.language ?? SubtitleFileName(name).language
        self.language = hinted
        self.title = title ?? track.title ?? hinted.flatMap { Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) }
            ?? ((name as NSString).deletingPathExtension as NSString).lastPathComponent
        self.delay = delay
        self.codec = track.codec.displayName
        self.duration = info.duration
        self.source = source
        self.stream = track.id
        self.track = track
        self.transcodes = transcodes
    }
}

extension AudioTrack {
    /// The movie this sound file belonged to is closed: the file's network connection goes now (a file on an SMB server keeps a
    /// connection of its own) instead of when the last copy of the track goes. Do not add the track to a session afterwards.
    public func close() { source.byteSource.close() }
}
