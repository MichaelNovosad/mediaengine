import AVFoundation
import CoreVideo
import FFmpegLGPL
import Foundation
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// Interlaced pictures, soft telecine and pixel aspect ratio in the software path (ANM-7).
@Suite("Interlacing, pulldown and aspect ratio")
struct InterlaceTests {
    // MARK: The deinterlacer on made-up pictures

    /// A 8-bit 4:2:0 picture of `size` luma pixels whose luma is `luma(x, y)` and whose chroma is neutral.
    private static func picture(width: Int, height: Int, bits: Int = 8, luma: (Int, Int) -> Int) -> CVPixelBuffer {
        let type = bits == 8 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, type, nil, &buffer)
        let image = buffer!
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(image, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
            let w = CVPixelBufferGetWidthOfPlane(image, plane) * (plane == 0 ? 1 : 2), h = CVPixelBufferGetHeightOfPlane(image, plane)
            for y in 0..<h { for x in 0..<w {
                let value = plane == 0 ? luma(x, y) : 128
                if bits == 8 { base.storeBytes(of: UInt8(value), toByteOffset: y * stride + x, as: UInt8.self) }
                else { base.storeBytes(of: UInt16(value << 6), toByteOffset: y * stride + 2 * x, as: UInt16.self) }
            } }
        }
        return image
    }

    private static func luma(_ buffer: CVPixelBuffer, bits: Int = 8) -> [[Int]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return (0..<CVPixelBufferGetHeight(buffer)).map { y in (0..<CVPixelBufferGetWidth(buffer)).map { x in
            bits == 8 ? Int(base.load(fromByteOffset: y * stride + x, as: UInt8.self)) : Int(base.load(fromByteOffset: y * stride + 2 * x, as: UInt16.self)) >> 6
        } }
    }

    /// A moving block: the first field (even lines) saw it at the left, the second field (odd lines) a few pixels to the right.
    private static func movingBlock(_ x: Int, _ y: Int) -> Int {
        let background = 40 + y / 2                                       // smooth, still
        let left = y % 2 == 0 ? 20 : 30                                   // the block's columns in this field
        return (x >= left && x < left + 12 && y >= 16 && y < 48) ? 220 : background
    }

    @Test("the field captured first is kept, the lines of the other field are cleaned where something moved", arguments: [true, false])
    func cleansMotion(topFieldFirst: Bool) {
        let buffer = Self.picture(width: 64, height: 64, luma: Self.movingBlock)
        let before = Self.luma(buffer)
        Deinterlacer.apply(to: buffer, topFieldFirst: topFieldFirst, bits: 8)
        let after = Self.luma(buffer)
        let keptParity = topFieldFirst ? 0 : 1
        for y in 0..<64 where y % 2 == keptParity { #expect(after[y] == before[y], "kept line \(y) changed") }
        // In the middle of the block's edge the other field's lines were wrong (the block was elsewhere): they now match the kept lines.
        for y in stride(from: 20, to: 44, by: 1) where y % 2 != keptParity {
            for x in 20...31 { #expect(abs(after[y][x] - after[y - 1][x]) <= 1 || abs(after[y][x] - after[y + 1][x]) <= 1, "line \(y) column \(x): \(after[y][x])") }
        }
        // The comb is gone: neighbouring lines no longer alternate.
        func comb(_ rows: [[Int]]) -> Int {
            var total = 0
            for y in 1..<63 { for x in 0..<64 { total += abs(2 * rows[y][x] - rows[y - 1][x] - rows[y + 1][x]) } }
            return total
        }
        #expect(comb(after) * 3 < comb(before), "comb \(comb(before)) -> \(comb(after))")
    }

    @Test("a still picture keeps every line, so progressive detail is not softened")
    func stillPictureUntouched() {
        let buffer = Self.picture(width: 64, height: 64) { x, y in 30 + y * 2 + (x / 8) * 10 }
        let before = Self.luma(buffer)
        Deinterlacer.apply(to: buffer, topFieldFirst: true, bits: 8)
        #expect(Self.luma(buffer) == before)
    }

    @Test("a diagonal edge is interpolated along the edge")
    func diagonalEdge() {
        // Kept (even) lines: a diagonal edge. Odd lines: nonsense that sticks out of both neighbours.
        func edge(_ x: Int, _ y: Int) -> Int { x + y < 40 ? 30 : 220 }
        let buffer = Self.picture(width: 64, height: 64) { x, y in y % 2 == 0 ? edge(x, y) : (edge(x, y) < 100 ? 255 : 0) }
        Deinterlacer.apply(to: buffer, topFieldFirst: true, bits: 8)
        let after = Self.luma(buffer)
        var right = 0, total = 0
        for y in stride(from: 3, to: 60, by: 2) { for x in 2..<62 { total += 1; if abs(after[y][x] - edge(x, y)) < 30 { right += 1 } } }
        #expect(Double(right) / Double(total) > 0.9, "\(right) of \(total) interpolated pixels follow the edge")
    }

    @Test("10-bit pictures and chroma are cleaned too")
    func tenBitAndChroma() {
        let buffer = Self.picture(width: 64, height: 64, bits: 10, luma: Self.movingBlock)
        let before = Self.luma(buffer, bits: 10)
        Deinterlacer.apply(to: buffer, topFieldFirst: true, bits: 10)
        let after = Self.luma(buffer, bits: 10)
        for y in stride(from: 0, to: 64, by: 2) { #expect(after[y] == before[y]) }
        #expect(abs(after[30][24] - after[29][24]) <= 1 || abs(after[30][24] - after[31][24]) <= 1)
        // Neutral chroma stays neutral.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        #expect(chroma.load(fromByteOffset: 5 * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + 6, as: UInt16.self) == 128 << 6)
    }

    // MARK: Pulldown

    @Test("soft telecine: a picture that repeats a field stays on screen half a frame longer, and the file's own duration wins")
    func pulldownDuration() {
        let period = 1.0 / 24
        #expect(SoftwareVideoDecoder.displayDuration(packetDuration: nil, framePeriod: period, repeatFields: 0) == period)
        #expect(abs(SoftwareVideoDecoder.displayDuration(packetDuration: nil, framePeriod: period, repeatFields: 1) - period * 1.5) < 1e-12)
        #expect(abs(SoftwareVideoDecoder.displayDuration(packetDuration: nil, framePeriod: period, repeatFields: 2) - period * 2) < 1e-12)
        #expect(SoftwareVideoDecoder.displayDuration(packetDuration: 0.05, framePeriod: period, repeatFields: 1) == 0.05)
        #expect(SoftwareVideoDecoder.displayDuration(packetDuration: 0, framePeriod: period, repeatFields: -3) == period)
    }

    // MARK: Real files (extended build)

    private func decode(_ name: String, _ mode: Deinterlacing) throws -> [DecodedFrame] {
        let reader = try PacketReader(source: FileByteSource(url: Fixture.url(name)), cancellation: CancellationFlag())
        let index = try #require((0..<reader.streamCount).first { reader.parameters($0).pointee.codec_type == AVMEDIA_TYPE_VIDEO })
        let declared = reader.stream(index).pointee.sample_aspect_ratio
        let decoder = try SoftwareVideoDecoder(parameters: reader.parameters(index), timeBase: reader.timeBase(index), frameRate: 25,
                                               containerAspect: declared.num > 0 && declared.den > 0 ? Rational(declared) : nil)
        decoder.setDeinterlacing(mode)
        var frames: [DecodedFrame] = []
        while let packet = try reader.next() {
            guard packet.stream == index else { continue }
            decoder.send(packet)
            while let frame = decoder.receive() { frames.append(frame) }
        }
        decoder.send(nil)
        while let frame = decoder.receive() { frames.append(frame) }
        return frames
    }

    private static func comb(_ buffer: CVPixelBuffer) -> Int {
        let rows = luma(buffer)
        var total = 0
        for y in 1..<(rows.count - 1) {
            for x in 0..<rows[y].count { total += abs(2 * rows[y][x] - rows[y - 1][x] - rows[y + 1][x]) }
        }
        return total
    }

    @Test("interlaced files are recognised with their field order, and cleaned of combing unless the host turns it off",
          .enabled(if: isExtendedBuild), arguments: [("fixture-interlaced-tff", true), ("fixture-interlaced-bff", false)])
    func interlacedFiles(name: String, topFieldFirst: Bool) throws {
        let raw = try decode(name, .off), cleaned = try decode(name, .automatic)
        #expect(raw.count == 37 && cleaned.count == raw.count, "\(raw.count) / \(cleaned.count) pictures")
        #expect(raw.allSatisfy { $0.isInterlaced && $0.topFieldFirst == topFieldFirst && !$0.wasDeinterlaced })
        #expect(cleaned.allSatisfy { $0.isInterlaced && $0.topFieldFirst == topFieldFirst && $0.wasDeinterlaced })
        // The test pattern moves, so the woven pictures are combed. Its still parts (gridlines, text) have fine vertical detail
        // of their own that the measure counts and the cleaning keeps, so the drop is measured, not total.
        var before = 0, after = 0
        for (original, clean) in zip(raw.dropFirst(2), cleaned.dropFirst(2)) { before += Self.comb(original.pixelBuffer); after += Self.comb(clean.pixelBuffer) }
        #expect(after * 10 < before * 9, "comb \(before) -> \(after)")
        // The field that came first is the one that is kept.
        let keptParity = topFieldFirst ? 0 : 1
        for (original, clean) in zip(raw.dropFirst(5).prefix(3), cleaned.dropFirst(5).prefix(3)) {
            let a = Self.luma(original.pixelBuffer), b = Self.luma(clean.pixelBuffer)
            for y in 0..<a.count where y % 2 == keptParity { #expect(a[y] == b[y], "kept line \(y) of \(name) changed") }
        }
    }

    @Test("a progressive file is never touched by the deinterlacer", .enabled(if: isExtendedBuild))
    func progressiveUntouched() throws {
        let frames = try decode("fixture-avi-xvid", .automatic)
        #expect(!frames.isEmpty && frames.allSatisfy { !$0.isInterlaced && !$0.wasDeinterlaced })
    }

    // MARK: Pixel aspect ratio

    @Test("the pixel aspect ratio the container declares reaches the picture and the display's format description", .enabled(if: isExtendedBuild))
    func anamorphic() async throws {
        let info = try await Fixture.probe("fixture-anamorphic")
        let declared = try #require(info.videoTracks.first?.video?.pixelAspectRatio)
        #expect(abs(declared - 16.0 / 11) < 0.001, "\(declared)")
        let frame = try #require(try decode("fixture-anamorphic", .automatic).first)
        let attachment = try #require(CVBufferCopyAttachment(frame.pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Int])
        #expect(attachment[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] == 16 && attachment[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] == 11)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame.pixelBuffer, formatDescriptionOut: &description)
        let extensionValue = CMFormatDescriptionGetExtension(try #require(description), extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Int]
        #expect(extensionValue?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] == 16, "\(String(describing: extensionValue))")
    }
}

#if os(macOS)
@Suite("Interlaced playback", .serialized)
@MainActor
struct InterlacedPlaybackTests {
    @Test("an interlaced MPEG-2 file plays through the software player with deinterlacing on", .enabled(if: isExtendedBuild))
    func plays() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-interlaced-tff"))
        let made = try await session.makeController()
        made.isMuted = true
        let player = try #require(made as? SoftwareController)
        defer { player.close() }
        #expect(player.deinterlacing == .automatic)
        player.play()
        #expect(await waitUntil(10) { player.state == .ended }, "\(player.state) at \(player.currentTime), \(player.statistics)")
        #expect(player.statistics.decodedFrames >= 36, "\(player.statistics)")
        // Pictures that are late are dropped, and a sanitizer makes everything late: count what was shown only on a plain build.
        if testPatience == 1 { #expect(player.statistics.displayedFrames >= 34, "\(player.statistics)") }
    }
}
#endif
