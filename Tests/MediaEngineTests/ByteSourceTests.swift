import Foundation
import Synchronization
import Testing
@testable import MediaEngine

/// Runs blocking work on a plain thread, the way the engine does.
private func onThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}

private func readAll(_ source: some ByteSource, at offset: Int64, count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let read = try bytes.withUnsafeMutableBytes { try source.read(at: offset, into: $0) }
    return Array(bytes.prefix(read))
}

@Suite("Byte sources")
struct ByteSourceTests {
    let sample = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    @Test("memory source returns the requested range and stops at the end")
    func memorySource() throws {
        let source = DataByteSource(sample)
        #expect(source.length == 10_000)
        #expect(try readAll(source, at: 100, count: 50) == Array(sample[100..<150]))
        #expect(try readAll(source, at: 9_990, count: 50) == Array(sample[9_990..<10_000]))
        #expect(try readAll(source, at: 10_000, count: 50).isEmpty)
        #expect(throws: MediaError.self) { try readAll(source, at: -1, count: 4) }
    }

    @Test("file source reads positionally, from many threads at once")
    func fileSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bytesource-\(UUID().uuidString).bin")
        try sample.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileByteSource(url: url)
        #expect(source.length == 10_000)
        #expect(try readAll(source, at: 4_000, count: 100) == Array(sample[4_000..<4_100]))
        #expect(try readAll(source, at: 20_000, count: 10).isEmpty)

        let expected = sample
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try await onThread {
                        let offset = Int64(index * 500)
                        return try readAll(source, at: offset, count: 300) == Array(expected[Int(offset)..<Int(offset) + 300])
                    }
                }
            }
            return try await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 })
    }

    @Test("file source rejects missing files, directories and non-file URLs")
    func fileSourceErrors() {
        #expect(throws: MediaError.self) { try FileByteSource(url: URL(fileURLWithPath: "/definitely/not/here.mkv")) }
        #expect(throws: MediaError.self) { try FileByteSource(url: FileManager.default.temporaryDirectory) }
        #expect(throws: MediaError.self) { try FileByteSource(url: URL(string: "https://example.com/a.mkv")!) }
    }

    @Test("errors carry plain-language descriptions and no file names")
    func errorDescriptions() {
        let errors: [MediaError] = [.cancelled, .unreadable(detail: "x"), .notMedia, .corrupt(detail: "x"),
                                    .network(detail: "x"), .rangeRequestsUnsupported, .engine(detail: "x")]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
            #expect(!(error.errorDescription ?? "").contains("/"))
        }
    }
}

// MARK: HTTP

/// A tiny in-process web server for URLSession, with range support and failure injection.
final class StubServer: Sendable {
    struct State {
        var getRanges: [String] = []
        var failuresRemaining = 0
        var failureStatus = 503
        var permanentStatus: Int?
        var delay: TimeInterval = 0
    }
    let data: Data
    let supportsRange: Bool
    private let state = Mutex(State())

    init(data: Data, supportsRange: Bool = true) {
        self.data = data
        self.supportsRange = supportsRange
    }

    func configure(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var getRanges: [String] { state.withLock { $0.getRanges } }

    typealias Reply = (status: Int, headers: [String: String], body: Data, delay: TimeInterval)

    func respond(to request: URLRequest, url: URL) -> Reply {
        enum Outcome { case head, permanent(Int), failure(Int), serve(delay: TimeInterval) }
        let outcome = state.withLock { state -> Outcome in
            if request.httpMethod == "HEAD" { return .head }
            state.getRanges.append(request.value(forHTTPHeaderField: "Range") ?? "none")
            if let permanent = state.permanentStatus { return .permanent(permanent) }
            if state.failuresRemaining > 0 {
                state.failuresRemaining -= 1
                return .failure(state.failureStatus)
            }
            return .serve(delay: state.delay)
        }
        switch outcome {
        case .head:
            return (200, ["Content-Length": "\(data.count)", "Accept-Ranges": supportsRange ? "bytes" : "none"], Data(), 0)
        case .permanent(let status), .failure(let status):
            return (status, [:], Data(), 0)
        case .serve(let delay):
            guard supportsRange, let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else {
                return (200, ["Content-Length": "\(data.count)"], data, delay)
            }
            let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts[0]) ?? 0
            let end = min(Int(parts.count > 1 ? parts[1] : "") ?? data.count - 1, data.count - 1)
            guard start < data.count else { return (416, [:], Data(), 0) }
            let body = data[start...end]
            return (206, ["Content-Range": "bytes \(start)-\(end)/\(data.count)", "Content-Length": "\(body.count)"], Data(body), delay)
        }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let current = Mutex<StubServer?>(nil)
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.current.withLock({ $0 }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let reply = server.respond(to: request, url: url)
        let send: @Sendable () -> Void = { [self] in
            if stopped.withLock({ $0 }) { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: send) } else { send() }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}

@Suite("HTTP byte source", .serialized)
struct HTTPByteSourceTests {
    let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ ($0 >> 8)) })
    let url = URL(string: "https://media.test/movie.mkv")!

    private func open(_ server: StubServer, chunk: Int = 64 * 1024) async throws -> HTTPByteSource {
        StubProtocol.current.withLock { $0 = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try await HTTPByteSource.open(url: url, configuration: configuration, chunkSize: chunk, maxCachedChunks: 4)
    }

    @Test("learns the length and reads ranges across chunk boundaries")
    func readsAcrossChunks() async throws {
        let server = StubServer(data: payload)
        let source = try await open(server)
        #expect(source.length == Int64(payload.count))
        let expected = Array(payload[65_000..<131_500])
        let bytes = try await onThread { try readAll(source, at: 65_000, count: 66_500) }
        #expect(bytes == expected)
        let tail = try await onThread { try readAll(source, at: 299_990, count: 100) }
        #expect(tail == Array(payload[299_990...]))
    }

    @Test("never fetches the same range twice while it is cached")
    func cachesChunks() async throws {
        let server = StubServer(data: payload)
        let source = try await open(server)
        _ = try await onThread { try readAll(source, at: 0, count: 1_000) }
        _ = try await onThread { try readAll(source, at: 500, count: 1_000) }
        try await Task.sleep(for: .milliseconds(200))              // let the read-ahead settle
        let ranges = server.getRanges
        #expect(Set(ranges).count == ranges.count)
        #expect(ranges.contains("bytes=0-65535"))
    }

    @Test("retries transient server errors")
    func retries() async throws {
        let server = StubServer(data: payload)
        let source = try await open(server)
        server.configure { $0.failuresRemaining = 2; $0.failureStatus = 503 }
        let bytes = try await onThread { try readAll(source, at: 10, count: 100) }
        #expect(bytes == Array(payload[10..<110]))
    }

    @Test("reports permanent errors as network errors")
    func permanentError() async throws {
        let server = StubServer(data: payload)
        let source = try await open(server)
        server.configure { $0.permanentStatus = 404 }
        await #expect(throws: MediaError.network(detail: "HTTP 404")) {
            _ = try await onThread { try readAll(source, at: 0, count: 10) }
        }
    }

    @Test("refuses servers without range support")
    func noRanges() async throws {
        let server = StubServer(data: payload, supportsRange: false)
        await #expect(throws: MediaError.rangeRequestsUnsupported) { _ = try await open(server) }
    }

    @Test("cancelPendingReads aborts a blocked read quickly")
    func cancellation() async throws {
        let server = StubServer(data: payload)
        let source = try await open(server)
        server.configure { $0.delay = 10 }
        let started = ContinuousClock.now
        async let outcome: Result<[UInt8], any Error> = onThread { Result { try readAll(source, at: 200_000, count: 100) } }
        try await Task.sleep(for: .milliseconds(300))
        source.cancelPendingReads()
        let result = try await outcome
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(throws: MediaError.cancelled) { try result.get() }
    }
}
