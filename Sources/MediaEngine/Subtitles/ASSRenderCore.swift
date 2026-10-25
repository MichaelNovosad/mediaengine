import CoreGraphics
import Foundation
internal import LibASS
import Synchronization

/// Messages libass prints (font selection, script problems), kept for diagnostics and tests.
final class ASSMessageLog: @unchecked Sendable {
    private let lines = Mutex<[String]>([])
    private static let limit = 400

    func add(_ line: String) {
        lines.withLock { lines in
            if lines.count >= Self.limit { lines.removeFirst(Self.limit / 4) }
            lines.append(line)
        }
    }

    var all: [String] { lines.withLock { $0 } }
}

/// Formats and stores one libass message. (The callback itself is a closure written where it is passed: a C `va_list`
/// parameter can be named only in the position of an imported function pointer.)
private func record(_ level: Int32, _ format: UnsafePointer<CChar>?, _ arguments: CVaListPointer?, _ data: UnsafeMutableRawPointer?) {
    guard let format, let arguments, let data else { return }
    var buffer = [CChar](repeating: 0, count: 1024)
    _ = vsnprintf(&buffer, buffer.count, format, arguments)
    let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    Unmanaged<ASSMessageLog>.fromOpaque(data).takeUnretainedValue().add("[\(level)] \(text)")
}

/// libass: one library, one renderer and one track. Not thread-safe; ``SubtitleRenderer`` serialises access.
///
/// Fonts come from the container's attachments (added here) and from the system through the CoreText font provider,
/// which also finds fallbacks for CJK, Indic and other scripts. Shaping goes through HarfBuzz and bidirectional text
/// through FriBidi inside libass.
final class ASSRenderCore {
    /// What one frame of subtitles looks like: a single image over the union of everything libass drew.
    struct Rendered {
        var image: CGImage
        var frame: CGRect
    }

    let log = ASSMessageLog()
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private var track: UnsafeMutablePointer<ASS_Track>?
    private var frameSize = (width: 0, height: 0)
    private var cache: (time: Int64, rendered: Rendered?)?

    init?(fonts: [(name: String, data: Data)], storageSize: CGSize?, verbose: Bool = false) {
        guard let library = ass_library_init() else { return nil }
        self.library = library
        ass_set_message_cb(library, { level, format, arguments, data in record(level, format, arguments, data) },
                           Unmanaged.passUnretained(log).toOpaque())
        for font in fonts {
            font.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count > 0 else { return }
                ass_add_font(library, font.name, base, Int32(raw.count))
            }
        }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            return nil
        }
        self.renderer = renderer
        ass_set_fonts(renderer, nil, "Helvetica", Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
        ass_set_hinting(renderer, ASS_HINTING_NONE)
        ass_set_shaper(renderer, ASS_SHAPING_COMPLEX)
        if let storageSize, storageSize.width > 0, storageSize.height > 0 {
            ass_set_storage_size(renderer, Int32(storageSize.width), Int32(storageSize.height))
        }
    }

    deinit {
        if let track { ass_free_track(track) }
        ass_renderer_done(renderer)
        ass_library_done(library)
    }

    /// A track made from the codec's private data (Matroska: the script header with the styles); events follow with
    /// ``addEvent(_:start:duration:)``.
    func startTrack(header: Data) -> Bool {
        guard let track = ass_new_track(library) else { return false }
        header.withUnsafeBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) { ass_process_codec_private(track, base, Int32(raw.count)) }
        }
        // The engine removes repeated blocks itself (see ASSBackend): ReadOrder numbers restart in every file of a play list.
        ass_set_check_readorder(track, 0)
        self.track = track
        cache = nil
        return true
    }

    /// A track from a whole script (an external `.ass` file), UTF-8.
    func loadScript(_ script: Data) -> Bool {
        var bytes = script
        let track: UnsafeMutablePointer<ASS_Track>? = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            return ass_read_memory(library, base, raw.count, nil)
        }
        guard let track else { return false }
        self.track = track
        cache = nil
        return true
    }

    /// One Matroska block (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`).
    func addEvent(_ data: Data, start: Int64, duration: Int64) {
        guard let track else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) { ass_process_chunk(track, base, Int32(raw.count), start, duration) }
        }
        cache = nil
    }

    /// Draws the subtitles shown at `milliseconds` into one picture of `width` x `height` pixels, or `nil` when
    /// nothing is shown. `changed` is false when the result is exactly what the previous call at the same size returned.
    func render(atMilliseconds milliseconds: Int64, width: Int, height: Int) -> (rendered: Rendered?, changed: Bool) {
        guard let track, width > 0, height > 0 else { return (nil, false) }
        var sizeChanged = false
        if frameSize.width != width || frameSize.height != height {
            ass_set_frame_size(renderer, Int32(width), Int32(height))
            frameSize = (width, height)
            sizeChanged = true
            cache = nil
        }
        var change: Int32 = 0
        let head = ass_render_frame(renderer, track, milliseconds, &change)
        if change == 0, !sizeChanged, let cache { return (cache.rendered, false) }
        let rendered = Self.composite(head)
        cache = (milliseconds, rendered)
        return (rendered, true)
    }

    // MARK: Compositing

    /// Blends libass's alpha masks (each with its own colour) over a transparent picture the size of their union.
    /// libass reports transparency, not opacity, in the low byte of the colour.
    private static func composite(_ head: UnsafeMutablePointer<ASS_Image>?) -> Rendered? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var cursor = head
        var count = 0
        while let image = cursor {
            let w = Int(image.pointee.w), h = Int(image.pointee.h)
            if w > 0, h > 0 {
                minX = min(minX, Int(image.pointee.dst_x)); minY = min(minY, Int(image.pointee.dst_y))
                maxX = max(maxX, Int(image.pointee.dst_x) + w); maxY = max(maxY, Int(image.pointee.dst_y) + h)
                count += 1
            }
            cursor = image.pointee.next
        }
        guard count > 0, maxX > minX, maxY > minY else { return nil }
        let width = maxX - minX, height = maxY - minY
        var pixels = [UInt8](repeating: 0, count: width * height * 4)          // premultiplied RGBA

        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            cursor = head
            while let image = cursor {
                defer { cursor = image.pointee.next }
                let w = Int(image.pointee.w), h = Int(image.pointee.h), stride = Int(image.pointee.stride)
                guard w > 0, h > 0, let bitmap = image.pointee.bitmap else { continue }
                let color = image.pointee.color
                let opacity = 255 - Int(color & 0xFF)
                if opacity == 0 { continue }
                let red = Int((color >> 24) & 0xFF), green = Int((color >> 16) & 0xFF), blue = Int((color >> 8) & 0xFF)
                let x0 = Int(image.pointee.dst_x) - minX, y0 = Int(image.pointee.dst_y) - minY
                for row in 0..<h {
                    let source = bitmap + row * stride
                    var target = base + ((y0 + row) * width + x0) * 4
                    for column in 0..<w {
                        let mask = Int(source[column])
                        if mask != 0 {
                            let alpha = (mask * opacity + 127) / 255                  // 0...255
                            let inverse = 255 - alpha
                            target[0] = UInt8((red * alpha + 127) / 255 + (Int(target[0]) * inverse + 127) / 255)
                            target[1] = UInt8((green * alpha + 127) / 255 + (Int(target[1]) * inverse + 127) / 255)
                            target[2] = UInt8((blue * alpha + 127) / 255 + (Int(target[2]) * inverse + 127) / 255)
                            target[3] = UInt8(alpha + (Int(target[3]) * inverse + 127) / 255)
                        }
                        target += 4
                    }
                }
            }
        }
        guard let cgImage = ImageMaking.cgImage(premultipliedRGBA: pixels, width: width, height: height) else { return nil }
        return Rendered(image: cgImage, frame: CGRect(x: minX, y: minY, width: width, height: height))
    }
}

enum ImageMaking {
    static func cgImage(premultipliedRGBA pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
