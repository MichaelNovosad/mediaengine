import AVKit
import MediaEngine
import SwiftUI

struct PlayerScreen: View {
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
    }

    func open(_ fileURL: URL) async throws {
        let session = try await PlaybackSession(url: fileURL)   // probes and chooses the best path
        let item = try await session.makePlayerItem()            // plain AVPlayerItem
        let preferences = TrackPreferences(audioLanguages: ["ja"], subtitleLanguages: ["en"])
        try await session.apply(preferences, to: item)          // Japanese audio, English subtitles
        player.replaceCurrentItem(with: item)
        player.play()
    }
}
