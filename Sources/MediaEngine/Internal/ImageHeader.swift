import Foundation

/// The pixel size of a JPEG or PNG picture, read from its header (no decoding).
enum ImageHeader {
    static func size(of bytes: UnsafeBufferPointer<UInt8>) -> (width: Int, height: Int)? {
        if bytes.count >= 24, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            // PNG: the signature (8 bytes), then the IHDR chunk: length (4), type (4), width (4), height (4).
            func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 << 8 | Int(bytes[at + $1]) } }
            let width = u32(16), height = u32(20)
            return width > 0 && height > 0 ? (width, height) : nil
        }
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        // JPEG: segments after the start marker, each FF, a marker byte and (except standalone markers) a two-byte length; the frame
        // header (SOF0 to SOF15, not DHT C4, JPG C8 and DAC CC) holds the precision, the height and the width.
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xFF { index += 1; continue }                       // fill byte
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { index += 2; continue }
            if marker == 0xD9 || marker == 0xDA { return nil }                // end of picture or start of the data: no frame header
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                guard index + 8 < bytes.count else { return nil }
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                return width > 0 && height > 0 ? (width, height) : nil
            }
            guard length >= 2 else { return nil }
            index += 2 + length
        }
        return nil
    }
}
