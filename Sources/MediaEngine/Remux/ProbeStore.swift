import Foundation
import Synchronization

/// What the probe found out about files read over a network, kept so that opening one again (later, or when the player's
/// session is made again because files were added) skips the look at the file's start and end, which costs a second or
/// more over a network. In memory for this run of the app, and on disk in the app's Caches folder (the system may clear
/// it), at most ``limit`` files, a few kilobytes each.
///
/// A file is recognised as for ``KeyframeIndexStore`` (its length and a hash of its first 64 KB). A kept description is
/// used only by the same build of the app on a device with the same capabilities (the playback plan depends on both);
/// anything else probes again. Test runs neither read nor write it, so that they always see what the code finds now.
final class ProbeStore: Sendable {
    static let shared = ProbeStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MediaEngine/Probes", isDirectory: true))

    private struct Record: Codable {
        var format = 1
        var build: String
        var capabilities: String
        var info: MediaInfo
    }

    let limit = 200
    private let directory: URL?
    private let memory = Mutex<[String: MediaInfo]>([:])
    private let enabled: Bool

    init(directory: URL?) {
        self.directory = directory
        let name = ProcessInfo.processInfo.processName.lowercased()
        enabled = !(name.contains("xctest") || name.contains("swiftpm-testing") || Bundle.main.bundlePath.hasSuffix(".xctest"))
    }

    func lookup(_ source: any ByteSource) -> MediaInfo? {
        guard enabled, let key = KeyframeIndexStore.key(for: source) else { return nil }
        if let info = memory.withLock({ $0[key] }) { return info }
        guard let url = file(for: key), let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.format == 1, record.build == Self.build, record.capabilities == Self.capabilities else { return nil }
        memory.withLock { $0[key] = record.info }
        return record.info
    }

    func remember(_ info: MediaInfo, for source: any ByteSource) {
        guard enabled, let key = KeyframeIndexStore.key(for: source) else { return }
        memory.withLock { $0[key] = info }
        guard let directory, let url = file(for: key),
              let data = try? JSONEncoder().encode(Record(build: Self.build, capabilities: Self.capabilities, info: info)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > limit else { return }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in files.sorted(by: { modified($0) < modified($1) }).prefix(files.count - limit) { try? FileManager.default.removeItem(at: old) }
    }

    private func file(for key: String) -> URL? {
        directory?.appendingPathComponent(key + ".json")
    }

    /// This build of the app: its version and when its executable was made (a new build of the engine is a new executable).
    private static let build: String = {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "")-\(info?["CFBundleVersion"] as? String ?? "")"
        let made = Bundle.main.executableURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return "\(version)-\(made?.timeIntervalSince1970 ?? 0)"
    }()

    /// What the playback plan depends on besides the file.
    private static var capabilities: String {
        let current = DeviceCapabilities.current
        return "\(current.hardwareAV1)-\(current.availableProfiles.rawValue)"
    }
}
