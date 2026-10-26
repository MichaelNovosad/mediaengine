import Foundation
import MediaEngine

// usage: SwapProbe <media file>
let arguments = CommandLine.arguments
guard arguments.count > 1 else { print("usage: SwapProbe <media file>"); exit(2) }
do {
    let session = try await PlaybackSession(url: URL(fileURLWithPath: arguments[1]))
    let build = MediaEngine.buildInfo
    print("ffmpeg \(build.ffmpegVersion) | \(build.ffmpegLicense)")
    let profiles = MediaEngine.availableProfiles
    print("profiles core" + (profiles.contains(.extended) ? "+extended" : "") + (profiles.contains(.licensedAudio) ? "+licensedAudio" : ""))
    print("plan \(session.info.playbackPlan.path.rawValue)")
    print("acknowledgements \(MediaEngine.acknowledgements.map(\.id).joined(separator: ","))")
} catch {
    print("failed: \(error)")
    exit(1)
}
