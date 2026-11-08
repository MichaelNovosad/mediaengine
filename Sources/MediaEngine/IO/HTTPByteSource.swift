import Foundation
import Synchronization

/// Reads a file from an HTTP(S) server with range requests.
///
/// Bytes arrive in fixed-size chunks that are cached (least recently used chunks are dropped). While the engine reads
/// straight on, the next few chunks are fetched at the same time, each its own request, so that a distant server's round
/// trips overlap; after a jump only the next one is. Transient failures (timeouts, dropped connections, 5xx) are
/// retried with backoff; anything else surfaces as a ``MediaError``. ``throughput`` says how fast chunks have arrived.
public final class HTTPByteSource: ByteSource {
    public let length: Int64?

    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let chunkSize: Int64
    private let maxCachedChunks: Int
    private let maxAttempts = 4
    /// Chunks fetched ahead at the same time while the engine reads straight on.
    private let readAhead = 4
    private let state = Mutex(State())
    private let meter = Mutex(ThroughputMeter())

    public var throughput: Double? { meter.withLock { $0.bytesPerSecond } }

    private struct State {
        var cache: [Int64: Data] = [:]
        var recency: [Int64] = []                       // least recently used first
        var inFlight: [Int64: DispatchGroup] = [:]
        var tasks: [Int: URLSessionTask] = [:]
        var epoch = 0                                   // bumped by cancelPendingReads()
        /// The chunk the last read ended in, to tell reading on from jumping.
        var lastIndex: Int64 = -2

        mutating func touch(_ index: Int64) {
            recency.removeAll { $0 == index }
            recency.append(index)
        }
        mutating func insert(_ index: Int64, _ data: Data, limit: Int) {
            cache[index] = data
            touch(index)
            while recency.count > limit { cache[recency.removeFirst()] = nil }
        }
    }

    private struct Retryable: Error { var detail: String }

    private init(url: URL, headers: [String: String], session: URLSession, length: Int64?, chunkSize: Int, maxCachedChunks: Int) {
        self.url = url
        self.headers = headers
        self.session = session
        self.length = length
        self.chunkSize = Int64(max(chunkSize, 4 * 1024))
        self.maxCachedChunks = max(maxCachedChunks, 2)
    }

    deinit { session.invalidateAndCancel() }

    /// Contacts the server and checks that it supports range requests.
    ///
    /// - Parameters:
    ///   - url: The address of the file.
    ///   - headers: Extra request headers, for example an authorization token.
    ///   - configuration: Customize timeouts, caching or authentication.
    ///   - delegate: Answers the session's challenges for every request of this source: a server certificate the host
    ///     trusts by itself (a home server's own, pinned), or credentials for a sign-in that needs the server's
    ///     challenge first (HTTP Digest). The session keeps it until the source is released.
    ///   - chunkSize: Bytes fetched per request. Larger chunks mean fewer requests.
    ///   - maxCachedChunks: How many chunks stay in memory.
    public static func open(
        url: URL,
        headers: [String: String] = [:],
        configuration: URLSessionConfiguration = .ephemeral,
        delegate: (any URLSessionDelegate & Sendable)? = nil,
        chunkSize: Int = 512 * 1024,
        maxCachedChunks: Int = 32
    ) async throws -> HTTPByteSource {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MediaError.network(detail: "not an HTTP(S) URL")
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let length = try await discoverLength(url: url, headers: headers, session: session)
        return HTTPByteSource(url: url, headers: headers, session: session, length: length,
                              chunkSize: chunkSize, maxCachedChunks: maxCachedChunks)
    }

    private static func discoverLength(url: URL, headers: [String: String], session: URLSession) async throws -> Int64 {
        func request(_ method: String, range: String? = nil) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            return request
        }
        do {
            let (_, response) = try await session.data(for: request("HEAD"))
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true,
               let text = http.value(forHTTPHeaderField: "Content-Length"), let size = Int64(text), size >= 0 {
                return size
            }
        } catch let error as URLError where error.code == .cancelled {
            throw MediaError.cancelled
        } catch {
            // fall through to the GET probe: some servers reject HEAD
        }
        do {
            let (_, response) = try await session.data(for: request("GET", range: "bytes=0-0"))
            guard let http = response as? HTTPURLResponse else { throw MediaError.network(detail: "not an HTTP response") }
            guard http.statusCode == 206 else {
                if (200..<300).contains(http.statusCode) { throw MediaError.rangeRequestsUnsupported }
                throw MediaError.network(detail: "HTTP \(http.statusCode)")
            }
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = range.split(separator: "/").last, let size = Int64(total) else {
                throw MediaError.rangeRequestsUnsupported
            }
            return size
        } catch let error as MediaError {
            throw error
        } catch let error as URLError {
            throw error.code == .cancelled ? MediaError.cancelled : MediaError.network(detail: "URLError \(error.code.rawValue)")
        }
    }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset >= 0 else { throw MediaError.unreadable(detail: "negative offset") }
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        let epoch = state.withLock { $0.epoch }
        var written = 0
        while written < buffer.count {
            let position = offset + Int64(written)
            if let length, position >= length { break }
            let index = position / chunkSize
            let chunk = try loadChunk(index, epoch: epoch)
            let within = Int(position - index * chunkSize)
            guard within < chunk.count else { break }
            let count = min(buffer.count - written, chunk.count - within)
            chunk.withUnsafeBytes { source in
                (base + written).copyMemory(from: source.baseAddress! + within, byteCount: count)
            }
            written += count
        }
        if written > 0 {
            let last = (offset + Int64(written) - 1) / chunkSize
            let onward = state.withLock { state -> Bool in
                defer { state.lastIndex = last }
                return offset / chunkSize == state.lastIndex || offset / chunkSize == state.lastIndex + 1
            }
            for ahead in 1...(onward ? readAhead : 1) { prefetch(last + Int64(ahead), epoch: epoch) }
        }
        return written
    }

    /// A small request for just these bytes (a chunk already in the cache answers at once); nothing is cached or read ahead.
    public func readSparse(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset >= 0 else { throw MediaError.unreadable(detail: "negative offset") }
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        if let length, offset >= length { return 0 }
        let end = min(offset + Int64(buffer.count), length ?? Int64.max)
        let index = offset / chunkSize
        let cached = state.withLock { $0.cache[index] }
        if let cached, end <= index * chunkSize + Int64(cached.count) {
            let within = Int(offset - index * chunkSize), count = Int(end - offset)
            cached.withUnsafeBytes { base.copyMemory(from: $0.baseAddress! + within, byteCount: count) }
            return count
        }
        let epoch = state.withLock { $0.epoch }
        var attempt = 0
        while true {
            do {
                let data = try fetchOnce(offset..<end, epoch: epoch)
                let count = min(data.count, buffer.count)
                data.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: count) }
                return count
            } catch let retry as Retryable {
                attempt += 1
                if attempt >= maxAttempts { throw MediaError.network(detail: retry.detail) }
                try pause(seconds: 0.3 * pow(3, Double(attempt - 1)), epoch: epoch)
            }
        }
    }

    public func cancelPendingReads() {
        let tasks = state.withLock { state -> [URLSessionTask] in
            state.epoch += 1
            return Array(state.tasks.values)
        }
        tasks.forEach { $0.cancel() }
    }

    // MARK: Chunks

    private enum Action { case hit(Data), wait(DispatchGroup), lead(DispatchGroup) }

    private func loadChunk(_ index: Int64, epoch: Int) throws -> Data {
        while true {
            let action: Action = try state.withLock { state in
                if state.epoch != epoch { throw MediaError.cancelled }
                if let data = state.cache[index] { state.touch(index); return .hit(data) }
                if let group = state.inFlight[index] { return .wait(group) }
                let group = DispatchGroup()
                group.enter()
                state.inFlight[index] = group
                return .lead(group)
            }
            switch action {
            case .hit(let data):
                return data
            case .wait(let group):
                group.wait()
            case .lead(let group):
                do {
                    let data = try fetch(index, epoch: epoch)
                    state.withLock { state in
                        state.insert(index, data, limit: maxCachedChunks)
                        state.inFlight[index] = nil
                    }
                    group.leave()
                    return data
                } catch {
                    state.withLock { $0.inFlight[index] = nil }
                    group.leave()
                    throw error
                }
            }
        }
    }

    private func prefetch(_ index: Int64, epoch: Int) {
        if let length, index * chunkSize >= length { return }
        let alreadyThere = state.withLock { $0.cache[index] != nil || $0.inFlight[index] != nil }
        if alreadyThere { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            _ = try? loadChunk(index, epoch: epoch)
        }
    }

    private func fetch(_ index: Int64, epoch: Int) throws -> Data {
        let start = index * chunkSize
        var end = start + chunkSize
        if let length { end = min(end, length) }
        var attempt = 0
        while true {
            do {
                return try fetchOnce(start..<end, epoch: epoch)
            } catch let retry as Retryable {
                attempt += 1
                if attempt >= maxAttempts { throw MediaError.network(detail: retry.detail) }
                try pause(seconds: 0.3 * pow(3, Double(attempt - 1)), epoch: epoch)
            }
        }
    }

    private final class Outcome: Sendable {
        let value = Mutex<(Data?, URLResponse?, (any Error)?)>((nil, nil, nil))
    }

    private func fetchOnce(_ range: Range<Int64>, epoch: Int) throws -> Data {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")

        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            outcome.value.withLock { $0 = (data, response, error) }
            semaphore.signal()
        }
        try state.withLock { state in
            if state.epoch != epoch { throw MediaError.cancelled }
            state.tasks[task.taskIdentifier] = task
        }
        let began = DispatchTime.now()
        task.resume()
        let waited = semaphore.wait(timeout: .now() + 90)
        state.withLock { $0.tasks[task.taskIdentifier] = nil }
        if waited == .timedOut {
            task.cancel()
            throw Retryable(detail: "request timed out")
        }
        if state.withLock({ $0.epoch }) != epoch { throw MediaError.cancelled }

        let (data, response, error) = outcome.value.withLock { $0 }
        if let error {
            guard let urlError = error as? URLError else { throw MediaError.network(detail: "transport error") }
            switch urlError.code {
            case .cancelled:
                throw MediaError.cancelled
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .resourceUnavailable:
                throw Retryable(detail: "URLError \(urlError.code.rawValue)")
            default:
                throw MediaError.network(detail: "URLError \(urlError.code.rawValue)")
            }
        }
        guard let http = response as? HTTPURLResponse else { throw MediaError.network(detail: "not an HTTP response") }
        let body = data ?? Data()
        switch http.statusCode {
        case 206:
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e9
            meter.withLock { $0.record(bytes: body.count, seconds: seconds) }
            return body.count > range.count ? body.prefix(range.count) : body
        case 200:
            // The server ignored the Range header. Only acceptable when the whole file fits one chunk.
            if range.lowerBound == 0, Int64(body.count) <= chunkSize { return body }
            throw MediaError.rangeRequestsUnsupported
        case 416:
            return Data()                                    // range starts past the end: end of file
        case 408, 429, 500...599:
            throw Retryable(detail: "HTTP \(http.statusCode)")
        default:
            throw MediaError.network(detail: "HTTP \(http.statusCode)")
        }
    }

    /// Sleeps in small steps so cancellation is noticed quickly.
    private func pause(seconds: Double, epoch: Int) throws {
        var remaining = seconds
        while remaining > 0 {
            if state.withLock({ $0.epoch }) != epoch { throw MediaError.cancelled }
            let step = min(remaining, 0.05)
            Thread.sleep(forTimeInterval: step)
            remaining -= step
        }
    }
}
