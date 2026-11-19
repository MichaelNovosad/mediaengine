import CoreGraphics
import Foundation
import Testing
@testable import MediaEngine

private let size = CGSize(width: 640, height: 360)

/// The picture all three tracks show: a 200 x 50 red box with a 20 x 30 white square near its left end (one transparent
/// pixel around), at (100, 250) from 0.5 s to 2.0 s and at (300, 100) from 3.0 s to 4.5 s, in a 640 x 360 frame.
@Suite("Picture subtitles (PGS, VobSub, DVB)")
struct BitmapSubtitleTests {
    private func renderer(_ track: String) async throws -> (PlaybackSession, SubtitleRenderer) {
        let session = try await PlaybackSession(url: Fixture.url("fixture-bitmap"))
        let choice = try #require(session.overlayChoices.first { $0.title.hasPrefix(track) })
        return (session, try await session.makeSubtitleRenderer(for: choice))
    }

    private func isRed(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Bool { c.a > 200 && c.r > 200 && c.g < 70 && c.b < 70 }
    private func isWhite(_ c: (r: Int, g: Int, b: Int, a: Int)) -> Bool { c.a > 200 && c.r > 200 && c.g > 200 && c.b > 200 }

    @Test("the picture is where the track puts it, in the colours it has, and only while it lasts", arguments: ["PGS", "VobSub", "DVB"])
    func shows(track: String) async throws {
        let (session, renderer) = try await renderer(track)
        defer { renderer.close(); session.close() }
        try await renderer.prepare(at: 1.0)
        let during = renderer.frame(at: 1.0, size: size)
        #expect(during.images.count == 1 && during.changed, "\(track): \(during.images.count) pictures")
        let image = Shot(during)
        let b = try #require(image.bounds(), "\(track) drew nothing")
        #expect(abs(b.minX - 101) <= 3 && abs(b.maxX - 298) <= 3 && abs(b.minY - 251) <= 3 && abs(b.maxY - 298) <= 3, "\(track): \(b)")
        #expect(isRed(image.color(250, 275)) && isWhite(image.color(116, 275)), "\(track): \(image.color(250, 275)) \(image.color(116, 275))")
        #expect(image.alpha(100, 250) < 128, "the border pixel is transparent")

        #expect(renderer.frame(at: 1.1, size: size).changed == false)
        #expect(renderer.frame(at: 0.2, size: size).images.isEmpty && renderer.frame(at: 2.5, size: size).images.isEmpty, "\(track): before and after")
        try await renderer.prepare(at: 3.5)
        let second = try #require(Shot(renderer.frame(at: 3.5, size: size)).bounds(), "\(track): second picture")
        #expect(abs(second.minX - 301) <= 3 && abs(second.minY - 101) <= 3, "\(track): \(second)")
        #expect(renderer.frame(at: 5.0, size: size).images.isEmpty)
    }

    @Test("the picture follows the size of the video on screen", arguments: ["PGS", "VobSub", "DVB"])
    func scaled(track: String) async throws {
        let (session, renderer) = try await renderer(track)
        defer { renderer.close(); session.close() }
        try await renderer.prepare(at: 1.0)
        let frame = renderer.frame(at: 1.0, size: CGSize(width: 1280, height: 720))
        let picture = try #require(frame.images.first)
        #expect(abs(picture.frame.minX - 200) <= 4 && abs(picture.frame.minY - 500) <= 4 && abs(picture.frame.width - 400) <= 6 && abs(picture.frame.height - 100) <= 4,
                "\(track): \(picture.frame)")
    }

    @Test("jumping straight to the second picture works: every display set starts on its own")
    func jump() async throws {
        let (session, renderer) = try await renderer("PGS")
        defer { renderer.close(); session.close() }
        try await renderer.prepare(at: 3.5)
        #expect(!renderer.frame(at: 3.5, size: size).images.isEmpty)
    }

    @Test("a display set in one block, as Matroska muxers store PGS, decodes like segments in separate blocks")
    func wholeDisplaySets() async throws {
        let sup = try Data(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/bitmap.sup"))
        // Segments: "PG", pts(4), dts(4), type(1), size(2), payload. Matroska keeps type, size and payload only.
        var sets: [(pts: Double, body: Data)] = []
        var cursor = 0, current = Data(), start = 0.0
        while cursor + 13 <= sup.count {
            let pts = Double(sup[cursor + 2...cursor + 5].reduce(0) { $0 << 8 | UInt32($1) }) / 90_000
            let kind = sup[cursor + 10], length = Int(sup[cursor + 11]) << 8 | Int(sup[cursor + 12])
            if current.isEmpty { start = pts }
            current += sup[cursor + 10..<cursor + 13 + length]
            cursor += 13 + length
            if kind == 0x80 { sets.append((start, current)); current = Data() }
        }
        #expect(sets.count == 4, "two pictures and two clears")
        let reader = try PacketReader(source: FileByteSource(url: Fixture.url("fixture-bitmap")), cancellation: CancellationFlag())
        let backend = try #require(BitmapBackend(parameters: reader.parameters(2), videoSize: size))
        backend.add(sets.map { OverlayEvent(data: $0.body, start: $0.pts, duration: 0) })
        let shown = backend.render(at: 1.0, size: size)
        #expect(shown.images.count == 1 && abs((shown.images.first?.frame.minX ?? 0) - 100) < 1)
        #expect(backend.render(at: 2.5, size: size).images.isEmpty && backend.render(at: 3.5, size: size).images.count == 1)
    }

    /// The segments of `Fixtures/src/bitmap.sup` one by one, each with its own time, as a Blu-ray transport stream carries them:
    /// the number of the display set (0 and 2 are the pictures, 1 and 3 their clears), the segment's type and the block.
    private func segments() throws -> [(set: Int, kind: UInt8, event: OverlayEvent)] {
        let sup = try Data(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/bitmap.sup"))
        var result: [(set: Int, kind: UInt8, event: OverlayEvent)] = []
        var cursor = 0, set = 0
        while cursor + 13 <= sup.count {
            let pts = Double(sup[cursor + 2...cursor + 5].reduce(0) { $0 << 8 | UInt32($1) }) / 90_000
            let kind = sup[cursor + 10], length = Int(sup[cursor + 11]) << 8 | Int(sup[cursor + 12])
            result.append((set, kind, OverlayEvent(data: Data(sup[cursor + 10..<cursor + 13 + length]), start: pts, duration: 0)))
            cursor += 13 + length
            if kind == 0x80 { set += 1 }
        }
        return result
    }

    private func pgsBackend() throws -> BitmapBackend {
        let reader = try PacketReader(source: FileByteSource(url: Fixture.url("fixture-bitmap")), cancellation: CancellationFlag())
        return try #require(BitmapBackend(parameters: reader.parameters(2), videoSize: size))
    }

    @Test("after a jump, the rest of a display set whose start was not read does not bring back the picture shown before the jump")
    func jumpIntoTheMiddleOfADisplaySet() throws {
        let parts = try segments()
        #expect(Set(parts.map(\.set)) == [0, 1, 2, 3], "two pictures and two clears")
        let backend = try pgsBackend()
        backend.add(parts.filter { $0.set == 0 }.map(\.event))                 // the first picture, on screen when the person jumps
        var loaded = TimeRanges()
        loaded.insert(0...1.2)
        #expect(backend.render(at: 1.0, size: size, loaded: loaded).images.count == 1)

        // The window after the jump begins in the middle of the second picture's display set: its composition was not read. Its end
        // segment drew the first picture's composition again (the app's owner, 2026-11-19, Lost in Translation).
        let second = parts.filter { $0.set == 2 }
        #expect(second.first?.kind == 0x16, "a display set begins with its composition")
        backend.add(second.dropFirst().map(\.event))
        loaded.insert(2.9...6)
        #expect(backend.render(at: 3.5, size: size, loaded: loaded).images.isEmpty, "nothing from before the jump")

        // Read whole (the next window, or the stretch before it read from the file), the display set shows its own picture.
        backend.add(second.map(\.event))
        let shown = backend.render(at: 3.5, size: size, loaded: loaded)
        #expect(shown.images.count == 1 && abs((shown.images.first?.frame.minX ?? 0) - 300) < 2, "\(shown.images.map(\.frame))")
    }

    @Test("a picture without an end of its own is not drawn across a stretch whose blocks were never read")
    func openEndedOnlyOverWhatWasRead() throws {
        let backend = try pgsBackend()
        backend.add(try segments().filter { $0.set == 0 }.map(\.event))
        var loaded = TimeRanges()
        loaded.insert(0...1.5)
        #expect(backend.render(at: 1.0, size: size, loaded: loaded).images.count == 1)
        loaded.insert(9...11)
        #expect(backend.render(at: 10, size: size, loaded: loaded).images.isEmpty, "its clear may lie in the stretch not read")
        #expect(backend.render(at: 10, size: size, loaded: .everything).images.count == 1, "everything read and no clear: it stays")
    }

    @Test("segments of a Blu-ray stream given one by one, in the file's order, draw both pictures and their clears")
    func segmentBySegment() throws {
        let backend = try pgsBackend()
        backend.add(try segments().map(\.event))
        #expect(backend.render(at: 1.0, size: size).images.count == 1 && backend.render(at: 2.5, size: size).images.isEmpty)
        #expect(backend.render(at: 3.5, size: size).images.count == 1 && backend.render(at: 5.0, size: size).images.isEmpty)
    }

    @Test("damaged picture blocks do not crash the decoder", arguments: [2, 3, 4])
    func damaged(stream: Int) throws {
        // Many rounds with a fixed seed: the same damage every run, so a crash can be reproduced.
        for round in 0..<60 { try damage(stream: stream, seed: UInt64(round) &* 31 &+ UInt64(stream)) }
    }

    private func damage(stream: Int, seed: UInt64) throws {
        let reader = try PacketReader(source: FileByteSource(url: Fixture.url("fixture-bitmap")), cancellation: CancellationFlag())
        let backend = try #require(BitmapBackend(parameters: reader.parameters(stream), videoSize: size))
        var generator = SplitMix64(state: seed)
        var events: [OverlayEvent] = []
        while let packet = try reader.next() {
            guard packet.stream == stream else { continue }
            var data = packet.data
            for _ in 0..<4 where !data.isEmpty { data[Int.random(in: 0..<data.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator) }
            events.append(OverlayEvent(data: data, start: reader.timeBase(stream).seconds(packet.pts), duration: 1))
        }
        events.append(OverlayEvent(data: Data((0..<400).map { _ in UInt8.random(in: 0...255, using: &generator) }), start: 4, duration: 1))
        events.append(OverlayEvent(data: Data(), start: 5, duration: 1))
        backend.add(events)
        for t in stride(from: 0.0, through: 6.0, by: 0.5) { _ = backend.render(at: t, size: size) }
    }
}
