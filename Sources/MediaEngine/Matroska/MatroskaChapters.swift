import Foundation

/// Chapters as Matroska stores them, including what FFmpeg leaves out: whether an edition is ordered and which other
/// file (segment) a chapter plays. Times are seconds.
struct MatroskaEdition {
    var uid: UInt64 = 0
    var isOrdered = false
    var isDefault = false
    var isHidden = false
    var atoms: [Atom] = []

    struct Atom {
        var uid: UInt64 = 0
        var start: Double = 0
        var end: Double?
        var isEnabled = true
        var isHidden = false
        var title: String?
        /// 16 bytes; absent when the chapter plays this file.
        var segmentUID: Data?
        var segmentEditionUID: UInt64?
    }
}

enum MatroskaChapters {
    private enum ID {
        static let ebml: UInt32 = 0x1A45DFA3, segment: UInt32 = 0x18538067, seekHead: UInt32 = 0x114D9B74
        static let seek: UInt32 = 0x4DBB, seekID: UInt32 = 0x53AB, seekPosition: UInt32 = 0x53AC
        static let info: UInt32 = 0x1549A966, segmentUID: UInt32 = 0x73A4, chapters: UInt32 = 0x1043A770, cluster: UInt32 = 0x1F43B675
        static let edition: UInt32 = 0x45B9, editionUID: UInt32 = 0x45BC, editionHidden: UInt32 = 0x45BD
        static let editionDefault: UInt32 = 0x45DB, editionOrdered: UInt32 = 0x45DD
        static let atom: UInt32 = 0xB6, atomUID: UInt32 = 0x73C4, timeStart: UInt32 = 0x91, timeEnd: UInt32 = 0x92
        static let atomHidden: UInt32 = 0x98, atomEnabled: UInt32 = 0x4598, atomSegmentUID: UInt32 = 0x6E67, atomSegmentEdition: UInt32 = 0x6EBC
        static let display: UInt32 = 0x80, chapString: UInt32 = 0x85
    }

    struct Result {
        /// This file's own segment identifier (16 bytes), when it has one.
        var segmentUID: Data?
        var editions: [MatroskaEdition]
    }

    /// Where the segment says it ends (the offset after its last byte), or `nil` when its size is not stated (live recordings)
    /// or the header cannot be read. A file shorter than that is a download that was cut off.
    static func declaredEnd(of source: any ByteSource) -> Int64? {
        let reader = EBMLReader(source: source)
        guard let ebml = reader.header(at: 0), ebml.id == ID.ebml, let ebmlSize = ebml.size else { return nil }
        let segmentOffset = Int64(ebml.headerLength).addingReportingOverflow(ebmlSize)
        guard !segmentOffset.overflow, let segment = reader.header(at: segmentOffset.partialValue), segment.id == ID.segment,
              let size = segment.size else { return nil }
        let end = segmentOffset.partialValue.addingReportingOverflow(Int64(segment.headerLength)).partialValue.addingReportingOverflow(size)
        return end.overflow ? nil : end.partialValue
    }

    /// The segment identifier and the chapter editions of a Matroska file, or `nil` if the structure cannot be read.
    static func read(from source: any ByteSource) -> Result? {
        let reader = EBMLReader(source: source)
        guard let ebml = reader.header(at: 0), ebml.id == ID.ebml, let ebmlSize = ebml.size else { return nil }
        let segmentOffset = Int64(ebml.headerLength) + ebmlSize
        guard let segment = reader.header(at: segmentOffset), segment.id == ID.segment else { return nil }
        let dataStart = segmentOffset + Int64(segment.headerLength)

        // The first elements of the segment, up to the first cluster, say where Info and Chapters are.
        var positions: [UInt32: Int64] = [:]
        for (header, offset) in reader.children(from: dataStart, size: segment.size, limit: 64, stopAt: ID.cluster) {
            if header.id == ID.cluster { break }
            if positions[header.id] == nil { positions[header.id] = offset }
            if header.id == ID.seekHead, let size = header.size {
                for entry in reader.children(from: offset + Int64(header.headerLength), size: size) where entry.header.id == ID.seek {
                    guard let entrySize = entry.header.size else { continue }
                    var target: UInt32?, position: Int64?
                    for field in reader.children(from: entry.offset + Int64(entry.header.headerLength), size: entrySize) {
                        let at = field.offset + Int64(field.header.headerLength), length = Int(field.header.size ?? 0)
                        if field.header.id == ID.seekID, let raw = reader.bytes(at: at, count: length) { target = raw.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
                        if field.header.id == ID.seekPosition, let value = reader.uint(at: at, size: length) {
                            // The value comes from the file: it can be any 64-bit number.
                            if let relative = Int64(exactly: value), case let (sum, overflow) = dataStart.addingReportingOverflow(relative), !overflow { position = sum }
                        }
                    }
                    if let target, let position, positions[target] == nil { positions[target] = position }
                }
            }
        }

        var uid: Data?
        if let infoOffset = positions[ID.info], let info = reader.header(at: infoOffset), let size = info.size {
            for child in reader.children(from: infoOffset + Int64(info.headerLength), size: size) where child.header.id == ID.segmentUID {
                if let raw = reader.bytes(at: child.offset + Int64(child.header.headerLength), count: Int(child.header.size ?? 0)) { uid = Data(raw) }
            }
        }

        var editions: [MatroskaEdition] = []
        if let chaptersOffset = positions[ID.chapters], let chapters = reader.header(at: chaptersOffset), let size = chapters.size {
            for child in reader.children(from: chaptersOffset + Int64(chapters.headerLength), size: size) where child.header.id == ID.edition {
                if let edition = parseEdition(reader, child.header, child.offset) { editions.append(edition) }
            }
        }
        return Result(segmentUID: uid, editions: editions)
    }

    private static func parseEdition(_ reader: EBMLReader, _ header: EBMLHeader, _ offset: Int64) -> MatroskaEdition? {
        guard let size = header.size else { return nil }
        var edition = MatroskaEdition()
        for child in reader.children(from: offset + Int64(header.headerLength), size: size) {
            let at = child.offset + Int64(child.header.headerLength), length = Int(child.header.size ?? 0)
            switch child.header.id {
            case ID.editionUID: edition.uid = reader.uint(at: at, size: length) ?? 0
            case ID.editionHidden: edition.isHidden = (reader.uint(at: at, size: length) ?? 0) != 0
            case ID.editionDefault: edition.isDefault = (reader.uint(at: at, size: length) ?? 0) != 0
            case ID.editionOrdered: edition.isOrdered = (reader.uint(at: at, size: length) ?? 0) != 0
            case ID.atom: if let atom = parseAtom(reader, child.header, child.offset) { edition.atoms.append(atom) }
            default: break
            }
        }
        return edition
    }

    private static func parseAtom(_ reader: EBMLReader, _ header: EBMLHeader, _ offset: Int64) -> MatroskaEdition.Atom? {
        guard let size = header.size else { return nil }
        var atom = MatroskaEdition.Atom()
        var haveStart = false
        for child in reader.children(from: offset + Int64(header.headerLength), size: size) {
            let at = child.offset + Int64(child.header.headerLength), length = Int(child.header.size ?? 0)
            switch child.header.id {
            case ID.atomUID: atom.uid = reader.uint(at: at, size: length) ?? 0
            case ID.timeStart: if let value = reader.uint(at: at, size: length) { atom.start = Double(value) / 1e9; haveStart = true }
            case ID.timeEnd: if let value = reader.uint(at: at, size: length) { atom.end = Double(value) / 1e9 }
            case ID.atomHidden: atom.isHidden = (reader.uint(at: at, size: length) ?? 0) != 0
            case ID.atomEnabled: atom.isEnabled = (reader.uint(at: at, size: length) ?? 1) != 0
            case ID.atomSegmentUID: atom.segmentUID = reader.bytes(at: at, count: length).map { Data($0) }
            case ID.atomSegmentEdition: atom.segmentEditionUID = reader.uint(at: at, size: length)
            case ID.display where atom.title == nil:
                for field in reader.children(from: at, size: child.header.size) where field.header.id == ID.chapString {
                    atom.title = reader.string(at: field.offset + Int64(field.header.headerLength), size: Int(field.header.size ?? 0))
                }
            default: break
            }
        }
        return haveStart ? atom : nil
    }
}
