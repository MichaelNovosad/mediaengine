import Foundation

/// Reads codec facts straight from the codec configuration records stored in containers.
///
/// The engine ships no H.264, HEVC or AV1 decoder, so FFmpeg cannot tell us the profile, level or
/// bit depth. These records (avcC, hvcC, av1C) carry them.
enum Extradata {
    struct AVC: Equatable {
        var profileIdc: Int
        var levelIdc: Int
    }

    /// `avcC` (ISO 14496-15): `[1, profile, compatibility, level, ...]`.
    static func avc(_ data: [UInt8]) -> AVC? {
        guard data.count >= 4, data[0] == 1 else { return nil }
        return AVC(profileIdc: Int(data[1]), levelIdc: Int(data[3]))
    }

    struct HEVC: Equatable {
        var profileIdc: Int
        var isHighTier: Bool
        var levelIdc: Int
        var chromaFormatIdc: Int
        var bitDepth: Int
    }

    /// `hvcC` (ISO 14496-15): fixed 22-byte header before the parameter-set arrays.
    static func hevc(_ data: [UInt8]) -> HEVC? {
        guard data.count >= 23, data[0] == 1 else { return nil }
        return HEVC(
            profileIdc: Int(data[1] & 0x1F),
            isHighTier: data[1] & 0x20 != 0,
            levelIdc: Int(data[12]),
            chromaFormatIdc: Int(data[16] & 0x03),
            bitDepth: Int(data[17] & 0x07) + 8)
    }

    struct AV1: Equatable {
        var seqProfile: Int
        var levelIdx: Int
        var bitDepth: Int
        var isMonochrome: Bool
        var subsamplingX: Bool
        var subsamplingY: Bool
    }

    /// `av1C`: `[marker|version, profile|level, tier|bitdepth|mono|subsampling, ...]`.
    static func av1(_ data: [UInt8]) -> AV1? {
        guard data.count >= 4, data[0] == 0x81 else { return nil }
        let highBitDepth = data[2] & 0x40 != 0
        let twelveBit = data[2] & 0x20 != 0
        return AV1(
            seqProfile: Int(data[1] >> 5),
            levelIdx: Int(data[1] & 0x1F),
            bitDepth: twelveBit ? 12 : (highBitDepth ? 10 : 8),
            isMonochrome: data[2] & 0x10 != 0,
            subsamplingX: data[2] & 0x08 != 0,
            subsamplingY: data[2] & 0x04 != 0)
    }

    // MARK: Names

    static func h264ProfileName(_ idc: Int) -> String {
        switch idc {
        case 66: "Baseline"
        case 77: "Main"
        case 88: "Extended"
        case 100: "High"
        case 110: "High 10"
        case 122: "High 4:2:2"
        case 244: "High 4:4:4 Predictive"
        case 44: "CAVLC 4:4:4 Intra"
        case 118: "Multiview High"
        case 128: "Stereo High"
        default: "Profile \(idc)"
        }
    }

    static func hevcProfileName(_ idc: Int) -> String {
        switch idc {
        case 1: "Main"
        case 2: "Main 10"
        case 3: "Main Still Picture"
        case 4: "Format Range Extensions"
        case 5: "High Throughput"
        case 9: "Screen Content Coding"
        default: "Profile \(idc)"
        }
    }

    static func av1ProfileName(_ profile: Int) -> String {
        switch profile {
        case 0: "Main"
        case 1: "High"
        case 2: "Professional"
        default: "Profile \(profile)"
        }
    }

    /// H.264 `level_idc` 30 means level 3.0; 9 means level 1b.
    static func h264Level(_ idc: Int) -> String {
        idc == 9 ? "1b" : "\(idc / 10).\(idc % 10)"
    }

    /// HEVC `general_level_idc` is the level times 30 (63 means level 2.1).
    static func hevcLevel(_ idc: Int) -> String {
        let tenths = idc * 10 / 30
        return "\(tenths / 10).\(tenths % 10)"
    }

    static func av1Level(_ idx: Int) -> String {
        "\(2 + idx / 4).\(idx % 4)"
    }
}
