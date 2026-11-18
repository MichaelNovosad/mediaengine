import Foundation
import Testing
@testable import MediaEngine

/// What the engine keeps in the Caches folder, and the app's Settings > Storage that shows its size and clears it (2026-11-18, EGA-113).
@Suite("The engine's caches")
struct CacheTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a keyframe map kept on disk is counted in the folder's size, and forgotten in memory and on disk by removeAll")
    func keyframeMaps() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KeyframeIndexStore(directory: root.appendingPathComponent("KeyframeIndexes", isDirectory: true))
        let entry = KeyframeIndexStore.Entry(stream: 0, keyframes: [0, 1, 2], positions: [0, 1000, 2000], duration: 3)
        store.remember(entry, for: "film")
        #expect(store.lookup("film") == entry)
        #expect(MediaEngine.folderSize(root) > 0)

        store.removeAll()
        #expect(store.lookup("film") == nil)
        #expect(MediaEngine.folderSize(root) == 0)
    }

    @Test("a folder's size adds up the files in its subfolders; a folder that is not there is empty")
    func sizes() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: inner.appendingPathComponent("one"))
        try Data(repeating: 2, count: 5_000).write(to: root.appendingPathComponent("two"))
        #expect(MediaEngine.folderSize(root) >= 15_000)
        #expect(MediaEngine.folderSize(root.appendingPathComponent("missing", isDirectory: true)) == 0)
    }
}
