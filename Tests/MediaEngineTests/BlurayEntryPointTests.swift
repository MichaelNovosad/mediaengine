import Foundation
import Synchronization
import Testing
@testable import MediaEngine

/// A source that is not a file (as Eiga's server connection is not).
private final class MemorySource: ByteSource {
    let base: DataByteSource
    init(_ data: Data) { base = DataByteSource(data) }
    var length: Int64? { base.length }
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int { try base.read(at: offset, into: buffer) }
}

/// A Blu-ray stream made from `fixture-ts`: each 188-byte transport packet behind a 4-byte header, as an `.m2ts` file has them.
private func bluRayStream(extra: Int = 0) throws -> Data {
    let ts = try Fixture.data("fixture-ts")
    var m2ts = Data(capacity: ts.count / 188 * 192 + extra * 192)
    var at = ts.startIndex
    while at + 188 <= ts.endIndex {
        m2ts.append(contentsOf: [0, 0, 0, 0])
        m2ts.append(ts[at..<(at + 188)])
        at += 188
    }
    for _ in 0..<extra {                                                  // null packets: another file of the same stream
        m2ts.append(contentsOf: [0, 0, 0, 0, 0x47, 0x1F, 0xFF, 0x10])
        m2ts.append(Data(repeating: 0xFF, count: 184))
    }
    return m2ts
}

/// The pictures a player can start from, found the way a disc's authoring tool lists them: packets of the video PID that start a PES
/// and carry the random access flag.
private func keyframes(of m2ts: Data, pid: Int) -> [DiscInfo.EntryPoint] {
    let bytes = [UInt8](m2ts)
    var result: [DiscInfo.EntryPoint] = []
    var packet = 0
    while (packet + 1) * 192 <= bytes.count {
        let ts = Array(bytes[(packet * 192 + 4)..<((packet + 1) * 192)])
        let here = Int(ts[1] & 0x1F) << 8 | Int(ts[2])
        let adaptation = (ts[3] >> 4) & 3
        if here == pid, ts[1] & 0x40 != 0, adaptation == 3, ts[4] > 0, ts[5] & 0x40 != 0 {
            let at = 5 + Int(ts[4])
            let b = ts[(at + 9)..<(at + 14)].map(Int64.init)
            let pts = ((b[0] >> 1) & 0x7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1
            result.append(DiscInfo.EntryPoint(pid: pid, time: pts & ~0x1FF, offset: Int64(packet) * 192))
        }
        packet += 1
    }
    return result
}

/// A clip information file with an entry-point map for one stream, laid out as `DiscInfo.entryPoints` reads it; fine entries that share
/// their upper bits share a coarse entry.
private func clipInfo(_ points: [DiscInfo.EntryPoint]) -> Data {
    func be(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (count - 1 - $0))) } }
    var coarse: [(fine: Int, time: UInt64, packet: UInt64)] = []
    var fine: [UInt64] = []
    for (index, point) in points.enumerated() {
        let time = UInt64(point.time), packet = UInt64(point.offset / 192)
        let upperTime = (time >> 19) & 0x3FFE, upperPacket = packet & ~UInt64(0x1FFFF)
        if coarse.last.map({ $0.time != upperTime || $0.packet != upperPacket }) ?? true { coarse.append((index, upperTime, upperPacket)) }
        fine.append(((time >> 9) & 0x7FF) << 17 | (packet & 0x1FFFF))
    }
    var stream: [UInt8] = be(UInt64(4 + 8 * coarse.count), 4)
    for entry in coarse { stream += be(UInt64(entry.fine) << 46 | entry.time << 32 | entry.packet, 8) }
    for entry in fine { stream += be(entry, 4) }
    let pid = UInt64(points.first?.pid ?? 0)
    var map: [UInt8] = [0, 1]
    map += be(pid << 16 | 1 << 2 | UInt64(coarse.count) >> 14, 4)
    map += be((UInt64(coarse.count) & 0x3FFF) << 18 | UInt64(fine.count), 4)
    map += be(14, 4)                                                       // the stream's entries follow the map's header
    map += stream
    var cpi: [UInt8] = be(UInt64(2 + map.count), 4) + [0x00, 0x01]
    cpi += map
    var file: [UInt8] = Array("HDMV0200".utf8)
    file += be(40, 4) + be(40, 4) + be(40, 4) + be(0, 4) + be(0, 4)
    file += [UInt8](repeating: 0, count: 40 - file.count)
    return Data(file + cpi)
}

@Suite("Blu-ray keyframes from the clip file (EGA-121)")
struct BlurayEntryPointTests {
    @Test("the map's times and offsets come back as written, coarse and fine entries combined, 33-bit times included")
    func parses() {
        let points = [DiscInfo.EntryPoint(pid: 0x1011, time: 53_999_616, offset: 768),
                      DiscInfo.EntryPoint(pid: 0x1011, time: 54_093_824, offset: 192 * 4000),
                      DiscInfo.EntryPoint(pid: 0x1011, time: 54_183_424, offset: 192 * 140_000),
                      DiscInfo.EntryPoint(pid: 0x1011, time: (1 << 33) - 512, offset: 192 * 9_000_000)]
        #expect(DiscInfo.entryPoints(blurayClipInfo: clipInfo(points)) == points)
        #expect(DiscInfo.entryPoints(blurayClipInfo: Data("HDMV0200".utf8)).isEmpty)
        #expect(DiscInfo.entryPoints(blurayClipInfo: Data(repeating: 0, count: 100)).isEmpty)
    }

    @Test("a clip file cut at any length, or with random bytes in its map, is read without a crash and gives no entry it does not hold")
    func truncated() {
        let points = (0..<40).map { DiscInfo.EntryPoint(pid: 0x1011, time: Int64($0) * 90_112, offset: Int64($0) * 192 * 1_000) }
        let whole = clipInfo(points)
        #expect(DiscInfo.entryPoints(blurayClipInfo: whole) == points)
        for length in 0..<whole.count {
            let read = DiscInfo.entryPoints(blurayClipInfo: whole.prefix(length))
            #expect(read.count <= points.count && Array(points.prefix(read.count)) == read, "cut at \(length)")
        }
        var generator = SplitMix64(state: 122)
        for _ in 0..<500 {
            var bytes = [UInt8](whole)
            for _ in 0..<4 { bytes[Int(generator.next() % UInt64(bytes.count - 16)) + 16] = UInt8(truncatingIfNeeded: generator.next()) }
            _ = DiscInfo.entryPoints(blurayClipInfo: Data(bytes))
        }
    }

    @Test("a map that fits its stream is taken: every reader jumps straight to the keyframe at or before a time")
    func fitsAndJumps() async throws {
        let m2ts = try bluRayStream()
        let source = MemorySource(m2ts)
        let points = keyframes(of: m2ts, pid: 0x100)
        #expect(points.count == 3)
        let session = try await PlaybackSession(source: MediaSource(byteSource: source),
                                                disc: DiscInfo.Facts(entryPoints: DiscInfo.entryPoints(blurayClipInfo: clipInfo(points))))
        let video = try #require(session.info.videoTracks.first)
        #expect(video.containerID == 0x100)
        let key = try #require(KeyframeIndexStore.key(for: session.source.byteSource))
        #expect(KeyframeIndexStore.shared.entryPoints(for: key)?.offsets == points.map(\.offset))

        let reader = try PacketReader(source: session.source.byteSource, cancellation: CancellationFlag())
        let index = reader.keyframeIndex(stream: video.id)
        #expect(index.compactMap(\.position) .filter { points.map(\.offset).contains($0) }.count == 3)
        let base = reader.timeBase(video.id)
        let second = index.sorted { $0.timestamp < $1.timestamp }[1].timestamp
        reader.limit(to: [video.id])
        try reader.seek(stream: video.id, to: second + base.ticks(seconds: 0.5))
        let first = try #require(try reader.next())
        #expect(first.isKeyframe && abs(first.pts - second) <= 512, "landed at \(first.pts), the keyframe is at \(second)")
    }

    @Test("a map that does not fit its stream (offsets one packet off) is left out")
    func doesNotFit() async throws {
        let m2ts = try bluRayStream(extra: 3)
        let source = MemorySource(m2ts)
        let points = keyframes(of: m2ts, pid: 0x100).map { DiscInfo.EntryPoint(pid: $0.pid, time: $0.time, offset: $0.offset + 192) }
        let session = try await PlaybackSession(source: MediaSource(byteSource: source), disc: DiscInfo.Facts(entryPoints: points))
        let key = try #require(KeyframeIndexStore.key(for: session.source.byteSource))
        #expect(KeyframeIndexStore.shared.entryPoints(for: key) == nil)
    }

    @Test("a packet agrees with an entry only when it starts a PES of the entry's PID with that time")
    func agrees() throws {
        let m2ts = try bluRayStream()
        let point = try #require(keyframes(of: m2ts, pid: 0x100).first)
        let packet = Array(m2ts[Int(point.offset)..<(Int(point.offset) + 192)])
        #expect(DiscInfo.agrees(point, packet: packet))
        #expect(!DiscInfo.agrees(DiscInfo.EntryPoint(pid: 0x101, time: point.time, offset: point.offset), packet: packet))
        #expect(!DiscInfo.agrees(DiscInfo.EntryPoint(pid: point.pid, time: point.time + 512, offset: point.offset), packet: packet))
        #expect(!DiscInfo.agrees(point, packet: Array(packet.prefix(100))))
    }
}
