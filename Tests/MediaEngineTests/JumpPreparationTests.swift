import Foundation
import Synchronization
import Testing
@testable import MediaEngine

/// A file in memory whose reads can be slowed down once the session is open, so that a build takes long enough to be overtaken.
private final class SlowWhenAsked: ByteSource, @unchecked Sendable {
    let base: DataByteSource
    let delay = Mutex<TimeInterval>(0)
    private let reads = Mutex(0)
    init(_ data: Data) { base = DataByteSource(data) }
    var length: Int64? { base.length }
    var readCount: Int { reads.withLock { $0 } }
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        reads.withLock { $0 += 1 }
        let wait = delay.withLock { $0 }
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return try base.read(at: offset, into: buffer)
    }
}

/// Reading the film where the person rests a finger on the progress bar (the app's Jira EGA-124).
@Suite("Jump preparation")
struct JumpPreparationTests {
    @Test("the piece at a prepared place is built before the player asks; the request then builds nothing")
    func prepared() async throws {
        let info = try await Fixture.probe("fixture-subs-long")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-subs-long")), info: info, cancellation: CancellationFlag())
        defer { session.close() }
        let video = try #require(info.videoTracks.first?.id)
        let last = session.plan.segments.count - 1
        try #require(last >= 1, "\(session.plan.segments.count) pieces")
        let time = session.plan.segments[last].start + 0.5
        #expect(session.piece(containing: time) == last)
        #expect(!session.isBuilt(stream: video, segment: last))

        session.prepare(at: time)
        #expect(await waitUntil(5) { session.isBuilt(stream: video, segment: last) })
        let built = session.buildCount
        session.prepare(at: time)                                  // the same place again: nothing more to read
        let data = try #require(try session.resource(path: "video-\(last).m4s"))
        #expect(!data.data.isEmpty)
        #expect(session.buildCount == built, "the request found the piece built")
    }

    @Test("a newer place stops the build of an older one; only the newest is built")
    func newestWins() async throws {
        let info = try await Fixture.probe("fixture-subs-long")
        let source = SlowWhenAsked(try Fixture.data("fixture-subs-long"))
        let session = try RemuxSession(source: source, info: info, cancellation: CancellationFlag())
        defer { session.close() }
        let video = try #require(info.videoTracks.first?.id)
        let pieces = session.plan.segments.count
        try #require(pieces >= 3, "\(pieces) pieces")
        let older = pieces - 1, newer = 1

        source.delay.withLock { $0 = 0.15 }                         // a piece now takes seconds to read
        let before = source.readCount
        session.prepare(at: session.plan.segments[older].start + 0.1)
        #expect(await waitUntil(5) { source.readCount > before }, "the older place is being read")
        session.prepare(at: session.plan.segments[newer].start + 0.1)
        source.delay.withLock { $0 = 0 }
        #expect(await waitUntil(10) { session.isBuilt(stream: video, segment: newer) })
        #expect(!session.isBuilt(stream: video, segment: older), "the older place stopped when the newer one came")
    }
}
