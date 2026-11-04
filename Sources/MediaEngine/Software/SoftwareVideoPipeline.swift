internal import FFmpegLGPL
import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Reads, decodes and queues the pictures of one video stream for an `AVSampleBufferDisplayLayer`. The layer is attached to
/// a render synchronizer, which is the clock: it shows each picture when the synchronizer's time reaches the picture's
/// presentation time, so whoever owns the synchronizer decides when pictures appear. The reader and the decoder are only
/// touched by the feeding task, and a new task starts only after the old one has ended.
final class SoftwareVideoPipeline: @unchecked Sendable {
    struct Statistics: Sendable, Equatable {
        /// Pictures the decoder produced.
        var decoded = 0
        /// Pictures given to the display layer.
        var queued = 0
        /// Pictures thrown away because they were already late (the machine could not keep up) when they came out of the decoder.
        var dropped = 0
        /// Presentation time of the last picture given to the layer.
        var lastQueuedTime = 0.0
    }

    /// Show this in a view (`MediaVideoView`); it must be created, put in a layer tree and changed on the main actor.
    let layer: AVSampleBufferDisplayLayer
    /// The clock the pictures follow (set its rate and time to play, pause or seek).
    let synchronizer: AVSampleBufferRenderSynchronizer

    /// Hands the pictures to the layer's renderer, through the synchronizer. iOS, macOS and visionOS 27 have the synchronizer's Swift
    /// receiver (it waits until the renderer wants more and says why an enqueue was cancelled); 26, the minimum since 2026-11-04, has
    /// the classic calls of the same renderer.
    private final class Sink: @unchecked Sendable {
        enum Outcome { case enqueued, stop }

        private let renderer: AVSampleBufferVideoRenderer
        /// `AVSampleBufferVideoRenderer.Receiver` on 27 and newer (a stored property cannot carry an availability of its own).
        private let receiver: AnyObject?

        @MainActor
        init(renderer: AVSampleBufferVideoRenderer, synchronizer: AVSampleBufferRenderSynchronizer) {
            self.renderer = renderer
            if #available(iOS 27, macOS 27, visionOS 27, *) {
                receiver = synchronizer.sampleBufferReceiver(adding: renderer)
            } else {
                synchronizer.addRenderer(renderer)
                receiver = nil
            }
        }

        func flush(removingDisplayedImage: Bool) async {
            if #available(iOS 27, macOS 27, visionOS 27, *), let receiver = receiver as? AVSampleBufferVideoRenderer.Receiver {
                await receiver.flush(removingDisplayedImage: removingDisplayedImage)
                return
            }
            let renderer = renderer
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                renderer.flush(removingDisplayedImage: removingDisplayedImage) { done.resume() }
            }
        }

        /// Waits until the renderer wants more, then queues the picture; `.stop` ends the feeding (a flush, an error, a cancel).
        func enqueue(_ sample: sending CMSampleBuffer) async -> Outcome {
            if #available(iOS 27, macOS 27, visionOS 27, *), let receiver = receiver as? AVSampleBufferVideoRenderer.Receiver {
                do {
                    switch try await receiver.enqueue(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)) {
                    case .enqueued, .enqueuedWithDecodeFailures: return .enqueued
                    case .cancelledDueToFlush, .cancelledDueToFlushRequiredToResume, .cancelledDueToError: return .stop
                    @unknown default: return .stop
                    }
                } catch {
                    return .stop
                }
            }
            // The classic way: the renderer says when it wants more; asked every 10 ms, as a picture lasts 16 ms or more.
            while !renderer.isReadyForMoreMediaData {
                if Task.isCancelled || renderer.status == .failed { return .stop }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled else { return .stop }
            renderer.enqueue(sample)
            return renderer.status == .failed ? .stop : .enqueued
        }
    }

    private let sink: Sink
    private let reader: PacketReader
    private let decoder: SoftwareVideoDecoder
    private let stream: Int
    private let statistics = Mutex(Statistics())
    private let hook = Mutex<(@Sendable (DecodedFrame) -> Void)?>(nil)
    private let endHandler = Mutex<(@Sendable () -> Void)?>(nil)
    private let task = Mutex<Task<Void, Never>?>(nil)
    private let lateTolerance = 0.12

    @MainActor
    init(reader: PacketReader, stream: Int, frameRate: Double?) throws {
        layer = AVSampleBufferDisplayLayer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        sink = Sink(renderer: layer.sampleBufferRenderer, synchronizer: synchronizer)
        layer.videoGravity = .resizeAspect
        self.reader = reader
        self.stream = stream
        let declared = reader.stream(stream).pointee.sample_aspect_ratio
        decoder = try SoftwareVideoDecoder(parameters: reader.parameters(stream), timeBase: reader.timeBase(stream), frameRate: frameRate,
                                           containerAspect: declared.num > 0 && declared.den > 0 ? Rational(declared) : nil)
        reader.limit(to: [stream])
    }

    var currentStatistics: Statistics { statistics.withLock { $0 } }

    /// What to do with interlaced pictures; takes effect with the next decoded picture.
    func setDeinterlacing(_ mode: Deinterlacing) { decoder.setDeinterlacing(mode) }

    /// Called for every picture handed to the layer (tests and diagnostics).
    func onFrame(_ handler: (@Sendable (DecodedFrame) -> Void)?) { hook.withLock { $0 = handler } }
    /// Called once when the stream has no more pictures.
    func onEnd(_ handler: (@Sendable () -> Void)?) { endHandler.withLock { $0 = handler } }

    /// Starts feeding at `time`: decoding begins at the keyframe before it, pictures from `time` on are shown (the first
    /// one at once, so a paused player shows the picture it was moved to). Whatever was queued is thrown away first.
    func start(at time: Double) async {
        await stop()
        await sink.flush(removingDisplayedImage: false)
        let discardBefore = max(time, 0)
        decoder.flush()
        if discardBefore <= 0 { try? reader.rewind() } else { try? reader.seek(stream: stream, to: reader.timeBase(stream).ticks(seconds: discardBefore)) }
        reader.limit(to: [stream])
        let feeding = Task.detached(priority: .userInitiated) { [self] in await feed(from: discardBefore) }
        task.withLock { $0 = feeding }
    }

    /// Stops feeding and waits until the feeding task has ended.
    func stop() async {
        let running = task.withLock { current -> Task<Void, Never>? in defer { current = nil }; return current }
        running?.cancel()
        await running?.value
    }

    /// Stops and forgets what was queued; used before the owner of the pipeline lets it go.
    func close() async {
        await stop()
        await sink.flush(removingDisplayedImage: true)
    }

    // MARK: The feeding task

    private func feed(from discardBefore: Double) async {
        var first = true
        var formatDescription: CMVideoFormatDescription?
        var sentEnd = false
        while !Task.isCancelled {
            // The next picture at or after the seek target, in presentation order.
            var next: DecodedFrame?
            while next == nil {
                if let frame = decoder.receive() {
                    if frame.time + frame.duration / 2 >= discardBefore { next = frame }
                    continue
                }
                if sentEnd { break }
                guard let packet = try? reader.next() else { sentEnd = true; decoder.send(nil); continue }
                if packet.stream == stream { decoder.send(packet) }
            }
            guard let frame = next else {
                if !Task.isCancelled { endHandler.withLock { $0 }?() }
                return
            }
            statistics.withLock { $0.decoded += 1 }
            if !first, synchronizer.rate > 0, frame.time + frame.duration < synchronizer.currentTime().seconds - lateTolerance {
                statistics.withLock { $0.dropped += 1 }
                continue
            }
            guard let sample = makeSample(frame, formatDescription: &formatDescription, immediately: first) else { continue }
            first = false
            switch await sink.enqueue(sample) {
            case .enqueued:
                statistics.withLock { $0.queued += 1; $0.lastQueuedTime = frame.time }
                hook.withLock { $0 }?(frame)
            case .stop:
                return
            }
        }
    }

    private func makeSample(_ frame: DecodedFrame, formatDescription: inout CMVideoFormatDescription?, immediately: Bool) -> CMSampleBuffer? {
        let buffer = frame.pixelBuffer
        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: buffer) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &formatDescription)
        }
        guard let description = formatDescription else { return nil }
        let scale: CMTimeScale = 90_000
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: frame.duration, preferredTimescale: scale),
                                        presentationTimeStamp: CMTime(seconds: frame.time, preferredTimescale: scale),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: description,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if immediately, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
