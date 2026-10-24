import Foundation
import Network
import Security
import Synchronization

/// A minimal HTTP/1.1 server that hands one ``RemuxSession`` to AVPlayer.
///
/// Hardening (acceptance criterion SYS-5): it listens on the loopback interface only, on a port the system
/// picks, behind a random 128-bit path token; it answers only `GET` and `HEAD` for resources of its own session,
/// rejects requests whose `Host` header is not its own address (DNS rebinding), and stops with the session.
/// Anything the loopback server can hand out by relative path.
protocol ResourceProvider: Sendable {
    func resource(path: String) throws -> RemuxSession.Resource?
}

final class LoopbackServer: @unchecked Sendable {
    let token: String
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let provider: any ResourceProvider
    private let queue = DispatchQueue(label: "dev.mediaengine.server")
    private let work = DispatchQueue(label: "dev.mediaengine.server.work", qos: .userInitiated, attributes: .concurrent)
    private let connections = Mutex<[ObjectIdentifier: NWConnection]>([:])
    /// How many requests were answered successfully (diagnostics and tests).
    private let served = Mutex(0)
    var servedCount: Int { served.withLock { $0 } }

    /// Starts listening and returns once the port is known.
    static func start(session: any ResourceProvider) async throws -> LoopbackServer {
        let server = try LoopbackServer(provider: session)
        try await server.waitUntilReady()
        return server
    }

    private init(provider: any ResourceProvider) throws {
        self.provider = provider
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MediaError.engine(detail: "no secure random bytes")
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            @Sendable func finish(_ result: Result<Void, any Error>) {
                if resumed.withLock({ let was = $0; $0 = true; return was }) { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    port = listener.port?.rawValue ?? 0
                    finish(port == 0 ? .failure(MediaError.engine(detail: "server has no port")) : .success(()))
                case .failed(let error):
                    finish(.failure(MediaError.engine(detail: "server failed: \(error)")))
                case .cancelled:
                    finish(.failure(MediaError.cancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The address AVPlayer should open.
    var masterURL: URL { URL(string: "http://127.0.0.1:\(port)/\(token)/master.m3u8")! }

    func stop() {
        listener.cancel()
        let open = connections.withLock { state -> [NWConnection] in
            let all = Array(state.values)
            state.removeAll()
            return all
        }
        open.forEach { $0.cancel() }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections.withLock { $0[key] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections.withLock { $0[key] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private static let maxRequestBytes = 16 * 1024

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[..<end.lowerBound]
                let remainder = Data(buffer[end.upperBound...])
                work.async { self.respond(to: Data(head), on: connection, then: remainder) }
            } else if error != nil || isComplete || buffer.count > Self.maxRequestBytes {
                connection.cancel()
            } else {
                receive(on: connection, buffered: buffer)
            }
        }
    }

    // MARK: Requests

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
    }

    static func parse(_ head: Data) -> Request? {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers)
    }

    /// Decides the response for a request. Pure given the session; used by the connection code and by tests.
    func response(for request: Request) -> (status: Int, headers: [String: String], body: Data) {
        guard request.method == "GET" || request.method == "HEAD" else { return (405, ["Allow": "GET, HEAD"], Data()) }
        let allowedHosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"], allowedHosts.contains(host) else { return (403, [:], Data()) }

        let prefix = "/\(token)/"
        guard request.path.hasPrefix(prefix), !request.path.contains(".."), !request.path.contains("?") else { return (404, [:], Data()) }
        let name = String(request.path.dropFirst(prefix.count))
        let resource: RemuxSession.Resource?
        do { resource = try provider.resource(path: name) } catch let error as MediaError where error == .cancelled { return (503, [:], Data()) }
        catch { return (500, [:], Data()) }
        guard let resource else { return (404, [:], Data()) }

        var headers = ["Content-Type": resource.contentType, "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        var body = resource.data
        var status = 200
        if let range = request.headers["range"], let slice = Self.byteRange(range, length: body.count) {
            guard slice.lowerBound < body.count else { return (416, ["Content-Range": "bytes */\(body.count)"], Data()) }
            headers["Content-Range"] = "bytes \(slice.lowerBound)-\(slice.upperBound - 1)/\(body.count)"
            body = body.subdata(in: slice)
            status = 206
        }
        served.withLock { $0 += 1 }
        return (status, headers, body)
    }

    /// Parses `bytes=a-b`, `bytes=a-` and `bytes=-n` against a body of `length` bytes.
    static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 { return max(length - suffix, 0)..<length }
        guard let start = Int(parts[0]), start >= 0 else { return nil }
        let end = parts[1].isEmpty ? length - 1 : min(Int(parts[1]) ?? length - 1, length - 1)
        return start..<(end + 1 > start ? end + 1 : start)
    }

    private static let reasons = [200: "OK", 206: "Partial Content", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                                  416: "Range Not Satisfiable", 500: "Internal Server Error", 503: "Service Unavailable"]

    private func respond(to head: Data, on connection: NWConnection, then remainder: Data) {
        guard let request = Self.parse(head) else {
            send(status: 400, headers: [:], body: Data(), isHead: false, on: connection, keepAlive: false)
            return
        }
        let result = response(for: request)
        let keepAlive = request.headers["connection"]?.lowercased() != "close"
        send(status: result.status, headers: result.headers, body: result.body, isHead: request.method == "HEAD",
             on: connection, keepAlive: keepAlive, remainder: remainder)
    }

    private func send(status: Int, headers: [String: String], body: Data, isHead: Bool, on connection: NWConnection,
                      keepAlive: Bool, remainder: Data = Data()) {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Error")\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var packet = Data(head.utf8)
        if !isHead { packet.append(body) }
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil || !keepAlive { connection.cancel(); return }
            self?.receive(on: connection, buffered: remainder)
        })
    }
}
