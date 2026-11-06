import CoreGraphics
internal import FFmpegLGPL
import Foundation

/// One subtitle block as the container stores it, on the file's timeline.
struct OverlayEvent: Sendable {
    var data: Data
    var start: Double
    var duration: Double
}

/// Something that can draw the subtitles shown at one moment. Used from one thread at a time (see ``SubtitleRenderer``).
protocol OverlayBackend: AnyObject {
    /// New events (blocks seen again are ignored).
    func add(_ events: [OverlayEvent])
    /// The pictures to draw `time` seconds into the file, at the position and size they take in a frame of `size`.
    /// `changed` is false when they are exactly those returned last time.
    func render(at time: Double, size: CGSize) -> (images: [SubtitleImage], changed: Bool)
    /// The viewer's size and colour for text; picture subtitles ignore it.
    func setAppearance(_ appearance: SubtitleAppearance)
    /// Whether a block can depend on the blocks before it (PGS display sets that reuse an earlier picture), so that blocks given
    /// out of order should be given again in order.
    var decodesInOrder: Bool { get }
}

extension OverlayBackend {
    func setAppearance(_ appearance: SubtitleAppearance) {}
    var decodesInOrder: Bool { false }
}

/// ASS and SSA through libass.
final class ASSBackend: OverlayBackend {
    let core: ASSRenderCore

    /// Streams from a container: `header` is the codec's private data, the blocks follow through ``add(_:)``.
    init?(header: Data, fonts: [(name: String, data: Data)], videoSize: CGSize?) {
        guard let core = ASSRenderCore(fonts: fonts, storageSize: videoSize), core.startTrack(header: header) else { return nil }
        self.core = core
    }

    /// A complete script (an external `.ass` file).
    init?(script: Data, fonts: [(name: String, data: Data)], videoSize: CGSize?) {
        guard let core = ASSRenderCore(fonts: fonts, storageSize: videoSize), core.loadScript(script) else { return nil }
        self.core = core
    }

    /// Blocks already given to libass. Windows overlap, so a block is read more than once; libass's own check goes by
    /// ReadOrder, which starts again at 0 in every file of a play list, so the blocks are compared by content instead.
    private struct Seen: Hashable {
        var start: Int64
        var duration: Int64
        var data: Data
    }
    private var seen = Set<Seen>()

    func setAppearance(_ appearance: SubtitleAppearance) { core.setAppearance(appearance) }

    func add(_ events: [OverlayEvent]) {
        for event in events {
            let key = Seen(start: Int64((event.start * 1000).rounded()), duration: Int64((max(event.duration, 0) * 1000).rounded()), data: event.data)
            guard seen.insert(key).inserted else { continue }
            core.addEvent(event.data, start: Int64((event.start * 1000).rounded()), duration: Int64((max(event.duration, 0) * 1000).rounded()))
        }
    }

    func render(at time: Double, size: CGSize) -> (images: [SubtitleImage], changed: Bool) {
        let result = core.render(atMilliseconds: Int64((time * 1000).rounded()), width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        return (result.rendered.map { [SubtitleImage(image: $0.image, frame: $0.frame)] } ?? [], result.changed)
    }
}

/// Picture subtitles (PGS, VobSub, DVB) through FFmpeg's decoders.
final class BitmapBackend: OverlayBackend {
    private struct Display {
        var start: Double
        var end: Double?                       // nil: until the next display
        var pictures: [(image: CGImage, rect: CGRect)]
    }

    private let context: UnsafeMutablePointer<AVCodecContext>
    private let videoSize: CGSize
    private var displays: [Display] = []       // sorted by start
    /// Displays decoded with pictures, and those decoded empty: a clear, or a display set decoded before the one whose pictures
    /// it reuses (blocks given out of order), which a later decode in order replaces.
    private var known = Set<Int64>()
    private var empty = Set<Int64>()

    var decodesInOrder: Bool { true }
    private var lastShown: (start: Double, size: CGSize)?

    init?(parameters: UnsafeMutablePointer<AVCodecParameters>, videoSize: CGSize?) {
        FFmpegLogging.ensureInstalled()
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id), let context = avcodec_alloc_context3(codec) else { return nil }
        guard avcodec_parameters_to_context(context, parameters) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return nil
        }
        context.pointee.pkt_timebase = AVRational(num: 1, den: 1_000_000)
        guard avcodec_open2(context, codec, nil) >= 0 else {
            var pointer: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&pointer)
            return nil
        }
        self.context = context
        let declared = CGSize(width: Int(context.pointee.width), height: Int(context.pointee.height))
        self.videoSize = declared.width > 0 && declared.height > 0 ? declared : (videoSize ?? CGSize(width: 1920, height: 1080))
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&pointer)
    }

    func add(_ events: [OverlayEvent]) {
        // Each window is decoded as one run from its start: PGS display sets build on the ones before them.
        avcodec_flush_buffers(context)
        for event in events.sorted(by: { $0.start < $1.start }) { decode(event) }
        displays.sort { $0.start < $1.start }
    }

    private func decode(_ event: OverlayEvent) {
        var packet = AVPacket()
        guard !event.data.isEmpty, av_new_packet(&packet, Int32(event.data.count)) >= 0 else { return }
        defer { av_packet_unref(&packet) }
        event.data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(packet.data, base, raw.count) }
        }
        packet.pts = Int64((event.start * 1_000_000).rounded())
        packet.dts = packet.pts
        packet.duration = Int64((max(event.duration, 0) * 1_000_000).rounded())

        var subtitle = AVSubtitle()
        var got: Int32 = 0
        guard avcodec_decode_subtitle2(context, &subtitle, &got, &packet) >= 0, got != 0 else { return }
        defer { avsubtitle_free(&subtitle) }

        let begin = event.start + Double(subtitle.start_display_time) / 1000
        let key = Int64((begin * 1000).rounded())
        guard !known.contains(key) else { return }
        var end: Double?
        if subtitle.end_display_time != 0, subtitle.end_display_time != UInt32.max { end = event.start + Double(subtitle.end_display_time) / 1000 }
        if end == nil, event.duration > 0 { end = begin + event.duration }
        if let stop = end, stop <= begin { end = nil }

        var pictures: [(CGImage, CGRect)] = []
        for index in 0..<Int(subtitle.num_rects) {
            guard let rect = subtitle.rects[index]?.pointee, rect.type == SUBTITLE_BITMAP, let image = Self.image(of: rect) else { continue }
            pictures.append((image, CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.w), height: Int(rect.h))))
        }
        if pictures.isEmpty {
            guard empty.insert(key).inserted else { return }
        } else {
            known.insert(key)
            if empty.remove(key) != nil { displays.removeAll { Int64(($0.start * 1000).rounded()) == key && $0.pictures.isEmpty } }
        }
        displays.append(Display(start: begin, end: end, pictures: pictures))
    }

    func render(at time: Double, size: CGSize) -> (images: [SubtitleImage], changed: Bool) {
        // The last display that has started; an empty one (PGS "clear") or one past its end shows nothing.
        var low = 0, high = displays.count
        while low < high {
            let middle = (low + high) / 2
            if displays[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return ([], changedTo(nil, size)) }
        let display = displays[low - 1]
        if display.pictures.isEmpty || (display.end.map { time >= $0 } ?? false) { return ([], changedTo(nil, size)) }
        let scaleX = size.width / videoSize.width, scaleY = size.height / videoSize.height
        let images = display.pictures.map { picture in
            SubtitleImage(image: picture.image, frame: CGRect(x: picture.rect.minX * scaleX, y: picture.rect.minY * scaleY,
                                                               width: picture.rect.width * scaleX, height: picture.rect.height * scaleY))
        }
        return (images, changedTo(display.start, size))
    }

    private func changedTo(_ start: Double?, _ size: CGSize) -> Bool {
        let previous = lastShown
        lastShown = start.map { ($0, size) }
        if let start { return previous?.start != start || previous?.size != size }
        return previous != nil
    }

    /// A palette picture as premultiplied RGBA.
    private static func image(of rect: AVSubtitleRect) -> CGImage? {
        let width = Int(rect.w), height = Int(rect.h)
        guard width > 0, height > 0, let indices = rect.data.0, let palette = rect.data.1 else { return nil }
        let stride = Int(rect.linesize.0)
        let colors = palette.withMemoryRebound(to: UInt32.self, capacity: 256) { Array(UnsafeBufferPointer(start: $0, count: 256)) }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let argb = colors[Int(indices[row * stride + column])]
                let alpha = Int((argb >> 24) & 0xFF)
                let target = (row * width + column) * 4
                pixels[target] = UInt8((Int((argb >> 16) & 0xFF) * alpha + 127) / 255)
                pixels[target + 1] = UInt8((Int((argb >> 8) & 0xFF) * alpha + 127) / 255)
                pixels[target + 2] = UInt8((Int(argb & 0xFF) * alpha + 127) / 255)
                pixels[target + 3] = UInt8(alpha)
            }
        }
        return ImageMaking.cgImage(premultipliedRGBA: pixels, width: width, height: height)
    }
}

/// Where blocks come from, a window of time at a time.
protocol OverlayEventSource: AnyObject {
    /// The blocks that start in `[from, to)`. Called from one thread at a time.
    func events(from: Double, to: Double) throws -> [OverlayEvent]
}

/// Reads the blocks of one subtitle stream from a file (or a play list) a window at a time.
final class OverlayEventLoader: OverlayEventSource {
    private let source: any PacketSource
    private let stream: Int
    private let anchor: Int
    private let cancellation: CancellationFlag

    /// - Parameters:
    ///   - anchor: A stream with an index to seek by (the video, else an audio stream).
    ///   - marker: A cheap stream whose packets tell how far the file has been read (audio, else the video).
    init(source: any PacketSource, stream: Int, anchor: Int, marker: Int, cancellation: CancellationFlag) {
        self.source = source
        self.stream = stream
        self.anchor = anchor
        self.cancellation = cancellation
        source.limit(to: [stream, marker])
    }

    /// The blocks that start in `[from, to)`. Not thread-safe.
    func events(from: Double, to: Double) throws -> [OverlayEvent] {
        let subtitleBase = source.timeBase(stream)
        if from <= 0 { try source.rewind() } else { try source.seek(stream: anchor, to: source.timeBase(anchor).ticks(seconds: from)) }
        var result: [OverlayEvent] = []
        while let packet = try source.next() {
            if cancellation.isCancelled { throw MediaError.cancelled }
            let seconds = source.timeBase(packet.stream).seconds(packet.pts)
            if packet.stream == stream {
                let start = subtitleBase.seconds(packet.pts)
                if start >= from, start < to {
                    result.append(OverlayEvent(data: packet.data, start: start, duration: subtitleBase.seconds(max(packet.duration, 0))))
                }
            }
            if seconds >= to + 1.5 { break }                  // far enough: later blocks are not needed yet
        }
        return result
    }
}
