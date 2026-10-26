import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MediaEngine

private func makeServer(_ name: String = "fixture-basic") async throws -> (LoopbackServer, RemuxSession) {
    let info = try await Fixture.probe(name)
    let session = try RemuxSession(source: FileByteSource(url: Fixture.url(name)), info: info, cancellation: CancellationFlag())
    return (try await LoopbackServer.start(session: session), session)
}

private func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 5
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    return (data, response as! HTTPURLResponse)
}

@Suite("Loopback server")
struct LoopbackServerTests {
    @Test("serves playlists and segments with correct types, ranges and HEAD")
    func serves() async throws {
        let (server, _) = try await makeServer()
        defer { server.stop() }
        let base = server.masterURL.deletingLastPathComponent()

        let (master, masterResponse) = try await fetch(server.masterURL)
        #expect(masterResponse.statusCode == 200)
        #expect(masterResponse.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        #expect(String(decoding: master, as: UTF8.self).hasPrefix("#EXTM3U"))

        let (initData, initResponse) = try await fetch(base.appendingPathComponent("video-init.mp4"))
        #expect(initResponse.statusCode == 200 && initResponse.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(MP4Box.parse(initData).map(\.type) == ["ftyp", "moov"])

        let (_, head) = try await fetch(base.appendingPathComponent("video-0.m4s"), method: "HEAD")
        #expect(head.statusCode == 200 && (Int(head.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0) > 1_000)

        let (partial, ranged) = try await fetch(base.appendingPathComponent("video-0.m4s"), headers: ["Range": "bytes=4-11"])
        #expect(ranged.statusCode == 206 && partial.count == 8)
        #expect(String(decoding: partial.prefix(4), as: UTF8.self) == "moof")
        #expect(ranged.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 4-11/") == true)
        #expect(server.servedCount >= 4)
    }

    @Test("refuses a wrong token, unknown resources, other methods, a foreign Host header and path tricks")
    func refuses() async throws {
        let (server, _) = try await makeServer()
        defer { server.stop() }
        let good = ["host": "127.0.0.1:\(server.port)"]
        func status(_ method: String, _ path: String, headers: [String: String]? = nil) -> Int {
            server.response(for: LoopbackServer.Request(method: method, path: path, headers: headers ?? good)).status
        }
        let token = server.token
        #expect(status("GET", "/\(token)/master.m3u8") == 200)
        #expect(status("GET", "/0000/master.m3u8") == 404)
        #expect(status("GET", "/master.m3u8") == 404)
        #expect(status("GET", "/\(token)/nothing.m3u8") == 404)
        #expect(status("GET", "/\(token)/../master.m3u8") == 404)
        #expect(status("GET", "/\(token)/master.m3u8?x=1") == 404)
        #expect(status("POST", "/\(token)/master.m3u8") == 405)
        #expect(status("DELETE", "/\(token)/master.m3u8") == 405)
        #expect(status("GET", "/\(token)/master.m3u8", headers: ["host": "evil.example"]) == 403)
        #expect(status("GET", "/\(token)/master.m3u8", headers: [:]) == 403)
        #expect(status("GET", "/\(token)/video-0.m4s", headers: good.merging(["range": "bytes=99999999-"]) { $1 }) == 416)
    }

    @Test("the token is random per server and long enough to be unguessable")
    func tokens() async throws {
        let (first, _) = try await makeServer()
        let (second, _) = try await makeServer()
        defer { first.stop(); second.stop() }
        #expect(first.token.count == 32 && second.token.count == 32 && first.token != second.token)
        #expect(first.port != second.port)
    }

    @Test("listens on the loopback interface only")
    func loopbackOnly() async throws {
        let (server, _) = try await makeServer()
        defer { server.stop() }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }
        var external: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                external.append(String(cBuffer: host))
            }
        }
        // Not having a network interface (CI, simulators) is fine: there is nothing to attack then.
        for ip in external.prefix(2) {
            let url = URL(string: "http://\(ip):\(server.port)/\(server.token)/master.m3u8")!
            await #expect(throws: (any Error).self, "reachable on \(ip)") { _ = try await fetch(url) }
        }
        #expect(try await fetch(server.masterURL).1.statusCode == 200)
    }

    @Test("stopping the server ends access")
    func stops() async throws {
        let (server, _) = try await makeServer()
        let url = server.masterURL
        #expect(try await fetch(url).1.statusCode == 200)
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) { _ = try await fetch(url) }
    }

    @Test("byte range parsing")
    func ranges() {
        #expect(LoopbackServer.byteRange("bytes=0-9", length: 100) == 0..<10)
        #expect(LoopbackServer.byteRange("bytes=90-", length: 100) == 90..<100)
        #expect(LoopbackServer.byteRange("bytes=-10", length: 100) == 90..<100)
        #expect(LoopbackServer.byteRange("bytes=50-500", length: 100) == 50..<100)
        #expect(LoopbackServer.byteRange("bytes=0-1,5-6", length: 100) == nil)
        #expect(LoopbackServer.byteRange("items=0-1", length: 100) == nil)
    }
}

@MainActor
@Suite("Playback session")
struct PlaybackSessionTests {
    @Test("an MKV becomes a player item served from the loopback address")
    func makesItem() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        #expect(session.info.container.isMatroskaFamily)
        let item = try await session.makePlayerItem()
        let url = try #require((item.asset as? AVURLAsset)?.url)
        #expect(url.host == "127.0.0.1" && url.path.hasSuffix("/master.m3u8"))
        #expect(try await fetch(url).1.statusCode == 200)
        session.close()
    }

    @Test("the item keeps its session alive after the caller lets go of it")
    func itemRetainsSession() async throws {
        let item: AVPlayerItem
        do {
            let session = try await PlaybackSession(url: Fixture.url("fixture-hevc"))
            item = try await session.makePlayerItem()
        }
        let url = try #require((item.asset as? AVURLAsset)?.url)
        #expect(try await fetch(url).1.statusCode == 200)
    }

    @Test("closing the session stops the server and later calls fail cleanly")
    func closing() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let item = try await session.makePlayerItem()
        let url = try #require((item.asset as? AVURLAsset)?.url)
        session.close()
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) { _ = try await fetch(url) }
        await #expect(throws: MediaError.cancelled) { _ = try await session.makePlayerItem() }
    }

    @Test("two items from one session share one server")
    func sharedServer() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let first = try #require((try await session.makePlayerItem().asset as? AVURLAsset)?.url)
        let second = try #require((try await session.makePlayerItem().asset as? AVURLAsset)?.url)
        #expect(first == second)
        session.close()
    }

    @Test("garbage is refused at the door")
    func garbage() async {
        await #expect(throws: MediaError.notMedia) {
            _ = try await PlaybackSession(source: MediaSource(byteSource: DataByteSource(Data(repeating: 7, count: 2_000))))
        }
    }
}

#if os(macOS)
/// The real thing: AVPlayer loads our HLS from the loopback server, decodes it, seeks and plays to the end.
@MainActor
@Suite("AVPlayer end to end", .serialized)
struct AVPlayerEndToEndTests {
    @Test("plays, seeks and finishes", arguments: [("fixture-basic", 640, 360), ("fixture-hevc", 640, 360), ("fixture-hlg", 640, 360)])
    func plays(name: String, width: Int, height: Int) async throws {
        try await verifyPlayback(name: name, width: width, height: height)
    }

    /// OPEN ISSUE (E-S3 finding): AVPlayer's HLS path rejects PQ (HDR10) video with CoreMedia -17223, even for
    /// FFmpeg's own HLS output of the same file, although the identical stream plays as a local fragmented MP4 and
    /// HLG/10-bit SDR play through HLS. To be settled with real HDR10 files on real hardware; see docs/PROGRESS.md.
    @Test("HDR10 (PQ) over HLS is rejected by AVPlayer: known issue")
    func pqKnownIssue() async throws {
        await withKnownIssue("AVPlayer HLS rejects synthetic PQ video (-17223)") {
            try await verifyPlayback(name: "fixture-hdr10", width: 640, height: 360)
        }
    }

    @Test("the system audio menu lists every track, including the transcoded one, and switching works")
    func audioSelection() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay })

        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
        let languages = group.options.compactMap { $0.locale?.language.languageCode?.identifier }
        #expect(group.options.count == 2 && Set(languages) == ["en", "ja"], "menu: \(group.options.map(\.displayName)) \(languages)")

        player.play()
        #expect(await waitUntil(8) { item.currentTime().seconds > 0.6 })
        let japanese = try #require(group.options.first { $0.locale?.language.languageCode?.identifier == "ja" })
        item.select(japanese, in: group)                         // the second track is FLAC, served as ALAC
        let before = item.currentTime().seconds
        #expect(await waitUntil(8) {
            item.currentMediaSelection.selectedMediaOption(in: group)?.locale?.language.languageCode?.identifier == "ja"
                && item.currentTime().seconds > before + 0.4
        }, "after switching: at \(item.currentTime().seconds)")
        #expect(item.error == nil)
        player.pause()
        session.close()
    }

    @Test("playback crosses a segment boundary on the Opus and the Vorbis track", arguments: ["en", "ja"])
    func crossesBoundary(language: String) async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-opus-vorbis"))
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay })
        #expect(abs(item.duration.seconds - 14.0) < 0.3)
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .audible))
        let option = try #require(group.options.first { $0.locale?.language.languageCode?.identifier == language })
        item.select(option, in: group)

        await item.seek(to: CMTime(seconds: 4.8, preferredTimescale: 600))        // the boundary sits at about 6 s
        player.play()
        #expect(await waitUntil(10) { item.currentTime().seconds > 7.5 }, "stuck at \(item.currentTime().seconds) on \(language)")
        #expect(item.error == nil && player.timeControlStatus == .playing)
        player.pause()
        session.close()
    }

    @Test("a truncated download plays what it has and then stops without an error")
    func truncatedDownload() async throws {
        let data = try Fixture.data("fixture-opus-vorbis")                          // 14 s; the index sits at the end
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("truncated-\(UUID().uuidString).mkv")
        try data.prefix(data.count * 6 / 10).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try await PlaybackSession(url: url)
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")
        let duration = item.duration.seconds
        // The duration is the header's: finding the true end of a damaged file would mean reading all of it.
        #expect(abs(duration - 14.0) < 0.3, "duration \(duration) s")

        player.play()
        #expect(await waitUntil(10) { item.currentTime().seconds > 2.0 }, "stuck at \(item.currentTime().seconds)")
        #expect(await waitUntil(15) { item.currentTime().seconds >= duration - 0.2 || player.timeControlStatus == .paused },
                "did not come to a stop at the end of the readable part; at \(item.currentTime().seconds) of \(duration)")
        let stoppedAt = item.currentTime().seconds                              // 60% of the bytes hold about 8.3 s
        #expect(stoppedAt > 6.5 && stoppedAt < 9, "stopped at \(stoppedAt) s")
        #expect(item.error == nil, "\(String(describing: item.error))")
        player.pause()
        session.close()
    }

    /// SPIKE RESULT (RMX-9, 2026-10-25): AVPlayer takes HLS playlists and initialization segments from an
    /// `AVAssetResourceLoader` but refuses media segments with "custom url not redirect" (CoreMedia -12881): they
    /// must come from a real network URL. So there is no socket-free transport; see docs/RESEARCH.md section 16.
    /// This test fails the day AVPlayer starts accepting them, which is when the transport is worth building.
    @Test("AVPlayer does not take HLS media segments from a resource loader: known limitation")
    func resourceLoaderLimitation() async throws {
        await withKnownIssue("HLS media segments cannot come from an AVAssetResourceLoader (-12881, custom url not redirect)") {
            let info = try await Fixture.probe("fixture-basic")
            let remux = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-basic")), info: info, cancellation: CancellationFlag())
            let probe = ResourceLoaderProbe(provider: remux)
            defer { probe.stop(); remux.close() }
            let asset = AVURLAsset(url: probe.masterURL)
            asset.resourceLoader.setDelegate(probe, queue: probe.queue)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            let ready = await waitUntil(5) { item.status != .unknown }
            #expect(ready && item.status == .readyToPlay, "\(String(describing: item.error))")
            player.play()
            #expect(await waitUntil(5) { item.currentTime().seconds > 0.5 })
        }
    }

    @Test("an SRT track shows up in the subtitle menu and its cues arrive on time")
    func subtitleCues() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        let item = try await session.makePlayerItem()
        let collector = CueCollector()
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        output.suppressesPlayerRendering = true
        output.setDelegate(collector, queue: .main)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")

        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
        // The system may add machine-translated options for the viewer's languages ("Russian (Russia) Translated"); ours is the plain one.
        let ours = group.options.filter { $0.mediaType == .subtitle && !$0.displayName.contains("Translated") }
        #expect(ours.count == 1, "options: \(group.options.map { "\($0.displayName) \($0.extendedLanguageTag ?? "-")" })")
        let option = try #require(ours.first)
        #expect(option.locale?.language.languageCode?.identifier == "en" && option.displayName == "English", "\(option.displayName)")
        item.select(option, in: group)
        player.play()
        #expect(await waitUntil(8) { collector.texts.contains("こんにちは — second line, UTF-8.") }, "got \(collector.texts)")
        #expect(collector.texts.contains("Hello, subtitle one."), "got \(collector.texts)")
        // The cues arrive for the item time that equals their time in the file, i.e. in step with the video frame
        // shown at that moment (the WebVTT times carry the same shift as the remuxed audio and video).
        let arrival = try #require(collector.firstTime(of: "Hello, subtitle one."))
        #expect(abs(arrival - 0.2) < 0.15, "the first cue (0.2 s in the file) was delivered for item time \(arrival)")
        let second = try #require(collector.firstTime(of: "こんにちは — second line, UTF-8."))
        #expect(abs(second - 1.6) < 0.15, "the second cue (1.6 s in the file) was delivered for item time \(second)")
        player.pause()
        session.close()
    }

    @Test("a positioned ASS sign is drawn where the script put it")
    func subtitlePlacement() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-anime"))
        let item = try await session.makePlayerItem()
        let collector = CueCollector()
        let output = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        output.suppressesPlayerRendering = true
        output.setDelegate(collector, queue: .main)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(10) { item.status == .readyToPlay }, "\(String(describing: item.error))")
        let group = try #require(try await item.asset.loadMediaSelectionGroup(for: .legible))
        // The forced "Signs and Songs" track: a sign at \pos(320,60) of a 640x360 script, then an unpositioned line.
        let signs = try #require(group.options.first { $0.displayName == "English Forced" })
        item.select(signs, in: group)
        player.play()
        #expect(await waitUntil(8) { collector.texts.contains("Karaoke line") }, "got \(collector.texts)")
        let sign = try #require(collector.cue("SIGN: Station"))
        #expect(sign.position == 50, "text position \(String(describing: sign.position))")
        #expect(abs((sign.line ?? -1) - 17) < 1, "line position \(String(describing: sign.line))")
        let line = try #require(collector.cue("Karaoke line"))
        #expect(line.line == 100, "an unpositioned cue sits at the bottom, not at \(String(describing: line.line))")
        player.pause()
        session.close()
    }

    @Test("a file with B-frames plays, seeks and finishes")
    func playsBFrames() async throws {
        try await verifyPlayback(name: "fixture-bframes", width: 640, height: 360, duration: 10.0, seeks: [0.4, 6.5])
    }

    private func verifyPlayback(name: String, width: Int, height: Int, duration expected: Double = 3.05,
                                seeks: [Double] = [0.2, 2.2]) async throws {
        let session = try await PlaybackSession(url: Fixture.url(name))
        let item = try await session.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes())
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let ready = await waitUntil(10) { item.status != .unknown }
        #expect(ready && item.status == .readyToPlay, "\(name): \(String(describing: item.error))")
        guard item.status == .readyToPlay else { return }

        #expect(abs(item.duration.seconds - expected) < 0.2, "duration \(item.duration.seconds)")
        #expect(Int(item.presentationSize.width) == width && Int(item.presentationSize.height) == height)
        let kinds = Set(item.tracks.compactMap { $0.assetTrack?.mediaType })
        #expect(kinds.contains(.video) && kinds.contains(.audio), "\(name) tracks: \(kinds)")

        player.play()
        #expect(await waitUntil(8) { item.currentTime().seconds > 1.0 }, "\(name) did not reach 1 s; at \(item.currentTime().seconds); \(String(describing: item.error))")
        let (frame, _) = output.pixelBufferAndDisplayTime(forItemTime: item.currentTime())
        #expect(frame != nil, "\(name) produced no frame")

        // Seek backwards and forwards: segments are requested out of order.
        for target in seeks {
            await item.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            #expect(await waitUntil(6) { abs(item.currentTime().seconds - target) < 0.6 && player.timeControlStatus == .playing },
                    "\(name) after seeking to \(target): at \(item.currentTime().seconds), \(player.timeControlStatus.rawValue)")
        }

        #expect(await waitUntil(expected + 5) { item.currentTime().seconds >= item.duration.seconds - 0.15 || player.timeControlStatus == .paused },
                "\(name) did not reach the end; at \(item.currentTime().seconds)")
        #expect(item.error == nil, "\(String(describing: item.error))")
        player.pause()
        session.close()
    }
}
#endif

/// Receives the subtitle text AVPlayer would draw, with the placement it computed.
private final class CueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    struct Cue { var time: Double; var text: String; var line: Double?; var position: Double? }
    private let received = Mutex<[Cue]>([])
    var texts: [String] { received.withLock { $0.map(\.text) } }
    func firstTime(of text: String) -> Double? { received.withLock { $0.first { $0.text == text }?.time } }
    func cue(_ text: String) -> Cue? { received.withLock { $0.first { $0.text == text } } }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        for string in strings {
            let text = string.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let attributes = string.attributes(at: 0, effectiveRange: nil)
            let line = attributes[NSAttributedString.Key(kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String)] as? Double
            let position = attributes[NSAttributedString.Key(kCMTextMarkupAttribute_TextPositionPercentageRelativeToWritingDirection as String)] as? Double
            received.withLock { $0.append(Cue(time: itemTime.seconds, text: text, line: line, position: position)) }
        }
    }
}
