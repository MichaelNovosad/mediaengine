import Darwin
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

enum Fixture {
    /// Repository root, found from this file's location (works for macOS and simulator runs alike).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let names = ["fixture-basic", "fixture-hevc", "fixture-hdr10", "fixture-hlg", "fixture-flac24", "fixture-opus-vorbis", "fixture-bframes", "fixture-subs-long", "fixture-licensed-audio", "fixture-anime"]

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
final class SlowByteSource: ByteSource {
    let base: DataByteSource
    let delay: TimeInterval
    private let reads = Mutex(0)
    init(base: DataByteSource, delay: TimeInterval) { self.base = base; self.delay = delay }
    var length: Int64? { base.length }
    /// How many reads have started, so a test can act at a known moment instead of guessing with a sleep.
    var readCount: Int { reads.withLock { $0 } }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        reads.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: delay)
        return try base.read(at: offset, into: buffer)
    }
}

/// Blocks its first read until `release()`, so a test can act while the probe is certainly still in flight, however
/// busy the machine is (sleeping and polling is not enough: parallel tests can starve the task that would act).
final class GatedByteSource: ByteSource {
    let base: DataByteSource
    private let gate = DispatchSemaphore(value: 0)
    private let reads = Mutex(0)
    init(base: DataByteSource) { self.base = base }
    var length: Int64? { base.length }
    var readCount: Int { reads.withLock { $0 } }
    func release() { gate.signal() }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let number = reads.withLock { count -> Int in count += 1; return count }
        if number == 1 { gate.wait() }
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

// MARK: Shared helpers

/// Sample count and decode-time span of a fragment, read from its `moof`.
struct FragmentFacts { var sampleCount: Int; var baseDecodeTime: UInt64; var totalDuration: UInt64; var sequence: UInt32 }

func facts(_ fragment: Data) throws -> FragmentFacts {
    let moof = try #require(MP4Box.find(["moof"], in: fragment))
    let mfhd = try #require(MP4Box.find(["mfhd"], in: fragment, within: moof.payload))
    let traf = try #require(MP4Box.find(["traf"], in: fragment, within: moof.payload))
    let tfdt = try #require(MP4Box.find(["tfdt"], in: fragment, within: traf.payload))
    let trun = try #require(MP4Box.find(["trun"], in: fragment, within: traf.payload))
    let flags = fragment.uint32(at: trun.payload.lowerBound) & 0x00FF_FFFF
    let count = Int(fragment.uint32(at: trun.payload.lowerBound + 4))
    var offset = trun.payload.lowerBound + 12                                 // after version/flags, count, data offset
    var total: UInt64 = 0
    for _ in 0..<count {
        total += UInt64(fragment.uint32(at: offset)); offset += 4             // duration
        offset += 4                                                          // size
        if flags & 0x400 != 0 { offset += 4 }                                // flags
        if flags & 0x800 != 0 { offset += 4 }                                // composition offset
    }
    return FragmentFacts(sampleCount: count, baseDecodeTime: fragment.uint64(at: tfdt.payload.lowerBound + 4),
                         totalDuration: total, sequence: fragment.uint32(at: mfhd.payload.lowerBound + 4))
}

/// Like `facts`, but returns `nil` instead of failing the test (for benchmarks that tolerate odd fragments).
func fragmentFacts(_ fragment: Data) -> FragmentFacts? {
    guard MP4Box.find(["moof"], in: fragment) != nil else { return nil }
    return try? facts(fragment)
}

/// The process's physical memory footprint in bytes.
func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}
