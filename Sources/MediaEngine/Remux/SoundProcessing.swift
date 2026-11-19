internal import FFmpegLGPL
import Foundation

/// Changes the sound of a film before it plays: an equalizer, a volume boost. Give one to ``PlaybackSession/soundProcessor`` before the
/// first player item or controller is made. The engine then decodes the sound tracks it serves, passes the samples through the processor
/// and serves them as Apple Lossless (ALAC) instead of the original format.
///
/// Which tracks it reaches: every track the engine converts anyway (FLAC, Opus, Vorbis, PCM, the DTS core and the like), AAC-LC with up
/// to 5.1 channels (decoded by Apple's own AudioToolbox, as AVPlayer would), and AC-3 and E-AC-3 when the linked build has their
/// decoders (the `audioFallback` profile; Apple's decoders trim their own delay so that pieces decoded one at a time would not join).
/// Other tracks (HE-AAC, MP3, more than 5.1 channels of AAC) play as they are, without the processor: see
/// ``PlaybackSession/soundProcessorReaches(_:)``. An E-AC-3 track with Dolby Atmos keeps only its channels when it is processed.
///
/// Films that the system plays by itself (an MP4 or MOV with formats AVPlayer reads, ``PlaybackPath/native``) are not served by the
/// engine: their sound does not pass through a processor (an `MTAudioProcessingTap` on the player item reaches it).
///
/// The engine builds the pieces of a film out of order and several at once (a jump, a sound switch, reading ahead), so a processor
/// hands out a fresh ``SoundStage`` for each piece. The engine runs a short stretch of the sound before the piece through the stage first
/// (at least ``warmUp`` seconds, thrown away), so that a filter has settled when the piece begins and the pieces join without a click.
public protocol SoundProcessor: AnyObject, Sendable {
    /// A new stage for one stretch of sound with this sample rate and number of channels.
    func makeStage(sampleRate: Double, channels: Int) -> any SoundStage
}

extension SoundProcessor {
    /// Seconds of sound before each piece that run through a new stage and are thrown away.
    public static var warmUp: Double { SoundProcessing.warmUp }
}

/// One stretch of sound passing through a ``SoundProcessor``.
public protocol SoundStage: AnyObject {
    /// Changes `frames` samples of every channel in place: planar 32-bit float, about -1 to 1 (values past 1 are clipped when the
    /// sound is encoded). Called in the order of the sound, from one thread at a time.
    func process(_ channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frames: Int)
}

enum SoundProcessing {
    /// Seconds before a piece that warm a new stage up.
    static let warmUp = 0.2

    /// How a track's sound reaches a processor.
    enum Route: Equatable {
        /// The track is converted anyway: through the converter's own decoder.
        case converted
        /// AAC-LC: decoded by AudioToolbox, then converted.
        case system
        /// AC-3, E-AC-3: decoded by FFmpeg's decoder of the linked build, then converted.
        case ffmpeg
        /// Not reached: the track plays as it is.
        case none
    }

    /// Whether a processor reaches this track, from what the probe says about it (``PlaybackSession/soundProcessorReaches(_:)``).
    static func reaches(_ track: Track, transcodes: Bool) -> Bool {
        if transcodes { return true }
        switch track.codec.name {
        case "aac": return [1, 2, 6].contains(track.audio?.channels ?? 0) && (track.codec.profile ?? "LC") == "LC"
        case "ac3": return avcodec_find_decoder(AV_CODEC_ID_AC3) != nil
        case "eac3": return avcodec_find_decoder(AV_CODEC_ID_EAC3) != nil
        default: return false
        }
    }

    /// The route for a track whose plan is `transcodes` (converted anyway) or passthrough.
    static func route(codecName: String, transcodes: Bool, parameters: UnsafePointer<AVCodecParameters>) -> Route {
        if transcodes { return .converted }
        switch codecName {
        case "aac":
            return AudioTranscoder.systemDecodes(parameters) ? .system : .none
        case "ac3", "eac3":
            return avcodec_find_decoder(parameters.pointee.codec_id) != nil ? .ffmpeg : .none
        default:
            return .none
        }
    }
}
