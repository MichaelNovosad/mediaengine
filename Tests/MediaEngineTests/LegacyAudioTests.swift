import FFmpegLGPL
import Foundation
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// The audio of legacy files (extended profile) is converted to lossless ALAC segment by segment, like Opus and Vorbis:
/// a segment decoded alone, from a warm-up of the packets before it, equals the same stretch of a conversion of the
/// whole stream.
@Suite("Legacy audio conversion", .enabled(if: isExtendedBuild))
struct LegacyAudioTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var stream: Int
        var codec: String
        var warmStart: Bool       // the decoder keeps state: without warm-up the start of a segment differs
        var testDescription: String { codec }
    }
    static let cases = [Case(stream: 2, codec: "mp2", warmStart: true), Case(stream: 3, codec: "adpcm_ms", warmStart: false)]

    @Test("the codecs are announced as convertible", arguments: cases)
    func convertible(testCase: Case) {
        #expect(AudioTranscoder.canTranscode(testCase.codec))
    }

    @Test("a segment converted on its own matches the same stretch of the whole conversion", arguments: cases)
    func segmentsMatch(testCase: Case) throws {
        let (reader, packets) = try allPackets("fixture-avi-audio", stream: testCase.stream)
        let base = reader.timeBase(testCase.stream)
        let cut = try #require(packets.firstIndex { base.seconds($0.pts) >= 6.0 })
        let end = try #require(packets.firstIndex { base.seconds($0.pts) >= 12.0 })
        let warmUp = AudioTranscoder.prerollSeconds(testCase.codec)
        let preroll = Array(packets[..<cut].filter { base.seconds($0.pts) >= 6.0 - warmUp })
        let main = Array(packets[cut..<end])

        let transcoder = try AudioTranscoder(parameters: reader.parameters(testCase.stream), sourceTimeBase: base)
        let alac = try transcoder.makeEncodedParameters()
        defer { var pointer: UnsafeMutablePointer<AVCodecParameters>? = alac; avcodec_parameters_free(&pointer) }
        let whole = try decodeToS32(alac, packets: try transcoder.transcode(packets, stream: testCase.stream)).samples
        let samplesBefore = try decodeToS32(reader.parameters(testCase.stream), packets: Array(packets[..<cut])).samples.count

        let warmed = try transcoder.transcode(main, preroll: preroll, stream: testCase.stream)
        let decoded = try decodeToS32(alac, packets: warmed).samples
        let expected = Array(whole[samplesBefore..<(samplesBefore + decoded.count)])
        #expect(decoded.count > 5 * 44_100, "\(testCase.codec): about six seconds of stereo, got \(decoded.count)")
        var different = 0, worst: Int64 = 0
        for pair in zip(decoded, expected) where pair.0 != pair.1 { different += 1; worst = max(worst, abs(Int64(pair.0) - Int64(pair.1))) }
        print("LEGACYAUDIO \(testCase.codec): \(different) of \(decoded.count) samples differ, worst \(worst)")
        #expect(Double(different) / Double(max(decoded.count, 1)) < 0.001 && worst < 1 << 16, "\(testCase.codec): \(different) samples differ, worst \(worst)")

        let cold = try decodeToS32(alac, packets: try transcoder.transcode(main, stream: testCase.stream)).samples
        let coldDiffers = zip(cold, expected).contains { $0 != $1 } || cold.count != decoded.count
        if testCase.warmStart { #expect(coldDiffers, "\(testCase.codec): without warm-up the start should differ; if not, the warm-up is unnecessary") }
        else { #expect(!coldDiffers, "\(testCase.codec) is block-based: a segment needs no warm-up") }
    }

    @Test("the sound of each converted track is the tone in the file, whole", arguments: cases)
    func tone(testCase: Case) throws {
        let (reader, packets) = try allPackets("fixture-avi-audio", stream: testCase.stream)
        let transcoder = try AudioTranscoder(parameters: reader.parameters(testCase.stream), sourceTimeBase: reader.timeBase(testCase.stream))
        let alac = try transcoder.makeEncodedParameters()
        defer { var pointer: UnsafeMutablePointer<AVCodecParameters>? = alac; avcodec_parameters_free(&pointer) }
        let decoded = try decodeToS32(alac, packets: try transcoder.transcode(packets, stream: testCase.stream))
        let frames = decoded.samples.count / max(decoded.channels, 1)
        #expect(abs(Double(frames) / 44_100 - 14.0) < 0.15, "\(testCase.codec): \(Double(frames) / 44_100) s")
        // Zero crossings of the left channel in a 2 s stretch give the frequency: 330, 550 and 770 Hz.
        let wanted = [330.0, 550.0, 770.0][testCase.stream - 1]    // the first track (WMA) is not converted in version 1
        var crossings = 0
        let start = 44_100 * 3 * decoded.channels
        var previous = decoded.samples[start]
        for index in stride(from: start + decoded.channels, to: start + 2 * 44_100 * decoded.channels, by: decoded.channels) {
            if (previous < 0) != (decoded.samples[index] < 0) { crossings += 1 }
            previous = decoded.samples[index]
        }
        let measured = Double(crossings) / 2 / 2
        #expect(abs(measured - wanted) < 6, "\(testCase.codec): \(measured) Hz, expected \(wanted)")
    }
}

@Suite("Audio the engine does not convert in version 1")
struct UnsupportedLegacyAudioTests {
    @Test("Windows Media Audio is reported as unavailable, the video of the file still plays by software")
    func wma() async throws {
        let info = try await Fixture.probe("fixture-avi-audio")
        let wma = try #require(info.audioTracks.first { $0.codec.name == "wmav2" })
        let plan = try #require(info.playbackPlan.tracks.first { $0.trackID == wma.id })
        guard case .unavailable(let reason) = plan.treatment else { Issue.record("playable: \(plan.treatment)"); return }
        #expect(reason.detail.contains("WMA") || reason.detail.contains("not supported"), "\(reason.detail)")
        #expect(info.playbackPlan.notes.contains { $0.contains("cannot be played") })
    }
}
