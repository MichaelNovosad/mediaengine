import Foundation

/// How the person wants the subtitles that the engine draws: their size and the colour of the text. Both sit on top of what the file says;
/// `standard` leaves the file alone.
///
/// Size applies to every text subtitle, styled ASS ones too. The colour applies to lines that look like plain dialogue (every SubRip, WebVTT and
/// Timed Text line, and the ordinary lines of an ASS file); text that the ASS file positions or colours on purpose (signs, karaoke) keeps its
/// own look. Picture subtitles (PGS, VobSub, DVB) are not changed.
public struct SubtitleAppearance: Equatable, Sendable {
    /// The range of ``scale``: from half to two and a half times the size the file asks for.
    public static let scaleRange: ClosedRange<Double> = 0.5...2.5

    /// 1 is the size in the file.
    public var scale: Double
    /// The colour of the text as `0xRRGGBB`, or `nil` to keep the file's.
    public var color: UInt32?

    public init(scale: Double = 1, color: UInt32? = nil) {
        self.scale = scale.isFinite ? min(max(scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : 1
        self.color = color.map { $0 & 0xFFFFFF }
    }

    public static let standard = SubtitleAppearance()

    public var isStandard: Bool { abs(scale - 1) < 0.001 && color == nil }
}
