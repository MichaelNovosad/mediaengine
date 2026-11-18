import Foundation

extension MediaEngine {
    /// Where the engine keeps what it learned about files it opened: descriptions of files read over a network (so that opening one
    /// again skips a second or more of probing) and the keyframe maps of files without a usable index. In the app's Caches folder, which
    /// the system may also empty.
    static let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MediaEngine", isDirectory: true)

    /// How many bytes that takes on disk. Reads the folder: call it off the main thread.
    public static func cacheSize() -> Int64 {
        cacheFolder.map(folderSize) ?? 0
    }

    /// Forgets it, in memory and on disk. Nothing stops working: files are probed and indexed again the next time they open, which
    /// takes longer once for files on a server or without an index.
    public static func clearCache() {
        ProbeStore.shared.removeAll()
        KeyframeIndexStore.shared.removeAll()
    }

    /// The bytes of the regular files in a folder and its subfolders (0 for a folder that is not there).
    static func folderSize(_ folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}
