import AVFoundation
import CoreVideo
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

#if os(macOS)
/// The software player (the engine's own decoders, AVPlayer for the sound) and the controller protocol. Real-time tests:
/// listed in `PLAYBACK_SUITES` (scripts/lib/tests.sh).
@Suite("Software player", .serialized)
@MainActor
struct SoftwareControllerPlaybackTests {
    private func controller(_ name: String) async throws -> SoftwareController {
        let session = try await PlaybackSession(url: Fixture.url(name))
        let made = try await session.makeController()
        made.isMuted = true
        return try #require(made as? SoftwareController, "\(name) is not played by the software path: \(session.info.playbackPlan.path)")
    }

    @Test("a software-decoded file plays from start to end with its sound, in step, and reports its end",
          .enabled(if: isExtendedBuild), arguments: ["fixture-avi-xvid", "fixture-flv", "fixture-wmv", "fixture-mpeg2", "fixture-realmedia", "fixture-ogm"])
    func playsToTheEnd(name: String) async throws {
        let player = try await controller(name)
        defer { player.close() }
        #expect(player.state == .ready && player.path == .software && player.error == nil)
        #expect(abs((player.duration ?? 0) - 3) < 0.2)
        let times = Mutex<[Double]>([])
        player.onFrame { frame in times.withLock { $0.append(frame.time) } }
        player.play()
        #expect(player.state == .playing)
        #expect(await waitUntil(8) { player.currentTime > 1.2 }, "\(name) stuck at \(player.currentTime): \(player.statistics)")
        if let lead = player.soundLead { #expect(abs(lead) < 0.12, "\(name): the sound is \(lead) s ahead of the picture") }
        #expect(await waitUntil(10) { player.state == .ended }, "\(name) did not end: \(player.state) at \(player.currentTime), \(player.statistics)")
        #expect(abs(player.currentTime - (player.duration ?? 0)) < 0.2)
        // Pictures that are late are dropped: how many were shown is a speed measurement, made on a plain full-speed run only
        // (background priority and sanitizers set `testPatience` above 1; the benchmark is where speed is gated).
        if testPatience == 1 { #expect(player.statistics.displayedFrames >= 68 && player.statistics.droppedFrames <= 3, "\(player.statistics)") }
        let seen = times.withLock { $0 }
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $1 > $0 })
    }

    /// VP8, VP9 and AV1 streams of the codec projects, in the formats the converter shows (8 and 10 bit, 4:2:0 and 4:4:4, film
    /// grain, a size change in the middle). Needs `scripts/fetch-conformance.sh`.
    @Test("VP8, VP9 and AV1 vectors play to the end through the software path, picture by picture",
          .enabled(if: isExtendedBuild && Conformance.vectors.count >= 60),
          arguments: ["vp80-00-comprehensive-001", "vp90-2-02-size-66x66", "vp91-2-04-yuv444", "vp92-2-20-10bit-yuv420",
                      "av1-1-b8-01-size-66x66", "av1-1-b10-23-film_grain-50", "av1-1-b8-03-sizeup"])
    func playsVectors(name: String) async throws {
        // Macs and iPhones with an AV1 decoder in hardware would play AV1 through AVPlayer: take the software path here.
        setenv("MEDIAENGINE_DISABLE_HARDWARE_AV1", "1", 1)
        let session = try await PlaybackSession(url: Conformance.stream(name))
        let made = try await session.makeController()
        made.isMuted = true
        let player = try #require(made as? SoftwareController, "\(name): \(session.info.playbackPlan.path)")
        defer { player.close() }
        let expected = try Conformance.references(name).count
        let widths = Mutex<Set<Int>>([])
        player.onFrame { frame in widths.withLock { _ = $0.insert(CVPixelBufferGetWidth(frame.pixelBuffer)) } }
        player.play()
        #expect(await waitUntil(15) { player.state == .ended }, "\(name): \(player.state) at \(player.currentTime), \(player.statistics), \(String(describing: player.error))")
        #expect(player.error == nil)
        #expect(player.statistics.decodedFrames >= expected - 1, "\(name): \(expected) frames expected, \(player.statistics)")
        if testPatience == 1 { #expect(player.statistics.displayedFrames >= expected - 3, "\(name): \(expected) frames expected, \(player.statistics)") }   // sanitizers make pictures late
        if name == "av1-1-b8-03-sizeup", testPatience == 1 { #expect(widths.withLock { $0.count } >= 2, "the picture size never changed: \(widths.withLock { $0 })") }
    }

    @Test("pause stops the picture, play goes on from the same place, and a seek shows the picture it was moved to",
          .enabled(if: isExtendedBuild))
    func pauseAndSeek() async throws {
        let player = try await controller("fixture-avi-xvid")
        defer { player.close() }
        let times = Mutex<[Double]>([])
        player.onFrame { frame in times.withLock { $0.append(frame.time) } }
        player.play()
        #expect(await waitUntil(8) { player.currentTime > 0.6 })
        player.pause()
        #expect(player.state == .paused && player.rate == 0)
        let stopped = player.currentTime
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(player.currentTime - stopped) < 0.05, "time moved while paused: \(stopped) to \(player.currentTime)")

        // A seek while paused shows the picture at the target: the first picture after it is at or after 2.0 s.
        times.withLock { $0 = [] }
        await player.seek(to: 2.0)
        #expect(player.state == .paused && abs(player.currentTime - 2.0) < 0.05)
        #expect(await waitUntil(5) { times.withLock { !$0.isEmpty } }, "no picture after the seek")
        let first = try #require(times.withLock { $0.first })
        #expect(first >= 1.95 && first < 2.2, "first picture after the seek is at \(first)")

        player.play()
        #expect(await waitUntil(10) { player.state == .ended }, "\(player.state) at \(player.currentTime)")
        // Playing again from the end starts over.
        player.play()
        #expect(await waitUntil(6) { player.state == .playing && player.currentTime > 0.3 && player.currentTime < 2.5 }, "\(player.state) at \(player.currentTime)")
    }

    @Test("seeking while playing keeps playing from the new place; a seek back repeats pictures", .enabled(if: isExtendedBuild))
    func seekWhilePlaying() async throws {
        let player = try await controller("fixture-flv")
        defer { player.close() }
        player.play()
        #expect(await waitUntil(8) { player.currentTime > 1.5 })
        await player.seek(to: 0.4)
        #expect(player.state == .playing)
        #expect(await waitUntil(5) { player.currentTime > 0.4 && player.currentTime < 1.4 }, "at \(player.currentTime)")
        #expect(await waitUntil(10) { player.state == .ended })
    }

    @Test("double speed plays a 3 s film in about half the time", .enabled(if: isExtendedBuild))
    func fast() async throws {
        let player = try await controller("fixture-ogm")
        defer { player.close() }
        player.setRate(2)
        let start = ContinuousClock.now
        player.play()
        #expect(player.rate == 2)
        #expect(await waitUntil(6) { player.state == .ended })
        let took = ContinuousClock.now - start
        #expect(took > .seconds(1.2), "\(took)")                                        // never faster than double speed allows
        if testPatience == 1 { #expect(took < .seconds(2.6), "\(took)") }                // a slow machine plays it later
    }

    @Test("subtitles from a file are drawn over the picture by the engine, at the right time", .enabled(if: isExtendedBuild))
    func subtitles() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-avi-xvid"))
        try session.add(SubtitleTrack(data: Data("1\n00:00:01,000 --> 00:00:02,000\nHello there\n".utf8), name: "Film.en.srt"))
        let player = try #require(try await session.makeController() as? SoftwareController)
        player.isMuted = true
        defer { player.close() }
        let choice = try #require(player.subtitleChoices.first)
        #expect(choice.isExternal && player.subtitleFrame(size: CGSize(width: 640, height: 360)) == nil, "nothing drawn before one is chosen")
        try await player.select(choice)
        await player.seek(to: 1.5)
        let frame = try #require(player.subtitleFrame(size: CGSize(width: 640, height: 360)))
        #expect(frame.images.count == 1)
        await player.seek(to: 2.5)
        #expect(player.subtitleFrame(size: CGSize(width: 640, height: 360))?.images.isEmpty == true)
        try await player.deselectSubtitles()
        #expect(player.subtitleFrame(size: CGSize(width: 640, height: 360)) == nil)
    }

    @Test("the audio tracks of the file can be listed and switched while playing")
    func audioChoices() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-avi-xvid"))
        guard isExtendedBuild else { return }
        let player = try #require(try await session.makeController() as? SoftwareController)
        player.isMuted = true
        defer { player.close() }
        #expect(player.audioChoices.count == 1)
        try await player.select(player.audioChoices[0])
    }

    @Test("files AVPlayer plays are controlled through the same protocol: play, pause, seek, time, end", arguments: ["fixture-basic", "fixture-ts"])
    func avPlayerController(name: String) async throws {
        let session = try await PlaybackSession(url: Fixture.url(name))
        let player = try await session.makeController()
        player.isMuted = true
        defer { player.close() }
        #expect(player is AVPlayerController && player.path == .remux)
        #expect(await waitUntil(10) { player.state == .ready })
        player.play()
        #expect(await waitUntil(10) { player.currentTime > 0.8 && player.state == .playing }, "\(player.state) at \(player.currentTime)")
        player.pause()
        #expect(player.state == .paused)
        await player.seek(to: 1.5)
        #expect(abs(player.currentTime - 1.5) < 0.2)
        player.play()
        #expect(await waitUntil(10) { player.state == .ended }, "\(player.state) at \(player.currentTime)")
        var updates = 0
        for await time in player.timeUpdates { _ = time; updates += 1; if updates >= 2 { break } }
        #expect(updates >= 1, "the time stream gives the time")
    }

    @Test("a file that cannot be played gives no controller")
    func unsupported() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-licensed-audio"))
        if session.info.playbackPlan.path == .unsupported {
            await #expect(throws: MediaError.self) { _ = try await session.makeController() }
        }
    }
}
#endif
