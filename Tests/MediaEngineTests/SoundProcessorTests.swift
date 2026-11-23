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

/// A gain that can change while the film plays, as an equalizer the person adjusts: each new stage takes the gain of now.
private final class LiveGain: SoundProcessor {
    let gain: Mutex<Float>
    let stages = Mutex(0)
    init(_ gain: Float) { self.gain = Mutex(gain) }

    func makeStage(sampleRate: Double, channels: Int) -> any SoundStage {
        stages.withLock { $0 += 1 }
        return Stage(gain: gain.withLock { $0 })
    }

    final class Stage: SoundStage {
        let gain: Float
        init(gain: Float) { self.gain = gain }
        func process(_ channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frames: Int) {
            for plane in channels { for index in 0..<frames { plane[index] *= gain } }
        }
    }
}

/// The loudest 16-bit sample of one served sound track: its init segment and every fragment, decoded by AVFoundation.
private func peak(of session: RemuxSession, track id: Int) async throws -> Int {
    var bytes = try #require(try session.resource(path: "audio-\(id)-init.mp4")).data
    for index in session.plan.segments.indices { bytes.append(try #require(try session.resource(path: "audio-\(id)-\(index).m4s")).data) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("sound-copy-\(UUID().uuidString).mp4")
    try bytes.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let asset = AVURLAsset(url: file)
    let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    let provider = reader.outputProvider(for: output)
    try reader.start()
    var loudest = 0
    while let ready = try await provider.next() {
        let pcm = try ready.withUnsafeSampleBuffer { buffer -> [Int16] in
            var values = [Int16](repeating: 0, count: (buffer.dataBuffer?.dataLength ?? 0) / 2)
            if let block = buffer.dataBuffer, !values.isEmpty { try values.withUnsafeMutableBytes { try block.copyDataBytes(to: $0) } }
            return values
        }
        for value in pcm { loudest = max(loudest, abs(Int(value))) }
    }
    return loudest
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

    @Test("each track the processor reaches is served twice more through it; the original stays; a change is heard in a copy built afresh")
    func copies() async throws {
        let info = try await Fixture.probe("fixture-basic")
        let gain = LiveGain(1)
        let remux = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-basic")), info: info, cancellation: CancellationFlag(),
                                     soundProcessor: gain)
        defer { remux.close() }
        let aac = 1
        let first = try #require(remux.soundCopy(of: aac, slot: 0))
        let second = try #require(remux.soundCopy(of: aac, slot: 1))
        #expect(remux.soundCopy(of: 2, slot: 0) != nil, "the FLAC track too")

        // In the master playlist the copies are never chosen by the player itself; the original is the default.
        let master = String(decoding: try #require(try remux.resource(path: "master.m3u8")).data, as: UTF8.self)
        let copyLines = master.split(separator: "\n").filter { $0.contains("processed") }
        #expect(copyLines.count == 4 && copyLines.allSatisfy { $0.contains("AUTOSELECT=NO") && $0.contains("DEFAULT=NO") }, "\(master)")
        #expect(master.contains("audio-\(first).m3u8") && master.contains("audio-\(second).m3u8"))

        let original = try await peak(of: remux, track: aac)
        let same = try await peak(of: remux, track: first)
        #expect(original > 1000 && abs(same - original) <= original / 50, "gain 1: \(same) against the original's \(original)")

        // The person changes the setting: the next copy, forgotten and built again, has it; the original never changes.
        gain.gain.withLock { $0 = 0.25 }
        remux.forgetCopies(slot: 1)
        let quieter = try await peak(of: remux, track: second)
        #expect(abs(Double(quieter) - Double(original) * 0.25) <= Double(original) * 0.03, "a quarter: \(quieter) of \(original)")
        let originalAgain = try await peak(of: remux, track: aac)
        let firstAgain = try await peak(of: remux, track: first)
        #expect(originalAgain == original, "the original as the file has it")
        #expect(firstAgain == same, "the other copy keeps what it was built with until it is forgotten")
        remux.forgetCopies(slot: 0)
        let firstNow = try await peak(of: remux, track: first)
        #expect(abs(firstNow - quieter) <= quieter / 50)

        // Through the processor from the start: the default track's copy is the default rendition.
        remux.setDefaultCopySlot(0)
        let started = String(decoding: try #require(try remux.resource(path: "master.m3u8")).data, as: UTF8.self)
        let defaults = started.split(separator: "\n").filter { $0.contains("TYPE=AUDIO") && $0.contains("DEFAULT=YES") }
        #expect(defaults.count == 1 && defaults[0].contains("processed 1") && defaults[0].contains("AUTOSELECT=YES"), "\(started)")
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
    @MainActor
    private func selectedTitle(_ item: AVPlayerItem) async throws -> String? {
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        for metadata in option.commonMetadata where metadata.commonKey == .commonKeyTitle {
            if let text = try? await metadata.load(.stringValue) { return text }
        }
        return nil
    }

    @Test("with the sound through the processor from the start, AVPlayer plays the processed copy", .timeLimit(.minutes(1)))
    @MainActor
    func plays() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let processor = Gain(0.8)
        session.soundProcessor = processor
        session.processesSound = true
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); session.close() }
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")
        player.play()
        #expect(await waitUntil(8) { item.currentTime().seconds > 1.5 }, "at \(item.currentTime().seconds)")
        #expect(item.error == nil && processor.counts.withLock { $0.stages } > 0, "the served sound passed through the processor")
        let title = try await selectedTitle(item)
        #expect(title?.contains("processed 1") == true, "\(String(describing: title))")
        let choice = await session.selectedChoice(of: .audio, on: item)
        #expect(choice != nil && choice?.title.contains("processed") == false, "the copy stands for its track")
    }

    @Test("a change of the processor switches the sound to a fresh copy and back while the picture plays on", .timeLimit(.minutes(1)))
    @MainActor
    func switchesLive() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-subs-long"))     // 14 s, H.264 and AAC
        let processor = LiveGain(1)
        session.soundProcessor = processor
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); session.close() }
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")
        player.play()
        #expect(await waitUntil(8) { item.currentTime().seconds > 1 }, "at \(item.currentTime().seconds)")
        let original = try await selectedTitle(item)
        #expect(original?.contains("processed") == false, "as the file has it: \(String(describing: original))")
        let stagesBefore = processor.stages.withLock { $0 }          // the copies' start segments were made through it

        // On: the copy of slot 1 plays, and the picture goes on from where it was (no jump back, no stop).
        var before = item.currentTime().seconds
        try await session.applySoundProcessing(true, on: item)
        #expect(session.processesSound)
        let firstCopy = try await selectedTitle(item)
        #expect(firstCopy?.contains("processed 1") == true, "\(String(describing: firstCopy))")
        #expect(await waitUntil(5) { processor.stages.withLock { $0 } > stagesBefore }, "the copy is built through the processor")
        #expect(await waitUntil(3) { item.currentTime().seconds > before + 1 }, "the film plays on: \(item.currentTime().seconds) after \(before)")
        #expect(player.rate > 0 && item.error == nil)

        // A change of the setting: the other copy, built with the new gain.
        processor.gain.withLock { $0 = 0.5 }
        before = item.currentTime().seconds
        try await session.applySoundProcessing(true, on: item)
        let secondCopy = try await selectedTitle(item)
        #expect(secondCopy?.contains("processed 2") == true, "\(String(describing: secondCopy))")
        #expect(await waitUntil(3) { item.currentTime().seconds > before + 1 }, "the film plays on: \(item.currentTime().seconds) after \(before)")

        // Off: the track as the file has it again.
        try await session.applySoundProcessing(false, on: item)
        let back = try await selectedTitle(item)
        #expect(!session.processesSound && back == original, "\(String(describing: back)) against \(String(describing: original))")
        #expect(player.rate > 0 && item.error == nil)
    }
}
