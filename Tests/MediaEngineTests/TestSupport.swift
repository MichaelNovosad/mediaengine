import Foundation
import Testing
@testable import MediaEngine

enum Fixture {
    /// Repository root, found from this file's location (works for macOS and simulator runs alike).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let names = ["fixture-basic", "fixture-hevc", "fixture-hdr10", "fixture-licensed-audio", "fixture-anime"]

    static func url(_ name: String) -> URL { root.appendingPathComponent("Fixtures/\(name).mkv") }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func groundTruth(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/ground-truth/\(name).json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func probe(_ name: String) async throws -> MediaInfo {
        try await MediaSource(url: url(name)).probe()
    }
}

/// Reports a huge file whose real content is only the first bytes; the rest reads as zeros.
/// Proves that probing cost does not depend on the file size.
struct PaddedByteSource: ByteSource {
    let base: Data
    let totalLength: Int64
    var length: Int64? { totalLength }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset >= 0, offset < totalLength, let destination = buffer.baseAddress else { return 0 }
        let count = Int(min(Int64(buffer.count), totalLength - offset))
        if offset < Int64(base.count) {
            let available = min(count, base.count - Int(offset))
            base.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), from: Int(offset)..<(Int(offset) + available))
            if available < count { memset(destination + available, 0, count - available) }
        } else {
            memset(destination, 0, count)
        }
        return count
    }
}

/// Wraps a source and delays every read.
struct SlowByteSource: ByteSource {
    let base: DataByteSource
    let delay: TimeInterval
    var length: Int64? { base.length }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        Thread.sleep(forTimeInterval: delay)
        return try base.read(at: offset, into: buffer)
    }
}

/// Builds tracks for planner tests without needing a file.
func makeTrack(id: Int = 0, kind: Track.Kind, codec: String, display: String? = nil,
               profile: String? = nil, profileID: Int? = nil) -> Track {
    Track(id: id, kind: kind,
          codec: Codec(name: codec, displayName: display ?? codec, profile: profile, profileIdentifier: profileID, level: nil),
          language: nil, title: nil, isDefault: false, isForced: false, isHearingImpaired: false,
          isCommentary: false, bitrate: nil)
}
