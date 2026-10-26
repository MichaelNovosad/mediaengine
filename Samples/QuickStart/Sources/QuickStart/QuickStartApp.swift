import AVKit
import MediaEngine
import SwiftUI
import UniformTypeIdentifiers

@main
struct QuickStartApp: App {
    var body: some Scene { WindowGroup { PlayerScreen() } }
}

/// Pick any video file (MKV and WebM included) and play it with the system player controls: AirPlay, Picture in Picture,
/// subtitles and audio menus, HDR.
struct PlayerScreen: View {
    @State private var player = AVPlayer()
    @State private var picking = true
    @State private var message = "Choose a video file"

    var body: some View {
        VideoPlayer(player: player)
            .overlay(alignment: .top) { if player.currentItem == nil { Text(message).padding() } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.movie, .audiovisualContent, .data]) { result in
                guard case .success(let url) = result else { return }
                Task { await open(url) }
            }
    }

    @MainActor
    func open(_ fileURL: URL) async {
        do {
            let session = try await PlaybackSession(url: fileURL)   // probes and chooses the best path
            let item = try await session.makePlayerItem()            // plain AVPlayerItem
            player.replaceCurrentItem(with: item)                    // AVPlayerViewController / VideoPlayer
            player.play()
        } catch {
            message = "Could not open the file: \(error.localizedDescription)"
        }
    }
}
