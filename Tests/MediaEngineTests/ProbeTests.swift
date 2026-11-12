import Foundation
import Testing
@testable import MediaEngine

@Suite("Probe")
struct ProbeTests {
    @Test("basic MKV: container, tracks, chapters, plan")
    func basic() async throws {
        let info = try await Fixture.probe("fixture-basic")
        #expect(info.container.kind == .matroska)
        #expect(info.container.isMatroskaFamily)
        #expect(info.title == "MediaEngine fixture basic")
        #expect(abs((info.duration ?? 0) - 3.052) < 0.01)
        #expect(info.fileSize == Int64(try Fixture.data("fixture-basic").count))
        #expect(info.tracks.count == 4)

        let video = try #require(info.videoTracks.first)
        #expect(video.codec.name == "h264")
        #expect(video.codec.displayName == "H.264")
        #expect(video.codec.profile == "High")
        #expect(video.codec.profileIdentifier == 100)
        #expect(video.codec.level == "3.0")
        #expect(video.video?.width == 640 && video.video?.height == 360)
        #expect(video.video?.frameRate == 25)
        #expect(video.video?.hdr == .sdr)
        #expect(video.video?.rotation == 0)

        let audio = info.audioTracks
        #expect(audio.map(\.codec.name) == ["aac", "flac"])
        #expect(audio[0].language?.languageCode?.identifier == "en")
        #expect(audio[0].isDefault && !audio[1].isDefault)
        #expect(audio[1].language?.languageCode?.identifier == "ja")
        #expect(audio[1].title == "Japanese FLAC")
        #expect(audio[1].audio?.isLossless == true)
        #expect(audio[1].audio?.sampleRate == 48_000)

        let subtitle = try #require(info.subtitleTracks.first)
        #expect(subtitle.codec.name == "subrip")
        #expect(subtitle.subtitle?.format == .text)
        #expect(subtitle.isDefault)

        #expect(info.chapters.map(\.title) == ["Opening", "Main"])
        #expect(abs(info.chapters[1].start - 1.5) < 0.001 && abs(info.chapters[1].end - 3.0) < 0.001)
        #expect(info.attachments.isEmpty)

        #expect(info.playbackPlan.path == .remux)
        #expect(info.requiredProfile.isEmpty)
        #expect(info.playbackPlan.tracks.map(\.treatment) ==
                [.passthrough, .passthrough, .transcodeAudio(.alac), .convertToWebVTT])
    }

    @Test("HDR10 HEVC Main 10 with E-AC-3 5.1")
    func hdr10() async throws {
        let info = try await Fixture.probe("fixture-hdr10")
        let video = try #require(info.videoTracks.first)
        #expect(video.codec.name == "hevc")
        #expect(video.codec.profile == "Main 10")
        #expect(video.video?.bitDepth == 10)
        #expect(video.video?.chroma == .yuv420)
        #expect(video.video?.colorPrimaries == "bt2020")
        #expect(video.video?.colorTransfer == "smpte2084")
        #expect(video.video?.colorMatrix == "bt2020nc")
        #expect(video.video?.hdr == .hdr10)
        let audio = try #require(info.audioTracks.first)
        #expect(audio.codec.name == "eac3")
        #expect(audio.audio?.channels == 6)
        #expect(audio.audio?.channelLayout == "5.1(side)")
        #expect(info.playbackPlan.path == .remux)
    }

    @Test("HLG HEVC Main 10 is reported as HLG")
    func hlg() async throws {
        let info = try await Fixture.probe("fixture-hlg")
        let video = try #require(info.videoTracks.first)
        #expect(video.video?.hdr == .hlg && video.video?.colorTransfer == "arib-std-b67" && video.video?.bitDepth == 10)
    }

    @Test("plain HEVC with AC-3 is SDR and needs nothing extra")
    func hevc() async throws {
        let info = try await Fixture.probe("fixture-hevc")
        let video = try #require(info.videoTracks.first)
        #expect(video.codec.name == "hevc" && video.codec.profile == "Main")
        #expect(video.video?.bitDepth == 8)
        #expect(video.video?.hdr == .sdr)
        #expect(info.audioTracks.first?.codec.name == "ac3")
        #expect(info.requiredProfile.isEmpty)
    }

    @Test("DTS needs the dtsCore module and TrueHD the licensed audio module; without them they are reported unavailable")
    func licensedAudio() async throws {
        let info = try await Fixture.probe("fixture-licensed-audio")
        #expect(info.audioTracks.map(\.codec.name) == ["dts", "truehd"])
        #expect(info.requiredProfile == [.dtsCore, .licensedAudio])
        #expect(info.playbackPlan.path == .remux)                    // video still plays
        let available = MediaEngine.availableProfiles
        for (track, plan) in zip(info.audioTracks, info.playbackPlan.tracks.filter { $0.kind == .audio }) {
            let needed: CodecProfile = track.codec.name == "dts" ? .dtsCore : .licensedAudio
            if available.contains(needed) {
                #expect(plan.treatment == .transcodeAudio(.alac), "\(track.codec.name)")
                continue
            }
            guard case .unavailable(let reason) = plan.treatment else { Issue.record("expected unavailable"); continue }
            #expect(reason.code == .needsCodecProfile)
            #expect(reason.requires == needed)
        }
        if !available.contains(.dtsCore), !available.contains(.licensedAudio) {
            #expect(info.playbackPlan.notes.contains { $0.contains("silent") })
        }
    }

    @Test("anime-style MKV: two audio languages, styled subtitles, forced signs track, font and cover attachments")
    func anime() async throws {
        let info = try await Fixture.probe("fixture-anime")
        #expect(info.audioTracks.map(\.title) == ["Japanese", "English dub"])
        #expect(info.audioTracks.map { $0.language?.languageCode?.identifier } == ["ja", "en"])
        #expect(info.subtitleTracks.map(\.codec.name) == ["ass", "ass"])
        #expect(info.subtitleTracks.map(\.isForced) == [false, true])
        #expect(info.subtitleTracks.map(\.title) == ["Dialogue", "Signs and Songs"])
        #expect(info.chapters.map(\.title) == ["Opening", "Part A", "Ending"])
        #expect(info.attachments.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.coverArt, .font])
        let font = try #require(info.attachments.first { $0.kind == .font })
        #expect(font.filename == "FakeFont.ttf" && font.byteCount == 2_048)
        #expect(info.tracks.count == 5)                              // attachments and cover art are not tracks
    }

    @Test("results are identical through file, memory and padded sources")
    func sameResultEverywhere() async throws {
        let data = try Fixture.data("fixture-basic")
        let fromFile = try await Fixture.probe("fixture-basic")
        let fromMemory = try await MediaSource(byteSource: DataByteSource(data)).probe()
        #expect(fromFile == fromMemory)

        // 60 GB of reported size, real content only at the start: probing must not depend on size.
        let hugeSize: Int64 = 60 * 1_024 * 1_024 * 1_024
        let padded = PaddedByteSource(base: data, totalLength: hugeSize)
        let fromPadded = try await MediaSource(byteSource: padded).probe()
        #expect(fromPadded.tracks == fromFile.tracks)
        #expect(fromPadded.fileSize == hugeSize)
    }

    @Test("MediaInfo survives a JSON round trip")
    func codable() async throws {
        let info = try await Fixture.probe("fixture-anime")
        let decoded = try JSONDecoder().decode(MediaInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }

    // MARK: Failure and cancellation

    @Test("garbage and empty input are reported as not media, not as crashes")
    func notMedia() async {
        await #expect(throws: MediaError.notMedia) { try await MediaSource(byteSource: DataByteSource(Data(repeating: 0x42, count: 4_096))).probe() }
        await #expect(throws: MediaError.notMedia) { try await MediaSource(byteSource: DataByteSource(Data())).probe() }
    }

    @Test("truncated files either describe what is there or fail cleanly")
    func truncated() async throws {
        let data = try Fixture.data("fixture-basic")
        for cut in [64, 700, 2_000, 40_000, data.count - 10] {
            do { _ = try await MediaSource(byteSource: DataByteSource(data.prefix(cut))).probe() }
            catch let error as MediaError { #expect(error != .cancelled) }
        }
    }

    @Test("a download that was cut off is flagged, with a note, while the whole file is not")
    func incompleteDownload() async throws {
        let data = try Fixture.data("fixture-basic")
        let whole = try await MediaSource(byteSource: DataByteSource(data)).probe()
        #expect(!whole.isIncomplete && !whole.playbackPlan.notes.contains { $0.contains("incomplete") })

        // The header (and with it the segment size) is there; the end of the file is not.
        var flagged = 0
        for cut in [data.count * 3 / 4, data.count / 2, data.count - 40] {
            guard let info = try? await MediaSource(byteSource: DataByteSource(data.prefix(cut))).probe() else { continue }
            #expect(info.isIncomplete, "cut at \(cut) of \(data.count)")
            #expect(info.playbackPlan.notes.contains { $0.contains("incomplete") && $0.contains("%") }, "\(info.playbackPlan.notes)")
            flagged += 1
        }
        #expect(flagged >= 1, "no truncated copy could be probed at all")
        // A recording that does not know its own size (live) is never called incomplete.
        #expect(MatroskaChapters.declaredEnd(of: DataByteSource(Data([0x1A, 0x45, 0xDF, 0xA3, 0x80, 0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))) == nil)
    }

    @Test("a source that throws surfaces its own error")
    func sourceFailure() async {
        struct Broken: ByteSource {
            var length: Int64? { 1_000 }
            func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int { throw MediaError.network(detail: "gone") }
        }
        await #expect(throws: MediaError.network(detail: "gone")) { try await MediaSource(byteSource: Broken()).probe() }
    }

    @Test("a task cancelled before it starts finishes with .cancelled")
    func cancelledBeforeStart() async throws {
        let source = MediaSource(byteSource: DataByteSource(try Fixture.data("fixture-basic")))
        let task = Task { try await source.probe() }
        task.cancel()
        await #expect(throws: MediaError.cancelled) { try await task.value }
    }

    @Test("cancelling while a read is in flight ends with .cancelled")
    func cancelledDuringReads() async throws {
        let gated = GatedByteSource(base: DataByteSource(try Fixture.data("fixture-basic")))
        let task = Task { try await MediaSource(byteSource: gated).probe() }
        while gated.readCount == 0 { try await Task.sleep(for: .milliseconds(5)) }      // the probe is blocked inside its first read
        task.cancel()
        gated.release()
        await #expect(throws: MediaError.cancelled) { try await task.value }           // how fast: ExclusiveTests
    }

    @Test("ISO 639-2 language tags map to languages, including bibliographic codes")
    func languages() {
        func code(_ tag: String?) -> String? { LanguageCodes.language(from: tag)?.languageCode?.identifier }
        #expect(code("eng") == "en" && code("jpn") == "ja" && code("deu") == "de")
        #expect(code("ger") == "de" && code("fre") == "fr" && code("chi") == "zh" && code("cze") == "cs")
        #expect(code("ukr") == "uk" && code("rus") == "ru" && code("kor") == "ko" && code("hin") == "hi")
        #expect(code("und") == nil && code("mul") == nil && code("zxx") == nil && code("qaa") == nil)
        #expect(code(nil) == nil && code("") == nil)
        #expect(code("pt-BR") == "pt")
    }
}
