import Foundation
import FFmpegLGPL
import Testing
@testable import MediaEngine

// These tests prove the packaged framework links, imports into Swift, and can demux real Matroska
// files through a custom reader (the shape the library's ByteSource will take).

private let averrorEOF: Int32 = -541_478_725   // AVERROR_EOF (FFERRTAG('E','O','F',' ')); not importable as a macro

private final class MemorySource {
    let data: Data
    var position = 0
    init(_ data: Data) { self.data = data }
}

private func readPacket(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    let source = Unmanaged<MemorySource>.fromOpaque(opaque!).takeUnretainedValue()
    let remaining = source.data.count - source.position
    if remaining <= 0 { return averrorEOF }
    let count = min(Int(size), remaining)
    source.data.copyBytes(to: buffer!, from: source.position..<(source.position + count))
    source.position += count
    return Int32(count)
}

private func seekPacket(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    let source = Unmanaged<MemorySource>.fromOpaque(opaque!).takeUnretainedValue()
    if whence & AVSEEK_SIZE != 0 { return Int64(source.data.count) }
    let target: Int64
    switch whence & ~AVSEEK_FORCE {
    case SEEK_SET: target = offset
    case SEEK_CUR: target = Int64(source.position) + offset
    case SEEK_END: target = Int64(source.data.count) + offset
    default: return -1
    }
    guard target >= 0, target <= Int64(source.data.count) else { return -1 }
    source.position = Int(target)
    return target
}

private struct ProbedStream: Equatable {
    var kind: AVMediaType
    var codec: AVCodecID
    var language: String?
    var title: String?
}

private struct Probed {
    var streams: [ProbedStream]
    var chapterTitles: [String]
    var duration: Double
}

private func metadata(_ dict: OpaquePointer?, _ key: String) -> String? {
    guard let entry = av_dict_get(dict, key, nil, 0), let value = entry.pointee.value else { return nil }
    return String(cString: value)
}

/// Opens `data` as a media file through custom I/O and reads the stream table.
private func probe(_ data: Data) throws -> Probed {
    let source = MemorySource(data)
    let bufferSize = 64 * 1024
    guard let raw = av_malloc(bufferSize) else { throw ProbeError.allocation }
    var io = avio_alloc_context(
        raw.assumingMemoryBound(to: UInt8.self), Int32(bufferSize), 0,
        Unmanaged.passUnretained(source).toOpaque(), readPacket, nil, seekPacket)
    defer {
        if let io { av_free(io.pointee.buffer) }
        avio_context_free(&io)
    }
    guard let io, let context = avformat_alloc_context() else { throw ProbeError.allocation }
    context.pointee.pb = io
    context.pointee.flags |= AVFMT_FLAG_CUSTOM_IO

    var opened: UnsafeMutablePointer<AVFormatContext>? = context
    let openResult = avformat_open_input(&opened, nil, nil, nil)
    guard openResult >= 0, let format = opened else { throw ProbeError.open(openResult) }
    defer { var toClose: UnsafeMutablePointer<AVFormatContext>? = format; avformat_close_input(&toClose) }
    _ = avformat_find_stream_info(format, nil)

    var streams: [ProbedStream] = []
    for index in 0..<Int(format.pointee.nb_streams) {
        let stream = format.pointee.streams[index]!
        streams.append(ProbedStream(
            kind: stream.pointee.codecpar.pointee.codec_type,
            codec: stream.pointee.codecpar.pointee.codec_id,
            language: metadata(stream.pointee.metadata, "language"),
            title: metadata(stream.pointee.metadata, "title")))
    }
    var chapters: [String] = []
    for index in 0..<Int(format.pointee.nb_chapters) {
        chapters.append(metadata(format.pointee.chapters[index]!.pointee.metadata, "title") ?? "")
    }
    return Probed(
        streams: streams, chapterTitles: chapters,
        duration: Double(format.pointee.duration) / Double(AV_TIME_BASE))
}

private enum ProbeError: Error { case allocation, open(Int32) }

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Fixtures").appendingPathComponent(name))
}

@Suite("Packaged FFmpeg")
struct FFmpegIntegrationTests {
    @Test("reports an LGPL build of the pinned version")
    func buildInfoIsLGPL() {
        let info = MediaEngine.buildInfo
        #expect(info.ffmpegLicense.hasPrefix("LGPL"))
        #expect(!info.ffmpegLicense.contains("nonfree"))
        #expect(info.ffmpegVersion == "9.0.2")
    }

    @Test("package traits reach the code as compile-time conditions")
    func traitsReachTheCode() {
        // scripts/check-traits.sh runs this with EXPECTED_TRAITS set for each trait combination.
        guard let expected = ProcessInfo.processInfo.environment["EXPECTED_TRAITS"] else {
            #expect(MediaEngine.enabledTraits.contains("Subtitles"))   // default configuration
            return
        }
        let wanted = expected.split(separator: ",").map(String.init).sorted()
        #expect(MediaEngine.enabledTraits.sorted() == wanted)
    }

    @Test("the build configuration never enabled GPL or nonfree code")
    func configurationIsClean() {
        let configuration = String(cString: avformat_configuration())
        #expect(!configuration.contains("--enable-gpl"))
        #expect(!configuration.contains("--enable-nonfree"))
        #expect(!configuration.contains("--enable-version3"))
    }

    @Test("demuxes an MKV with H.264, AAC, FLAC, SRT and chapters through custom I/O")
    func probesBasicFixture() throws {
        let result = try probe(fixture("fixture-basic.mkv"))
        #expect(result.streams.map(\.kind) == [AVMEDIA_TYPE_VIDEO, AVMEDIA_TYPE_AUDIO, AVMEDIA_TYPE_AUDIO, AVMEDIA_TYPE_SUBTITLE])
        #expect(result.streams.map(\.codec) == [AV_CODEC_ID_H264, AV_CODEC_ID_AAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_SUBRIP])
        #expect(result.streams[1].language == "eng")
        #expect(result.streams[2].language == "jpn")
        #expect(result.streams[2].title == "Japanese FLAC")
        #expect(result.chapterTitles == ["Opening", "Main"])
        #expect(abs(result.duration - 3.05) < 0.2)
    }

    @Test("demuxes an MKV with HEVC and AC-3 without any software decoder compiled in")
    func probesHEVCFixture() throws {
        let result = try probe(fixture("fixture-hevc.mkv"))
        #expect(result.streams.map(\.codec) == [AV_CODEC_ID_HEVC, AV_CODEC_ID_AC3])
        #expect(avcodec_find_decoder(AV_CODEC_ID_HEVC) == nil)   // Apple decodes HEVC; we ship no decoder
        #expect(avcodec_find_decoder(AV_CODEC_ID_H264) == nil)
        #expect(avcodec_find_decoder(AV_CODEC_ID_AC3) == nil)
    }

    @Test("truncated or garbage input fails cleanly instead of crashing")
    func damagedInputIsHandled() throws {
        let full = try fixture("fixture-basic.mkv")
        _ = try? probe(full.prefix(2_000))                 // header only: may open, must not crash
        #expect(throws: (any Error).self) { try probe(Data(repeating: 0x42, count: 4_096)) }
        #expect(throws: (any Error).self) { try probe(Data()) }
    }
}
