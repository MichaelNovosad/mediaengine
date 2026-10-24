import Foundation

/// Every failure the engine reports.
///
/// `errorDescription` is plain language and safe to show to people. `debugDescription` adds technical
/// detail for logs; it never contains file names or paths.
public enum MediaError: Error, Sendable, Equatable {
    /// The operation was cancelled.
    case cancelled
    /// Bytes could not be read from the source. `detail` is a short technical reason.
    case unreadable(detail: String)
    /// The data is not a media file the engine recognizes.
    case notMedia
    /// The file looks like media but is damaged or truncated beyond what the engine can use.
    case corrupt(detail: String)
    /// A network source failed. `detail` is a short technical reason.
    case network(detail: String)
    /// The server does not support HTTP range requests, which the engine needs for seeking.
    case rangeRequestsUnsupported
    /// The file is understood but this build cannot play it (for example a video format that is out of scope).
    case unsupported(detail: String)
    /// Something went wrong inside the engine.
    case engine(detail: String)
}

extension MediaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "The operation was cancelled."
        case .unreadable:
            "The file could not be read."
        case .notMedia:
            "This file is not a video or audio file the app can open."
        case .corrupt:
            "This file looks damaged or incomplete."
        case .network:
            "The network connection failed."
        case .rangeRequestsUnsupported:
            "This server does not support skipping around in a file, which playback needs."
        case .unsupported:
            "This file uses a format the app cannot play."
        case .engine:
            "Something went wrong while opening the file."
        }
    }
}

extension MediaError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .cancelled: "MediaError.cancelled"
        case .unreadable(let detail): "MediaError.unreadable(\(detail))"
        case .notMedia: "MediaError.notMedia"
        case .corrupt(let detail): "MediaError.corrupt(\(detail))"
        case .network(let detail): "MediaError.network(\(detail))"
        case .rangeRequestsUnsupported: "MediaError.rangeRequestsUnsupported"
        case .unsupported(let detail): "MediaError.unsupported(\(detail))"
        case .engine(let detail): "MediaError.engine(\(detail))"
        }
    }
}
