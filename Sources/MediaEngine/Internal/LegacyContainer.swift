internal import FFmpegLGPL
import Foundation

/// Recognises the legacy containers that this build cannot open (RealMedia is only in the extended build), from their
/// first bytes, so it can say "needs the extended module" instead of "this is not a media file".
enum LegacyContainer {
    static func name(of source: any ByteSource) -> String? {
        var header = [UInt8](repeating: 0, count: 16)
        let count = header.withUnsafeMutableBytes { (try? source.read(at: 0, into: $0)) ?? 0 }
        return name(of: Array(header.prefix(count)))
    }

    /// The format a file's first bytes announce, when this build has no demuxer for it.
    static func name(of header: [UInt8]) -> String? {
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            header.count >= offset + bytes.count && Array(header[offset..<(offset + bytes.count)]) == bytes
        }
        if starts(Array("RIFF".utf8)), starts(Array("AVI ".utf8), at: 8), av_find_input_format("avi") == nil { return "AVI" }
        if starts(Array("FLV".utf8)), av_find_input_format("flv") == nil { return "Flash video (FLV)" }
        if starts(Array(".RMF".utf8)), av_find_input_format("rm") == nil { return "RealMedia" }
        if starts([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]), av_find_input_format("asf") == nil { return "Windows Media (ASF)" }
        return nil
    }
}
