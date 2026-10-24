import AVFoundation
import Darwin
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

/// Small, deterministic pseudo-random generator so a failing mutation can be reproduced from its seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Everything a player would ask of a damaged file: probe, open a session, fetch every playlist and segment.
/// The only acceptable outcomes are results or errors, never a crash or a hang.
@discardableResult
private func exercise(_ data: Data) async -> Int {
    var produced = 0
    guard let info = try? await MediaSource(byteSource: DataByteSource(data)).probe() else { return 0 }
    guard let session = try? RemuxSession(source: DataByteSource(data), info: info, cancellation: CancellationFlag()) else { return 0 }
    defer { session.close() }
    _ = try? session.resource(path: "master.m3u8")
    for track in info.tracks where session.hasOutput(track.id) {
        let prefix = track.kind == .video ? "video" : "audio-\(track.id)"
        _ = try? session.resource(path: prefix == "video" ? "video.m3u8" : "\(prefix).m3u8")
        _ = try? session.resource(path: "\(prefix)-init.mp4")
        for index in session.plan.segments.indices.prefix(8) {
            if (try? session.resource(path: "\(prefix)-\(index).m4s")) != nil { produced += 1 }
        }
        // Out-of-order request, as after a seek.
        if let last = session.plan.segments.indices.last { _ = try? session.resource(path: "\(prefix)-\(last).m4s") }
    }
    return produced
}

@Suite("Damaged files", .timeLimit(.minutes(3)))
struct DamagedFileTests {
    private static let names = ["fixture-basic", "fixture-opus-vorbis", "fixture-hevc", "fixture-bframes"]

    @Test("truncated at many points", arguments: names)
    func truncation(name: String) async throws {
        let data = try Fixture.data(name)
        var generator = SplitMix64(state: 1)
        var cuts = [0, 1, 4, 16, 64, 200, 1_000, 4_000, data.count - 1]
        cuts += (0..<40).map { _ in Int.random(in: 0..<data.count, using: &generator) }
        for cut in cuts { await exercise(data.prefix(cut)) }
    }

    @Test("bytes flipped in the header area, where the structure lives", arguments: names)
    func headerCorruption(name: String) async throws {
        let original = try Fixture.data(name)
        var generator = SplitMix64(state: 2)
        for round in 0..<60 {
            var data = original
            for _ in 0..<Int.random(in: 1...24, using: &generator) {
                data[Int.random(in: 0..<min(6_000, data.count), using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = round
            await exercise(data)
        }
    }

    @Test("bytes flipped anywhere in the file", arguments: names)
    func randomCorruption(name: String) async throws {
        let original = try Fixture.data(name)
        var generator = SplitMix64(state: 3)
        var reached = 0
        for _ in 0..<40 {
            var data = original
            for _ in 0..<Int.random(in: 1...64, using: &generator) {
                data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if await exercise(data) > 0 { reached += 1 }
        }
        #expect(reached >= 20, "only \(reached) of 40 damaged files got as far as producing segments")
    }

    @Test("ranges overwritten with zeros or 0xFF", arguments: names)
    func zeroedRanges(name: String) async throws {
        let original = try Fixture.data(name)
        var generator = SplitMix64(state: 4)
        var reached = 0
        for _ in 0..<40 {
            var data = original
            let start = Int.random(in: 0..<data.count, using: &generator)
            let length = min(Int.random(in: 1...20_000, using: &generator), data.count - start)
            let fill: UInt8 = Bool.random(using: &generator) ? 0 : 0xFF
            data.replaceSubrange(start..<(start + length), with: Data(repeating: fill, count: length))
            if await exercise(data) > 0 { reached += 1 }
        }
        #expect(reached >= 20, "only \(reached) of 40 damaged files got as far as producing segments")
    }

    /// Reads normally until `breakDown()` is called; after that, everything past the first half of the file fails,
    /// like a network connection that drops after the file was opened.
    final class Flaky: ByteSource {
        private let data: Data
        private let broken = Mutex(false)
        init(_ data: Data) { self.data = data }
        var length: Int64? { Int64(data.count) }
        func breakDown() { broken.withLock { $0 = true } }
        func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            if broken.withLock({ $0 }), offset > Int64(data.count) / 2 { throw MediaError.network(detail: "connection lost") }
            return try DataByteSource(data).read(at: offset, into: buffer)
        }
    }

    @Test("a source that fails after opening reports an error instead of a short file")
    func failingSource() async throws {
        let source = Flaky(try Fixture.data("fixture-opus-vorbis"))
        let info = try await MediaSource(byteSource: source).probe()
        let session = try RemuxSession(source: source, info: info, cancellation: CancellationFlag())
        defer { session.close() }
        source.breakDown()
        #expect(throws: (any Error).self) { _ = try session.resource(path: "video-2.m4s") }
        #expect(try session.resource(path: "video-0.m4s") != nil)                 // the healthy half still works
    }
}

@Suite("Lifetime")
struct LifetimeTests {
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    /// Waits for a weak reference to clear; background read-ahead may hold the object for a moment after close.
    private func released<T: AnyObject>(_ box: WeakBox<T>) async -> Bool {
        for _ in 0..<100 {
            if box.value == nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test("a closed remux session is freed")
    func remuxSession() async throws {
        var weakSession: WeakBox<RemuxSession>?
        do {
            let source = try await MediaSource(url: Fixture.url("fixture-basic"))
            let session = try RemuxSession(source: source.byteSource, info: try await source.probe(), cancellation: CancellationFlag())
            weakSession = WeakBox(session)
            _ = try session.resource(path: "video-0.m4s")
            _ = try session.resource(path: "audio-2-0.m4s")
            session.close()
        }
        #expect(await released(try #require(weakSession)), "RemuxSession is still alive after close(): a retain cycle")
    }

    @Test("a playback session is freed once the player item is gone")
    @MainActor
    func playbackSession() async throws {
        var weakSession: WeakBox<PlaybackSession>?
        do {
            let session = try await PlaybackSession(url: Fixture.url("fixture-hevc"))
            weakSession = WeakBox(session)
            var item: AVPlayerItem? = try await session.makePlayerItem()
            #expect(item != nil)
            item = nil
        }
        #expect(await released(try #require(weakSession)), "PlaybackSession is still alive after its item was released: a retain cycle")
    }
}
