internal import FFmpegLGPL
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import Synchronization
import VideoToolbox

/// A still of the film near a time, for a host to show while its player jumps there (``PlaybackSession/previewPicture(at:)``).
public struct PreviewPicture: Sendable {
    /// The picture in the stream's own pixels (not yet in the shape the film is shown in: see ``VideoDetails/pixelAspectRatio``), at
    /// most 1920 pixels wide or high.
    public let image: CGImage
    /// Where the picture is on the film's timeline: the keyframe at or a little before the time asked for (a little after it when the
    /// file has nothing before).
    public let time: TimeInterval
}

extension PlaybackSession {
    /// A still of the film at about `seconds`, read and decoded on its own: only the keyframe there is read (through the session's own
    /// source, so a film on a network is not fetched twice), and decoded with Apple's decoder for H.264 and HEVC and with this build's
    /// own decoder for the rest. A host shows it while its player jumps to that place, which for the AVPlayer path waits for a whole
    /// piece of the film (Jira EGA-122).
    ///
    /// Calls are handled one at a time; a call made while an earlier one is still reading makes the earlier one give up (it returns
    /// `nil`), and so does cancelling the calling task. Returns `nil` as well when there is nothing to show: no video, a play list of
    /// several files (``playList``), a picture no decoder here takes, or no keyframe near the time.
    public func previewPicture(at seconds: TimeInterval) async throws -> PreviewPicture? {
        guard let maker = previewMaker() else { return nil }
        return try await maker.picture(at: seconds)
    }

    /// Opens the reader ``previewPicture(at:)`` uses, in the background, so that the first jump does not wait for it. Best called right
    /// after the session is made: a film on a network then reads its start once more from the session's shared cache, not from the network.
    public func preparePreviews() {
        previewMaker()?.prepare()
    }

    private func previewMaker() -> PreviewMaker? {
        guard playList == nil, let video = info.videoTracks.first else { return nil }
        return state.withLock { state -> PreviewMaker? in
            guard !state.isClosed else { return nil }
            if let maker = state.preview { return maker }
            let maker = PreviewMaker(source: source.byteSource, cancellation: cancellation, track: video, duration: duration)
            state.preview = maker
            return maker
        }
    }
}

/// Reads and decodes the stills of ``PlaybackSession/previewPicture(at:)``: one reader of the file of its own, opened at the first call
/// and kept, so later jumps only seek; everything happens on one serial queue.
final class PreviewMaker: @unchecked Sendable {
    private let source: any ByteSource
    private let cancellation: CancellationFlag
    private let stream: Int
    private let codec: String
    private let frameRate: Double?
    private let duration: Double?
    private let queue = DispatchQueue(label: "dev.mediaengine.preview", qos: .userInitiated)
    /// The newest call: an older one that sees another number gives up.
    private let latest = Mutex(0)
    private static let logger = Logger(subsystem: "dev.mediaengine", category: "player")
    /// The longest side of a still.
    static let maximumSide = 1920

    // Confined to `queue`.
    private var reader: PacketReader?
    private var appleFormat: CMVideoFormatDescription?
    private var appleFailed = false
    private var software: SoftwareVideoDecoder?
    private var softwareFailed = false
    private var transfer: VTPixelTransferSession?
    private var closed = false

    init(source: any ByteSource, cancellation: CancellationFlag, track: Track, duration: Double?) {
        self.source = source
        self.cancellation = cancellation
        stream = track.id
        codec = track.codec.name
        frameRate = track.video?.frameRate
        self.duration = duration
    }

    func picture(at seconds: Double) async throws -> PreviewPicture? {
        let ticket = latest.withLock { value -> Int in value += 1; return value }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PreviewPicture?, any Error>) in
                queue.async { continuation.resume(with: Result { try self.make(at: seconds, ticket: ticket) }) }
            }
        } onCancel: {
            latest.withLock { if $0 == ticket { $0 += 1 } }
        }
    }

    /// Opens the reader now, in the background.
    func prepare() {
        queue.async { [self] in
            guard !closed, reader == nil, !cancellation.isCancelled else { return }
            reader = try? PacketReader(source: source, cancellation: cancellation, durationHint: duration)
            if let reader, reader.hasStream(stream), codec == "h264" || codec == "hevc" {
                appleFormat = AppleDecoding.formatDescription(reader.parameters(stream))
            }
        }
    }

    /// Lets the reader and decoders go (the session closes).
    func close() {
        queue.async { [self] in
            closed = true
            reader = nil; software = nil
            if let transfer { VTPixelTransferSessionInvalidate(transfer) }
            transfer = nil
        }
    }

    private func isStale(_ ticket: Int) -> Bool { cancellation.isCancelled || latest.withLock { $0 != ticket } }

    // MARK: On the queue

    private func make(at seconds: Double, ticket: Int) throws -> PreviewPicture? {
        guard !closed, !isStale(ticket) else { return nil }
        let began = ContinuousClock.now
        if reader == nil { reader = try PacketReader(source: source, cancellation: cancellation, durationHint: duration) }
        guard let reader, reader.hasStream(stream) else { return nil }
        let found: (packet: MediaPacket, packets: Int, bytes: Int)?
        do {
            found = try keyframe(near: seconds, reader: reader, ticket: ticket)
        } catch {
            self.reader = nil                                   // opened afresh next time
            throw error
        }
        guard let found else { return nil }
        guard !isStale(ticket) else { return nil }
        let time = reader.timeBase(stream).seconds(found.packet.pts)
        var how = "Apple's decoder"
        var buffer = decodeWithApple(found.packet, reader: reader)
        if buffer == nil { buffer = decodeWithSoftware(found.packet, reader: reader); how = "this build's decoder" }
        guard let buffer, let image = image(from: buffer) else {
            Self.logger.info("Preview at \(seconds, format: .fixed(precision: 1), privacy: .public) s: the keyframe did not decode")
            return nil
        }
        let elapsed = ContinuousClock.now - began
        let milliseconds = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        Self.logger.info("Preview at \(seconds, format: .fixed(precision: 1), privacy: .public) s: keyframe at \(time, format: .fixed(precision: 2), privacy: .public) s, \(found.packets, privacy: .public) packets, \(found.bytes / 1024, privacy: .public) KB read on the way, \(milliseconds, privacy: .public) ms (\(how, privacy: .public))")
        return PreviewPicture(image: image, time: time)
    }

    /// The keyframe to show for `seconds`: the one at or before it, else the first one after it within two seconds. Files whose seeks
    /// land on the keyframe at or before the time (Matroska, MP4 with their index) give the first one met. MPEG transport and program
    /// streams seek by decode time and may land seconds early (a jump by byte position) or just after the keyframe: the reader goes on to
    /// a keyframe within a second before the time, and when it met none at or before it, tries once more from three seconds earlier
    /// (what it reads is what the player's own piece needs next, and a network film's readers share it).
    private func keyframe(near seconds: Double, reader: PacketReader, ticket: Int) throws -> (packet: MediaPacket, packets: Int, bytes: Int)? {
        let early = reader.seeksByDecodeTime
        var after: MediaPacket?
        var packets = 0, bytes = 0
        for back in early ? [0.3, 3.0] : [0.0] {
            let found = try scan(from: max(seconds - back, 0), to: seconds, early: early, reader: reader, ticket: ticket)
            packets += found.packets; bytes += found.bytes
            if let before = found.before { return (before, packets, bytes) }
            if after == nil { after = found.after }
            if isStale(ticket) || seconds - back <= 0 { break }
        }
        return after.map { ($0, packets, bytes) }
    }

    private func scan(from start: Double, to seconds: Double, early: Bool, reader: PacketReader, ticket: Int)
        throws -> (before: MediaPacket?, after: MediaPacket?, packets: Int, bytes: Int) {
        let base = reader.timeBase(stream)
        if start <= 0 { try reader.rewind() } else { try reader.seek(stream: stream, to: base.ticks(seconds: start)) }
        reader.limit(to: [stream])
        var before: MediaPacket?, after: MediaPacket?
        var packets = 0, bytes = 0
        while let packet = try reader.next() {
            if isStale(ticket) { break }
            guard packet.stream == stream else { continue }
            packets += 1
            bytes += packet.data.count
            if packet.isKeyframe {
                let time = base.seconds(packet.pts)
                if time > seconds + 0.04 {
                    if time <= seconds + 2 { after = packet }
                    break
                }
                before = packet
                if !early || time >= seconds - 1 { break }
            }
            if packets >= 3000 || bytes >= 24 << 20 { break }
        }
        return (before, after, packets, bytes)
    }

    /// H.264 and HEVC through VideoToolbox (hardware where there is one), straight to a scaled BGRA picture.
    private func decodeWithApple(_ packet: MediaPacket, reader: PacketReader) -> CVPixelBuffer? {
        guard !appleFailed, codec == "h264" || codec == "hevc" else { return nil }
        if appleFormat == nil { appleFormat = AppleDecoding.formatDescription(reader.parameters(stream)) }
        guard let format = appleFormat else { appleFailed = true; return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let size = Self.scaled(width: Int(dimensions.width), height: Int(dimensions.height))
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else {
            appleFailed = true                                  // Hi10P and the like on a device without such a decoder: the build's own
            return nil
        }
        defer { VTDecompressionSessionInvalidate(session) }
        guard let sample = Self.sampleBuffer(packet, format: format, timeBase: reader.timeBase(stream)) else { return nil }
        let output = FrameSlot()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { output.put(image) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? output.take() : nil
    }

    private static func sampleBuffer(_ packet: MediaPacket, format: CMVideoFormatDescription, timeBase: Rational) -> CMSampleBuffer? {
        let count = packet.data.count
        guard count > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = packet.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: count)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: timeBase.seconds(packet.pts), preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var size = count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    /// Everything else (and H.264 or HEVC that Apple's decoder refused) through the build's own decoder, made once and flushed
    /// before each still.
    private func decodeWithSoftware(_ packet: MediaPacket, reader: PacketReader) -> CVPixelBuffer? {
        guard !softwareFailed else { return nil }
        if software == nil {
            let declared = reader.stream(stream).pointee.sample_aspect_ratio
            software = try? SoftwareVideoDecoder(parameters: reader.parameters(stream), timeBase: reader.timeBase(stream), frameRate: frameRate,
                                                 containerAspect: declared.num > 0 && declared.den > 0 ? Rational(declared) : nil)
            if software == nil { softwareFailed = true; return nil }
        }
        guard let software else { return nil }
        software.flush()
        software.send(packet)
        software.send(nil)
        return software.receive()?.pixelBuffer
    }

    /// A decoded picture as a `CGImage`, converted to BGRA at most ``maximumSide`` pixels on its longest side when it is not already.
    private func image(from buffer: CVPixelBuffer) -> CGImage? {
        var picture = buffer
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let size = Self.scaled(width: width, height: height)
        if CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA || size.width != width || size.height != height {
            if transfer == nil {
                var made: VTPixelTransferSession?
                VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made)
                transfer = made
            }
            var converted: CVPixelBuffer?
            guard let transfer,
                  CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &converted) == kCVReturnSuccess,
                  let converted, VTPixelTransferSessionTransferImage(transfer, from: buffer, to: converted) == noErr else { return nil }
            picture = converted
        }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(picture, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }

    /// The size a still is made at: the picture's own, or smaller to fit ``maximumSide``, even numbers.
    static func scaled(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (max(width, 2), max(height, 2)) }
        let factor = min(1, Double(maximumSide) / Double(max(width, height)))
        func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
        return (factor < 1 ? even(Double(width) * factor) : width, factor < 1 ? even(Double(height) * factor) : height)
    }
}

/// Where VideoToolbox's output handler leaves the decoded picture (read after `VTDecompressionSessionWaitForAsynchronousFrames`).
private final class FrameSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    func put(_ picture: CVPixelBuffer) { lock.lock(); buffer = picture; lock.unlock() }
    func take() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
}
