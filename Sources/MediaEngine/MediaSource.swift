import Foundation

/// Something the engine can open: a file, a web address, or any ``ByteSource``.
///
/// ```swift
/// let source = try await MediaSource(url: fileURL)
/// let info = try await source.probe()
/// print(info.tracks.map(\.codec.displayName), info.playbackPlan.path)
/// ```
public struct MediaSource: Sendable {
    let byteSource: any ByteSource

    /// Wraps a custom byte source, for example a network share.
    public init(byteSource: some ByteSource) {
        self.byteSource = byteSource
    }

    /// Opens a local file (including security-scoped URLs from the system file picker) or an
    /// HTTP(S) address that supports range requests.
    public init(url: URL) async throws {
        switch url.scheme?.lowercased() {
        case "http", "https":
            self.byteSource = try await HTTPByteSource.open(url: url)
        case "file":
            self.byteSource = try FileByteSource(url: url)
        default:
            throw MediaError.unreadable(detail: "unsupported URL scheme")
        }
    }

    /// Reads the file's structure without decoding any media: container, tracks, chapters,
    /// attachments and the playback plan. Cancelling the task stops reading promptly.
    public func probe() async throws -> MediaInfo {
        let source = byteSource
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Blocking work belongs on its own thread, never on Swift's cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try Prober.probe(source: source, cancellation: cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            source.cancelPendingReads()
        }
    }
}
