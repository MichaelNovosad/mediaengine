import Foundation
import Synchronization
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// A source like a network share: every byte asked for is counted (a `DataByteSource` or a file would be taken as local).
private final class CountingSource: ByteSource {
    let base: DataByteSource
    private let asked = Mutex<Int64>(0)
    private let sparse = Mutex<Int64>(0)
    private let delay: Double

    init(_ data: Data, delay: Double = 0) {
        base = DataByteSource(data)
        self.delay = delay
    }

    var length: Int64? { base.length }
    var askedBytes: Int64 { asked.withLock { $0 } }
    var sparseBytes: Int64 { sparse.withLock { $0 } }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let count = try base.read(at: offset, into: buffer)
        asked.withLock { $0 += Int64(count) }
        return count
    }

    func readSparse(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try base.read(at: offset, into: buffer)
        sparse.withLock { $0 += Int64(count) }
        return count
    }
}

/// A clock the test moves.
private final class TestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
}

private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
}

/// Reads `count` bytes at `offset` the way FFmpeg's I/O does: as many reads as it takes.
private func readAll(_ cache: SharedReadCache, at offset: Int64, count: Int, reader: Int?) throws -> Data {
    var result = Data(count: count)
    var filled = 0
    try result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
        while filled < count {
            let read = try cache.read(at: offset + Int64(filled), into: UnsafeMutableRawBufferPointer(rebasing: bytes[filled..<count]), reader: reader)
            if read == 0 { break }
            filled += read
        }
    }
    return result.prefix(filled)
}

@Suite("A film's readers share what was read from a network source")
struct SharedReadCacheTests {
    @Test("two readers, one as far ahead as the cache allows: every byte is fetched once, with less room than plain LRU would need")
    func fetchesOnce() throws {
        let data = pattern(8 << 20)
        let source = CountingSource(data)
        let cache = SharedReadCache(source: source, chunkSize: 256 << 10, sharedBudget: 4 << 20, soloBudget: 1 << 20)
        let ahead = cache.register(), behind = cache.register()
        let lead = Int(cache.leadBytes)                                   // 3 MB: plain LRU would need twice that
        let step = 64 << 10
        // Both open the file at its start, as the picture reader and the sound do; then one runs ahead.
        _ = try readAll(cache, at: 0, count: step, reader: ahead)
        _ = try readAll(cache, at: 0, count: step, reader: behind)
        var front = step, back = step
        while back < data.count {
            if front < data.count {
                let read = try readAll(cache, at: Int64(front), count: min(step, data.count - front), reader: ahead)
                #expect(read == data[front..<(front + read.count)])
                front += read.count
            }
            if front - back >= lead || front >= data.count {
                let read = try readAll(cache, at: Int64(back), count: min(step, data.count - back), reader: behind)
                #expect(read == data[back..<(back + read.count)])
                back += read.count
            }
        }
        #expect(source.askedBytes == Int64(data.count), "fetched \(source.askedBytes) for \(data.count)")
        #expect(cache.keptBytes <= 4 << 20)
    }

    @Test("one reader alone keeps little")
    func oneReader() throws {
        let data = pattern(6 << 20)
        let source = CountingSource(data)
        let cache = SharedReadCache(source: source, chunkSize: 256 << 10, sharedBudget: 4 << 20, soloBudget: 1 << 20)
        let reader = cache.register()
        #expect(try readAll(cache, at: 0, count: data.count, reader: reader) == data)
        #expect(cache.keptBytes <= 1 << 20 && source.askedBytes == Int64(data.count))
    }

    @Test("a reader that stopped reading holds nothing back, and one that is gone counts no more")
    func idleReader() throws {
        let data = pattern(6 << 20)
        let clock = TestClock()
        let cache = SharedReadCache(source: CountingSource(data), chunkSize: 256 << 10, sharedBudget: 4 << 20, soloBudget: 1 << 20,
                                    idle: .seconds(20), clock: { clock.now })
        let reader = cache.register(), stale = cache.register()
        _ = try readAll(cache, at: 0, count: 64 << 10, reader: stale)
        clock.advance(.seconds(30))
        _ = try readAll(cache, at: 0, count: 3 << 20, reader: reader)
        #expect(cache.keptBytes <= 1 << 20, "a stale reader kept \(cache.keptBytes)")
        let other = cache.register()
        _ = try readAll(cache, at: 0, count: 64 << 10, reader: other)
        cache.unregister(other)
        _ = try readAll(cache, at: 3 << 20, count: 2 << 20, reader: reader)
        #expect(cache.keptBytes <= 1 << 20)
    }

    @Test("readers that miss the same chunk at once fetch it once")
    func sameChunkOnce() async throws {
        let data = pattern(1 << 20)
        let source = CountingSource(data, delay: 0.02)
        let cache = SharedReadCache(source: source, chunkSize: 256 << 10, sharedBudget: 4 << 20, soloBudget: 4 << 20)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 {
                group.addTask { try readAll(cache, at: 1000, count: 4000, reader: nil) }
            }
            for try await read in group { #expect(read == data[1000..<5000]) }
        }
        #expect(source.askedBytes == 256 << 10)
    }

    @Test("a read stops at its chunk's end, the end of the file gives nothing, and a sparse read goes to the source uncached")
    func edges() throws {
        let data = pattern((1 << 20) + 100)
        let source = CountingSource(data)
        let cache = SharedReadCache(source: source, chunkSize: 256 << 10, sharedBudget: 4 << 20, soloBudget: 4 << 20)
        var buffer = [UInt8](repeating: 0, count: 1000)
        let count = try buffer.withUnsafeMutableBytes { try cache.read(at: (256 << 10) - 10, into: $0) }
        #expect(count == 10 && Data(buffer.prefix(10)) == data[((256 << 10) - 10)..<(256 << 10)])
        #expect(try readAll(cache, at: 1 << 20, count: 500, reader: nil) == data[(1 << 20)...])
        let end = try buffer.withUnsafeMutableBytes { try cache.read(at: Int64(data.count), into: $0) }
        #expect(end == 0)
        let before = source.askedBytes
        _ = try buffer.withUnsafeMutableBytes { try cache.readSparse(at: 600_000, into: $0) }
        #expect(source.sparseBytes == 1000 && source.askedBytes == before)
        cache.close()
        #expect(cache.keptBytes == 0)
    }

    @Test("the sound's lead: what the shared room holds less one piece, between 6 and 30 s")
    func soundLead() {
        #expect(abs(RemuxSession.soundLead(byteRate: 5_600_000, room: 72_000_000) - (72.0 / 5.6 - 6)) < 0.01)
        #expect(RemuxSession.soundLead(byteRate: 1_000_000, room: 72_000_000) == 30)
        #expect(RemuxSession.soundLead(byteRate: 40_000_000, room: 72_000_000) == 6)
        #expect(RemuxSession.soundLead(byteRate: 0, room: 72_000_000) == 30)
    }

    @Test("a session puts a network source behind the cache and leaves a local file alone")
    func sessionWraps() async throws {
        let data = try Fixture.data("fixture-basic")
        let network = try await PlaybackSession(source: MediaSource(byteSource: CountingSource(data)))
        #expect(network.source.byteSource is SharedReadCache)
        let local = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        #expect(!(local.source.byteSource is SharedReadCache))
    }

    @Test("the engine's own player reads a film from a network source once, picture and sound together", .enabled(if: isExtendedBuild))
    @MainActor
    func softwarePlayerReadsOnce() async throws {
        let data = try Fixture.data("fixture-avi-xvid")
        let source = CountingSource(data)
        let session = try await PlaybackSession(source: MediaSource(byteSource: source))
        let made = try await session.makeController()
        made.isMuted = true
        let player = try #require(made as? SoftwareController)
        defer { player.close() }
        player.play()
        #expect(await waitUntil(15) { player.state == .ended }, "\(player.state) at \(player.currentTime)")
        // Both readers read the whole file (the picture reader and the remuxer of the sound); before, each fetched it.
        #expect(Double(source.askedBytes) < Double(data.count) * 1.15, "fetched \(source.askedBytes) for a file of \(data.count)")
    }
}
