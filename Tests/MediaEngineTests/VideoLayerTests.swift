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

/// Which sound the system may spatialize (the app's Jira EGA-106): set on the item that plays the sound.
@Suite("Spatial audio permission")
@MainActor
struct SpatializationTests {
    @Test("the AVPlayer path sets it on its item; the engine's own player on its sound item", arguments: ["fixture-basic", "fixture-mpeg2"])
    func reachesTheItem(name: String) async throws {
        let session = try await PlaybackSession(url: Fixture.url(name))
        guard session.info.playbackPlan.path != .unsupported else { return }                  // the software path needs the extended build
        let controller = try await session.makeController()
        controller.isMuted = true
        defer { controller.close() }
        controller.allowedAudioSpatialization = []
        #expect(controller.allowedAudioSpatialization == [])
        controller.allowedAudioSpatialization = .multichannel
        if let native = controller as? AVPlayerController {
            #expect(native.item.allowedAudioSpatializationFormats == .multichannel)
        } else {
            #expect(controller.allowedAudioSpatialization == .multichannel, "\(controller.path)")
        }
    }
}
