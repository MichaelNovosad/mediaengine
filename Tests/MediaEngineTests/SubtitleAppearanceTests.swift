import CoreGraphics
import Foundation
import Testing
@testable import MediaEngine

private let frameSize = CGSize(width: 960, height: 540)

@Suite("Subtitle size and colour")
struct SubtitleAppearanceTests {
    private func renderer() async throws -> (PlaybackSession, SubtitleRenderer) {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        try session.add(SubtitleTrack(data: Data("1\n00:00:01,000 --> 00:00:05,000\nHello world\n".utf8), name: "Film.en.srt"))
        let choice = try #require(session.overlayChoices.first { $0.isExternal })
        let renderer = try await session.makeSubtitleRenderer(for: choice)
        try await renderer.prepare(at: 2)
        return (session, renderer)
    }

    private func shot(_ renderer: SubtitleRenderer) -> Shot { Shot(renderer.frame(at: 2, size: frameSize)) }

    @Test("the size follows the setting, both ways, and the standard setting gives the file's size back")
    func size() async throws {
        let (session, renderer) = try await renderer()
        defer { renderer.close(); session.close() }
        func dims() throws -> (w: Int, h: Int) {
            let b = try #require(shot(renderer).bounds())
            return (b.maxX - b.minX + 1, b.maxY - b.minY + 1)
        }
        let normal = try dims()
        renderer.appearance = SubtitleAppearance(scale: 2)
        let big = try dims()
        #expect(Double(big.w) > Double(normal.w) * 1.7 && Double(big.h) > Double(normal.h) * 1.7, "normal \(normal), big \(big)")
        renderer.appearance = SubtitleAppearance(scale: 0.5)
        let small = try dims()
        #expect(Double(small.w) < Double(normal.w) * 0.6 && Double(small.h) < Double(normal.h) * 0.7, "normal \(normal), small \(small)")
        renderer.appearance = .standard
        let again = try dims()
        #expect(again.w == normal.w && again.h == normal.h)
    }

    private func count(_ shot: Shot, where match: (Int, Int, Int) -> Bool) -> Int {
        var total = 0
        for y in 0..<shot.height { for x in 0..<shot.width where shot.alpha(x, y) == 255 {
            let c = shot.color(x, y)
            if match(c.r, c.g, c.b) { total += 1 }
        } }
        return total
    }

    @Test("the text takes the colour that was chosen, the outline stays dark, and the file's own colour comes back")
    func color() async throws {
        let (session, renderer) = try await renderer()
        defer { renderer.close(); session.close() }
        let white = { (r: Int, g: Int, b: Int) in r > 235 && g > 235 && b > 235 }
        let yellow = { (r: Int, g: Int, b: Int) in abs(r - 0xFF) < 12 && abs(g - 0xD5) < 12 && abs(b - 0x4F) < 12 }
        let dark = { (r: Int, g: Int, b: Int) in r < 30 && g < 30 && b < 30 }
        #expect(count(shot(renderer), where: white) > 200 && count(shot(renderer), where: yellow) == 0, "plain text is white")
        renderer.appearance = SubtitleAppearance(color: 0xFFD54F)
        let tinted = shot(renderer)
        #expect(count(tinted, where: yellow) > 200 && count(tinted, where: white) == 0, "yellow text")
        #expect(count(tinted, where: dark) > 100, "the outline is still dark")
        renderer.appearance = .standard
        #expect(count(shot(renderer), where: white) > 200)
    }

    @Test("a delay moves the subtitles later or earlier, and taking it away puts them back")
    func delay() async throws {
        let (session, renderer) = try await renderer()          // the line is on screen from 1 s to 5 s
        defer { renderer.close(); session.close() }
        func shows(_ time: Double) -> Bool { !Shot(renderer.frame(at: time, size: frameSize)).isEmpty }
        try await renderer.prepare(at: 3)
        #expect(shows(2) && !shows(0.5) && !shows(5.5))
        renderer.delay = 3
        #expect(!shows(2) && shows(4.5) && shows(7) && !shows(8.5), "moved by three seconds")
        renderer.delay = -0.8
        #expect(shows(0.5) && !shows(4.5))
        renderer.delay = 0
        #expect(shows(2) && !shows(0.5))
        renderer.delay = .nan
        #expect(renderer.delay == 0, "a value that is not a number is ignored")
    }

    @Test("sizes are kept inside the range and a value that is not a number counts as the file's size")
    func range() {
        #expect(SubtitleAppearance(scale: 10).scale == 2.5 && SubtitleAppearance(scale: 0.1).scale == 0.5 && SubtitleAppearance(scale: .nan).scale == 1)
        #expect(SubtitleAppearance(color: 0x1_FF8800).color == 0xFF8800)
        #expect(SubtitleAppearance.standard.isStandard && !SubtitleAppearance(scale: 1.2).isStandard && !SubtitleAppearance(color: 0xFFFFFF).isStandard)
    }
}
