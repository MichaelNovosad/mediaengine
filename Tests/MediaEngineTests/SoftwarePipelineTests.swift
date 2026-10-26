import AVFoundation
import FFmpegLGPL
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// The software video path on its own: decode, queue, clock (extended build only: the decoders are in it).
@Suite("Software video pipeline", .serialized)
struct SoftwarePipelineTests {
    private func pipeline(_ name: String) async throws -> (SoftwareVideoPipeline, Int, MediaInfo) {
        let info = try await Fixture.probe(name)
        let reader = try PacketReader(source: FileByteSource(url: Fixture.url(name)), cancellation: CancellationFlag())
        let index = try #require(info.videoTracks.first?.id)
        let pipeline = try await MainActor.run { try SoftwareVideoPipeline(reader: reader, stream: index, frameRate: info.videoTracks.first?.video?.frameRate) }
        return (pipeline, index, info)
    }

    @Test("every software-decoded format reaches the display layer in order, at the right times, and the end is reported",
          .enabled(if: isExtendedBuild), arguments: ["fixture-avi-xvid", "fixture-flv", "fixture-wmv", "fixture-mpeg2", "fixture-realmedia", "fixture-ogm"])
    func playsToTheEnd(name: String) async throws {
        let (pipeline, _, _) = try await pipeline(name)
        let times = Mutex<[Double]>([])
        let ended = Mutex(false)
        pipeline.onFrame { frame in times.withLock { $0.append(frame.time) } }
        pipeline.onEnd { ended.withLock { $0 = true } }
        pipeline.synchronizer.setRate(1, time: .zero)
        await pipeline.start(at: 0)
        #expect(await waitUntil(15) { ended.withLock { $0 } }, "\(name) never reached its end; \(pipeline.currentStatistics)")
        let seen = times.withLock { $0 }
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $1 > $0 }, "presentation times rise")
        #expect(abs((seen.first ?? 9) - 0) < 0.1, "from \(seen.first ?? -1)")
        // Late pictures are dropped, so how many arrive and when the last one does measures speed: full-speed runs only.
        if testPatience == 1 {
            #expect((70...76).contains(seen.count), "\(name): \(seen.count) pictures")
            #expect(abs((seen.last ?? 0) - 2.96) < 0.15, "to \(seen.last ?? -1)")
            #expect(pipeline.currentStatistics.dropped < 5, "\(pipeline.currentStatistics)")
        }
        #expect(pipeline.currentStatistics.decoded >= 74, "\(pipeline.currentStatistics)")
        await pipeline.close()
    }
}
