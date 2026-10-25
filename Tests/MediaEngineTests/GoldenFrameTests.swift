import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MediaEngine

/// ANM-3: frames of effects that ASS players have to get right, compared with pictures recorded from libass 0.17.5 with
/// FreeType 2.14.3, HarfBuzz 14.6.0 and FriBidi 1.0.16 (the pinned builds). The font is the generated block font, so
/// no system font enters. Record again after a library update with `MEDIAENGINE_RECORD_GOLDEN=1 swift test --filter GoldenFrameTests`
/// and look at the pictures in `Tests/MediaEngineTests/Golden` before committing them.
@Suite("Golden frames (ANM-3)")
struct GoldenFrameTests {
    struct Scene: CustomTestStringConvertible {
        var name: String
        var events: [String]
        var time: Double
        var testDescription: String { name }
    }

    static let scenes: [Scene] = {
        func event(_ text: String, layer: Int = 0, start: String = "0:00:01.00", end: String = "0:00:09.00") -> String {
            "Dialogue: \(layer),\(start),\(end),Default,,0,0,0,,\(text)"
        }
        return [
            Scene(name: "rotation-z", events: [event("{\\pos(200,250)\\frz30\\1c&H2020E0&}ABC DEF")], time: 2),
            Scene(name: "outline-shadow-blur", events: [event("{\\pos(40,40)\\bord6\\shad5\\blur2\\1c&HE0E0E0&\\3c&H00A000&\\4c&H0000FF&}ABC")], time: 2),
            Scene(name: "clip-and-drawing", events: [
                event("{\\pos(40,40)\\clip(40,40,140,130)\\1c&H20A020&}ABC DEF"),
                event("{\\pos(300,60)\\1c&HFF8000&\\bord3\\3c&HFFFFFF&\\p1}m 0 0 l 120 0 120 80 60 40 0 80{\\p0}", layer: 1),
            ], time: 2),
            Scene(name: "karaoke-wipe", events: [event("{\\pos(20,100)\\1c&HE0A000&\\2c&H0000C0&\\kf200}ABC{\\kf200}DEF{\\kf200}GHI", start: "0:00:01.00", end: "0:00:08.00")], time: 2.5),
            Scene(name: "fade-and-move", events: [event("{\\move(20,200,420,200,0,2000)\\fad(500,500)\\1c&H0090E0&}ABC", start: "0:00:01.00", end: "0:00:04.00")], time: 2.2),
            Scene(name: "perspective", events: [event("{\\pos(300,180)\\frx40\\fry25\\fscx140\\1c&HC04000&}ABCD")], time: 2),
            Scene(name: "layers-and-alpha", events: [
                event("{\\pos(60,60)\\1c&H0000FF&}ABCDE", layer: 0),
                event("{\\pos(100,80)\\1c&H00FF00&\\1a&H80&}ABCDE", layer: 1),
                event("{\\pos(140,100)\\1c&HFF0000&\\alpha&H40&}ABCDE", layer: 2),
            ], time: 2),
            Scene(name: "scaled-spaced-bold", events: [event("{\\pos(30,250)\\fscx60\\fscy150\\fsp12\\b1\\1c&H8000C0&}ABC abc 123")], time: 2),
        ]
    }()

    private static let directory = Fixture.root.appendingPathComponent("Tests/MediaEngineTests/Golden")

    private static func pngData(_ shot: Shot) -> Data? {
        guard let image = ImageMaking.cgImage(premultipliedRGBA: shot.rgba, width: shot.width, height: shot.height) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func decode(_ png: Data, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }

    @Test("each scene matches the picture recorded for it", arguments: scenes)
    func matches(scene: Scene) throws {
        let image = try shot(assScript(scene.events), at: scene.time)
        #expect(!image.isEmpty, "\(scene.name) drew nothing")
        let file = Self.directory.appendingPathComponent("\(scene.name).png")
        if ProcessInfo.processInfo.environment["MEDIAENGINE_RECORD_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try #require(Self.pngData(image)).write(to: file)
            return
        }
        let recorded = try Data(contentsOf: file)
        let expected = try #require(Self.decode(recorded, width: image.width, height: image.height), "\(scene.name).png has the wrong size")
        var worst = 0, total = 0
        for (a, b) in zip(image.rgba, expected) { let d = abs(Int(a) - Int(b)); worst = max(worst, d); total += d }
        let mean = Double(total) / Double(expected.count)
        #expect(worst <= 12 && mean < 0.1, "\(scene.name): largest difference \(worst)/255, mean \(mean)")
    }
}
