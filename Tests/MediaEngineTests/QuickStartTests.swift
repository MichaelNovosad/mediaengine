import AVFoundation
import Foundation
import Testing
import MediaEngine

/// API-1: the quick start of the README, line for line, on every platform the package supports (macOS and the iOS, iPadOS and
/// visionOS simulators run this same test). Plain `import MediaEngine`, no `@testable`: only what an app can use.
@Suite("Quick start")
struct QuickStartTests {
    @Test("an MKV opens with three lines and AVFoundation reads the item the engine made")
    @MainActor
    func fiveLines() async throws {
        let fileURL = Fixture.url("fixture-basic")
        let player = AVPlayer()

        let session = try await PlaybackSession(url: fileURL)   // probes and chooses the best path
        let item = try await session.makePlayerItem()            // plain AVPlayerItem
        player.replaceCurrentItem(with: item)                    // AVPlayerViewController / VideoPlayer

        #expect(player.currentItem === item)
        #expect(session.info.playbackPlan.path == .remux)
        let duration = try await item.asset.load(.duration)
        #expect(abs(duration.seconds - 3) < 0.3, "duration \(duration.seconds)")
        let subtitles = try await item.asset.loadMediaSelectionGroup(for: .legible)      // the file's SRT track, as the system menu sees it
        #expect(subtitles?.options.count == 1)
        session.close()
    }

    @Test("the controller flavour of the quick start: one object for every playback path")
    @MainActor
    func controller() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let player = try await session.makeController()          // AVPlayer-based here; the software player for other files
        player.isMuted = true
        #expect(player.state == .ready || player.state == .loading)
        #expect((player.duration ?? 0) > 2)
        player.close()
    }
}
