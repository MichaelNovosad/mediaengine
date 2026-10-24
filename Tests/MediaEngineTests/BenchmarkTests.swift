import AVFoundation
import Darwin
import Foundation
import Testing
@testable import MediaEngine

/// Measurements on a real (or generated) file; they only run when `MEDIAENGINE_BENCH_FILE` names one:
///
///     MEDIAENGINE_BENCH_FILE=/path/movie.mkv swift test --filter BenchmarkTests
///
/// Everything is printed with a `BENCH` prefix. The assertions are the acceptance targets (PRB-1, RMX-5, RMX-6,
/// RMX-7, RMX-12); the numbers belong in `docs/PROGRESS.md` next to the machine they were taken on.
private let benchmarkPath = ProcessInfo.processInfo.environment["MEDIAENGINE_BENCH_FILE"]

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private func summary(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "none" }
    let sorted = values.sorted()
    return String(format: "median %.1f ms, mean %.1f ms, max %.1f ms (n=%d)",
                  sorted[sorted.count / 2], values.reduce(0, +) / Double(values.count), sorted.last!, values.count)
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Benchmark", .serialized, .timeLimit(.minutes(60)),
       .enabled(if: benchmarkPath != nil, "set MEDIAENGINE_BENCH_FILE to a media file"))
struct BenchmarkTests {
    private let clock = ContinuousClock()

    private func time<T>(_ work: () throws -> T) rethrows -> (value: T, ms: Double) {
        let start = clock.now
        let value = try work()
        return (value, milliseconds(clock.now - start))
    }

    @Test("open, first segments, seeks, sequential playback, continuity and memory")
    func pipeline() async throws {
        let url = URL(fileURLWithPath: try #require(benchmarkPath))
        let baseline = footprint()
        var peak = baseline
        func sample() { peak = max(peak, footprint()) }

        // Opening.
        let probeStart = clock.now
        let source = try await MediaSource(url: url)
        let info = try await source.probe()
        let probeMs = milliseconds(clock.now - probeStart)
        let sessionStart = clock.now
        let session = try RemuxSession(source: source.byteSource, info: info, cancellation: CancellationFlag())
        defer { session.close() }
        let sessionMs = milliseconds(clock.now - sessionStart)
        sample()
        let segmentCount = session.plan.segments.count
        let audioIDs = info.audioTracks.map(\.id).filter { session.hasOutput($0) }
        let video = info.videoTracks.first.map(\.id)
        print("BENCH file: \(url.lastPathComponent), \((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { $0 / 1_048_576 } ?? 0) MB, "
              + "\(Int(info.duration ?? 0)) s, \(segmentCount) segments, audio tracks \(audioIDs.map { id in "\(id)=\(info.tracks.first { $0.id == id }?.codec.name ?? "?")" })")
        print("BENCH probe: \(String(format: "%.1f", probeMs)) ms; session (index + plan): \(String(format: "%.1f", sessionMs)) ms")

        // The first things a player asks for.
        var first: [(String, Double)] = []
        for path in (["master.m3u8"] + (video != nil ? ["video.m3u8", "video-init.mp4", "video-0.m4s"] : []))
            + audioIDs.flatMap({ ["audio-\($0).m3u8", "audio-\($0)-init.mp4", "audio-\($0)-0.m4s"] }) {
            let result = try time { try session.resource(path: path) }
            #expect(result.value != nil, "\(path) was not served")
            first.append((path, result.ms))
        }
        sample()
        let firstTotal = first.reduce(0) { $0 + $1.1 }
        print("BENCH first requests: total \(String(format: "%.1f", firstTotal)) ms; " + first.map { "\($0.0) \(String(format: "%.1f", $0.1))" }.joined(separator: ", "))

        // Random seeks: segments never touched before, in random order.
        var generator = SplitMix64(state: 7)
        var candidates = Array(max(1, segmentCount / 20)..<max(2, segmentCount))
        candidates.shuffle(using: &generator)
        var videoSeeks: [Double] = [], audioSeeks: [Double] = []
        for index in candidates.prefix(12) {
            if video != nil { videoSeeks.append(try time { try session.resource(path: "video-\(index).m4s") }.ms) }
            for id in audioIDs.prefix(2) { audioSeeks.append(try time { try session.resource(path: "audio-\(id)-\(index).m4s") }.ms) }
            sample()
        }
        print("BENCH seek, video segment: \(summary(videoSeeks))")
        print("BENCH seek, audio segment: \(summary(audioSeeks))")

        // Whole-file sequential pass: timing like playback, plus continuity and sync over the full length.
        struct Track { var next: UInt64?; var worstGap = 0.0; var gaps = 0 }
        var tracks: [Int: Track] = [:]
        var offsets: [Double] = []
        var sequential: [Double] = []
        let streams = (video.map { [$0] } ?? []) + audioIDs
        for index in 0..<segmentCount {
            var starts: [Int: Double] = [:]
            var total = 0.0
            for stream in streams {
                let path = stream == video ? "video-\(index).m4s" : "audio-\(stream)-\(index).m4s"
                let result = try time { try session.resource(path: path) }
                total += result.ms
                guard let data = result.value?.data, let fragment = fragmentFacts(data) else { continue }
                let scale = Double(session.timescale(stream))
                starts[stream] = Double(fragment.baseDecodeTime) / scale
                var track = tracks[stream] ?? Track()
                if let expected = track.next {
                    let gap = (Double(fragment.baseDecodeTime) - Double(expected)) / scale
                    if abs(gap) > track.worstGap { track.worstGap = abs(gap) }
                    if abs(gap) > 0.001 { track.gaps += 1 }
                }
                track.next = fragment.baseDecodeTime + fragment.totalDuration
                tracks[stream] = track
            }
            sequential.append(total)
            // The first segment carries the audio priming (negative start); drift is judged on the rest.
            if index > 0, let v = video.flatMap({ starts[$0] }) {
                for id in audioIDs { if let a = starts[id] { offsets.append(a - v) } }
            }
            if index % 50 == 0 { sample() }
            if index % 4 == 0, ProcessInfo.processInfo.environment["MEDIAENGINE_BENCH_TRACE"] != nil {
                print("BENCH trace segment \(index): footprint \(footprint() / 1_048_576) MB, cache \(session.cachedBytes / 1_048_576) MB")
            }
        }
        sample()
        print("BENCH sequential, all streams per segment: \(summary(sequential))")
        for (stream, track) in tracks.sorted(by: { $0.key < $1.key }) {
            print("BENCH continuity stream \(stream): worst gap/overlap between neighbouring segments \(String(format: "%.1f", track.worstGap * 1000)) ms, \(track.gaps) joins off by more than 1 ms")
        }
        let slice = max(1, min(100, offsets.count / 4))
        let early = offsets.prefix(slice).reduce(0, +) / Double(slice), late = offsets.suffix(slice).reduce(0, +) / Double(slice)
        print("BENCH audio start minus video start: min \(String(format: "%.1f", (offsets.min() ?? 0) * 1000)) ms, max \(String(format: "%.1f", (offsets.max() ?? 0) * 1000)) ms; "
              + "mean of first \(slice) \(String(format: "%.1f", early * 1000)) ms, last \(slice) \(String(format: "%.1f", late * 1000)) ms, drift \(String(format: "%.1f", (late - early) * 1000)) ms")
        let grown = peak - baseline
        let beforeClose = footprint()
        session.close()
        try await Task.sleep(for: .milliseconds(300))
        let afterClose = footprint()
        _ = malloc_zone_pressure_relief(nil, 0)                                  // hand free malloc blocks back to the system
        print("BENCH memory after the pass: \(beforeClose / 1_048_576) MB; after close(): \(afterClose / 1_048_576) MB; after malloc relief: \(footprint() / 1_048_576) MB")
        if ProcessInfo.processInfo.environment["MEDIAENGINE_BENCH_HOLD"] != nil {
            print("BENCH holding pid \(getpid()) for inspection with leaks/heap/vmmap")
            try await Task.sleep(for: .seconds(40))
        }
        print("BENCH memory: baseline \(baseline / 1_048_576) MB, peak \(peak / 1_048_576) MB, growth \(grown / 1_048_576) MB")

        // Acceptance targets.
        #expect(probeMs < 500, "PRB-1: probe took \(probeMs) ms")
        #expect(firstTotal < 1_500, "RMX-6: first requests took \(firstTotal) ms")
        if let median = videoSeeks.sorted().dropFirst(videoSeeks.count / 2).first { #expect(median < 500, "RMX-5: median video seek \(median) ms") }
        #expect(grown < 150 * 1_048_576, "RMX-7: memory grew by \(grown / 1_048_576) MB")
        if offsets.count >= 8 { #expect(abs(late - early) < 0.04, "RMX-12: audio/video offset drifted by \((late - early) * 1000) ms") }
        for (stream, track) in tracks { #expect(track.worstGap < 0.04, "RMX-12: stream \(stream) has a \(track.worstGap * 1000) ms gap or overlap") }
    }

    @Test("AVPlayer: time to playing and seek completion")
    @MainActor
    func player() async throws {
        let url = URL(fileURLWithPath: try #require(benchmarkPath))
        let started = clock.now
        let session = try await PlaybackSession(url: url)
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        while player.currentTime().seconds < 0.1 {
            try await Task.sleep(for: .milliseconds(5))
            if clock.now - started > .seconds(20) { Issue.record("playback did not start within 20 s"); return }
        }
        let toPlaying = milliseconds(clock.now - started)
        let duration = session.info.duration ?? 60
        var generator = SplitMix64(state: 11)
        var seeks: [Double] = []
        for _ in 0..<8 {
            let target = Double.random(in: 1..<max(2, duration - 10), using: &generator)
            let begin = clock.now
            _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            var elapsed = milliseconds(clock.now - begin)
            // Seek completion means the data is ready; playback has resumed once the clock moves past the target.
            while player.currentTime().seconds < target + 0.1 {
                try await Task.sleep(for: .milliseconds(5))
                elapsed = milliseconds(clock.now - begin)
                if elapsed > 15_000 { break }
            }
            seeks.append(elapsed)
        }
        print("BENCH AVPlayer: time to playing \(String(format: "%.0f", toPlaying)) ms; seek to resumed playback: \(summary(seeks))")
        #expect(toPlaying < 1_500, "RMX-6: AVPlayer needed \(toPlaying) ms to start")
        #expect(seeks.sorted()[seeks.count / 2] < 500, "RMX-5: median seek-to-playing \(seeks.sorted()[seeks.count / 2]) ms")
        player.pause()
        session.close()
    }
}
