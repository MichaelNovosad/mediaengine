internal import FFmpegLGPL
import CoreVideo
import Foundation

/// Turns decoded FFmpeg frames (planar YUV) into the bi-planar `CVPixelBuffer`s that `AVSampleBufferDisplayLayer` and the
/// system's colour management understand, with the colour and pixel-aspect attachments set so the system tone-maps and
/// scales them correctly.
final class PixelBufferConverter {
    enum Failure: Error { case unsupportedFormat(Int32), allocation(CVReturn) }

    private struct PoolKey: Hashable { var width: Int; var height: Int; var format: OSType }
    private var pools: [PoolKey: CVPixelBufferPool] = [:]

    /// How a decoded frame is laid out in the `CVPixelBuffer` it is turned into.
    struct Layout: Equatable {
        /// The CoreVideo format: 8 bit, or 10 bit for everything deeper (12-bit sources lose their two lowest bits).
        var type: OSType
        var bits: Int
        /// Chroma subsampling of the buffer and of the source (a shift of 1 halves that direction).
        var chromaWidthShift: Int, chromaHeightShift: Int
        var sourceChromaWidthShift: Int, sourceChromaHeightShift: Int
        var sourceBits: Int
        var hasChroma: Bool
        var isSemiPlanar: Bool
    }

    /// The buffer format for a frame, or `nil` when the engine cannot show it (RGB, palettes, big-endian samples, packed
    /// formats). Planar YUV of any depth up to 16 bit and any subsampling is accepted: 4:2:0, 4:2:2 and 4:4:4 are kept,
    /// the rarer 4:4:0, 4:1:1 and 4:1:0 are widened to 4:4:4, grey becomes 4:2:0 with neutral chroma.
    static func layout(for frame: UnsafeMutablePointer<AVFrame>) -> Layout? {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        guard let descriptor = av_pix_fmt_desc_get(format)?.pointee else { return nil }
        let flags = descriptor.flags
        let full = isFullRange(frame, format: format)
        if format == AV_PIX_FMT_NV12 {
            return Layout(type: full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          bits: 8, chromaWidthShift: 1, chromaHeightShift: 1, sourceChromaWidthShift: 1, sourceChromaHeightShift: 1,
                          sourceBits: 8, hasChroma: true, isSemiPlanar: true)
        }
        // Grey formats have a single component and are not flagged planar.
        guard flags & UInt64(AV_PIX_FMT_FLAG_PLANAR) != 0 || descriptor.nb_components == 1, flags & UInt64(AV_PIX_FMT_FLAG_RGB) == 0,
              flags & UInt64(AV_PIX_FMT_FLAG_BE) == 0, flags & UInt64(AV_PIX_FMT_FLAG_PAL) == 0,
              flags & UInt64(AV_PIX_FMT_FLAG_BAYER) == 0 else { return nil }
        let depth = Int(descriptor.comp.0.depth)
        guard (8...16).contains(depth) else { return nil }
        let sourceWidthShift = Int(descriptor.log2_chroma_w), sourceHeightShift = Int(descriptor.log2_chroma_h)
        let hasChroma = descriptor.nb_components >= 3
        var widthShift = min(sourceWidthShift, 1), heightShift = min(sourceHeightShift, 1)
        if !hasChroma { widthShift = 1; heightShift = 1 }
        else if widthShift != heightShift && !(widthShift == 1 && heightShift == 0) { widthShift = 0; heightShift = 0 }
        let bits = depth == 8 ? 8 : 10
        let type: OSType
        switch (widthShift, heightShift, bits) {
        case (1, 1, 8): type = full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (1, 0, 8): type = full ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
        case (0, 0, 8): type = full ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case (1, 1, _): type = full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (1, 0, _): type = full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        default: type = full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        }
        return Layout(type: type, bits: bits, chromaWidthShift: widthShift, chromaHeightShift: heightShift,
                      sourceChromaWidthShift: sourceWidthShift, sourceChromaHeightShift: sourceHeightShift,
                      sourceBits: depth, hasChroma: hasChroma, isSemiPlanar: false)
    }

    /// The `yuvj` formats and frames that say so carry full-range samples; grey without a statement is full range.
    private static func isFullRange(_ frame: UnsafeMutablePointer<AVFrame>, format: AVPixelFormat) -> Bool {
        switch frame.pointee.color_range {
        case AVCOL_RANGE_JPEG: return true
        case AVCOL_RANGE_MPEG: return false
        default: return [AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUVJ440P, AV_PIX_FMT_GRAY8].contains(format)
        }
    }

    /// - Parameter deinterlaceTopFieldFirst: `nil` for a progressive picture; for an interlaced one, which field was captured
    ///   first (`true` for the top field), so that field is kept and the other is cleaned of combing (``Deinterlacer``).
    func convert(_ frame: UnsafeMutablePointer<AVFrame>, deinterlaceTopFieldFirst: Bool? = nil) throws -> CVPixelBuffer {
        guard let layout = Self.layout(for: frame) else { throw Failure.unsupportedFormat(frame.pointee.format) }
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let key = PoolKey(width: width, height: height, format: layout.type)
        let pool: CVPixelBufferPool
        if let existing = pools[key] {
            pool = existing
        } else {
            let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: layout.type, kCVPixelBufferWidthKey: width,
                                               kCVPixelBufferHeightKey: height, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            guard status == kCVReturnSuccess, let created else { throw Failure.allocation(status) }
            // Pictures that change size (some AV1 and VP9 streams do) must not pile up pools of sizes no longer used.
            if pools.count >= 4 { pools.removeAll() }
            pools[key] = created
            pool = created
        }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard status == kCVReturnSuccess, let buffer = output else { throw Failure.allocation(status) }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let chromaWidth = (width + (1 << layout.chromaWidthShift) - 1) >> layout.chromaWidthShift
        let chromaHeight = (height + (1 << layout.chromaHeightShift) - 1) >> layout.chromaHeightShift
        copyLuma(frame, to: buffer, width: width, height: height, layout: layout)
        copyChroma(frame, to: buffer, width: chromaWidth, height: chromaHeight, layout: layout)
        if let topFieldFirst = deinterlaceTopFieldFirst {
            Deinterlacer.apply(to: buffer, topFieldFirst: topFieldFirst, bits: layout.bits)
        }
        attach(frame, to: buffer, width: width, height: height)
        return buffer
    }

    // MARK: Planes

    /// A sample at `depth` bits as the 10-bit value that sits in the upper bits of a 16-bit word (P010 and its relatives).
    @inline(__always) private static func highAligned(_ value: UInt16, depth: Int) -> UInt16 { (value << UInt16(16 - depth)) & 0xFFC0 }

    private func copyLuma(_ frame: UnsafeMutablePointer<AVFrame>, to buffer: CVPixelBuffer, width: Int, height: Int, layout: Layout) {
        guard let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let plane = frame.pointee.data.0 else { return }
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let sourceStride = Int(frame.pointee.linesize.0)
        for row in 0..<height {
            let from = plane + row * sourceStride
            if layout.bits == 8 {
                memcpy(destination + row * destinationStride, from, width)
            } else {
                let line = destination.advanced(by: row * destinationStride).assumingMemoryBound(to: UInt16.self)
                from.withMemoryRebound(to: UInt16.self, capacity: width) { samples in
                    for x in 0..<width { line[x] = Self.highAligned(samples[x], depth: layout.sourceBits) }
                }
            }
        }
    }

    private func copyChroma(_ frame: UnsafeMutablePointer<AVFrame>, to buffer: CVPixelBuffer, width: Int, height: Int, layout: Layout) {
        guard let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        if !layout.hasChroma {
            // Neutral chroma: half of the range, in the buffer's own sample size.
            for row in 0..<height {
                if layout.bits == 8 { memset(destination + row * destinationStride, 128, width * 2) }
                else {
                    let line = destination.advanced(by: row * destinationStride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<(width * 2) { line[x] = 512 << 6 }
                }
            }
            return
        }
        if layout.isSemiPlanar, let plane = frame.pointee.data.1 {
            for row in 0..<height { memcpy(destination + row * destinationStride, plane + row * Int(frame.pointee.linesize.1), width * 2) }
            return
        }
        guard let u = frame.pointee.data.1, let v = frame.pointee.data.2 else { return }
        let uStride = Int(frame.pointee.linesize.1), vStride = Int(frame.pointee.linesize.2)
        // Where in the source plane the chroma sample of buffer position (x, row) is (equal subsampling: the same place).
        let sameGrid = layout.chromaWidthShift == layout.sourceChromaWidthShift && layout.chromaHeightShift == layout.sourceChromaHeightShift
        for row in 0..<height {
            let sourceRow = sameGrid ? row : (row << layout.chromaHeightShift) >> layout.sourceChromaHeightShift
            if layout.bits == 8 {
                let line = destination.advanced(by: row * destinationStride).assumingMemoryBound(to: UInt8.self)
                let uRow = u + sourceRow * uStride, vRow = v + sourceRow * vStride
                for x in 0..<width {
                    let sx = sameGrid ? x : (x << layout.chromaWidthShift) >> layout.sourceChromaWidthShift
                    line[2 * x] = uRow[sx]; line[2 * x + 1] = vRow[sx]
                }
            } else {
                let line = destination.advanced(by: row * destinationStride).assumingMemoryBound(to: UInt16.self)
                let sourceWidth = (Int(frame.pointee.width) + (1 << layout.sourceChromaWidthShift) - 1) >> layout.sourceChromaWidthShift
                (u + sourceRow * uStride).withMemoryRebound(to: UInt16.self, capacity: sourceWidth) { uRow in
                    (v + sourceRow * vStride).withMemoryRebound(to: UInt16.self, capacity: sourceWidth) { vRow in
                        for x in 0..<width {
                            let sx = sameGrid ? x : (x << layout.chromaWidthShift) >> layout.sourceChromaWidthShift
                            line[2 * x] = Self.highAligned(uRow[sx], depth: layout.sourceBits)
                            line[2 * x + 1] = Self.highAligned(vRow[sx], depth: layout.sourceBits)
                        }
                    }
                }
            }
        }
    }

    // MARK: Colour and shape

    private func attach(_ frame: UnsafeMutablePointer<AVFrame>, to buffer: CVPixelBuffer, width: Int, height: Int) {
        let highDefinition = width >= 1280 || height >= 720
        let primaries: CFString
        switch frame.pointee.color_primaries {
        case AVCOL_PRI_BT709: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: primaries = kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT470BG: primaries = kCVImageBufferColorPrimaries_EBU_3213
        default: primaries = highDefinition ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        }
        let transfer: CFString
        switch frame.pointee.color_trc {
        case AVCOL_TRC_SMPTE2084: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12: transfer = kCVImageBufferTransferFunction_ITU_R_2020
        default: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
        }
        let matrix: CFString
        switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M: matrix = kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        default: matrix = highDefinition ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        let aspect = frame.pointee.sample_aspect_ratio
        if aspect.num > 0, aspect.den > 0, aspect.num != aspect.den {
            let dictionary: [CFString: Any] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(aspect.num),
                                               kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(aspect.den)]
            CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, dictionary as CFDictionary, .shouldPropagate)
        }
    }
}
