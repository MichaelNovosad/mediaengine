import AVFoundation
import Foundation
import Testing
@testable import MediaEngine

/// The AVPlayer path's own picture layer is made only for a view that asks for it (Eiga's review 2026-11-18, N1): a layer nothing
/// showed still watched its player and took part in a deadlock inside AVFoundation.
@Suite("The AVPlayer path's own layer")
@MainActor
struct VideoLayerTests {
    @Test("the layer is made when asked for, once, and shows the controller's player")
    func madeWhenAsked() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let made = try await session.makeController()
        made.isMuted = true
        let controller = try #require(made as? AVPlayerController, "\(session.info.playbackPlan.path)")
        defer { controller.close() }
        #expect(!controller.hasVideoLayer, "a controller nothing shows has no layer watching its player")
        let layer = MediaVideoLayerHost.layer(for: controller)
        #expect(controller.hasVideoLayer)
        #expect(layer === controller.videoLayer, "the same layer every time")
        #expect(controller.videoLayer.player === controller.player)
        #expect(controller.videoLayer.videoGravity == .resizeAspect)
    }
}
