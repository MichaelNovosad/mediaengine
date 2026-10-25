import Foundation

/// The header of one EBML element: its identifier, the size of its data (`nil` when unknown) and how long the header is.
struct EBMLHeader {
    var id: UInt32
    var size: Int64?
    var headerLength: Int
}

/// A small reader for the parts of Matroska that FFmpeg does not expose (ordered chapters, segment identifiers). It
/// reads through a ``ByteSource`` at absolute offsets and never reads more than a few bytes at a time, so it is cheap on
/// local files and tolerable over the network (the source's cache serves the repeats).
struct EBMLReader {
    let source: any ByteSource

    /// No element this reader needs is larger than this; a damaged file can claim any size, so nothing bigger is allocated.
    static let largestRead = 1 << 20

    func bytes(at offset: Int64, count: Int) -> [UInt8]? {
        guard count >= 0, count <= Self.largestRead, offset >= 0 else { return nil }
        if count == 0 { return [] }
        if let length = source.length, offset + Int64(count) > length { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                let rest = UnsafeMutableRawBufferPointer(rebasing: raw[filled...])
                return (try? source.read(at: offset + Int64(filled), into: rest)) ?? -1
            }
            if read <= 0 { return nil }
            filled += read
        }
        return buffer
    }

    /// The header of the element that starts at `offset`.
    func header(at offset: Int64) -> EBMLHeader? {
        guard let first = bytes(at: offset, count: 1)?.first, first != 0 else { return nil }
        let idLength = first.leadingZeroBitCount + 1                       // 1...4 bytes, marker bits included in the id
        guard idLength <= 4, let idBytes = bytes(at: offset, count: idLength) else { return nil }
        let id = idBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }

        guard let sizeFirst = bytes(at: offset + Int64(idLength), count: 1)?.first, sizeFirst != 0 else { return nil }
        let sizeLength = sizeFirst.leadingZeroBitCount + 1                  // 1...8 bytes
        guard let sizeBytes = bytes(at: offset + Int64(idLength), count: sizeLength) else { return nil }
        var value = UInt64(sizeBytes[0] & (0xFF >> UInt8(sizeLength)))
        for byte in sizeBytes.dropFirst() { value = value << 8 | UInt64(byte) }
        let allOnes = (UInt64(1) << UInt64(7 * sizeLength)) - 1
        let size: Int64? = value == allOnes ? nil : Int64(clamping: value)
        return EBMLHeader(id: id, size: size, headerLength: idLength + sizeLength)
    }

    func uint(at offset: Int64, size: Int) -> UInt64? {
        guard (1...8).contains(size), let raw = bytes(at: offset, count: size) else { return nil }
        return raw.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    func string(at offset: Int64, size: Int) -> String? {
        guard size >= 0, size <= 4096, let raw = bytes(at: offset, count: size) else { return nil }
        let trimmed = raw.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// The children of the element whose data starts at `start` and lasts `size` bytes (`nil`: until a parent ends or the
    /// source does), as (header, absolute offset of the element). Stops after `limit` children.
    func children(from start: Int64, size: Int64?, limit: Int = 10_000, until stop: Int64? = nil) -> [(header: EBMLHeader, offset: Int64)] {
        var result: [(EBMLHeader, Int64)] = []
        var offset = start
        let end = size.map { start + $0 } ?? stop ?? source.length ?? Int64.max
        while offset < end, result.count < limit, let header = header(at: offset) {
            result.append((header, offset))
            guard let childSize = header.size else { break }            // unknown size: cannot skip it
            offset += Int64(header.headerLength) + childSize
        }
        return result
    }
}
