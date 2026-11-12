import Foundation

/// A random-access supplier of bytes: a local file, a web server, a network share.
///
/// The engine reads from a byte source on its own background threads and expects `read` to **block**
/// until bytes are available. It never calls a byte source from the main thread or from Swift's
/// cooperative thread pool, so implementations may block on network I/O.
///
/// ```swift
/// struct MyShareSource: ByteSource {
///     var length: Int64? { fileSize }
///     func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
///         try share.readSynchronously(offset: offset, into: buffer)   // returns 0 at the end of the file
///     }
/// }
/// ```
public protocol ByteSource: Sendable {
    /// Total size in bytes, or `nil` when unknown (for example a live stream).
    var length: Int64? { get }

    /// Reads up to `buffer.count` bytes starting at `offset`.
    ///
    /// - Returns: The number of bytes read. Return `0` only at the end of the data; a shorter read than
    ///   requested is allowed.
    /// - Throws: Any error; the engine reports it as a ``MediaError``.
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int

    /// Called when the operation using this source is cancelled. Abort in-flight network requests here so
    /// a blocked `read` returns promptly. The default implementation does nothing.
    func cancelPendingReads()

    /// Reads a few bytes far from where playback reads, for example the headers of a file's clusters while the engine
    /// builds an index for a file that has none.
    ///
    /// A source that fetches and caches large chunks for playback should answer this with a request for just these
    /// bytes, without caching a chunk or reading ahead: the engine calls it at offsets megabytes apart, thousands of
    /// times. A short read is allowed. The default implementation calls ``read(at:into:)``.
    func readSparse(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int

    /// How fast this source has been delivering bytes lately, in bytes per second, or `nil` when it does not measure it (a
    /// local file is as fast as the engine needs). The engine sizes the pieces it hands the player by it: over a slow link
    /// each piece is shorter, so that the first picture and every jump wait for less. The default is `nil`.
    var throughput: Double? { get }

    /// The session that read this source is finished with it: let network connections go now; later reads may fail. Called by
    /// ``PlaybackSession/close()`` for the source the session was made from and by ``AudioTrack/close()``. A source that holds a
    /// connection per file (SMB) should close it here rather than when its last reference goes, which can be late. The default does
    /// nothing.
    func close()
}

extension ByteSource {
    public func cancelPendingReads() {}

    public func close() {}

    public func readSparse(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try read(at: offset, into: buffer)
    }

    public var throughput: Double? { nil }
}

/// A running estimate of how fast a network source delivers: each fetch of at least `smallest` bytes is one sample, and the
/// estimate leans on the latest ones (small fetches are mostly waiting for the round trip and say little about speed).
public struct ThroughputMeter: Sendable {
    public private(set) var bytesPerSecond: Double?
    private let smallest: Int

    public init(smallest: Int = 128 * 1024) {
        self.smallest = smallest
    }

    /// Records one fetch of `bytes` that took `seconds`.
    public mutating func record(bytes: Int, seconds: Double) {
        guard bytes >= smallest, seconds > 0.000_1 else { return }
        let sample = Double(bytes) / seconds
        bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + sample * 0.3 } ?? sample
    }
}

/// A byte source backed by in-memory data. Handy for tests, previews and small files.
public struct DataByteSource: ByteSource {
    private let data: Data

    public init(_ data: Data) { self.data = data }

    public var length: Int64? { Int64(data.count) }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset >= 0 else { throw MediaError.unreadable(detail: "negative offset") }
        guard offset < Int64(data.count), let destination = buffer.baseAddress else { return 0 }
        let start = data.startIndex + Int(offset)
        let count = min(buffer.count, data.count - Int(offset))
        data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), from: start..<(start + count))
        return count
    }
}
