import Foundation

/// One film's bytes from a network source, read once for all of its readers (the app's owner, 2026-11-19).
///
/// The engine's own player reads a film twice: its picture reader and the remuxer that makes its sound each open the file and read
/// all of it, the sound some seconds ahead; picture-subtitle readers may read stretches of it a third time. A network source's own
/// cache (Eiga's SMB source keeps 24 MB) holds less than that lead, so the reader behind fetched every byte again: 12.3 MB/s asked
/// for a 5.6 MB/s film over the owner's server (2026-11-19), more than the router gives.
///
/// ``PlaybackSession`` puts this cache between a network source and everything that reads it. Each opening of the file by FFmpeg
/// (``AVIOBridge``) is a reader; what one reader fetched stays until every reader that is still reading has passed it, and what every
/// reader is past goes first. While only one reader reads it keeps little. The remuxer keeps the sound's lead within ``leadBytes``
/// (``RemuxSession``), so that the reader behind finds what the one ahead fetched.
final class SharedReadCache: ByteSource, @unchecked Sendable {
    /// The source the readers share.
    let source: any ByteSource
    let chunkSize: Int
    /// Room while two or more readers read.
    let sharedBudget: Int
    /// Room while one reader (or none) reads.
    let soloBudget: Int
    /// A reader that has not read for this long holds nothing back (a subtitle reader that read its stretch, a paused film).
    let idle: Duration
    private let clock: @Sendable () -> ContinuousClock.Instant

    static let standardChunk = 1 << 20
    static let standardBudget = 96 << 20
    static let standardSolo = 16 << 20

    /// How far apart two readers may be for the one behind to read from memory: three quarters of the shared room (the rest is for
    /// what the readers are reading now and what a jump leaves behind).
    var leadBytes: Int64 { Int64(sharedBudget) * 3 / 4 }

    private struct Chunk {
        var data: Data
        var used: UInt64
    }

    private struct Reader {
        var position: Int64 = 0
        /// When it last read; `nil` before its first read.
        var read: ContinuousClock.Instant?
    }

    private struct State {
        var chunks: [Int64: Chunk] = [:]
        var loading: Set<Int64> = []
        var bytes = 0
        var readers: [Int: Reader] = [:]
        var nextReader = 0
        var tick: UInt64 = 0
        var fetched: Int64 = 0
    }

    /// Guards `state`; readers that need a chunk another reader is fetching wait on it.
    private let condition = NSCondition()
    private var state = State()

    init(source: any ByteSource, chunkSize: Int = standardChunk, sharedBudget: Int = standardBudget, soloBudget: Int = standardSolo,
         idle: Duration = .seconds(20), clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.source = source
        self.chunkSize = max(chunkSize, 4096)
        self.sharedBudget = max(sharedBudget, self.chunkSize)
        self.soloBudget = max(soloBudget, self.chunkSize)
        self.idle = idle
        self.clock = clock
    }

    /// The session's source behind any cache: what a type check must look at (a DVD title).
    static func underlying(_ source: any ByteSource) -> any ByteSource {
        (source as? SharedReadCache)?.source ?? source
    }

    var length: Int64? { source.length }
    var throughput: Double? { source.throughput }
    func cancelPendingReads() { source.cancelPendingReads() }
    func notePlaying() { source.notePlaying() }

    /// Far from where playback reads (cluster headers for an index): straight to the source, nothing kept.
    func readSparse(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try source.readSparse(at: offset, into: buffer)
    }

    func close() {
        locked {
            state.chunks = [:]
            state.bytes = 0
        }
        source.close()
    }

    /// Bytes fetched from the source so far.
    var fetchedBytes: Int64 { locked { state.fetched } }

    /// How much is kept now.
    var keptBytes: Int { locked { state.bytes } }

    // MARK: Readers

    /// A new reader (one opening of the file); its reads tell the cache where it is.
    func register() -> Int {
        locked {
            let id = state.nextReader
            state.nextReader += 1
            state.readers[id] = Reader()
            return id
        }
    }

    func unregister(_ reader: Int) {
        locked { state.readers[reader] = nil }
    }

    // MARK: Reading

    /// A read that belongs to no reader (a header read outside FFmpeg): cached the same way.
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try read(at: offset, into: buffer, reader: nil)
    }

    /// Reads up to the end of the chunk that holds `offset` (a shorter read than asked is allowed).
    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer, reader: Int?) throws -> Int {
        guard offset >= 0 else { throw MediaError.unreadable(detail: "negative offset") }
        guard buffer.count > 0, let destination = buffer.baseAddress else { return 0 }
        let index = offset / Int64(chunkSize)
        let data = try chunk(index)
        let within = Int(offset - index * Int64(chunkSize))
        let count = within < data.count ? min(buffer.count, data.count - within) : 0
        if count > 0 {
            data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { destination.copyMemory(from: base + within, byteCount: count) }
            }
        }
        if let reader {
            let now = clock()
            locked {
                state.readers[reader]?.position = offset + Int64(count)
                state.readers[reader]?.read = now
            }
        }
        return count
    }

    /// The chunk, from memory, from another reader's fetch under way, or fetched now.
    private func chunk(_ index: Int64) throws -> Data {
        condition.lock()
        while true {
            if let kept = state.chunks[index] {
                state.tick += 1
                let tick = state.tick
                state.chunks[index]?.used = tick
                condition.unlock()
                return kept.data
            }
            guard state.loading.contains(index) else { break }
            condition.wait()
        }
        state.loading.insert(index)
        condition.unlock()

        let data: Data
        do {
            data = try fetch(index)
        } catch {
            condition.lock()
            state.loading.remove(index)
            condition.broadcast()
            condition.unlock()
            throw error
        }

        condition.lock()
        state.loading.remove(index)
        state.tick += 1
        let tick = state.tick
        state.chunks[index] = Chunk(data: data, used: tick)
        state.bytes += data.count
        state.fetched += Int64(data.count)
        trim(keeping: index)
        condition.broadcast()
        condition.unlock()
        return data
    }

    /// Reads a whole chunk from the source (shorter at the end of the file).
    private func fetch(_ index: Int64) throws -> Data {
        let start = index * Int64(chunkSize)
        var size = chunkSize
        if let length = source.length { size = Int(max(0, min(Int64(chunkSize), length - start))) }
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        var filled = 0
        try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            while filled < size {
                let read = try source.read(at: start + Int64(filled), into: UnsafeMutableRawBufferPointer(rebasing: bytes[filled..<size]))
                if read <= 0 { break }
                filled += read
            }
        }
        if filled < size { data.removeSubrange(filled..<size) }
        return data
    }

    /// Lets go of chunks until the cache is within its room: first what every reader still reading is past, the least recently used
    /// first, then the least recently used of the rest. Call with the lock held.
    private func trim(keeping kept: Int64) {
        let now = clock()
        let active = state.readers.values.filter { reader in reader.read.map { now - $0 < idle } ?? false }
        let budget = active.count >= 2 ? sharedBudget : soloBudget
        guard state.bytes > budget else { return }
        let floor = active.map(\.position).min()
        var behind: [(key: Int64, used: UInt64)] = []
        var rest: [(key: Int64, used: UInt64)] = []
        for (key, chunk) in state.chunks where key != kept {
            if let floor, (key + 1) * Int64(chunkSize) <= floor { behind.append((key, chunk.used)) } else { rest.append((key, chunk.used)) }
        }
        for (key, _) in behind.sorted(by: { $0.used < $1.used }) + rest.sorted(by: { $0.used < $1.used }) {
            guard state.bytes > budget else { return }
            if let removed = state.chunks.removeValue(forKey: key) { state.bytes -= removed.data.count }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        defer { condition.unlock() }
        return try body()
    }
}
