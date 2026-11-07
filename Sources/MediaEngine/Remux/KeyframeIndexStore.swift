import CryptoKit
import Foundation
import Synchronization

/// Keyframe lists the engine had to work for (a file whose own index was missing or unusable), kept so that the next
/// opening of the same file starts at once and every reader of the file can seek straight to a keyframe.
///
/// A file is recognised by its length and a hash of its first 64 KB, never by its name or place, and a list holds times
/// and byte offsets only. The lists live in the app's Caches folder (the system may clear it); at most ``limit`` are kept.
final class KeyframeIndexStore: Sendable {
    static let shared = KeyframeIndexStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MediaEngine/KeyframeIndexes", isDirectory: true))

    struct Entry: Codable, Sendable, Equatable {
        var version = 1
        /// The video stream the list belongs to (the demuxer's stream index).
        var stream: Int
        /// Seconds on the engine's timeline (the file's start time taken off), in order.
        var keyframes: [Double]
        /// Absolute byte offsets, where known: where the demuxer starts reading for that keyframe.
        var positions: [Int64?]
        var duration: Double
    }

    let limit = 200
    private let directory: URL?
    private let memory = Mutex<[String: Entry]>([:])

    init(directory: URL?) {
        self.directory = directory
    }

    /// The file's identity: its length and a hash of its first 64 KB (bytes every opening reads anyway).
    static func key(for source: any ByteSource) -> String? {
        guard let length = source.length, length > 0 else { return nil }
        guard let head = EBMLReader(source: source).bytes(at: 0, count: Int(min(length, 64 * 1024))) else { return nil }
        let digest = SHA256.hash(data: head).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(length)-\(digest)"
    }

    func lookup(_ key: String) -> Entry? {
        if let entry = memory.withLock({ $0[key] }) { return entry }
        guard let url = file(for: key), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1, entry.keyframes.count == entry.positions.count, !entry.keyframes.isEmpty else { return nil }
        memory.withLock { $0[key] = entry }
        return entry
    }

    func remember(_ entry: Entry, for key: String) {
        memory.withLock { $0[key] = entry }
        guard let directory, let url = file(for: key), let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        prune(directory)
    }

    private func file(for key: String) -> URL? {
        directory?.appendingPathComponent(key + ".json")
    }

    /// Keeps the newest ``limit`` lists.
    private func prune(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > limit else { return }
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for url in files.sorted(by: { modified($0) < modified($1) }).prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
