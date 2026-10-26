import AVFoundation
import Darwin
import CoreGraphics
import Foundation
import Testing
@testable import MediaEngine

// Everything here measures time, memory, descriptors or CPU of the whole process, so another test running at the
// same time spoils the numbers. These tests run in a pass of their own:
//
//     MEDIAENGINE_EXCLUSIVE=1 swift test --filter ExclusiveTests
//
// `scripts/verify.sh` does that after the normal run; a plain `swift test` skips them.

private func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }

private let exclusive = ProcessInfo.processInfo.environment["MEDIAENGINE_EXCLUSIVE"] == "1"

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

@Suite("Timing and resources", .serialized, .timeLimit(.minutes(3)),
       .enabled(if: exclusive, "needs the process to itself: set MEDIAENGINE_EXCLUSIVE=1 (scripts/verify.sh does)"))
struct ExclusiveTests {
    @Test("opening and closing sessions 100 times leaks neither memory nor file descriptors")
    func noLeaks() async throws {
        let url = Fixture.url("fixture-basic")
        func cycle() async throws {
            let source = try await MediaSource(url: url)
            let info = try await source.probe()
            let session = try RemuxSession(source: source.byteSource, info: info, cancellation: CancellationFlag())
            _ = try session.resource(path: "master.m3u8")
            _ = try session.resource(path: "video-0.m4s")
            _ = try session.resource(path: "audio-2-0.m4s")                     // transcoded track
            session.close()
        }
        for _ in 0..<10 { try await cycle() }                                    // warm-up: caches, lazy statics
        let memoryBefore = footprint(), descriptorsBefore = openDescriptors()
        for _ in 0..<100 { try await cycle() }
        let grown = footprint() - memoryBefore
        if !underAddressSanitizer { #expect(grown < 30 * 1_024 * 1_024, "memory grew by \(grown / 1_024) KB over 100 cycles") }
        #expect(openDescriptors() - descriptorsBefore <= 2, "descriptors went from \(descriptorsBefore) to \(openDescriptors())")
    }

    @Test("overlay subtitle renderers (libass, picture decoders) leak neither memory nor file descriptors")
    func noOverlayLeaks() async throws {
        func cycle(_ name: String) async throws {
            let session = try await PlaybackSession(url: Fixture.url(name))
            let renderer = try await session.makeSubtitleRenderer(for: session.overlayChoices[0])
            try await renderer.prepare(at: 1.0)
            _ = renderer.frame(at: 1.0, size: CGSize(width: 640, height: 360))
            renderer.close()
            session.close()
        }
        for name in ["fixture-ass-fx", "fixture-bitmap"] {
            for _ in 0..<10 { try await cycle(name) }
            let memoryBefore = footprint(), descriptorsBefore = openDescriptors()
            for _ in 0..<60 { try await cycle(name) }
            let grown = footprint() - memoryBefore
            if !underAddressSanitizer { #expect(grown < 30 * 1_024 * 1_024, "\(name): memory grew by \(grown / 1_024) KB over 60 cycles") }
            #expect(openDescriptors() - descriptorsBefore <= 2, "\(name): descriptors went from \(descriptorsBefore) to \(openDescriptors())")
        }
    }

    @Test("playback sessions with a server also clean up completely")
    func noServerLeaks() async throws {
        func cycle() async throws {
            let session = try await PlaybackSession(url: Fixture.url("fixture-hevc"))
            let item = try await session.makePlayerItem()
            _ = item
            session.close()
        }
        for _ in 0..<5 { try await cycle() }
        try await Task.sleep(for: .milliseconds(200))
        let memoryBefore = footprint(), descriptorsBefore = openDescriptors()
        for _ in 0..<40 { try await cycle() }
        try await Task.sleep(for: .milliseconds(300))
        let grown = footprint() - memoryBefore
        if !underAddressSanitizer { #expect(grown < 30 * 1_024 * 1_024, "memory grew by \(grown / 1_024) KB over 40 cycles") }
        #expect(openDescriptors() - descriptorsBefore <= 4, "descriptors went from \(descriptorsBefore) to \(openDescriptors())")
    }

    @Test("small files open and serve their first segments quickly")
    @MainActor
    func timing() async throws {
        let started = ContinuousClock.now
        let session = try await PlaybackSession(url: Fixture.url("fixture-opus-vorbis"))
        let opened = ContinuousClock.now - started
        #expect(opened < .milliseconds(500), "probe took \(opened)")
        let remuxStart = ContinuousClock.now
        let item = try await session.makePlayerItem()
        let url = try #require((item.asset as? AVURLAsset)?.url)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let ready = ContinuousClock.now - remuxStart
        #expect(ready < .milliseconds(800), "server up and master playlist served in \(ready)")
        session.close()
    }

    @Test("an open, idle session uses essentially no CPU")
    @MainActor
    func idle() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-hevc"))
        let item = try await session.makePlayerItem()
        _ = try await URLSession(configuration: .ephemeral).data(from: #require((item.asset as? AVURLAsset)?.url))
        try await Task.sleep(for: .milliseconds(500))                          // let read-ahead finish
        let before = cpuSeconds()
        try await Task.sleep(for: .seconds(2))
        let used = cpuSeconds() - before
        #expect(used < 0.05, "idle session used \(Int(used * 1000)) ms of CPU in 2 s")
        session.close()
    }

    @Test("building large fragments over and over does not pile up memory")
    func fragmentsDoNotAccumulate() {
        // 20 MB of packets. Growing the output by appending made every build leave a few blocks of that size behind.
        var packets: [MediaPacket] = []
        for index in 0..<200 {
            let time = Int64(index) * 40
            packets.append(MediaPacket(stream: 0, data: Data(repeating: UInt8(index & 0xFF), count: 100_000),
                                       pts: time, dts: time, duration: 40, isKeyframe: index == 0))
        }
        let writer = FragmentWriter(trackID: 1, timescale: 1000, timeBase: Rational(num: 1, den: 1000),
                                    hasCompositionOffsets: true, shift: 0)
        for _ in 0..<5 { _ = writer.fragment(sequence: 1, packets: packets) }
        let before = footprint()
        for _ in 0..<30 { _ = writer.fragment(sequence: 1, packets: packets) }
        let grown = footprint() - before
        if !underAddressSanitizer { #expect(grown < 40 * 1_024 * 1_024, "30 more builds added \(grown / 1_048_576) MB") }
    }

    @Test("finished fragments go back to the system as soon as they are released")
    func fragmentsAreReturned() {
        var packets: [MediaPacket] = []
        for index in 0..<200 {
            let time = Int64(index) * 40
            packets.append(MediaPacket(stream: 0, data: Data(repeating: UInt8(index & 0xFF), count: 100_000),
                                       pts: time, dts: time, duration: 40, isKeyframe: index == 0))
        }
        let writer = FragmentWriter(trackID: 1, timescale: 1000, timeBase: Rational(num: 1, den: 1000),
                                    hasCompositionOffsets: true, shift: 0)
        var held: [Data] = []
        for _ in 0..<3 { held.append(writer.fragment(sequence: 1, packets: packets) ?? Data()) }    // warm-up
        held.removeAll()
        let before = footprint()
        for _ in 0..<5 { held.append(writer.fragment(sequence: 1, packets: packets) ?? Data()) }    // 5 x 20 MB
        let holding = footprint() - before
        held.removeAll()
        let released = holding - (footprint() - before)
        #expect(holding > 80 * 1_048_576, "five 20 MB fragments should show up in the footprint, not \(holding / 1_048_576) MB")
        if !underAddressSanitizer {
            #expect(released > 80 * 1_048_576, "only \(released / 1_048_576) MB of \(holding / 1_048_576) MB came back after release")
        }
    }

    @Test("probing every fixture takes well under 500 ms (PRB-1)")
    func probeIsFast() async throws {
        for name in Fixture.names {
            let started = ContinuousClock.now
            _ = try await Fixture.probe(name)
            #expect(ContinuousClock.now - started < .milliseconds(500), "slow probe: \(name)")
        }
        // 60 GB of reported size, real content only at the start: probing must not depend on size.
        let padded = PaddedByteSource(base: try Fixture.data("fixture-basic"), totalLength: 60 * 1_024 * 1_024 * 1_024)
        let started = ContinuousClock.now
        _ = try await MediaSource(byteSource: padded).probe()
        #expect(ContinuousClock.now - started < .milliseconds(500), "probing a 60 GB source took \(ContinuousClock.now - started)")
    }

    @Test("cancelling a probe in the middle of a slow read finishes promptly (API-4)")
    func cancellationIsPrompt() async throws {
        let slow = SlowByteSource(base: DataByteSource(try Fixture.data("fixture-basic")), delay: 0.1)
        let task = Task { try await MediaSource(byteSource: slow).probe() }
        while slow.readCount == 0 { try await Task.sleep(for: .milliseconds(5)) }      // cancel while a read is in flight
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: MediaError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .milliseconds(300), "cancelling took \(ContinuousClock.now - started)")
    }
}

