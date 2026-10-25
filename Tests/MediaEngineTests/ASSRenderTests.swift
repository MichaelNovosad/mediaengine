import CoreGraphics
import Foundation
import Testing
@testable import MediaEngine

/// A rendered subtitle frame as numbers a test can look at.
struct Shot {
    let width: Int
    let height: Int
    let rgba: [UInt8]                             // premultiplied, frame-sized, origin top left
    let isEmpty: Bool

    init(_ rendered: ASSRenderCore.Rendered?, frame: (width: Int, height: Int)) {
        self.init(images: rendered.map { [($0.image, $0.frame)] } ?? [], frame: frame)
    }

    /// Pictures placed in a frame of the given size, blended in order.
    init(images: [(CGImage, CGRect)], frame: (width: Int, height: Int)) {
        width = frame.width; height = frame.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        for (image, rect) in images {
            guard let data = image.dataProvider?.data as Data? else { continue }
            let w = image.width, h = image.height
            let ox = Int(rect.minX.rounded()), oy = Int(rect.minY.rounded())
            for y in 0..<h where oy + y >= 0 && oy + y < height {
                for x in 0..<w where ox + x >= 0 && ox + x < width {
                    let target = ((oy + y) * width + ox + x) * 4, source = (y * w + x) * 4
                    let a = Int(data[source + 3])
                    for c in 0..<4 { buffer[target + c] = UInt8(Int(data[source + c]) + (Int(buffer[target + c]) * (255 - a) + 127) / 255) }
                }
            }
        }
        rgba = buffer
        isEmpty = images.isEmpty
    }

    init(_ frame: SubtitleFrame) {
        self.init(images: frame.images.map { ($0.image, $0.frame) }, frame: (Int(frame.size.width), Int(frame.size.height)))
    }

    func alpha(_ x: Int, _ y: Int) -> Int { Int(rgba[(y * width + x) * 4 + 3]) }
    /// Straight (not premultiplied) colour of a pixel.
    func color(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4, a = Int(rgba[i + 3])
        guard a > 0 else { return (0, 0, 0, 0) }
        return ((Int(rgba[i]) * 255 + a / 2) / a, (Int(rgba[i + 1]) * 255 + a / 2) / a, (Int(rgba[i + 2]) * 255 + a / 2) / a, a)
    }

    /// The box around pixels whose alpha is at least `threshold`.
    func bounds(threshold: Int = 128) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<height { for x in 0..<width where alpha(x, y) >= threshold {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? nil : (minX, maxX, minY, maxY)
    }

    func count(alphaIn range: ClosedRange<Int>) -> Int {
        var n = 0
        for y in 0..<height { for x in 0..<width where range.contains(alpha(x, y)) { n += 1 } }
        return n
    }

    /// Fraction of the bounding box that is opaque: solid blocks are near 1, letters of an ordinary font far less.
    var fill: Double {
        guard let b = bounds() else { return 0 }
        var opaque = 0
        for y in b.minY...b.maxY { for x in b.minX...b.maxX where alpha(x, y) >= 128 { opaque += 1 } }
        return Double(opaque) / Double((b.maxX - b.minX + 1) * (b.maxY - b.minY + 1))
    }

    /// Alpha summed per column inside `[from, to]`.
    func columnProfile(from: Int, to: Int) -> [Double] {
        (from...to).map { x in (0..<height).reduce(0.0) { $0 + Double(alpha(x, $1)) } }
    }

    /// Runs of columns that hold opaque pixels, as (first, last).
    func columnRuns(threshold: Int = 128) -> [(Int, Int)] {
        var runs: [(Int, Int)] = []
        for x in 0..<width {
            let on = (0..<height).contains { alpha(x, $0) >= threshold }
            if on { if let last = runs.last, last.1 == x - 1 { runs[runs.count - 1].1 = x } else { runs.append((x, x)) } }
        }
        return runs
    }
}

/// A script with one style and the given events.
func assScript(_ events: [String], font: String = "Media Blocks", size: Int = 100, resX: Int = 640, resY: Int = 360, extra: String = "") -> String {
    """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: \(resX)
    PlayResY: \(resY)
    ScaledBorderAndShadow: yes
    YCbCr Matrix: None
    \(extra)

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,\(font),\(size),&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    \(events.joined(separator: "\n"))
    """
}

func blockFont() throws -> [(name: String, data: Data)] {
    [("BlockFont.ttf", try Data(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/BlockFont.ttf")))]
}

/// Renders the script at `seconds` into a 640 x 360 frame (or `size`).
func shot(_ script: String, at seconds: Double, size: (width: Int, height: Int) = (640, 360), fonts: [(name: String, data: Data)]? = nil) throws -> Shot {
    let core = try #require(ASSRenderCore(fonts: try fonts ?? blockFont(), storageSize: CGSize(width: size.width, height: size.height)))
    #expect(core.loadScript(Data(script.utf8)))
    return Shot(core.render(atMilliseconds: Int64(seconds * 1000), width: size.width, height: size.height).rendered, frame: size)
}

private func line(_ text: String, start: String = "0:00:01.00", end: String = "0:00:09.00") -> String {
    "Dialogue: 0,\(start),\(end),Default,,0,0,0,,\(text)"
}

@Suite("libass: what the renderer draws")
struct ASSRenderTests {
    @Test("an attached font is used: three solid blocks of the size the font says; without it the text is ordinary letters")
    func attachedFont() throws {
        let with = try shot(assScript([line("{\\pos(0,0)}ABC")]), at: 2)
        let runs = with.columnRuns()
        #expect(runs.count == 3, "\(runs)")
        let widths = runs.map { $0.1 - $0.0 + 1 }
        #expect(widths.allSatisfy { abs($0 - widths[0]) <= 1 } && with.fill > 0.85, "widths \(widths), fill \(with.fill)")
        let advance = runs[1].0 - runs[0].0
        #expect(abs(Double(widths[0]) / Double(advance) - 500.0 / 600.0) < 0.03, "block \(widths[0]) of advance \(advance)")
        let without = try shot(assScript([line("{\\pos(0,0)}ABC")]), at: 2, fonts: [])
        #expect(without.fill < 0.7, "fill \(without.fill)")
    }

    @Test("libass says which font it picked for the style")
    func fontSelection() throws {
        let core = try #require(ASSRenderCore(fonts: try blockFont(), storageSize: nil))
        #expect(core.loadScript(Data(assScript([line("ABC")]).utf8)))
        _ = core.render(atMilliseconds: 2000, width: 640, height: 360)
        #expect(core.log.all.contains { $0.contains("fontselect") && $0.contains("MediaBlocks-Regular") }, "\(core.log.all.suffix(6))")
        #expect(core.log.all.contains { $0.contains("coretext") }, "the Apple font provider is in use")
    }

    @Test("nothing is drawn before an event starts or after it ends")
    func timing() throws {
        let script = assScript([line("{\\pos(0,0)}ABC", start: "0:00:01.00", end: "0:00:02.00")])
        #expect(try shot(script, at: 0.5).isEmpty && (try shot(script, at: 1.5)).isEmpty == false && (try shot(script, at: 2.5)).isEmpty)
    }

    @Test("colours: \\c sets the primary colour (BGR order in the script)")
    func colour() throws {
        let red = try shot(assScript([line("{\\pos(0,0)\\c&H0000FF&}A")]), at: 2)
        let b = try #require(red.bounds())
        let c = red.color((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2)
        #expect(c.r == 255 && c.g == 0 && c.b == 0 && c.a == 255, "\(c)")
    }

    @Test("rotation: \\frz90 turns the box on its side")
    func rotation() throws {
        let flat = try #require(try shot(assScript([line("{\\pos(200,250)}ABC")]), at: 2).bounds())
        let turned = try #require(try shot(assScript([line("{\\pos(200,250)\\frz90}ABC")]), at: 2).bounds())
        let flatW = flat.maxX - flat.minX, flatH = flat.maxY - flat.minY
        let turnedW = turned.maxX - turned.minX, turnedH = turned.maxY - turned.minY
        #expect(flatW > flatH * 2 && turnedH > turnedW * 2, "flat \(flatW)x\(flatH), turned \(turnedW)x\(turnedH)")
        #expect(abs(Double(turnedH) - Double(flatW)) < 4 && abs(Double(turnedW) - Double(flatH)) < 4, "flat \(flat), turned \(turned)")
    }

    @Test("blur: \\blur softens the edges")
    func blur() throws {
        let sharp = try shot(assScript([line("{\\pos(100,100)}A")]), at: 2).count(alphaIn: 16...239)
        let soft = try shot(assScript([line("{\\pos(100,100)\\blur8}A")]), at: 2).count(alphaIn: 16...239)
        #expect(soft > sharp * 5 && soft > 500, "sharp \(sharp), soft \(soft)")
    }

    @Test("clip: \\clip cuts the picture to the rectangle")
    func clip() throws {
        let whole = try #require(try shot(assScript([line("{\\pos(0,0)}ABC")]), at: 2).bounds())
        let clipped = try #require(try shot(assScript([line("{\\pos(0,0)\\clip(0,0,50,360)}ABC")]), at: 2).bounds())
        #expect(whole.maxX > 150 && clipped.maxX <= 50, "whole to \(whole.maxX), clipped to \(clipped.maxX)")
    }

    @Test("vector drawings: \\p1 draws the shape at its place")
    func drawing() throws {
        let image = try shot(assScript([line("{\\pos(100,100)\\p1}m 0 0 l 100 0 100 50 0 50{\\p0}")]), at: 2)
        let b = try #require(image.bounds())
        #expect(abs(b.minX - 100) <= 1 && abs(b.maxX - 199) <= 1 && abs(b.minY - 100) <= 1 && abs(b.maxY - 149) <= 1, "\(b)")
    }

    @Test("karaoke: \\k switches a syllable from the secondary to the primary colour when it is sung")
    func karaoke() throws {
        let script = assScript([line("{\\pos(0,0)\\k100}ABC{\\k100}DEF", start: "0:00:01.00", end: "0:00:05.00")])
        func colours(at seconds: Double) throws -> (first: (r: Int, g: Int, b: Int, a: Int), second: (r: Int, g: Int, b: Int, a: Int)) {
            let image = try shot(script, at: seconds)
            let runs = image.columnRuns()
            #expect(runs.count == 6, "\(runs)")
            let y = try #require(image.bounds()).minY + 20
            return (image.color((runs[0].0 + runs[0].1) / 2, y), image.color((runs[3].0 + runs[3].1) / 2, y))
        }
        let early = try colours(at: 1.5)               // 0.5 s in: the first syllable is being sung
        #expect(early.first.r == 255 && early.first.g == 255 && early.first.b == 255, "first \(early.first)")
        #expect(early.second.r == 255 && early.second.g == 0 && early.second.b == 0, "second \(early.second)")
        let late = try colours(at: 2.5)
        #expect(late.second.g == 255 && late.second.b == 255, "second \(late.second)")
    }

    @Test("fades: \\fad(1000,0) brings the text in over a second")
    func fade() throws {
        let script = assScript([line("{\\pos(0,0)\\fad(1000,0)}A", start: "0:00:01.00", end: "0:00:05.00")])
        func centreAlpha(_ seconds: Double) throws -> Int {
            let image = try shot(script, at: seconds)
            guard let b = image.bounds(threshold: 1) else { return 0 }
            return image.alpha((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2)
        }
        let start = try centreAlpha(1.05), middle = try centreAlpha(1.5), full = try centreAlpha(2.5)
        #expect(start < 40 && (100...155).contains(middle) && full == 255, "\(start) \(middle) \(full)")
    }

    @Test("motion: \\move slides the text between two points over its time")
    func move() throws {
        let script = assScript([line("{\\move(0,0,300,0,0,1000)}A", start: "0:00:01.00", end: "0:00:05.00")])
        let a = try #require(try shot(script, at: 1.01).bounds()).minX
        let b = try #require(try shot(script, at: 1.5).bounds()).minX
        let c = try #require(try shot(script, at: 3).bounds()).minX
        #expect(a < 15 && abs(b - 155) < 15 && abs(c - 305) < 5, "\(a) \(b) \(c)")
    }

    @Test("the frame size is the output size: twice the size draws twice as large, in the same place")
    func scaling() throws {
        let script = assScript([line("{\\pos(100,50)}ABC")])
        let small = try #require(try shot(script, at: 2).bounds())
        let large = try #require(try shot(script, at: 2, size: (1280, 720)).bounds())
        #expect(abs(Double(large.minX) - 2 * Double(small.minX)) <= 2 && abs(Double(large.maxX) - 2 * Double(small.maxX)) <= 3
                && abs(Double(large.maxY) - 2 * Double(small.maxY)) <= 3, "\(small) -> \(large)")
    }

    @Test("a frame that did not change says so; a different time or size does")
    func changeFlag() throws {
        let core = try #require(ASSRenderCore(fonts: try blockFont(), storageSize: nil))
        #expect(core.loadScript(Data(assScript([line("{\\pos(0,0)}ABC")]).utf8)))
        #expect(core.render(atMilliseconds: 2000, width: 640, height: 360).changed)
        #expect(core.render(atMilliseconds: 2500, width: 640, height: 360).changed == false)
        #expect(core.render(atMilliseconds: 2500, width: 320, height: 180).changed)
        #expect(core.render(atMilliseconds: 12_000, width: 320, height: 180).rendered == nil)
    }

    // MARK: Scripts of the world

    @Test("CJK text is drawn with a system fallback font, not as boxes")
    func cjk() throws {
        let image = try shot(assScript([line("{\\pos(0,0)}日本語のテキスト")], font: "Helvetica", size: 60), at: 2, fonts: [])
        let b = try #require(image.bounds())
        #expect(b.maxX - b.minX > 6 * 40 && image.fill < 0.6 && image.fill > 0.1, "\(b), fill \(image.fill)")
    }

    @Test("a font without the characters falls back: CJK text in the block font is not the block font's empty box")
    func cjkFallsBackFromEmbeddedFont() throws {
        let image = try shot(assScript([line("{\\pos(0,0)}日本語")]), at: 2)
        let b = try #require(image.bounds())
        #expect(b.maxX - b.minX > 150 && image.fill < 0.7, "\(b), fill \(image.fill)")
    }

    @Test("Indic scripts are shaped: a conjunct is drawn as fewer clusters than code points")
    func devanagari() throws {
        let shaped = try #require(try shot(assScript([line("{\\pos(0,0)}हिन्दी")], font: "Helvetica", size: 60), at: 2, fonts: []).bounds())
        let width = shaped.maxX - shaped.minX
        // 6 code points; with shaping the word is about three glyph cells wide, not six.
        #expect(width > 60 && width < 6 * 60, "\(width)")
    }

    @Test("right-to-left text is put in visual order by bidirectional processing")
    func hebrew() throws {
        func render(_ text: String) throws -> Shot { try shot(assScript([line("{\\pos(0,0)}\(text)")], font: "Helvetica", size: 80), at: 2, fonts: []) }
        let both = try render("אב"), aleph = try render("א"), bet = try render("ב")
        let b = try #require(both.bounds(threshold: 32)), a = try #require(aleph.bounds(threshold: 32)), t = try #require(bet.bounds(threshold: 32))
        func match(_ profile: [Double], _ reference: [Double]) -> Double {
            let n = min(profile.count, reference.count)
            let dot = (0..<n).reduce(0.0) { $0 + profile[$1] * reference[$1] }
            let norm = ((0..<n).reduce(0.0) { $0 + profile[$1] * profile[$1] } * (0..<n).reduce(0.0) { $0 + reference[$1] * reference[$1] }).squareRoot()
            return norm == 0 ? 0 : dot / norm
        }
        // Visual order for a right-to-left run: the second letter (bet) stands on the left.
        let left = both.columnProfile(from: b.minX, to: b.minX + (t.maxX - t.minX))
        let right = both.columnProfile(from: b.maxX - (a.maxX - a.minX), to: b.maxX)
        let betProfile = bet.columnProfile(from: t.minX, to: t.maxX), alephProfile = aleph.columnProfile(from: a.minX, to: a.maxX)
        #expect(match(left, betProfile) > 0.9 && match(right, alephProfile) > 0.9, "left~bet \(match(left, betProfile)), right~aleph \(match(right, alephProfile))")
    }
}
