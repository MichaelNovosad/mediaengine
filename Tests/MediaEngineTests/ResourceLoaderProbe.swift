import AVFoundation
import Foundation
import Security
import Synchronization
import UniformTypeIdentifiers
@testable import MediaEngine

/// Test-only experiment (spike result, see docs/RESEARCH.md section 16): hands a session's HLS resources to AVPlayer
/// through `AVAssetResourceLoader` with no socket. AVPlayer accepts the playlists and the initialization segments this
/// way, but refuses the media segments ("custom url not redirect"): HLS segments must come from a real network URL.
final class ResourceLoaderProbe: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let scheme: String
    let host: String
    /// The queue AVFoundation calls the delegate on.
    let queue = DispatchQueue(label: "dev.mediaengine.loader")
    private let work = DispatchQueue(label: "dev.mediaengine.loader.work", qos: .userInitiated, attributes: .concurrent)
    private let provider: any ResourceProvider

    /// A loading request in flight. AVFoundation's request objects are used from our work queue only.
    private final class Request: @unchecked Sendable {
        let loading: AVAssetResourceLoadingRequest
        let cancelled = Mutex(false)
        init(_ loading: AVAssetResourceLoadingRequest) { self.loading = loading }
    }
    private let pending = Mutex<[ObjectIdentifier: Request]>([:])
    private let closed = Mutex(false)
    private let answered = Mutex(0)

    init(provider: any ResourceProvider) {
        self.provider = provider
        func random(_ count: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: count)
            if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
                for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        scheme = "mediaengine-" + random(4)
        host = random(16)
        super.init()
    }

    /// The URL to build the `AVURLAsset` from.
    var masterURL: URL { URL(string: "\(scheme)://\(host)/master.m3u8")! }
    /// How many requests were answered successfully (diagnostics and tests).
    var answeredRequests: Int { answered.withLock { $0 } }
    /// Requests that were accepted and not finished yet (diagnostics and tests).
    var pendingRequests: Int { pending.withLock { $0.count } }

    /// Stops answering and fails everything still waiting. The player item stops working.
    func stop() {
        closed.withLock { $0 = true }
        let waiting = pending.withLock { requests -> [Request] in
            defer { requests.removeAll() }
            return Array(requests.values)
        }
        for request in waiting {
            request.cancelled.withLock { $0 = true }
            request.loading.finishLoading(with: URLError(.cancelled))
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed.withLock({ $0 }), let url = loadingRequest.request.url, url.scheme == scheme, url.host == host else { return false }
        let request = Request(loadingRequest)
        pending.withLock { $0[ObjectIdentifier(loadingRequest)] = request }
        let path = String(url.path.drop(while: { $0 == "/" }))
        work.async { [self] in serve(request, path: path) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.withLock { $0.removeValue(forKey: ObjectIdentifier(loadingRequest)) }?.cancelled.withLock { $0 = true }
    }

    // MARK: Answering

    private func serve(_ request: Request, path: String) {
        defer { pending.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(request.loading)) } }
        func finish(_ error: (any Error)?) {
            guard !request.cancelled.withLock({ $0 }) else { return }
            if let error { request.loading.finishLoading(with: error) } else {
                request.loading.finishLoading()
                answered.withLock { $0 += 1 }
            }
        }
        do {
            guard let resource = try provider.resource(path: path) else { return finish(URLError(.fileDoesNotExist)) }
            guard !request.cancelled.withLock({ $0 }) else { return }
            if let information = request.loading.contentInformationRequest {
                information.contentType = Self.contentType(forMIME: resource.contentType)
                information.contentLength = Int64(resource.data.count)
                information.isByteRangeAccessSupported = true
            }
            if let data = request.loading.dataRequest {
                data.respond(with: Self.slice(resource.data, offset: data.requestedOffset, length: data.requestedLength,
                                              toEnd: data.requestsAllDataToEndOfResource))
            }
            finish(nil)
        } catch {
            finish(error)
        }
    }

    /// The bytes AVFoundation asked for, clamped to the resource.
    static func slice(_ data: Data, offset: Int64, length: Int, toEnd: Bool) -> Data {
        let start = Int(min(max(offset, 0), Int64(data.count)))
        let end = toEnd ? data.count : min(data.count, start + max(length, 0))
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
    }

    /// `AVAssetResourceLoadingContentInformationRequest.contentType` wants a uniform type identifier.
    static func contentType(forMIME mime: String) -> String {
        UTType(mimeType: mime)?.identifier ?? mime
    }
}
