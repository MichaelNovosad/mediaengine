import AVKit
import MediaEngine
import SwiftUI

struct PlayerScreen: View {
    @State private var player = AVPlayer()

    var body: some View {
        VideoPlayer(player: player)
    }
}
