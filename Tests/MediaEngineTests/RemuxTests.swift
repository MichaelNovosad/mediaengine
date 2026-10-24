import Foundation
import Testing
@testable import MediaEngine
#if os(macOS)
import AVFoundation
#endif

private func makeSession(_ name: String) async throws -> RemuxSession {
    let info = try await Fixture.probe(name)
    return try RemuxSession(source: FileByteSource(url: Fixture.url(name)), info: info, cancellation: CancellationFlag())
}

/// Counts packets per stream by reading the whole file independently of the session.
private func packetCounts(_ name: String) throws -> [Int: Int] {
    let reader = try PacketReader(source: FileByteSource(url: Fixture.url(name)), cancellation: CancellationFlag())
    var counts: [Int: Int] = [:]
    while let packet = try reader.next() { counts[packet.stream, default: 0] += 1 }
    return counts
}

/// Sample count and decode-time span of a fragment, read from its `moof`.
private struct FragmentFacts { var sampleCount: Int; var baseDecodeTime: UInt64; var totalDuration: UInt64; var sequence: UInt32 }

private func facts(_ fragment: Data) throws -> FragmentFacts {
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

@Suite("Segment planning")
struct SegmentPlanTests {
    @Test("cuts at keyframes once the target duration is reached")
    func cutsAtKeyframes() {
        let plan = SegmentPlan.make(keyframes: [0, 2, 4, 6.5, 9, 12.4, 14, 18.2, 20], duration: 25, target: 6)
        #expect(plan.segments.map(\.start) == [0, 6.5, 14, 20])
        #expect(plan.segments.map(\.end) == [6.5, 14, 20, 25])
        #expect(plan.totalDuration == 25)
    }

    @Test("segments tile the timeline without gaps")
    func tiles() {
        let plan = SegmentPlan.make(keyframes: stride(from: 0, to: 600, by: 2.5).map { $0 }, duration: 601.3)
        #expect(plan.segments.first?.start == 0 && plan.segments.last?.end == 601.3)
        for pair in zip(plan.segments, plan.segments.dropFirst()) { #expect(pair.0.end == pair.1.start) }
        #expect(plan.segments.dropLast().allSatisfy { $0.duration >= 5.999 })
    }

    @Test("a short file is one segment; an audio-only file uses a fixed grid; a tiny tail is folded in")
    func edgeCases() {
        #expect(SegmentPlan.make(keyframes: [0, 1, 2], duration: 3.05).segments.count == 1)
        #expect(SegmentPlan.make(keyframes: [], duration: 20).segments.map(\.start) == [0, 6, 12, 18])
        let folded = SegmentPlan.make(keyframes: [0, 6], duration: 6.4)
        #expect(folded.segments.count == 1 && folded.segments[0].end == 6.4)
        #expect(SegmentPlan.make(keyframes: [], duration: 0).segments.isEmpty)
    }

    @Test("finds the segment for a time")
    func lookup() {
        let plan = SegmentPlan.make(keyframes: [0, 6, 12], duration: 18)
        #expect(plan.segment(at: 0)?.index == 0 && plan.segment(at: 5.99)?.index == 0)
        #expect(plan.segment(at: 6)?.index == 1 && plan.segment(at: 100)?.index == 2 && plan.segment(at: -3)?.index == 0)
    }
}

@Suite("HLS remux")
struct RemuxTests {
    @Test("playlists describe the video and the passthrough audio track")
    func playlists() async throws {
        let session = try await makeSession("fixture-basic")
        let master = String(decoding: try #require(try session.resource(path: "master.m3u8")).data, as: UTF8.self)
        #expect(master.hasPrefix("#EXTM3U"))
        #expect(master.contains("#EXT-X-STREAM-INF:"))
        #expect(master.contains("RESOLUTION=640x360") && master.contains("FRAME-RATE=25.000"))
        #expect(master.contains("avc1.64") && master.contains("mp4a.40.2"))
        #expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO") && master.contains("LANGUAGE=\"en\"") && master.contains("DEFAULT=YES"))
        #expect(master.contains("URI=\"audio-1.m3u8\"") && master.contains("URI=\"audio-2.m3u8\""))
        #expect(master.contains("NAME=\"English AAC\"") && master.contains("NAME=\"Japanese FLAC\"") && master.contains("LANGUAGE=\"ja\""))
        #expect(master.contains("\"avc1.64") && master.contains("mp4a.40.2"))

        let video = String(decoding: try #require(try session.resource(path: "video.m3u8")).data, as: UTF8.self)
        #expect(video.contains("#EXT-X-MAP:URI=\"video-init.mp4\"") && video.hasSuffix("#EXT-X-ENDLIST\n"))
        let total = video.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast(1)) }.reduce(0, +)
        #expect(abs(total - 3.052) < 0.01)
        #expect(try session.resource(path: "audio-1.m3u8") != nil)
        #expect(try session.resource(path: "nope.m3u8") == nil)
        #expect(try session.resource(path: "video-99.m4s") == nil)
    }

    @Test("init segments describe the codecs Apple expects", arguments: [
        ("fixture-basic", "video-init.mp4", ["avc1", "avcC"]),
        ("fixture-hevc", "video-init.mp4", ["hvc1", "hvcC"]),
        ("fixture-hevc", "audio-1-init.mp4", ["ac-3", "dac3"]),
        ("fixture-hdr10", "video-init.mp4", ["hvc1", "hvcC", "colr"]),
        ("fixture-hdr10", "audio-1-init.mp4", ["ec-3", "dec3"]),
        ("fixture-basic", "audio-1-init.mp4", ["mp4a", "esds"]),
        ("fixture-basic", "audio-2-init.mp4", ["alac"]),
        ("fixture-flac24", "audio-1-init.mp4", ["alac"]),
    ])
    func initSegments(name: String, path: String, markers: [String]) async throws {
        let session = try await makeSession(name)
        let data = try #require(try session.resource(path: path)).data
        let boxes = MP4Box.parse(data)
        #expect(boxes.map(\.type) == ["ftyp", "moov"])
        for marker in markers { #expect(data.range(of: Data(marker.utf8)) != nil, "\(name) \(path) lacks \(marker)") }
        #expect(MP4Box.find(["moov", "mvex", "trex"], in: data) != nil, "fragmented files need mvex/trex")
        #expect(data.range(of: Data("hev1".utf8)) == nil)
    }

    @Test("every packet lands in exactly one fragment, with continuous timestamps", arguments: ["fixture-basic", "fixture-hevc", "fixture-hdr10", "fixture-hlg", "fixture-flac24"])
    func fragmentsAreComplete(name: String) async throws {
        let session = try await makeSession(name)
        let expected = try packetCounts(name)
        let info = try await Fixture.probe(name)
        for track in info.tracks where session.hasOutput(track.id) {
            let prefix = track.kind == .video ? "video" : "audio-\(track.id)"
            var samples = 0
            var totalTicks: UInt64 = 0
            var previousEnd: UInt64?
            for index in session.plan.segments.indices {
                let fragment = try #require(try session.resource(path: "\(prefix)-\(index).m4s")).data
                let fact = try facts(fragment)
                #expect(fact.sequence == UInt32(index + 1))
                samples += fact.sampleCount
                if let previousEnd {
                    let gap = Int64(fact.baseDecodeTime) - Int64(previousEnd)
                    let scale = Double(session.timescale(track.id))
                    #expect(abs(Double(gap) / scale) < 0.05, "\(name) \(prefix) gap at segment \(index): \(Double(gap) / scale) s")
                }
                previousEnd = fact.baseDecodeTime + fact.totalDuration
                totalTicks += fact.totalDuration
            }
            let transcoded = info.playbackPlan.tracks.contains { plan in
                if plan.trackID == track.id, case .transcodeAudio = plan.treatment { true } else { false }
            }
            if transcoded {
                let seconds = Double(totalTicks) / Double(session.timescale(track.id))
                #expect(abs(seconds - 3.0) < 0.12, "\(name) stream \(track.id): transcoded audio lasts \(seconds) s")
            } else {
                #expect(samples == expected[track.id], "\(name) stream \(track.id): \(samples) samples vs \(expected[track.id] ?? -1) packets")
            }
        }
    }

    @Test("segments can be requested in any order and are identical each time")
    func randomAccess() async throws {
        let session = try await makeSession("fixture-basic")
        let first = try #require(try session.resource(path: "video-0.m4s")).data
        _ = try session.resource(path: "audio-1-0.m4s")
        let again = try #require(try session.resource(path: "video-0.m4s")).data
        #expect(first == again)
    }

    @Test("sources with unplayable video are refused")
    func refusesUnsupported() async throws {
        // fixture-licensed-audio has only unavailable audio but playable video: fine. A file whose only video is
        // out of scope has no wanted stream; simulate by removing all treatments.
        var info = try await Fixture.probe("fixture-licensed-audio")
        info.playbackPlan.tracks = info.playbackPlan.tracks.map { var t = $0; t.treatment = .unavailable(UnavailableReason(code: .outOfScope, detail: "x", requires: nil)); return t }
        #expect(throws: MediaError.self) {
            _ = try RemuxSession(source: FileByteSource(url: Fixture.url("fixture-licensed-audio")), info: info, cancellation: CancellationFlag())
        }
    }

    #if os(macOS)
    /// The strongest check available: AVFoundation itself reads the assembled stream.
    @Test("AVFoundation decodes the assembled video and audio", arguments: ["fixture-basic", "fixture-hevc", "fixture-hdr10", "fixture-hlg", "fixture-flac24"])
    func avfoundationDecodes(name: String) async throws {
        let session = try await makeSession(name)
        let expected = try packetCounts(name)
        let info = try await Fixture.probe(name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for track in info.tracks where session.hasOutput(track.id) {
            let prefix = track.kind == .video ? "video" : "audio-\(track.id)"
            var bytes = try #require(try session.resource(path: "\(prefix)-init.mp4")).data
            for index in session.plan.segments.indices {
                bytes.append(try #require(try session.resource(path: "\(prefix)-\(index).m4s")).data)
            }
            let file = directory.appendingPathComponent("\(prefix).mp4")
            try bytes.write(to: file)

            let asset = AVURLAsset(url: file)
            let mediaType: AVMediaType = track.kind == .video ? .video : .audio
            let avTrack = try #require(try await asset.loadTracks(withMediaType: mediaType).first)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 3.05) < 0.15, "\(name) \(prefix) duration \(duration)")

            let settings: [String: Any] = track.kind == .video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                   AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: avTrack, outputSettings: settings)
            let provider = reader.outputProvider(for: output)
            try reader.start()
            var buffers = 0
            var decodedSeconds = 0.0
            var lastEnd = 0.0
            while let ready = try await provider.next() {
                buffers += 1
                let presentation = ready.presentationTimeStamp.seconds
                let length = ready.duration.seconds
                decodedSeconds += length.isFinite ? length : 0
                lastEnd = max(lastEnd, presentation + (length.isFinite ? length : 0))
            }
            #expect(reader.status == .completed, "\(name) \(prefix): \(String(describing: reader.error))")
            if track.kind == .video {
                #expect(buffers == expected[track.id], "\(name) decoded \(buffers) frames, file has \(expected[track.id] ?? -1) packets")
            } else {
                #expect(decodedSeconds > 2.8 && decodedSeconds < 3.4, "\(name) \(prefix) decoded \(decodedSeconds) s of audio")
            }
            #expect(lastEnd > 2.8 && lastEnd < 3.4, "\(name) \(prefix) ends at \(lastEnd)")
        }
    }
    #endif
}
