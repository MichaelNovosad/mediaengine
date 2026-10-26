import AVKit
import MediaEngine
import SwiftUI
import UniformTypeIdentifiers

/// Pick a file, play it, switch tracks. Everything here goes through ``PlaybackController``, so the same code serves files the system
/// plays (MKV, MP4, ...) and files the engine decodes itself (old AVI, MPEG-2, VP9, ...).
struct PlayerView: View {
    @State private var controller: (any PlaybackController)?
    @State private var info: MediaInfo?
    @State private var message = "Choose a video file"
    @State private var pickingVideo = true
    @State private var pickingSubtitle = false
    @State private var showLicences = false
    @State private var userHasPro = true                     // your own purchase logic goes here

    var body: some View {
        VStack(spacing: 0) {
            picture
            if let controller { Controls(controller: controller, pickSubtitle: { pickingSubtitle = true }) }
        }
        .overlay(alignment: .top) { notice }
        .toolbar {
            ToolbarItem { Button("Open") { pickingVideo = true } }
            ToolbarItem { Button("Licences") { showLicences = true } }
        }
        .fileImporter(isPresented: $pickingVideo, allowedContentTypes: [.movie, .audiovisualContent, .data]) { result in
            if case .success(let url) = result { Task { await open(url) } }
        }
        .fileImporter(isPresented: $pickingSubtitle, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { Task { await addSubtitle(url) } }
        }
        .sheet(isPresented: $showLicences) { LicencesView() }
    }

    @ViewBuilder private var picture: some View {
        if let controller = controller as? AVPlayerController {
            VideoPlayer(player: controller.player)                // system controls, AirPlay, Picture in Picture
        } else if let controller {
            MediaVideoView(controller: controller)                // the software player's picture; Controls draws the buttons
        } else {
            Color.black.overlay { Text(message).foregroundStyle(.white) }
        }
    }

    /// What the file needs from the optional codec module, and whether this build has it (profile gating).
    @ViewBuilder private var notice: some View {
        if let info, info.requiredProfile.contains(.extended), !MediaEngine.availableProfiles.contains(.extended) {
            Text("This file needs the extended codec module, which this build does not include.").padding().background(.thinMaterial)
        } else if let info, info.requiredProfile.contains(.extended), !userHasPro {
            Text("This format is part of Pro.").padding().background(.thinMaterial)
        } else if info?.isIncomplete == true {
            Text("This file is incomplete (an unfinished download?).").padding().background(.thinMaterial)
        }
    }

    @MainActor
    func open(_ fileURL: URL) async {
        controller?.close()
        controller = nil
        do {
            let session = try await PlaybackSession(url: fileURL)
            info = session.info
            if session.info.requiredProfile.contains(.extended), !userHasPro { return }
            let made = try await session.makeController()
            if let native = made as? AVPlayerController {            // prefer the person's language for sound, subtitles off
                try? await session.apply(TrackPreferences(audioLanguages: [Locale.current.language.languageCode?.identifier ?? "en"], subtitles: .off), to: native.item)
            }
            controller = made
            made.play()
        } catch {
            message = "Could not open the file: \(error.localizedDescription)"
        }
    }

    @MainActor
    func addSubtitle(_ url: URL) async {
        guard let controller, let track = try? await SubtitleTrack(url: url) else { return }
        try? controller.session.add(track)
        if let added = controller.subtitleChoices.last { try? await controller.select(added) }
    }
}

/// Play and pause, a position slider, speed, audio and subtitle menus, and for the software player a deinterlacing switch.
struct Controls: View {
    let controller: any PlaybackController
    let pickSubtitle: () -> Void
    @State private var scrubbing: Double?

    var body: some View {
        HStack {
            Button(controller.state == .playing ? "Pause" : "Play") {
                controller.state == .playing ? controller.pause() : controller.play()
            }
            Slider(value: Binding(get: { scrubbing ?? controller.currentTime }, set: { scrubbing = $0 }), in: 0...max(controller.duration ?? 1, 1)) { editing in
                if !editing, let target = scrubbing { Task { await controller.seek(to: target); scrubbing = nil } }
            }
            Menu("Audio") {
                ForEach(controller.audioChoices) { choice in Button(choice.title) { Task { try? await controller.select(choice) } } }
            }
            Menu("Subtitles") {
                Button("Off") { Task { try? await controller.deselectSubtitles() } }
                ForEach(controller.subtitleChoices) { choice in Button(choice.title) { Task { try? await controller.select(choice) } } }
                Button("Add file…", action: pickSubtitle)
            }
            if let software = controller as? SoftwareController {
                Toggle("Deinterlace", isOn: Binding(get: { software.deinterlacing == .automatic }, set: { software.deinterlacing = $0 ? .automatic : .off }))
                    .toggleStyle(.button)
            }
        }
        .padding()
    }
}

/// The third-party licences of the binaries in this build, from ``MediaEngine/acknowledgements``.
struct LicencesView: View {
    var body: some View {
        NavigationStack {
            List(MediaEngine.acknowledgements) { item in
                DisclosureGroup("\(item.name) \(item.version), \(item.license)") {
                    if let notice = item.requiredNotice { Text(notice).font(.footnote) }
                    Text(item.licenseText).font(.caption2.monospaced())
                }
            }
            .navigationTitle("Licences")
        }
    }
}
