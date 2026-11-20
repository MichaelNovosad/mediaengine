import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// Makes the engine's own pictures sharper with Apple's low-latency super-resolution scaler (VideoToolbox's `VTFrameProcessor`), on the
/// device, for low-resolution films (the app's Jira EGA-108, "Enhanced Quality"). Measured on an M1 Max (2026-11-20): 720 × 480 to
/// 1440 × 960 in a median 2.2 ms per picture (worst 4.9 ms), 1280 × 720 to 1920 × 1080 in 3.3 ms, far under a picture's 41.7 ms at 24 a
/// second. The scaler takes 8-bit 4:2:0 pictures only (`420v`), and each size has its own factors (720p: 1.5 only; a full-HD picture
/// none). Apple's temporal noise filter would need pictures from the future and is not supported on that Mac: not used.
///
/// Used by one feeding task at a time (``SoftwareVideoPipeline``), hence `@unchecked Sendable`.
///
/// The iOS Simulator's SDK leaves the frame processors out (`#if ! TARGET_OS_SIMULATOR` in `VTFrameProcessor.h`): there the enhancer
/// offers nothing (below).
#if !targetEnvironment(simulator)
final class PictureEnhancer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.mediaengine", category: "player")

    /// The factor for pictures of this size: the largest the scaler offers, at most 2; `nil` when it offers none or the device has no
    /// scaler. Both sides must be multiples of 16: the scaler offers factors for 640 × 360 but fails every picture of it (error -19730),
    /// as for 712 × 400 and 720 × 404 and 408, while 640 × 368, 704 × 400, 720 × 480 and 720 × 576 work (measured 2026-11-20, macOS 27.2,
    /// M1 Max; the rule is not in the SDK's headers). DVDs (720 × 480 and 720 × 576) pass.
    static func scale(width: Int, height: Int) -> Float? {
        guard width > 0, height > 0, width % 16 == 0, height % 16 == 0, VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            return nil
        }
        return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height)
            .filter { $0 > 1 && $0 <= 2 }.max()
    }

    private var processor: VTFrameProcessor?
    private var pool: CVPixelBufferPool?
    private var size = (width: 0, height: 0)
    /// The size that could not be enhanced: not tried again.
    private var refused: (width: Int, height: Int)?

    /// The picture made larger and sharper, or `nil` when it cannot be (another pixel format, a size without a factor, an error): the
    /// caller shows the original then.
    func enhance(_ buffer: CVPixelBuffer, time: Double) async -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        if let refused, refused == (width, height) { return nil }
        if processor == nil || size != (width, height) {
            guard start(width: width, height: height) else { refused = (width, height); return nil }
        }
        guard let processor, let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        let stamp = CMTime(seconds: time, preferredTimescale: 90_000)
        guard let output, let source = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: stamp),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: stamp) else { return nil }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: source, destinationFrame: destination)
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                processor.process(parameters: parameters) { _, error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
        } catch {
            Self.logger.error("Enhanced Quality: a picture failed (\(String(describing: error), privacy: .public)); shown as it is")
            return nil
        }
        // Colour, pixel shape and field attachments go with the picture.
        CVBufferPropagateAttachments(buffer, output)
        return output
    }

    private func start(width: Int, height: Int) -> Bool {
        end()
        guard let factor = Self.scale(width: width, height: height) else { return false }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: factor)
        let processor = VTFrameProcessor()
        var pool: CVPixelBufferPool?
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            Self.logger.error("Enhanced Quality: the scaler did not start for \(width, privacy: .public)×\(height, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        CVPixelBufferPoolCreate(nil, nil, configuration.destinationPixelBufferAttributes as CFDictionary, &pool)
        guard pool != nil else { processor.endSession(); return false }
        self.processor = processor
        self.pool = pool
        size = (width, height)
        Self.logger.notice("Enhanced Quality: \(width, privacy: .public)×\(height, privacy: .public) scaled by \(factor, privacy: .public)")
        return true
    }

    func end() {
        processor?.endSession()
        processor = nil
        pool = nil
        size = (0, 0)
    }

    deinit { processor?.endSession() }
}
#else
final class PictureEnhancer: @unchecked Sendable {
    static func scale(width: Int, height: Int) -> Float? { nil }
    func enhance(_ buffer: CVPixelBuffer, time: Double) async -> CVPixelBuffer? { nil }
    func end() {}
}
#endif
