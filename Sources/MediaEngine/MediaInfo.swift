import Foundation

/// Everything the engine learns about a media file without decoding it.
public struct MediaInfo: Sendable, Equatable, Codable {
    public var container: Container
    /// Duration in seconds, when the file states one.
    public var duration: TimeInterval?
    public var title: String?
    /// File-level tags such as `title` or `encoder`.
    public var tags: [String: String]
    /// Average bit rate of the whole file in bits per second, when known.
    public var bitrate: Int64?
    /// Size of the file in bytes, when known.
    public var fileSize: Int64?
    /// Video, audio and subtitle tracks in file order. Attachments (fonts, cover art) are listed separately.
    public var tracks: [Track]
    public var chapters: [Chapter]
    public var attachments: [Attachment]
    /// How the engine would play this file and what it would need.
    public var playbackPlan: PlaybackPlan

    public var videoTracks: [Track] { tracks.filter { $0.kind == .video } }
    public var audioTracks: [Track] { tracks.filter { $0.kind == .audio } }
    public var subtitleTracks: [Track] { tracks.filter { $0.kind == .subtitle } }
    /// The codec profiles this file needs (see ``CodecProfile``). Hosts gate features with this.
    public var requiredProfile: CodecProfile { playbackPlan.requiredProfile }
}

/// The container format of a file.
public struct Container: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case matroska, webm, mp4, mpegTS, mpegPS, avi, asf, flv, ogg, wav, flac, mp3, aac, ac3, eac3, other
    }

    public var kind: Kind
    /// Short technical name of the format, for diagnostics.
    public var formatName: String

    /// `true` for Matroska (`.mkv`, `.mka`) and WebM files.
    public var isMatroskaFamily: Bool { kind == .matroska || kind == .webm }
}

/// A video, audio or subtitle track.
public struct Track: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case video, audio, subtitle }

    /// Position of the track in the file. Stable for a given file.
    public var id: Int
    public var kind: Kind
    public var codec: Codec
    /// Language of the track, or `nil` when the file does not say (or says "undetermined").
    public var language: Locale.Language?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var isCommentary: Bool
    /// Average bit rate in bits per second, when known.
    public var bitrate: Int64?
    public var video: VideoDetails?
    public var audio: AudioDetails?
    public var subtitle: SubtitleDetails?
}

public struct Codec: Sendable, Equatable, Codable {
    /// Short identifier such as `h264`, `hevc`, `aac`, `ac3`, `subrip`.
    public var name: String
    /// Name for people, such as "H.264" or "E-AC-3".
    public var displayName: String
    /// Profile name such as "High", "Main 10" or "DTS-HD MA", when known.
    public var profile: String?
    /// Numeric profile: H.264 `profile_idc`, HEVC `general_profile_idc`, AV1 `seq_profile`.
    public var profileIdentifier: Int?
    /// Level such as "4.1", when known.
    public var level: String?
}

public struct VideoDetails: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    /// Frames per second, or `nil` for variable or unknown rates.
    public var frameRate: Double?
    public var bitDepth: Int?
    public var chroma: Chroma?
    /// Width of a pixel relative to its height (1 for square pixels).
    public var pixelAspectRatio: Double?
    /// `true` for interlaced video, `false` for progressive, `nil` when unknown.
    public var isInterlaced: Bool?
    public var colorPrimaries: String?
    public var colorTransfer: String?
    public var colorMatrix: String?
    public var isFullRange: Bool?
    public var hdr: HDRFormat
    /// Clockwise rotation to apply when displaying, in degrees (0, 90, 180, 270).
    public var rotation: Int

    public enum Chroma: String, Sendable, Codable { case monochrome, yuv420, yuv422, yuv444 }
}

public enum HDRFormat: Sendable, Equatable, Codable {
    case sdr
    case hdr10
    case hlg
    /// Dolby Vision. `baseLayerCompatibility` is the compatibility id from the configuration record
    /// (0 none, 1 HDR10, 2 SDR, 4 HLG), when present.
    case dolbyVision(profile: Int, level: Int, baseLayerCompatibility: Int?)
}

public struct AudioDetails: Sendable, Equatable, Codable {
    public var channels: Int
    /// Layout such as "stereo" or "5.1(side)", when known.
    public var channelLayout: String?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var isLossless: Bool
    /// `true` for object-based audio such as Dolby Atmos streams.
    public var isObjectBased: Bool
}

public struct SubtitleDetails: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Codable {
        /// Text (SubRip, ASS/SSA, WebVTT, ...).
        case text
        /// Pictures (PGS, VobSub, DVB).
        case bitmap
    }
    public var format: Format
}

public struct Chapter: Sendable, Equatable, Codable, Identifiable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var title: String?
}

/// A file embedded in the container, such as a font or cover art.
public struct Attachment: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case font, coverArt, other }

    public var id: Int
    public var kind: Kind
    public var filename: String?
    public var mimeType: String?
    /// Size in bytes, when known.
    public var byteCount: Int?
}
