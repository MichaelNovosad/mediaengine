import Foundation
import Testing
@testable import MediaEngine

private let ownUID = "b1b2b3b4b5b6b7b8b9babbbcbdbebfc0"
private let openingUID = "a1a2a3a4a5a6a7a8a9aaabacadaeafb0"
private let missingUID = "deadbeefdeadbeefdeadbeefdeadbeef"

@Suite("EBML")
struct EBMLTests {
    private func header(_ bytes: [UInt8]) -> EBMLHeader? { EBMLReader(source: DataByteSource(Data(bytes))).header(at: 0) }

    @Test("identifiers and sizes of every length")
    func headers() {
        #expect(header([0xB6, 0x85])?.id == 0xB6 && header([0xB6, 0x85])?.size == 5 && header([0xB6, 0x85])?.headerLength == 2)
        let chapters = header([0x10, 0x43, 0xA7, 0x70, 0x40, 0x80])
        #expect(chapters?.id == 0x1043A770 && chapters?.size == 128 && chapters?.headerLength == 6)
        let long = header([0x18, 0x53, 0x80, 0x67, 0x01, 0, 0, 0, 0, 0x01, 0x00, 0x00])
        #expect(long?.id == 0x18538067 && long?.size == 0x10000 && long?.headerLength == 12)
        #expect(header([0xEC, 0xFF])?.size == nil, "all ones: unknown size")
        #expect(header([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])?.size == nil)
    }

    @Test("garbage, truncation and impossible lengths give nothing")
    func garbage() {
        #expect(header([]) == nil && header([0x00]) == nil && header([0xB6]) == nil)
        #expect(header([0x08, 0, 0, 0, 0]) == nil, "an identifier of five bytes does not exist")
        #expect(header([0x10, 0x43, 0xA7]) == nil)
        #expect(EBMLReader(source: DataByteSource(Data([1, 2, 3]))).bytes(at: 2, count: 4) == nil)
        #expect(EBMLReader(source: DataByteSource(Data([1, 2, 3]))).uint(at: 0, size: 0) == nil)
    }

    @Test("unreadable or damaged files never crash the reader", arguments: ["fixture-ordered", "fixture-linked-opening", "fixture-basic", "fixture-anime"])
    func damaged(name: String) throws {
        let data = try Fixture.data(name)
        for cut in stride(from: 0, to: data.count, by: 997) { _ = MatroskaChapters.read(from: DataByteSource(data.prefix(cut))) }
        // The structure lives in the first few kilobytes: damage that area a lot, with a fixed seed.
        var generator = SplitMix64(state: 7)
        for _ in 0..<4_000 {
            var copy = data
            for _ in 0..<Int.random(in: 1...12, using: &generator) {
                copy[Int.random(in: 0..<min(4_000, data.count), using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = MatroskaChapters.read(from: DataByteSource(copy))
        }
        #expect(MatroskaChapters.read(from: DataByteSource(Data("not matroska".utf8))) == nil)
    }

    @Test("numbers that cannot be positions or sizes in a SeekHead and elsewhere do not trap", arguments: [UInt64.max, UInt64(Int64.max), UInt64(Int64.max) + 1, 1 << 62, 1 << 56])
    func hugeNumbers(value: UInt64) {
        let ebml = element([0x1A, 0x45, 0xDF, 0xA3], [])
        let big = (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * $0)) }
        let seek = element([0x4D, 0xBB], element([0x53, 0xAB], [0x15, 0x49, 0xA9, 0x66]) + element([0x53, 0xAC], big))
        let seekHead = element([0x11, 0x4D, 0x9B, 0x74], seek + seek)
        for payload in [seekHead, seekHead + seekHead] {
            let file = Data(ebml + [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + payload)     // unknown segment size
            _ = MatroskaChapters.read(from: DataByteSource(file))
        }
    }

    /// An element: identifier, a one-byte size and the payload.
    private func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] { id + [0x80 | UInt8(payload.count)] + payload }
    /// An element header that claims 2^52 bytes of data and has none.
    private func hugeHeader(_ id: [UInt8]) -> [UInt8] { id + [0x01, 0x10, 0, 0, 0, 0, 0, 0] }

    @Test("an element that claims a huge size is not allocated: a damaged identifier does not crash the process")
    func hugeSizes() {
        let ebml = element([0x1A, 0x45, 0xDF, 0xA3], [])
        let segment: ([UInt8]) -> Data = { Data(ebml + element([0x18, 0x53, 0x80, 0x67], $0)) }
        let info = element([0x15, 0x49, 0xA9, 0x66], hugeHeader([0x73, 0xA4]))
        let result = MatroskaChapters.read(from: DataByteSource(segment(info)))
        #expect(result?.segmentUID == nil, "the identifier is ignored, the file is still read")
        let atom = element([0xB6], hugeHeader([0x6E, 0x67]) + [])
        let chapters = element([0x10, 0x43, 0xA7, 0x70], element([0x45, 0xB9], atom))
        _ = MatroskaChapters.read(from: DataByteSource(segment(chapters)))              // a crash here fails the whole run
        let reader = EBMLReader(source: DataByteSource(Data(count: 100)))
        #expect(reader.bytes(at: 0, count: Int.max) == nil && reader.bytes(at: 0, count: EBMLReader.largestRead + 1) == nil)
        #expect(reader.bytes(at: 90, count: 20) == nil && reader.bytes(at: 90, count: 10)?.count == 10, "past the end of the source is refused up front")
    }
}

@Suite("Ordered chapters")
struct OrderedChaptersTests {
    @Test("the main fixture plays the opening of another file, then its own second half, then its first half")
    func playList() async throws {
        let info = try await Fixture.probe("fixture-ordered")
        #expect(info.segmentUID == ownUID)
        let ordered = try #require(info.orderedChapters)
        #expect(ordered.pieces.map(\.title) == ["Opening", "Second half", "First half"])
        #expect(ordered.pieces.map { $0.segment?.uid } == [openingUID, nil, nil])
        #expect(ordered.pieces.map(\.start) == [0, 2, 0] && ordered.pieces.map(\.end) == [2, 4, 2])
        #expect(ordered.pieces.map(\.offset) == [0, 2, 4] && ordered.duration == 6)
        #expect(ordered.segments == [LinkedSegment(uid: openingUID)])
        #expect(info.playbackPlan.notes.contains { $0.contains("1 other file") }, "\(info.playbackPlan.notes)")
    }

    @Test("a file with a missing segment lists both")
    func missing() async throws {
        let ordered = try #require(try await Fixture.probe("fixture-ordered-missing").orderedChapters)
        #expect(ordered.segments.map(\.uid) == [openingUID, missingUID])
        #expect(ordered.pieces.map(\.offset) == [0, 2, 3] && ordered.duration == 5)
    }

    @Test("the linked file is an ordinary file that carries the identifier the other one names")
    func linkedFile() async throws {
        let info = try await Fixture.probe("fixture-linked-opening")
        #expect(info.segmentUID == openingUID && info.orderedChapters == nil)
        #expect(abs((info.duration ?? 0) - 2) < 0.1)
    }

    @Test("ordinary files have an identifier and no play list")
    func ordinary() async throws {
        for name in ["fixture-basic", "fixture-anime", "fixture-hevc"] {
            let info = try await Fixture.probe(name)
            #expect(info.orderedChapters == nil && info.segmentUID?.count == 32, Comment(rawValue: name))
        }
    }

    @Test("pieces whose segment is not there are left out and the timeline closes up")
    func available() async throws {
        let ordered = try #require(try await Fixture.probe("fixture-ordered-missing").orderedChapters)
        let reduced = ordered.available { $0.uid == openingUID }
        #expect(reduced.pieces.map(\.title) == ["Opening", "Second half"] && reduced.pieces.map(\.offset) == [0, 2])
        #expect(reduced.duration == 4 && reduced.segments.map(\.uid) == [openingUID])
        #expect(ordered.available { _ in true } == ordered)
        #expect(ordered.available { _ in false }.pieces.map(\.title) == ["Second half"])
    }

    @Test("an ordered edition that only plays the file from its start is no play list; unordered editions never are")
    func trivial() {
        func edition(ordered: Bool, atoms: [MatroskaEdition.Atom]) -> MatroskaEdition {
            var edition = MatroskaEdition(); edition.isOrdered = ordered; edition.isDefault = true; edition.atoms = atoms; return edition
        }
        var whole = MatroskaEdition.Atom(); whole.start = 0; whole.end = 10
        #expect(OrderedChapters.make(editions: [edition(ordered: true, atoms: [whole])], ownUID: nil) == nil)
        #expect(OrderedChapters.make(editions: [edition(ordered: false, atoms: [whole, whole])], ownUID: nil) == nil)
        #expect(OrderedChapters.make(editions: [], ownUID: nil) == nil)
        var tail = whole; tail.start = 4
        #expect(OrderedChapters.make(editions: [edition(ordered: true, atoms: [tail])], ownUID: nil)?.duration == 6, "skipping the start is a play list")
        var disabled = whole; disabled.isEnabled = false
        var noEnd = whole; noEnd.end = nil
        #expect(OrderedChapters.make(editions: [edition(ordered: true, atoms: [disabled, noEnd, tail])], ownUID: nil)?.pieces.count == 1)
        var own = whole; own.segmentUID = Data([UInt8](repeating: 7, count: 16))
        var again = own; again.start = 1
        let result = OrderedChapters.make(editions: [edition(ordered: true, atoms: [own, again])], ownUID: Data([UInt8](repeating: 7, count: 16)))
        #expect(result?.segments.isEmpty == true && result?.pieces.allSatisfy { $0.segment == nil } == true, "a chapter naming this very file plays this file")
    }
}
