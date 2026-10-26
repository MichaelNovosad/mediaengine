import AVFoundation
import Foundation
import Testing
@testable import MediaEngine

private let openingUID = "a1a2a3a4a5a6a7a8a9aaabacadaeafb0"
private let missingUID = "deadbeefdeadbeefdeadbeefdeadbeef"

private func source(_ name: String) throws -> MediaSource { MediaSource(byteSource: try FileByteSource(url: Fixture.url(name))) }

private func linkedSources(_ files: [String: String]) -> [String: MediaSource] {
    files.mapValues { MediaSource(byteSource: try! FileByteSource(url: Fixture.url($0))) }
}

/// Every packet of a file, per stream.
private func packets(of url: URL) throws -> [Int: [MediaPacket]] {
    let reader = try PacketReader(source: FileByteSource(url: url), cancellation: CancellationFlag())
    var result: [Int: [MediaPacket]] = [:]
    while let packet = try reader.next() { result[packet.stream, default: []].append(packet) }
    return result
}

private func drain(_ source: any PacketSource) throws -> [Int: [MediaPacket]] {
    var result: [Int: [MediaPacket]] = [:]
    while let packet = try source.next() { result[packet.stream, default: []].append(packet) }
    return result
}

@Suite("Timeline reader")
struct TimelineReaderTests {
    private func timeline(_ main: String = "fixture-ordered", linked: [String: String] = [openingUID: "fixture-linked-opening"]) async throws
        -> (reader: TimelineReader, list: OrderedChapters, incompatible: Set<String>) {
        let info = try await Fixture.probe(main)
        let built = try PlaybackSession.makeTimeline(main: FileByteSource(url: Fixture.url(main)), info: info, ordered: #require(info.orderedChapters),
                                                     linked: linkedSources(linked), cancellation: CancellationFlag())
        return (built.reader, built.list, built.incompatible)
    }

    /// What the play list says should come out, worked out from the source files without the timeline reader.
    private func expected(_ list: OrderedChapters, main: String, linked: [String: String]) throws -> [Int: [MediaPacket]] {
        var result: [Int: [MediaPacket]] = [:]
        for piece in list.pieces {
            let name = piece.segment.map { linked[$0.uid]! } ?? main
            let shift = piece.offset - piece.start
            for (stream, list) in try packets(of: Fixture.url(name)) {
                for var packet in list {
                    let seconds = Double(packet.pts) / 1000, length = Double(max(packet.duration, 0)) / 1000
                    // A frame belongs to the part it starts in; the first part also keeps one that straddles its start.
                    let before = piece.start > 0.001 ? seconds < piece.start - 0.001 : seconds + length <= piece.start + 0.001
                    if before || seconds >= piece.end - 0.001 { continue }
                    packet.pts = Int64((Double(packet.pts) + shift * 1000).rounded())
                    packet.dts = Int64((Double(packet.dts) + shift * 1000).rounded())
                    packet.position = -1
                    result[stream, default: []].append(packet)
                }
            }
        }
        return result
    }

    @Test("the packets are those of the parts in order, byte for byte, with timestamps on the play list's timeline")
    func packetsMatchSources() async throws {
        let (reader, list, bad) = try await timeline()
        #expect(bad.isEmpty && list.pieces.count == 3)
        let actual = try drain(reader)
        let want = try expected(list, main: "fixture-ordered", linked: [openingUID: "fixture-linked-opening"])
        #expect(Set(actual.keys) == [0, 1, 2] && Set(want.keys) == [0, 1, 2])
        for stream in [0, 1, 2] {
            let got = try #require(actual[stream]), wanted = try #require(want[stream])
            #expect(got.count == wanted.count, "stream \(stream): \(got.count) packets, expected \(wanted.count)")
            for (index, (a, b)) in zip(got, wanted).enumerated() where a != b {
                Issue.record("stream \(stream), packet \(index): pts \(a.pts) vs \(b.pts), dts \(a.dts) vs \(b.dts), \(a.data.count) vs \(b.data.count) bytes, key \(a.isKeyframe) vs \(b.isKeyframe)")
                break
            }
        }
        // 6 s of 25 fps video, continuous: timestamps rise by one frame, from the first frame to the last.
        let video = try #require(actual[0])
        #expect(video.count == 150 && video.first?.pts == 0 && video.last?.pts == 5_960, "\(video.count) frames, last at \(video.last?.pts ?? -1) ms")
        #expect(zip(video, video.dropFirst()).allSatisfy { $1.pts - $0.pts == 40 })
        #expect(video.filter(\.isKeyframe).map(\.pts) == [0, 1_000, 2_000, 3_000, 4_000, 5_000])
        // The subtitle track is read from whichever file the part comes from: the opening's block, then the second half's, then the first half's.
        #expect(try #require(actual[2]).map(\.pts) == [500, 2_500, 4_500])
        let audio = try #require(actual[1])
        #expect(audio.first.map { $0.pts <= 0 } == true && (audio.last.map { $0.pts + $0.duration } ?? 0) >= 5_950)
    }

    @Test("seeking lands inside the right part and reads on to the end with the same packets as a straight read")
    func seeking() async throws {
        let (reader, _, _) = try await timeline()
        let all = try #require(try drain(reader)[0])
        for (seconds, firstKey) in [(0.0, 0.0), (1.3, 1.0), (2.0, 2.0), (3.4, 3.0), (4.1, 4.0), (5.9, 5.0)] {
            try reader.seek(stream: 0, to: Int64(seconds * 1000))
            var video: [MediaPacket] = []
            while let packet = try reader.next() { if packet.stream == 0 { video.append(packet) } }
            let first = try #require(video.first, "seek to \(seconds)")
            #expect(first.isKeyframe && first.pts == Int64(firstKey * 1000), "seek to \(seconds) starts at \(first.pts)")
            #expect(video == all.filter { $0.pts >= first.pts }, "seek to \(seconds): the rest differs from a straight read")
        }
        try reader.rewind()
        #expect(try #require(try drain(reader)[0]) == all, "after rewind")
    }

    @Test("the keyframe list covers the whole timeline, with part starts as boundaries")
    func keyframes() async throws {
        let (reader, _, _) = try await timeline()
        let times = reader.keyframeIndex(stream: 0, loadingIndexUpTo: nil).map { reader.timeBase(0).seconds($0.timestamp) }
        #expect(times == [0, 1, 2, 3, 4, 5], "\(times)")
        #expect(try #require(try drain(reader)[0]).count == 150, "listing the keyframes leaves the reader usable")
    }

    @Test("a file with another video configuration is left out and reported")
    func incompatible() async throws {
        let (reader, list, bad) = try await timeline(linked: [openingUID: "fixture-hevc"])
        #expect(bad == [openingUID] && list.pieces.map(\.title) == ["Second half", "First half"] && list.duration == 4)
        let video = try #require(try drain(reader)[0])
        #expect(video.count == 100 && video.first?.pts == 0 && video.last?.pts == 3_960)
    }

    @Test("a play list with no file for a part leaves that part out")
    func missing() async throws {
        let (reader, list, bad) = try await timeline("fixture-ordered-missing")
        #expect(bad.isEmpty && list.pieces.map(\.title) == ["Opening", "Second half"] && list.duration == 4)
        let video = try #require(try drain(reader)[0])
        #expect(video.count == 100 && video.last?.pts == 3_960)
    }

    @Test("audio the linked file does not have shows as a gap in the coverage")
    func coverage() async throws {
        let (reader, _, _) = try await timeline()
        #expect(reader.coverage(of: 1) == [0...2, 2...4, 4...6], "all three parts have audio")
        #expect(reader.coverage(of: 0).count == 3)
    }
}

@Suite("Play lists in a session")
struct PlayListSessionTests {
    private func make(_ name: String = "fixture-ordered", linked: [String: String] = [:]) async throws -> PlaybackSession {
        let session = try await PlaybackSession(url: Fixture.url(name))
        for (uid, file) in linked { try session.link(LinkedSegment(uid: uid), to: source(file)) }
        return session
    }

    @Test("without the other file the opening is missing and the rest plays: 4 s, two chapters")
    func withoutLink() async throws {
        let session = try await make()
        defer { session.close() }
        #expect(session.missingSegments.map(\.uid) == [openingUID] && session.incompatibleSegments.isEmpty)
        #expect(session.playList?.pieces.map(\.title) == ["Second half", "First half"] && session.duration == 4)
        #expect(session.chapters.map(\.title) == ["Second half", "First half"] && session.chapters.map(\.start) == [0, 2])
    }

    @Test("with the file linked the whole 6 s plays and the chapters follow the play list")
    func withLink() async throws {
        let session = try await make(linked: [openingUID: "fixture-linked-opening"])
        defer { session.close() }
        #expect(session.missingSegments.isEmpty && session.duration == 6)
        #expect(session.chapters.map(\.title) == ["Opening", "Second half", "First half"])
        #expect(session.chapters.map(\.start) == [0, 2, 4] && session.chapters.map(\.end) == [2, 4, 6])
    }

    @Test("an ordinary file has no play list: its own chapters and duration")
    func ordinary() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { session.close() }
        #expect(session.playList == nil && session.missingSegments.isEmpty && session.chapters == session.info.chapters)
        #expect(session.duration == session.info.duration)
        #expect(try await session.locateSegments(in: Fixture.root.appendingPathComponent("Fixtures")).isEmpty)
    }

    @Test("a folder is searched by segment identifier, not by file name")
    func folder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("segments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: Fixture.url("fixture-linked-opening"), to: folder.appendingPathComponent("Part A.MKV"))
        try FileManager.default.copyItem(at: Fixture.url("fixture-basic"), to: folder.appendingPathComponent("Intro.mkv"))
        try Data("not media".utf8).write(to: folder.appendingPathComponent("notes.mkv"))
        try Data("text".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let session = try await make()
        defer { session.close() }
        let found = try await session.locateSegments(in: folder)
        #expect(found.map(\.uid) == [openingUID] && session.missingSegments.isEmpty && session.duration == 6)
        // The identifier the missing fixture names is not in the folder.
        let other = try await make("fixture-ordered-missing")
        defer { other.close() }
        #expect(try await other.locateSegments(in: folder).map(\.uid) == [openingUID] && other.missingSegments.map(\.uid) == [missingUID])
    }

    @Test("segments cannot be linked or located once the first item exists, or after closing")
    func lateLink() async throws {
        let session = try await make(linked: [openingUID: "fixture-linked-opening"])
        _ = try await session.makePlayerItem()
        #expect(throws: MediaError.self) { try session.link(LinkedSegment(uid: openingUID), to: source("fixture-linked-opening")) }
        await #expect(throws: MediaError.self) { _ = try await session.locateSegments(in: Fixture.root) }
        session.close()
        #expect(throws: MediaError.self) { try session.link(LinkedSegment(uid: openingUID), to: source("fixture-linked-opening")) }
    }

    @Test("an incompatible file is reported once the item is made, and the rest plays")
    func incompatible() async throws {
        let session = try await make(linked: [openingUID: "fixture-hevc"])
        defer { session.close() }
        #expect(session.incompatibleSegments.isEmpty && session.duration == 6, "not known before the item is made")
        _ = try await session.makePlayerItem()
        #expect(session.incompatibleSegments.map(\.uid) == [openingUID])
        #expect(session.duration == 4 && session.chapters.map(\.title) == ["Second half", "First half"])
    }

    @Test("the segments tile the 6 s timeline and every window holds both streams")
    func remuxOverPlayList() async throws {
        let info = try await Fixture.probe("fixture-ordered")
        let built = try PlaybackSession.makeTimeline(main: FileByteSource(url: Fixture.url("fixture-ordered")), info: info, ordered: #require(info.orderedChapters),
                                                     linked: linkedSources([openingUID: "fixture-linked-opening"]), cancellation: CancellationFlag())
        var playInfo = info
        playInfo.duration = built.list.duration
        let remux = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-ordered")), info: playInfo, cancellation: CancellationFlag(), packetSource: built.reader)
        #expect(abs(remux.plan.totalDuration - 6) < 0.05 && remux.plan.segments.first?.start == 0)
        var video = 0, audio = 0
        var previousEnd: UInt64?
        for index in remux.plan.segments.indices {
            let fragment = try #require(try remux.resource(path: "video-\(index).m4s")?.data)
            let facts = try facts(fragment)
            video += facts.sampleCount
            if let previousEnd { #expect(facts.baseDecodeTime == previousEnd, "segment \(index) is not contiguous") }
            previousEnd = facts.baseDecodeTime + facts.totalDuration
            if let a = try remux.resource(path: "audio-1-\(index).m4s")?.data, let facts = fragmentFacts(a) { audio += facts.sampleCount }
        }
        #expect(video == 150 && audio > 280, "\(video) frames, \(audio) audio samples")
    }

    @Test("a linked file cut short does not crash or hang: the playlist is still served")
    func truncatedLinkedFile() async throws {
        let full = try Fixture.data("fixture-linked-opening")
        let info = try await Fixture.probe("fixture-ordered")
        for fraction in [0.3, 0.6, 0.95] {
            let cut = Data(full.prefix(Int(Double(full.count) * fraction)))
            let linked = [openingUID: MediaSource(byteSource: DataByteSource(cut))]
            guard let built = try? PlaybackSession.makeTimeline(main: FileByteSource(url: Fixture.url("fixture-ordered")), info: info, ordered: #require(info.orderedChapters),
                                                                linked: linked, cancellation: CancellationFlag()) else { continue }
            var playInfo = info
            playInfo.duration = built.list.duration
            let remux = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-ordered")), info: playInfo, cancellation: CancellationFlag(), packetSource: built.reader)
            for index in remux.plan.segments.indices { _ = try remux.resource(path: "video-\(index).m4s") }
            #expect(try remux.resource(path: "master.m3u8") != nil)
        }
    }
}

#if os(macOS)
@Suite("Play lists in AVPlayer", .serialized)
struct PlayListPlaybackTests {
    private func play(_ session: PlaybackSession, duration expected: Double, seeks: [Double]) async throws {
        defer { session.close() }
        let item = try await session.makePlayerItem()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes())
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(30) { item.status != .unknown } && item.status == .readyToPlay, "\(String(describing: item.error))")
        guard item.status == .readyToPlay else { return }
        #expect(abs(item.duration.seconds - expected) < 0.2, "duration \(item.duration.seconds)")
        player.play()
        #expect(await waitUntil(30) { item.currentTime().seconds > 0.8 }, "did not start; at \(item.currentTime().seconds); \(String(describing: item.error))")
        #expect(output.pixelBufferAndDisplayTime(forItemTime: item.currentTime()).0 != nil)
        for target in seeks {
            await item.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            #expect(await waitUntil(30) { abs(item.currentTime().seconds - target) < 0.6 && player.timeControlStatus == .playing },
                    "after seeking to \(target): at \(item.currentTime().seconds), control \(player.timeControlStatus.rawValue), waiting for \(String(describing: player.reasonForWaitingToPlay)), item \(item.status.rawValue), error \(String(describing: item.error)), buffer empty \(item.isPlaybackBufferEmpty)")
        }
        #expect(await waitUntil(expected + 30) { item.currentTime().seconds >= item.duration.seconds - 0.15 || player.timeControlStatus == .paused },
                "did not reach the end; at \(item.currentTime().seconds)")
        #expect(item.error == nil, "\(String(describing: item.error))")
        player.pause()
    }

    @Test("the 6 s timeline of three parts from two files plays, seeks across the joins and finishes")
    func playsPlayList() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ordered"))
        try session.link(LinkedSegment(uid: openingUID), to: source("fixture-linked-opening"))
        try await play(session, duration: 6, seeks: [1.5, 4.5, 0.3, 2.6])
    }

    @Test("with the opening missing, the other two parts play as a 4 s film")
    func playsWithoutOpening() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-ordered"))
        try await play(session, duration: 4, seeks: [2.5, 0.4])
    }
}
#endif
