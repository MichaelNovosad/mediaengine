import AVFoundation
import Foundation

extension PlaybackSession {
    /// The audio tracks the player can play, in file order. Tracks the engine cannot play (DTS without the licensed
    /// module, for example) are not listed; ``MediaInfo/playbackPlan`` says why.
    public var audioChoices: [TrackChoice] { ServedTracks(info: info).choices().audio }

    /// The text subtitle tracks the player can show, in file order.
    public var subtitleChoices: [TrackChoice] { ServedTracks(info: info).choices().subtitles }

    /// Switches the item to this audio or subtitle track.
    ///
    /// The system menu cannot tell tracks of one language apart, so this matches the choice to the player's option
    /// by the track's name (which is unique, see ``TrackChoice/title``).
    @MainActor
    public func select(_ choice: TrackChoice, on item: AVPlayerItem) async throws {
        let group = try await mediaGroup(for: choice.kind, of: item)
        guard let option = await option(for: choice, in: group, of: item) else {
            throw MediaError.unsupported(detail: "the player does not offer the track \"\(choice.title)\"")
        }
        item.select(option, in: group)
    }

    /// Turns the subtitles off.
    @MainActor
    public func deselectSubtitles(on item: AVPlayerItem) async throws {
        let group = try await mediaGroup(for: .subtitle, of: item)
        item.select(nil, in: group)
    }

    /// The track the item currently plays or shows, or `nil` (no subtitles, or a track that is not ours, such as a
    /// system-made translation).
    @MainActor
    public func selectedChoice(of kind: TrackChoice.Kind, on item: AVPlayerItem) async -> TrackChoice? {
        guard let group = try? await mediaGroup(for: kind, of: item),
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        let title = await Self.title(of: selected)
        let choices = kind == .audio ? audioChoices : subtitleChoices
        return choices.first { $0.title == title }
    }

    /// Selects the tracks that `preferences` ask for ("Japanese audio, English subtitles"). The player picks tracks on
    /// its own from the system's language settings; call this once the item exists to apply a viewer's or a series'
    /// own choice instead.
    @MainActor
    public func apply(_ preferences: TrackPreferences, to item: AVPlayerItem) async throws {
        let picked = preferences.pick(audio: audioChoices, subtitles: subtitleChoices)
        if let audio = picked.audio { try await select(audio, on: item) }
        if let subtitle = picked.subtitle { try await select(subtitle, on: item) } else if !subtitleChoices.isEmpty {
            try await deselectSubtitles(on: item)
        }
    }

    // MARK: Internals

    @MainActor
    private func mediaGroup(for kind: TrackChoice.Kind, of item: AVPlayerItem) async throws -> AVMediaSelectionGroup {
        let characteristic: AVMediaCharacteristic = kind == .audio ? .audible : .legible
        guard let group = try await item.asset.loadMediaSelectionGroup(for: characteristic) else {
            throw MediaError.unsupported(detail: "the item has no \(kind.rawValue) tracks")
        }
        return group
    }

    /// The option named like the choice. Files AVFoundation plays itself may not carry our names; then the option at
    /// the choice's position is taken, if the counts agree.
    @MainActor
    private func option(for choice: TrackChoice, in group: AVMediaSelectionGroup, of item: AVPlayerItem) async -> AVMediaSelectionOption? {
        var titled: [(AVMediaSelectionOption, String?)] = []
        for option in group.options { titled.append((option, await Self.title(of: option))) }
        if let match = titled.first(where: { $0.1 == choice.title }) { return match.0 }
        let own = titled.filter { $0.1 != nil }.map(\.0)
        let choices = choice.kind == .audio ? audioChoices : subtitleChoices
        guard own.isEmpty, let position = choices.firstIndex(of: choice) else { return nil }
        let candidates = group.options.filter { !$0.displayName.contains("Translated") }
        return candidates.count == choices.count ? candidates[position] : nil
    }

    @MainActor
    private static func title(of option: AVMediaSelectionOption) async -> String? {
        for item in option.commonMetadata where item.commonKey == .commonKeyTitle {
            if let text = try? await item.load(.stringValue), !text.isEmpty { return text }
        }
        return nil
    }
}
