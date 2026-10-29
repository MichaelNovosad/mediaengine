import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

private let size = CGSize(width: 640, height: 360)

@Suite("Overlay subtitles in a session")
struct OverlayChoiceTests {
    @Test("ASS tracks are offered for the overlay with the same names as in the player's menu; text tracks are not")
    func assChoices() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-anime"))
        defer { session.close() }
        let overlay = session.overlayChoices
        #expect(overlay.map(\.title) == session.subtitleChoices.map(\.title) && overlay.count == 2 && overlay.allSatisfy { !$0.isBitmap })
        let multi = try await PlaybackSession(url: Fixture.url("fixture-multi"))
        defer { multi.close() }
        #expect(multi.subtitleChoices.count == 3 && multi.overlayChoices.map(\.title) == multi.subtitleChoices.map(\.title),
                "SubRip is shown by the player, and the engine can draw it too (the software path has no system subtitles)")
    }

    @Test("picture tracks are offered for the overlay only; the player's menu does not list them")
    func bitmapChoices() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-bitmap"))
        defer { session.close() }
        #expect(session.subtitleChoices.isEmpty)
        let overlay = session.overlayChoices
        #expect(overlay.map { $0.title.components(separatedBy: " - [").first ?? $0.title } == ["PGS", "VobSub", "DVB"] && overlay.allSatisfy(\.isBitmap), "\(overlay.map(\.title))")
        #expect(overlay.map(\.codec) == ["PGS", "VobSub", "DVB subtitles"], "\(overlay.map(\.codec))")
        #expect(overlay[1].language?.languageCode?.identifier == "ja")
    }

    @Test("a track that cannot be drawn (an audio track) is refused")
    func refused() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-multi"))
        defer { session.close() }
        await #expect(throws: MediaError.self) { _ = try await session.makeSubtitleRenderer(for: session.audioChoices[0]) }
    }

    @Test("external subtitle files of every text format join the overlay choices")
    func externalChoices() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ass-fx"))
        defer { session.close() }
        try session.add(SubtitleTrack(data: Data(assScript(["Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,x"]).utf8), name: "Film.en.ass"))
        try session.add(SubtitleTrack(data: Data("1\n00:00:01,000 --> 00:00:02,000\nplain\n".utf8), name: "Film.de.srt"))
        let overlay = session.overlayChoices
        #expect(overlay.count == 3 && overlay[1].isExternal && overlay[1].id == ServedTracks.externalSubtitleBase && overlay[2].isExternal, "\(overlay)")
        #expect(session.subtitleChoices.count == 3, "all three are text for the player")
    }
}

@Suite("Overlay renderer: ASS from a container")
struct ASSOverlayTests {
    private func renderer() async throws -> (PlaybackSession, SubtitleRenderer) {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ass-fx"))
        return (session, try await session.makeSubtitleRenderer(for: session.overlayChoices[0]))
    }

    @Test("blocks of the attached font appear where the event puts them, and only while it lasts")
    func shows() async throws {
        let (session, renderer) = try await renderer()
        defer { renderer.close(); session.close() }
        try await renderer.prepare(at: 1.0)
        let during = Shot(renderer.frame(at: 1.0, size: size))
        let runs = during.columnRuns()
        #expect(runs.count == 3 && during.fill > 0.85, "\(runs), fill \(during.fill)")
        let b = try #require(during.bounds())
        #expect(abs(b.minX - 20) <= 6 && abs(b.minY - 20) <= 8, "\(b)")
        #expect(Shot(renderer.frame(at: 0.2, size: size)).isEmpty && Shot(renderer.frame(at: 2.8, size: size)).isEmpty)
    }

    @Test("karaoke runs on the player's time")
    func karaoke() async throws {
        let (session, renderer) = try await renderer()
        defer { renderer.close(); session.close() }
        try await renderer.prepare(at: 3.5)
        func sample(_ t: Double) throws -> (first: Int, second: Int) {
            let image = Shot(renderer.frame(at: t, size: size))
            let runs = image.columnRuns()
            #expect(runs.count == 6, "\(runs)")
            let y = try #require(image.bounds()).minY + 15
            return (image.color((runs[0].0 + runs[0].1) / 2, y).g, image.color((runs[3].0 + runs[3].1) / 2, y).g)
        }
        let early = try sample(3.5), late = try sample(4.5)
        #expect(early.first == 255 && early.second == 0 && late.second == 255, "\(early) \(late)")
    }

    @Test("a system font is used where the style names one, and the frame says whether it changed")
    func systemFontAndChange() async throws {
        let (session, renderer) = try await renderer()
        defer { renderer.close(); session.close() }
        try await renderer.prepare(at: 5.2)
        let first = renderer.frame(at: 5.2, size: size)
        let hello = try #require(Shot(first).bounds())                  // style "Plain": Helvetica, bottom centre, with an outline
        #expect(first.changed && abs((hello.minX + hello.maxX) / 2 - 320) < 30 && hello.minY > 250 && hello.maxY - hello.minY < 60, "\(hello)")
        #expect(renderer.frame(at: 5.3, size: size).changed == false, "same subtitle, nothing to redraw")
        let bigger = renderer.frame(at: 5.3, size: CGSize(width: 1280, height: 720))
        #expect(bigger.changed && Shot(bigger).bounds().map { $0.minX > 400 } == true, "a new size draws again")
        let ended = renderer.frame(at: 5.9, size: CGSize(width: 1280, height: 720))
        #expect(ended.images.isEmpty && ended.changed)
    }

    @Test("jumping back and forth works: each time shows what it should")
    func seeking() async throws {
        let (session, renderer) = try await renderer()
        defer { renderer.close(); session.close() }
        try await renderer.prepare(at: 5.2)
        #expect(!Shot(renderer.frame(at: 5.2, size: size)).isEmpty)
        try await renderer.prepare(at: 1.0)
        #expect(Shot(renderer.frame(at: 1.0, size: size)).columnRuns().count == 3)
        try await renderer.prepare(at: 3.5)
        #expect(Shot(renderer.frame(at: 3.5, size: size)).columnRuns().count == 6)
    }

    @Test("without waiting, the frame turns up on its own once the file has been read")
    func background() async throws {
        let (session, renderer) = try await renderer()
        defer { renderer.close(); session.close() }
        // Eventually, not quickly: under a sanitizer with the whole suite running in parallel, reading the file takes seconds.
        let deadline = ContinuousClock.now + .seconds(30)
        var shown = false
        while ContinuousClock.now < deadline, !shown {
            shown = !renderer.frame(at: 1.0, size: size).images.isEmpty
            if !shown { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(shown)
    }

    @Test("after close the frames are empty")
    func closed() async throws {
        let (session, renderer) = try await renderer()
        defer { session.close() }
        try await renderer.prepare(at: 1.0)
        renderer.close()
        #expect(renderer.frame(at: 1.0, size: size).images.isEmpty)
    }

    @Test("the anime fixture's two tracks draw too (its font is a stub, the system's takes over)")
    func anime() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-anime"))
        defer { session.close() }
        for choice in session.overlayChoices {
            let renderer = try await session.makeSubtitleRenderer(for: choice)
            defer { renderer.close() }
            var any = false
            for t in stride(from: 0.2, through: 2.8, by: 0.3) {
                try await renderer.prepare(at: t)
                any = any || !renderer.frame(at: t, size: size).images.isEmpty
            }
            #expect(any, "\(choice.title) never showed anything")
        }
    }
}

@Suite("Overlay renderer: ASS file")
struct ExternalASSOverlayTests {
    private let events = ["Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\pos(0,0)}ABC"]

    @Test("an external ASS file is drawn with the fonts of the video file, and its delay moves it")
    func drawn() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ass-fx"))
        defer { session.close() }
        try session.add(SubtitleTrack(data: Data(assScript(events).utf8), name: "Film.en.ass", delay: 2))
        let renderer = try await session.makeSubtitleRenderer(for: session.overlayChoices[1])
        defer { renderer.close() }
        #expect(renderer.frame(at: 1.5, size: size).images.isEmpty, "delayed by two seconds: not yet")
        let shown = Shot(renderer.frame(at: 3.5, size: size))
        #expect(shown.columnRuns().count == 3 && shown.fill > 0.85, "attached font used")
        #expect(renderer.frame(at: 4.5, size: size).images.isEmpty)
    }
}

/// Blocks served from memory, with a record of what was asked.
private final class FakeEvents: OverlayEventSource, @unchecked Sendable {
    let calls = Mutex<[(Double, Double)]>([])
    let length: Int
    init(length: Int) { self.length = length }

    func events(from: Double, to: Double) throws -> [OverlayEvent] {
        calls.withLock { $0.append((from, to)) }
        // One block a second: "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text".
        return (max(0, Int(from.rounded(.up)))..<min(length, Int(to.rounded(.up)))).map { second in
            OverlayEvent(data: Data("\(second),0,Default,,0,0,0,,{\\pos(0,0)}A".utf8), start: Double(second), duration: 0.9)
        }
    }
}

@Suite("Overlay renderer: loading windows")
struct OverlayWindowTests {
    private func make(_ source: FakeEvents, offset: Double = 0) throws -> SubtitleRenderer {
        let script = assScript([])
        let header = String(script[..<script.range(of: "[Events]")!.lowerBound]) + "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        let backend = try #require(ASSBackend(header: Data(header.utf8), fonts: try blockFont(), videoSize: size))
        return SubtitleRenderer(backend: backend, loader: source, cancellation: CancellationFlag(), offset: { offset })
    }

    @Test("a window reaches back for blocks still on screen and ahead for the next ones; asking again inside it reads nothing")
    func window() async throws {
        let source = FakeEvents(length: 1000)
        let renderer = try make(source)
        defer { renderer.close() }
        try await renderer.prepare(at: 100)
        #expect(source.calls.withLock { $0.map(\.0) } == [85] && source.calls.withLock { $0.map(\.1) } == [145])
        try await renderer.prepare(at: 110)
        try await renderer.prepare(at: 120)
        #expect(source.calls.withLock { $0.count } == 1, "inside the loaded window and far from its end")
        #expect(!Shot(renderer.frame(at: 100.5, size: size)).isEmpty)
        try await renderer.prepare(at: 140)
        #expect(source.calls.withLock { $0.last.map { $0.0 == 145 } } == true, "near the end: continues where the window stopped")
    }

    @Test("a jump far away starts a new window; going back inside an old one is cheap")
    func jumps() async throws {
        let source = FakeEvents(length: 1000)
        let renderer = try make(source)
        defer { renderer.close() }
        try await renderer.prepare(at: 500)
        try await renderer.prepare(at: 100)
        #expect(source.calls.withLock { $0.count } == 2)
        #expect(!Shot(renderer.frame(at: 100.5, size: size)).isEmpty && Shot(renderer.frame(at: 500.5, size: size)).isEmpty == false)
        try await renderer.prepare(at: 3)                        // near the start: nothing earlier to look for
        #expect(source.calls.withLock { $0.last.map { $0.0 == 0 } } == true)
    }

    @Test("the same block read twice does not draw twice")
    func noDuplicates() async throws {
        let source = FakeEvents(length: 1000)
        let renderer = try make(source)
        defer { renderer.close() }
        try await renderer.prepare(at: 100)
        try await renderer.prepare(at: 90)                        // overlaps the first window: blocks 80...100 are read again
        let image = Shot(renderer.frame(at: 95.5, size: size))
        #expect(image.columnRuns().count == 1 && image.fill > 0.85)
    }

    @Test("the player's time is shifted by the offset")
    func offset() async throws {
        let source = FakeEvents(length: 1000)
        let renderer = try make(source, offset: 10)
        defer { renderer.close() }
        try await renderer.prepare(at: 50)
        #expect(source.calls.withLock { $0.first?.0 } == 25, "file time 40, less the look-back")
        #expect(!Shot(renderer.frame(at: 50.5, size: size)).isEmpty)
    }
}

@Suite("Overlay renderer: play lists")
struct PlayListOverlayTests {
    private let openingUID = "a1a2a3a4a5a6a7a8a9aaabacadaeafb0"

    private func shown(_ renderer: SubtitleRenderer, _ times: [Double]) async throws -> [Bool] {
        var result: [Bool] = []
        for t in times {
            try await renderer.prepare(at: t)
            result.append(!renderer.frame(at: t, size: size).images.isEmpty)
        }
        return result
    }

    @Test("subtitles come from the file each part is read from, at the part's place on the play list's timeline")
    func followsPlayList() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ordered"))
        defer { session.close() }
        try session.link(LinkedSegment(uid: openingUID), to: MediaSource(byteSource: FileByteSource(url: Fixture.url("fixture-linked-opening"))))
        let renderer = try await session.makeSubtitleRenderer(for: session.overlayChoices[0])
        defer { renderer.close() }
        // Opening (the other file) 0-2 s: a block at 0.5-1.5. Second half 2-4 s: 2.5-3.5. First half 4-6 s: 4.5-5.5.
        let result = try await shown(renderer, [0.2, 1.0, 1.8, 2.2, 3.0, 3.8, 4.2, 5.0, 5.8])
        #expect(result == [false, true, false, false, true, false, false, true, false], "\(result)")
    }

    @Test("a part that is not available leaves its subtitles out, and the rest close up")
    func withoutTheOpening() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ordered"))
        defer { session.close() }
        let renderer = try await session.makeSubtitleRenderer(for: session.overlayChoices[0])
        defer { renderer.close() }
        // Second half 0-2 s on the shorter timeline: 0.5-1.5; first half 2-4 s: 2.5-3.5.
        let result = try await shown(renderer, [0.2, 1.0, 1.8, 2.2, 3.0, 3.8])
        #expect(result == [false, true, false, false, true, false], "\(result)")
    }
}

@Suite("Overlay renderer: SubRip and WebVTT")
struct TextOverlayTests {
    @Test("an external SRT file is drawn at the bottom centre, with the cues' times and its delay")
    func external() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { session.close() }
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i> & {goodbye}\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond\nline\n"
        try session.add(SubtitleTrack(data: Data(srt.utf8), name: "Film.en.srt", delay: 0.5))
        let choice = try #require(session.overlayChoices.first { $0.isExternal })
        let renderer = try await session.makeSubtitleRenderer(for: choice)
        defer { renderer.close() }
        #expect(renderer.frame(at: 1.2, size: size).images.isEmpty, "the delay moves the first cue to 1.5 s")
        let shown = Shot(renderer.frame(at: 1.8, size: size))
        let b = try #require(shown.bounds(threshold: 32))
        #expect(abs((b.minX + b.maxX) / 2 - 320) < 40 && b.minY > 250, "bottom centre: \(b)")
        #expect(renderer.frame(at: 2.8, size: size).images.isEmpty)
        let second = Shot(renderer.frame(at: 3.8, size: size))
        let two = try #require(second.bounds(threshold: 32))
        #expect(two.maxY - two.minY > b.maxY - b.minY, "two lines are taller than one")
    }

    @Test("a SubRip track inside the file is drawn with its own times")
    func embedded() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { session.close() }
        let choice = try #require(session.overlayChoices.first { $0.codec == "SubRip" })
        let renderer = try await session.makeSubtitleRenderer(for: choice)
        defer { renderer.close() }
        try await renderer.prepare(at: 0.5)
        #expect(!renderer.frame(at: 0.5, size: size).images.isEmpty && renderer.frame(at: 0.1, size: size).images.isEmpty)
        #expect(!renderer.frame(at: 2.0, size: size).images.isEmpty && renderer.frame(at: 1.5, size: size).images.isEmpty, "between the cues")
    }
}
