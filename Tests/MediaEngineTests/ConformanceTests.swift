import CryptoKit
import FFmpegLGPL
import Foundation
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// The official decoder conformance vectors of VP8, VP9 and AV1 (libvpx and libaom test data), decoded with the engine's
/// decoders and compared frame by frame with the publishers' MD5 files (SWD-3). The vectors are downloaded by
/// `scripts/fetch-conformance.sh` into `build/conformance/mkv` (never committed); `scripts/verify.sh` fetches them for the
/// extended build, which is the only one that contains the decoders.
enum Conformance {
    static let directory = Fixture.root.appendingPathComponent("build/conformance/mkv")

    /// Every vector that was downloaded (the name without extension).
    static let vectors: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".md5") }.map { String($0.dropLast(4)) }.sorted()
    }()

    static func stream(_ name: String) -> URL {
        for ext in ["mkv", "webm"] {
            let candidate = directory.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(name).mkv")
    }

    struct Reference { var md5: String; var size: (width: Int, height: Int)? }

    /// Lines of `<md5>  <stream>-<width>x<height>-<n>.i420` (one stream names its frames `01.yuv` instead: no size then).
    static func references(_ name: String) throws -> [Reference] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name).md5"), encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            let label = try #require(parts.last)
            let dimensions = label.split(separator: "-").dropLast().last.map { $0.split(separator: "x").compactMap { Int($0) } } ?? []
            return Reference(md5: String(parts[0]), size: dimensions.count == 2 ? (dimensions[0], dimensions[1]) : nil)
        }
    }

    struct Output { var md5: String; var width: Int; var height: Int; var format: String }

    /// Decodes the first video stream (threaded like the software player) and hashes every picture exactly as the codec
    /// projects do: each plane, row by row, without padding, 16-bit little endian above 8 bits.
    static func decode(_ url: URL) throws -> [Output] {
        let reader = try PacketReader(source: FileByteSource(url: url), cancellation: CancellationFlag())
        let index = try #require((0..<reader.streamCount).first { reader.parameters($0).pointee.codec_type == AVMEDIA_TYPE_VIDEO })
        let parameters = reader.parameters(index)
        let codec = try #require(avcodec_find_decoder(parameters.pointee.codec_id), "no decoder")
        let context = try #require(avcodec_alloc_context3(codec))
        defer { var pointer: UnsafeMutablePointer<AVCodecContext>? = context; avcodec_free_context(&pointer) }
        try #require(avcodec_parameters_to_context(context, parameters) >= 0)
        context.pointee.thread_count = 0
        context.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        try #require(avcodec_open2(context, codec, nil) >= 0)
        let frame = try #require(av_frame_alloc())
        defer { var pointer: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&pointer) }

        var outputs: [Output] = []
        func drain() {
            while avcodec_receive_frame(context, frame) >= 0 {
                outputs.append(hash(frame))
                av_frame_unref(frame)
            }
        }
        while let packet = try reader.next() {
            guard packet.stream == index else { continue }
            var av = AVPacket()
            guard av_new_packet(&av, Int32(packet.data.count)) >= 0 else { continue }
            packet.data.withUnsafeBytes { if let base = $0.baseAddress { memcpy(av.data, base, $0.count) } }
            av.pts = packet.pts; av.dts = packet.dts
            avcodec_send_packet(context, &av)
            av_packet_unref(&av)
            drain()
        }
        avcodec_send_packet(context, nil)
        drain()
        return outputs
    }

    private static func hash(_ frame: UnsafeMutablePointer<AVFrame>) -> Output {
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        let description = av_pix_fmt_desc_get(format)!.pointee
        let bytes = description.comp.0.depth > 8 ? 2 : 1
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        var md5 = Insecure.MD5()
        let planes = Int(av_pix_fmt_count_planes(format))
        let data = [frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2]
        let strides = [Int(frame.pointee.linesize.0), Int(frame.pointee.linesize.1), Int(frame.pointee.linesize.2)]
        for plane in 0..<min(planes, 3) {
            let planeWidth = plane == 0 ? width : (width + (1 << Int(description.log2_chroma_w)) - 1) >> Int(description.log2_chroma_w)
            let planeHeight = plane == 0 ? height : (height + (1 << Int(description.log2_chroma_h)) - 1) >> Int(description.log2_chroma_h)
            guard let base = data[plane] else { continue }
            for row in 0..<planeHeight {
                md5.update(bufferPointer: UnsafeRawBufferPointer(start: base + row * strides[plane], count: planeWidth * bytes))
            }
        }
        let name = String(cString: av_get_pix_fmt_name(format))
        return Output(md5: md5.finalize().map { String(format: "%02x", $0) }.joined(), width: width, height: height, format: name)
    }
}

@Suite("Decoder conformance", .enabled(if: isExtendedBuild))
struct ConformanceTests {
    @Test("the conformance vectors have been downloaded")
    func vectorsPresent() {
        #expect(Conformance.vectors.count >= 60, "run scripts/fetch-conformance.sh (found \(Conformance.vectors.count))")
    }

    @Test("every frame is bit-exact with the codec project's reference output", arguments: Conformance.vectors)
    func bitExact(name: String) throws {
        let expected = try Conformance.references(name)
        let actual = try Conformance.decode(Conformance.stream(name))
        #expect(actual.count == expected.count, "\(name): \(actual.count) frames decoded, \(expected.count) expected")
        for (number, pair) in zip(actual, expected).enumerated() {
            let sizeMatches = pair.1.size.map { $0.width == pair.0.width && $0.height == pair.0.height } ?? true
            guard pair.0.md5 != pair.1.md5 || !sizeMatches else { continue }
            Issue.record("\(name): frame \(number + 1) is \(pair.0.width)x\(pair.0.height) \(pair.0.format) md5 \(pair.0.md5), expected md5 \(pair.1.md5) \(pair.1.size.map { "\($0.width)x\($0.height)" } ?? "")")
            return
        }
    }
}
