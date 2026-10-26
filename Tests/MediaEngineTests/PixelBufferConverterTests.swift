import CoreVideo
import FFmpegLGPL
import Foundation
import Testing
@testable import MediaEngine

/// The conversion of decoded pictures into display buffers (SWD-3): every planar YUV format the engine's decoders can
/// produce lands in a buffer of the right type with the right samples, and what cannot be shown is refused.
@Suite("Pixel buffer conversion")
struct PixelBufferConverterTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var format: AVPixelFormat
        var name: String
        var depth: Int
        var bufferType: OSType
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(format: AV_PIX_FMT_YUV420P, name: "yuv420p", depth: 8, bufferType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUVJ420P, name: "yuvj420p", depth: 8, bufferType: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        Case(format: AV_PIX_FMT_YUV420P10LE, name: "yuv420p10", depth: 10, bufferType: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV420P12LE, name: "yuv420p12", depth: 12, bufferType: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV422P, name: "yuv422p", depth: 8, bufferType: kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV422P10LE, name: "yuv422p10", depth: 10, bufferType: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV444P, name: "yuv444p", depth: 8, bufferType: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV444P12LE, name: "yuv444p12", depth: 12, bufferType: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV440P, name: "yuv440p", depth: 8, bufferType: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV440P12LE, name: "yuv440p12", depth: 12, bufferType: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV410P, name: "yuv410p", depth: 8, bufferType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        Case(format: AV_PIX_FMT_YUV411P, name: "yuv411p", depth: 8, bufferType: kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange),
    ]

    /// A sample of plane `plane` at (x, y), spread over the whole range of `depth` bits.
    private static func sample(_ plane: Int, _ x: Int, _ y: Int, depth: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: (x * 37 + y * 101 + plane * 211 + 13) * 7) & UInt16((1 << depth) - 1)
    }

    private static func makeFrame(_ format: AVPixelFormat, width: Int, height: Int, depth: Int) throws -> UnsafeMutablePointer<AVFrame> {
        let frame = try #require(av_frame_alloc())
        frame.pointee.format = format.rawValue
        frame.pointee.width = Int32(width); frame.pointee.height = Int32(height)
        try #require(av_frame_get_buffer(frame, 0) >= 0)
        let description = av_pix_fmt_desc_get(format)!.pointee
        let planes = [frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2]
        let strides = [Int(frame.pointee.linesize.0), Int(frame.pointee.linesize.1), Int(frame.pointee.linesize.2)]
        for plane in 0..<Int(description.nb_components) {
            let w = plane == 0 ? width : (width + (1 << Int(description.log2_chroma_w)) - 1) >> Int(description.log2_chroma_w)
            let h = plane == 0 ? height : (height + (1 << Int(description.log2_chroma_h)) - 1) >> Int(description.log2_chroma_h)
            let base = try #require(planes[plane])
            for y in 0..<h { for x in 0..<w {
                let value = sample(plane, x, y, depth: depth)
                if depth == 8 { base[y * strides[plane] + x] = UInt8(value) }
                else { (base + y * strides[plane]).withMemoryRebound(to: UInt16.self, capacity: w) { $0[x] = value } }
            } }
        }
        return frame
    }

    private static func buffered(_ value: UInt16, depth: Int) -> UInt16 { depth == 8 ? value : (value << UInt16(16 - depth)) & 0xFFC0 }

    @Test("planar YUV of every depth and subsampling keeps its samples", arguments: cases)
    func converts(testCase: Case) throws {
        let (width, height) = (35, 19)                                    // odd sizes: the chroma rounds up
        let frame = try Self.makeFrame(testCase.format, width: width, height: height, depth: testCase.depth)
        defer { var pointer: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&pointer) }
        let buffer = try PixelBufferConverter().convert(frame)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == testCase.bufferType)
        #expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)

        let description = av_pix_fmt_desc_get(testCase.format)!.pointee
        let layout = try #require(PixelBufferConverter.layout(for: frame))
        let bits = layout.bits
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        func read(_ plane: Int, _ index: Int, _ row: Int) -> UInt16 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            return bits == 8 ? UInt16(base.load(fromByteOffset: row * stride + index, as: UInt8.self))
                             : base.load(fromByteOffset: row * stride + index * 2, as: UInt16.self)
        }
        for y in stride(from: 0, to: height, by: 3) { for x in stride(from: 0, to: width, by: 2) {
            #expect(read(0, x, y) == Self.buffered(Self.sample(0, x, y, depth: testCase.depth), depth: testCase.depth), "luma \(x),\(y)")
        } }
        let chromaWidth = (width + (1 << layout.chromaWidthShift) - 1) >> layout.chromaWidthShift
        let chromaHeight = (height + (1 << layout.chromaHeightShift) - 1) >> layout.chromaHeightShift
        #expect(CVPixelBufferGetWidthOfPlane(buffer, 1) == chromaWidth && CVPixelBufferGetHeightOfPlane(buffer, 1) == chromaHeight)
        for cy in 0..<chromaHeight { for cx in 0..<chromaWidth {
            // The chroma sample of the buffer covers luma position (cx << shift, cy << shift): take the source's chroma there.
            let lumaX = cx << layout.chromaWidthShift, lumaY = cy << layout.chromaHeightShift
            let sx = lumaX >> Int(description.log2_chroma_w), sy = lumaY >> Int(description.log2_chroma_h)
            let u = Self.buffered(Self.sample(1, sx, sy, depth: testCase.depth), depth: testCase.depth)
            let v = Self.buffered(Self.sample(2, sx, sy, depth: testCase.depth), depth: testCase.depth)
            #expect(read(1, 2 * cx, cy) == u && read(1, 2 * cx + 1, cy) == v, "chroma \(cx),\(cy)")
        } }
    }

    @Test("grey pictures get neutral chroma", arguments: [(AV_PIX_FMT_GRAY8, 8), (AV_PIX_FMT_GRAY10LE, 10), (AV_PIX_FMT_GRAY12LE, 12)])
    func grey(format: AVPixelFormat, depth: Int) throws {
        let frame = try Self.makeFrame(format, width: 16, height: 8, depth: depth)
        defer { var pointer: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&pointer) }
        let buffer = try PixelBufferConverter().convert(frame)
        #expect(CVPixelBufferGetPlaneCount(buffer) == 2 && CVPixelBufferGetWidthOfPlane(buffer, 1) == 8)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        if depth == 8 { #expect(chroma.load(as: UInt8.self) == 128) } else { #expect(chroma.load(as: UInt16.self) == 512 << 6) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let first = depth == 8 ? UInt16(luma.load(as: UInt8.self)) : luma.load(as: UInt16.self)
        #expect(first == Self.buffered(Self.sample(0, 0, 0, depth: depth), depth: depth))
    }

    @Test("a frame that says it is full range, or limited range, is taken at its word")
    func range() throws {
        let frame = try Self.makeFrame(AV_PIX_FMT_YUV420P, width: 16, height: 8, depth: 8)
        defer { var pointer: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&pointer) }
        frame.pointee.color_range = AVCOL_RANGE_JPEG
        #expect(PixelBufferConverter.layout(for: frame)?.type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        frame.pointee.color_range = AVCOL_RANGE_MPEG
        #expect(PixelBufferConverter.layout(for: frame)?.type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test("what cannot be shown is refused, not shown wrongly", arguments: [AV_PIX_FMT_GBRP, AV_PIX_FMT_RGB24, AV_PIX_FMT_YUV420P10BE, AV_PIX_FMT_PAL8])
    func refuses(format: AVPixelFormat) throws {
        let frame = try #require(av_frame_alloc())
        defer { var pointer: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&pointer) }
        frame.pointee.format = format.rawValue
        #expect(PixelBufferConverter.layout(for: frame) == nil)
    }

    @Test("pictures that change size keep converting")
    func sizeChanges() throws {
        let converter = PixelBufferConverter()
        for (width, height) in [(64, 48), (48, 32), (32, 16), (64, 48), (80, 60), (100, 70), (64, 48)] {
            let frame = try Self.makeFrame(AV_PIX_FMT_YUV420P, width: width, height: height, depth: 8)
            defer { var pointer: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&pointer) }
            let buffer = try converter.convert(frame)
            #expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
        }
    }
}
