import AVFoundation
import FFmpegLGPL
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

/// Multiplies every sample by `gain`; counts the stages it made and the samples it saw.
private final class Gain: SoundProcessor {
    let gain: Float
    let counts = Mutex((stages: 0, samples: 0))
    init(_ gain: Float) { self.gain = gain }

    func makeStage(sampleRate: Double, channels: Int) -> any SoundStage {
        counts.withLock { $0.stages += 1 }
        return Stage(owner: self)
    }

    final class Stage: SoundStage {
        let owner: Gain
        init(owner: Gain) { self.owner = owner }
        func process(_ channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frames: Int) {
            for plane in channels { for index in 0..<frames { plane[index] *= owner.gain } }
            owner.counts.withLock { $0.samples += frames }
        }
    }
}

private func withALAC<T>(_ transcoder: AudioTranscoder, _ body: (UnsafePointer<AVCodecParameters>) throws -> T) throws -> T {
    let parameters = try transcoder.makeEncodedParameters()
    defer { var pointer: UnsafeMutablePointer<AVCodecParameters>? = parameters; avcodec_parameters_free(&pointer) }
    return try body(parameters)
}

@Suite("Sound processor (equalizer hook)")
struct SoundProcessorTests {
    @Test("AAC-LC decoded by AudioToolbox: pieces made one at a time, with their warm-up, join into the whole")
    func systemPiecesJoin() throws {
        let (reader, packets) = try allPackets("fixture-basic", stream: 1)               // AAC-LC, mono
        let base = reader.timeBase(1)
        #expect(AudioTranscoder.systemDecodes(reader.parameters(1)))
        let processor = Gain(1)
        let transcoder = try AudioTranscoder(parameters: reader.parameters(1), sourceTimeBase: base, processor: processor, systemDecoding: true)
        let cut = try #require(packets.firstIndex { base.seconds($0.pts) >= 1.5 })
        let warmUp = Array(packets[..<cut].filter { base.seconds($0.pts) >= 1.5 - SoundProcessing.warmUp })
        #expect(!warmUp.isEmpty)

        let whole = try transcoder.transcode(packets, stream: 1)
        let first = try transcoder.transcode(Array(packets[..<cut]), stream: 1)
        let second = try transcoder.transcode(Array(packets[cut...]), preroll: warmUp, stream: 1)
        // The first packet carries the encoder's priming (2112 samples to drop): the sound starts after it.
        #expect(whole.first?.pts == base.convert(packets[0].pts, to: transcoder.outputTimeBase) + Int64(packets[0].skipStart))
        #expect(second.first?.pts == base.convert(packets[cut].pts, to: transcoder.outputTimeBase), "the piece starts at its first packet")
        // Matroska keeps milliseconds, so a piece starts within one millisecond of the exact sample (as in FFmpeg's path).
        let firstEnd = try #require(first.last.map { $0.pts + $0.duration })
        #expect(abs(firstEnd - (second.first?.pts ?? 0)) <= 48, "where the pieces meet: \(firstEnd) and \(String(describing: second.first?.pts))")

        try withALAC(transcoder) { alac in
            let all = try decodeToS32(alac, packets: whole).samples
            let joined = try decodeToS32(alac, packets: first).samples + decodeToS32(alac, packets: second).samples
            #expect(all.count == joined.count && all.count == packets.count * 1024 - packets[0].skipStart,
                    "1024 samples a packet less the priming: \(all.count), \(joined.count), \(packets.count) packets")
            let worst = zip(all, joined).map { abs(Int64($0) - Int64($1)) }.max() ?? 0
            #expect(worst <= 1 << 16, "worst difference \(worst): more than one 16-bit step")
            #expect(all.contains { abs($0) > 1 << 24 }, "there is sound")
        }
        #expect(processor.counts.withLock { $0.stages } == 3)
    }

    @Test("the processor changes the converted sound, and its warm-up is not served")
    func gainApplies() throws {
        let (reader, packets) = try allPackets("fixture-basic", stream: 2)               // FLAC, converted anyway
        let base = reader.timeBase(2)
        let plain = try AudioTranscoder(parameters: reader.parameters(2), sourceTimeBase: base)
        let half = Gain(0.5)
        let halved = try AudioTranscoder(parameters: reader.parameters(2), sourceTimeBase: base, processor: half)
        let cut = try #require(packets.firstIndex { base.seconds($0.pts) >= 1.0 })
        let warmUp = Array(packets[..<cut].filter { base.seconds($0.pts) >= 1.0 - SoundProcessing.warmUp })
        let main = Array(packets[cut...])

        let original = try withALAC(plain) { try decodeToS32($0, packets: try plain.transcode(main, stream: 2)).samples }
        let changed = try withALAC(halved) { try decodeToS32($0, packets: try halved.transcode(main, preroll: warmUp, stream: 2)).samples }
        #expect(original.count == changed.count, "the warm-up adds no samples: \(original.count) vs \(changed.count)")
        let worst = zip(original, changed).map { abs(Int64($0) / 2 - Int64($1)) }.max() ?? 0
        #expect(worst <= 1 << 16, "half of every sample, within one 16-bit step: worst \(worst)")
        #expect(half.counts.withLock { $0.samples } > original.count, "the warm-up went through the stage too")
    }

    @Test("which tracks a processor reaches")
    func reaches() async throws {
        let basic = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { basic.close() }
        #expect(basic.audioChoices.count == 2 && basic.audioChoices.allSatisfy { basic.soundProcessorReaches($0) }, "AAC-LC and FLAC")
        let hevc = try await PlaybackSession(url: Fixture.url("fixture-hevc"))
        defer { hevc.close() }
        let ac3 = try #require(hevc.audioChoices.first)
        #expect(hevc.soundProcessorReaches(ac3) == MediaEngine.availableProfiles.contains(.audioFallback), "AC-3 needs the build's decoder")
        #expect(!SoundProcessing.reaches(makeTrack(kind: .audio, codec: "mp3"), transcodes: false))
    }

}

/// Real time: in the playback pass (`scripts/lib/tests.sh`).
@Suite("Sound processor in AVPlayer")
struct SoundProcessorPlaybackTests {
    @Test("AVPlayer plays a film whose AAC track goes through a processor", .timeLimit(.minutes(1)))
    @MainActor
    func plays() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let processor = Gain(0.8)
        session.soundProcessor = processor
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); session.close() }
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")
        player.play()
        #expect(await waitUntil(8) { item.currentTime().seconds > 1.5 }, "at \(item.currentTime().seconds)")
        #expect(item.error == nil && processor.counts.withLock { $0.stages } > 0, "the served sound passed through the processor")
    }
}
