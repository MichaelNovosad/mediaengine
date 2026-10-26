import AVFoundation
import Foundation
import Testing
@testable import MediaEngine

private func audioURL(_ name: String) -> URL { Fixture.root.appendingPathComponent("Fixtures/audio/\(name)") }

@Suite("External audio files")
struct ExternalAudioFileTests {
    @Test("each format is opened, with the codec, whether it needs converting, and a name", arguments: [
        ("ext-aac.m4a", "AAC", false), ("ext-aac.aac", "AAC", false), ("ext-ac3.ac3", "AC-3", false),
        ("ext-flac.flac", "FLAC", true), ("ext-opus.mka", "Opus", true),
    ])
    func formats(file: String, codec: String, transcodes: Bool) async throws {
        let track = try await AudioTrack(url: audioURL(file))
        #expect(track.codec == codec && track.transcodes == transcodes)
        #expect(abs((try #require(track.duration, "\(file) has no duration")) - 3) < 0.2 && track.delay == 0 && !track.title.isEmpty)
    }

    @Test("language and title come from the file's tags, then its name, and can be given")
    func naming() async throws {
        #expect(try await AudioTrack(url: audioURL("ext-aac.m4a")).language?.languageCode?.identifier == "en", "tag")
        #expect(try await AudioTrack(url: audioURL("ext-flac.flac")).language == nil, "no tag and no hint in the name")
        let japanese = try await AudioTrack(url: audioURL("ext-opus.mka"))
        #expect(japanese.title == "Japanese dub" && japanese.language?.languageCode?.identifier == "ja")
        let source = try await MediaSource(url: audioURL("ext-ac3.ac3"))
        let hinted = try await AudioTrack(source: source, name: "Film.2020.de.ac3")
        #expect(hinted.language?.languageCode?.identifier == "de")
        let given = try await AudioTrack(source: source, name: "Film.de.ac3", language: Locale.Language(identifier: "fr"), title: "Mine", delay: -0.25)
        #expect(given.title == "Mine" && given.language?.languageCode?.identifier == "fr" && given.delay == -0.25)
        #expect(try await AudioTrack(source: source, name: "Film.ac3").language == nil)
    }

    @Test("files without audio the player can play are refused with a reason")
    func refusing() async throws {
        await #expect(throws: MediaError.self) { _ = try await AudioTrack(url: Fixture.url("fixture-licensed-audio")) }       // DTS and TrueHD only
        await #expect(throws: MediaError.self) { _ = try await AudioTrack(url: audioURL("missing.flac")) }
        await #expect(throws: MediaError.self) {
            _ = try await AudioTrack(source: MediaSource(byteSource: DataByteSource(Data("not media".utf8))), name: "x.mka")
        }
    }
}

@Suite("External audio in a session")
struct ExternalAudioSessionTests {
    private func session(_ video: String, _ files: [AudioTrack]) async throws -> RemuxSession {
        let info = try await Fixture.probe(video)
        return try RemuxSession(source: FileByteSource(url: Fixture.url(video)), info: info, cancellation: CancellationFlag(), externalAudio: files)
    }

    @Test("the choices list the file after the embedded tracks, flagged external, with unique names")
    func choices() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-multi"))
        defer { session.close() }
        try session.add(await AudioTrack(url: audioURL("ext-aac.m4a"), title: "Main"))
        try session.add(await AudioTrack(url: audioURL("ext-opus.mka")))
        let audio = session.audioChoices
        #expect(audio.count == 6 && audio.prefix(4).allSatisfy { !$0.isExternal } && audio.suffix(2).allSatisfy(\.isExternal))
        #expect(audio.suffix(2).map(\.id) == [20_000, 20_001] && audio[4].title == "Main (3)" && audio[5].title == "Japanese dub")
        #expect(Set(audio.map(\.title)).count == audio.count)
        #expect(session.subtitleChoices.allSatisfy { !$0.isExternal })
        let late = try await AudioTrack(url: audioURL("ext-ac3.ac3"))
        _ = try await session.makePlayerItem()
        #expect(throws: MediaError.self) { try session.add(late) }
    }

    @Test("the master playlist offers the file as a rendition and serves its init segment and fragments", arguments: [
        "ext-aac.m4a", "ext-aac.aac", "ext-ac3.ac3", "ext-flac.flac", "ext-opus.mka",
    ])
    func served(file: String) async throws {
        let external = try await AudioTrack(url: audioURL(file))
        let session = try await session("fixture-opus-vorbis", [external])
        let master = String(decoding: try #require(try session.resource(path: "master.m3u8")).data, as: UTF8.self)
        #expect(master.contains("URI=\"audio-20000.m3u8\"") && master.contains("DEFAULT=NO"), "\(master)")
        #expect(try session.resource(path: "audio-20000.m3u8") != nil && (try session.resource(path: "audio-20000-init.mp4")) != nil)
        var samples = 0
        for index in session.plan.segments.indices {
            let fragment = try #require(try session.resource(path: "audio-20000-\(index).m4s")).data
            samples += fragmentFacts(fragment)?.sampleCount ?? 0          // a segment the file does not reach is an empty fragment
        }
        #expect(samples > 20, "\(file): \(samples) samples")
        #expect(try session.resource(path: "audio-20000-99.m4s") == nil && (try session.resource(path: "audio-20001-0.m4s")) == nil)
    }

    @Test("a delay places the audio later on the timeline: seven seconds of delay puts a 3 s file in the second segment")
    func delay() async throws {
        let external = try await AudioTrack(url: audioURL("ext-aac.m4a"), delay: 7)
        let session = try await session("fixture-opus-vorbis", [external])          // segments [0, 6), [6, 12), [12, 14)
        #expect(session.plan.segments.count == 3)
        let data0 = try #require(try session.resource(path: "audio-20000-0.m4s")).data
        let data1 = try #require(try session.resource(path: "audio-20000-1.m4s")).data
        let data2 = try #require(try session.resource(path: "audio-20000-2.m4s")).data
        let facts1 = try #require(fragmentFacts(data1))
        #expect(fragmentFacts(data0) == nil && fragmentFacts(data2) == nil && facts1.sampleCount > 100, "segments 0 and 2 are empty fragments")
        let scale = Double(session.timescale(20_000))
        let start = Double(facts1.baseDecodeTime) / scale
        #expect(abs(start - (7 + session.mediaShift)) < 0.1, "starts at \(start), expected about \(7 + session.mediaShift)")
        let length = Double(facts1.totalDuration) / scale
        #expect(abs(length - 3) < 0.15, "lasts \(length) s")
    }

    @Test("segments the file does not reach are marked as gaps, so the player does not wait for them")
    func gaps() async throws {
        func gapFlags(_ delay: Double) async throws -> (flags: [Bool], version: String) {
            let external = try await AudioTrack(url: audioURL("ext-aac.m4a"), delay: delay)
            let session = try await session("fixture-opus-vorbis", [external])             // segments [0, 6), [6, 12), [12, 14)
            let playlist = String(decoding: try #require(try session.resource(path: "audio-20000.m3u8")).data, as: UTF8.self)
            let lines = playlist.split(separator: "\n").map(String.init)
            let flags = lines.indices.filter { lines[$0].hasPrefix("#EXTINF") }.map { lines[$0 - 1] == "#EXT-X-GAP" }
            return (flags, lines.first { $0.hasPrefix("#EXT-X-VERSION") } ?? "")
        }
        #expect(try await gapFlags(0).flags == [false, true, true], "3 s of audio reach only the first segment")
        #expect(try await gapFlags(0).version == "#EXT-X-VERSION:8")
        #expect(try await gapFlags(7).flags == [true, false, true], "delayed by 7 s it sits in the second one")
        #expect(try await gapFlags(5).flags == [false, false, true], "5 to 8 s straddles the first boundary")
        // The video's own audio has no gaps and keeps the older playlist version.
        let info = try await Fixture.probe("fixture-opus-vorbis")
        let plain = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-opus-vorbis")), info: info, cancellation: CancellationFlag())
        let own = String(decoding: try #require(try plain.resource(path: "audio-1.m3u8")).data, as: UTF8.self)
        #expect(!own.contains("EXT-X-GAP") && own.contains("#EXT-X-VERSION:7"))
    }

    @Test("raw AAC is cut at segment boundaries through its own index: no frame lost, none doubled, no gap")
    func rawAACAcrossSegments() async throws {
        let external = try await AudioTrack(url: audioURL("ext-aac.aac"), delay: 5)
        let session = try await session("fixture-opus-vorbis", [external])             // the file sits at 5 s to 8 s: segments 0 and 1
        let reader = try PacketReader(source: FileByteSource(url: audioURL("ext-aac.aac")), cancellation: CancellationFlag())
        var frames = 0
        while try reader.next() != nil { frames += 1 }
        var total = 0
        var previousEnd: UInt64?
        for index in session.plan.segments.indices {
            guard let facts = fragmentFacts(try #require(try session.resource(path: "audio-20000-\(index).m4s")).data) else { continue }
            total += facts.sampleCount
            if let previousEnd {
                let gap = (Double(facts.baseDecodeTime) - Double(previousEnd)) / Double(session.timescale(20_000))
                #expect(abs(gap) < 0.001, "segment \(index) starts \(gap) s after the one before")
            }
            previousEnd = facts.baseDecodeTime + facts.totalDuration
        }
        #expect(total == frames && frames > 100, "\(total) frames served of \(frames)")
    }

    @Test("a negative delay cuts the start of the file instead of starting before the video")
    func earlier() async throws {
        let external = try await AudioTrack(url: audioURL("ext-flac.flac"), delay: -1)
        let session = try await session("fixture-basic", [external])
        let fragment = try facts(try #require(try session.resource(path: "audio-20000-0.m4s")).data)
        let scale = Double(session.timescale(20_000))
        #expect(abs(Double(fragment.baseDecodeTime) / scale - session.mediaShift) < 0.1, "the audio that remains starts with the video")
        #expect(abs(Double(fragment.totalDuration) / scale - 2) < 0.2, "the first second of the file is cut: \(Double(fragment.totalDuration) / scale) s are left")
    }

    @Test("audio from a file never moves the video, whatever its own start or delay")
    func neverMovesTheVideo() async throws {
        let alone = try await session("fixture-hevc", [])
        for (file, delay) in [("ext-aac.m4a", 0.0), ("ext-aac.m4a", -2.0), ("ext-flac.flac", 5.0), ("ext-aac.aac", 0.0)] {
            let external = try await AudioTrack(url: audioURL(file), delay: delay)
            let with = try await session("fixture-hevc", [external])
            #expect(with.mediaShift == alone.mediaShift, "\(file) at \(delay)")
            let fragment = try #require(try with.resource(path: "audio-20000-0.m4s")).data
            if let facts = fragmentFacts(fragment) { #expect(facts.baseDecodeTime >= 0) }
        }
    }
}

#if os(macOS)
@MainActor
@Suite("External audio in AVFoundation and AVPlayer", .serialized)
struct ExternalAudioPlaybackTests {
    /// Decodes an assembled rendition: where it starts, how long it lasts and the pitch of the tone (700 Hz in the files).
    private func decode(_ session: RemuxSession, id: Int) async throws -> (start: Double, length: Double, hertz: Double) {
        var bytes = try #require(try session.resource(path: "audio-\(id)-init.mp4")).data
        for index in session.plan.segments.indices { bytes.append(try #require(try session.resource(path: "audio-\(id)-\(index).m4s")).data) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString).mp4")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        var first: Double?
        var crossings = 0, samples = 0
        var previous: Int16 = 0
        let rate = 48000.0                                             // the test files are 48 kHz mono
        while let ready = try await provider.next() {
            let (time, pcm) = try ready.withUnsafeSampleBuffer { buffer -> (Double, [Int16]) in
                var values = [Int16](repeating: 0, count: (buffer.dataBuffer?.dataLength ?? 0) / 2)
                if let block = buffer.dataBuffer, !values.isEmpty { try values.withUnsafeMutableBytes { try block.copyDataBytes(to: $0) } }
                return (buffer.presentationTimeStamp.seconds, values)
            }
            if first == nil, !pcm.isEmpty { first = time }
            for value in pcm {
                if (previous < 0 && value >= 0) || (previous >= 0 && value < 0) { crossings += 1 }
                previous = value
                samples += 1
            }
        }
        let length = Double(samples) / rate
        return (first ?? -1, length, Double(crossings) / 2 / max(length, 0.001))
    }

    @Test("the repackaged and converted audio is the tone that was in the file, whole, at the right start",
          arguments: ["ext-aac.m4a", "ext-aac.aac", "ext-ac3.ac3", "ext-flac.flac", "ext-opus.mka"])
    func content(file: String) async throws {
        let external = try await AudioTrack(url: audioURL(file))
        let info = try await Fixture.probe("fixture-opus-vorbis")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-opus-vorbis")), info: info,
                                       cancellation: CancellationFlag(), externalAudio: [external])
        let result = try await decode(session, id: 20_000)
        #expect(abs(result.hertz - 700) < 25, "\(file): \(result.hertz) Hz")
        #expect(abs(result.length - 3) < 0.25 || result.length > 13, "\(file): \(result.length) s of audio")
        #expect(result.start < 0.2 + session.mediaShift, "\(file) starts at \(result.start)")
    }

    @Test("a delayed file keeps its tone and its length")
    func delayedContent() async throws {
        let external = try await AudioTrack(url: audioURL("ext-flac.flac"), delay: 7)
        let info = try await Fixture.probe("fixture-opus-vorbis")
        let session = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-opus-vorbis")), info: info,
                                       cancellation: CancellationFlag(), externalAudio: [external])
        let result = try await decode(session, id: 20_000)
        #expect(abs(result.hertz - 700) < 25, "\(result.hertz) Hz")
        #expect(abs(result.length - 3) < 0.25, "\(result.length) s of audio")
        // (AVAssetReader on the bare file does not show the 7 s gap; the fragment's own timestamps do, see `delay` above.)
    }

    @Test("AVPlayer can switch to the external audio and plays on")
    func switching() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-opus-vorbis"))
        defer { session.close() }
        try session.add(await AudioTrack(url: audioURL("ext-flac.flac"), delay: 2))
        try session.add(await AudioTrack(url: audioURL("ext-ac3.ac3")))
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")
        player.play()
        for choice in session.audioChoices.suffix(2) {
            try await session.select(choice, on: item)
            #expect(await session.selectedChoice(of: .audio, on: item) == choice, "\(choice.title)")
            let before = item.currentTime().seconds
            #expect(await waitUntil(8) { item.currentTime().seconds > before + 0.6 }, "stuck at \(item.currentTime().seconds) on \(choice.title)")
        }
        #expect(item.error == nil)
        player.pause()
    }
}
#endif
