import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// A file read through something that is not a `FileByteSource`, as a film on a server is: the session puts its shared read cache in
/// front of it, and the preview reads through that cache.
private final class NetworkLike: ByteSource, @unchecked Sendable {
    let file: FileByteSource
    private let asked = Mutex<Int64>(0)
    init(url: URL) throws { file = try FileByteSource(url: url) }
    var length: Int64? { file.length }
    var askedBytes: Int64 { asked.withLock { $0 } }
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try file.read(at: offset, into: buffer)
        asked.withLock { $0 += Int64(count) }
        return count
    }
}

/// Whether a picture is one flat colour (a black or broken decode), from a few samples of its pixels.
private func isFlat(_ image: CGImage) -> Bool {
    let width = 32, height = 18
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return true }
    let lightness = stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) + Int(pixels[$0 + 1]) + Int(pixels[$0 + 2]) }
    return (lightness.max() ?? 0) - (lightness.min() ?? 0) < 30
}

/// The still a host shows while its player jumps (the app's Jira EGA-122): the keyframe at or before the time, read on its own.
@Suite("Jump preview")
struct PreviewPictureTests {
    /// Keyframes of the fixtures on the engine's timeline (ffprobe; MPEG files start at 0 there).
    @Test("Matroska with Apple's decoder: the keyframe at or before each time, one reader for several jumps", arguments: [
        ("fixture-basic", [(1.5, 1.0), (2.9, 2.0), (0.3, 0.0), (1.0, 1.0)]),
        ("fixture-hevc", [(2.5, 2.0), (0.5, 0.0)]),
        ("fixture-bframes", [(4.0, 3.68), (9.0, 8.52), (1.0, 0.92)]),
    ])
    func matroska(name: String, jumps: [(Double, Double)]) async throws {
        let session = try await PlaybackSession(url: Fixture.url(name))
        defer { session.close() }
        for (asked, keyframe) in jumps {
            let began = ContinuousClock.now
            let picture = try #require(try await session.previewPicture(at: asked), "\(name) at \(asked)")
            let took = ContinuousClock.now - began
            #expect(abs(picture.time - keyframe) < 0.02, "\(name) at \(asked): \(picture.time), not \(keyframe)")
            #expect(picture.image.width == 640 && picture.image.height == 360)
            #expect(!isFlat(picture.image), "\(name) at \(asked): a flat picture")
            #expect(took < .seconds(2 * testPatience), "\(name) at \(asked): \(took)")
        }
    }

    @Test("MPEG-TS: H.264 with its parameter sets in the stream, decoded by Apple's decoder")
    func transportStream() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ts"))
        defer { session.close() }
        // ffprobe: keyframes at 1.444, 2.444, 3.444 in the file, which starts at 1.4.
        let picture = try #require(try await session.previewPicture(at: 1.5))
        #expect(abs(picture.time - 1.044) < 0.02, "\(picture.time)")
        #expect(!isFlat(picture.image))
        let later = try #require(try await session.previewPicture(at: 2.5))
        #expect(abs(later.time - 2.044) < 0.02, "\(later.time)")
    }

    @Test("MPEG-2 through this build's own decoder", .enabled(if: isExtendedBuild))
    func software() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-mpeg2"))
        defer { session.close() }
        // ffprobe: keyframes at 0.54, 1.02, 1.50 in the file, which starts at 0.53.
        let picture = try #require(try await session.previewPicture(at: 1.2))
        #expect(abs(picture.time - 0.97) < 0.03, "\(picture.time)")
        #expect(picture.image.width == 640 && picture.image.height == 360)
        #expect(!isFlat(picture.image))
    }

    @Test("a film on a network: read through the session's shared cache, a few hundred kilobytes for a jump")
    func network() async throws {
        let source = try NetworkLike(url: Fixture.url("fixture-bframes"))
        let session = try await PlaybackSession(source: MediaSource(byteSource: source))
        defer { session.close() }
        let before = source.askedBytes
        let picture = try #require(try await session.previewPicture(at: 6.0))
        #expect(abs(picture.time - 5.52) < 0.02, "\(picture.time)")
        #expect(!isFlat(picture.image))
        let read = source.askedBytes - before
        let file = source.length ?? 0
        #expect(read < file, "read \(read) of \(file) bytes")
    }

    @Test("prepared in advance: the reader is open before the first jump")
    func prepared() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-hevc"))
        defer { session.close() }
        session.preparePreviews()
        session.preparePreviews()                                   // twice is harmless
        let picture = try #require(try await session.previewPicture(at: 1.5))
        #expect(abs(picture.time - 1.0) < 0.02, "\(picture.time)")
    }

    @Test("nothing after the session closed")
    func closed() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        _ = try await session.previewPicture(at: 1)
        session.close()
        #expect(try await session.previewPicture(at: 2) == nil)
    }

    @Test("a still's size: the picture's own, or smaller to fit 1920 pixels")
    func sizes() {
        #expect(PreviewMaker.scaled(width: 640, height: 360) == (640, 360))
        #expect(PreviewMaker.scaled(width: 3840, height: 2160) == (1920, 1080))
        #expect(PreviewMaker.scaled(width: 1440, height: 1080) == (1440, 1080))
        #expect(PreviewMaker.scaled(width: 2160, height: 3840) == (1080, 1920))
    }
}
