import Foundation

/// Builds ISO base media boxes (big-endian).
struct ByteWriter {
    private(set) var data = Data()

    init() {}
    /// Reserves the final size up front: growing a large buffer by appending reallocates it again and again, and the
    /// allocator keeps the abandoned blocks, which would multiply the memory a segment needs.
    init(capacity: Int) { data.reserveCapacity(capacity) }

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
    mutating func u32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func u64(_ value: UInt64) { u32(UInt32(value >> 32)); u32(UInt32(value & 0xFFFF_FFFF)) }
    mutating func fourCC(_ text: String) { data.append(contentsOf: Array(text.utf8.prefix(4))) }
    mutating func append(_ other: Data) { data.append(other) }

    /// Writes a box: the closure fills the payload, the size field is filled in afterwards.
    mutating func box(_ type: String, _ body: (inout ByteWriter) -> Void) {
        let start = data.count
        u32(0)
        fourCC(type)
        body(&self)
        let size = UInt32(data.count - start)
        data.replaceSubrange(start..<(start + 4), with: [UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
    }
}

/// Reads the box structure of an MP4 byte string.
struct MP4Box {
    var type: String
    /// Offset of the box header and of its payload within the parsed data.
    var start: Int
    var payload: Range<Int>
    var end: Int { payload.upperBound }

    /// The boxes directly inside `range` of `data`.
    static func children(of data: Data, in range: Range<Int>) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(data.uint32(at: offset))
            let type = String(decoding: data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8)], as: UTF8.self)
            var header = 8
            if size == 1, offset + 16 <= range.upperBound {          // 64-bit size
                size = Int(data.uint64(at: offset + 8)); header = 16
            } else if size == 0 {                                   // extends to the end
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { break }
            boxes.append(MP4Box(type: type, start: offset, payload: (offset + header)..<(offset + size)))
            offset += size
        }
        return boxes
    }

    /// Top-level boxes of `data`.
    static func parse(_ data: Data) -> [MP4Box] { children(of: data, in: 0..<data.count) }

    /// Follows a path such as `["moov", "trak", "mdia", "mdhd"]`, taking the first match at each level.
    static func find(_ path: [String], in data: Data, within range: Range<Int>? = nil) -> MP4Box? {
        guard let first = path.first else { return nil }
        let candidates = children(of: data, in: range ?? 0..<data.count)
        guard let match = candidates.first(where: { $0.type == first }) else { return nil }
        return path.count == 1 ? match : find(Array(path.dropFirst()), in: data, within: match.payload)
    }
}

extension Data {
    func uint32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) << 24 | UInt32(self[base + 1]) << 16 | UInt32(self[base + 2]) << 8 | UInt32(self[base + 3])
    }
    func uint64(at offset: Int) -> UInt64 { UInt64(uint32(at: offset)) << 32 | UInt64(uint32(at: offset + 4)) }
}
