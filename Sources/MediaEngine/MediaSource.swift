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
                // Blocking work belongs on its own thread, never on Swift's cooperative pool (the look-up below reads the
                // file's first 64 KB to recognise it, which over a network blocks too).
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        // A file read over a network that was looked at before (a reopening, or the session made again when
                        // files are added) is described from what was kept: the look at its start and end costs a second or more.
                        if source.throughput != nil, let remembered = ProbeStore.shared.lookup(source) {
                            continuation.resume(returning: remembered)
                            return
                        }
                        let info = try Prober.probe(source: source, cancellation: cancellation)
                        if source.throughput != nil { ProbeStore.shared.remember(info, for: source) }
                        continuation.resume(returning: info)
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

    /// The bytes of several attachments (the fonts of a subtitle track), read with one opening of the file.
    func data(of attachments: [Attachment]) async -> [Int: Data] {
        let source = byteSource
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: (try? AttachmentReader.read(attachments, from: source, cancellation: cancellation)) ?? [:])
                }
            }
        } onCancel: {
            cancellation.cancel()
            source.cancelPendingReads()
        }
    }

    /// The bytes of a file embedded in the container: cover art, or a font for subtitle rendering. Attachments larger
    /// than 32 MB are refused.
    public func data(of attachment: Attachment) async throws -> Data {
        let source = byteSource
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try AttachmentReader.read(attachment, from: source, cancellation: cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
            source.cancelPendingReads()
        }
    }
}

