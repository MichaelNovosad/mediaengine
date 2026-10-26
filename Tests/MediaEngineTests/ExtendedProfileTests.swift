import AVFoundation
import FFmpegLGPL
import Foundation
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// The legacy containers and codecs of the `extended` profile (ANM-8, SWD-3). Every build probes and plans them; only the
/// extended variant (`MEDIAENGINE_PROFILE=extended swift test`, binary `build/FFmpegLGPL-extended.xcframework`) can decode them.
@Suite("Extended profile")
struct ExtendedProfileTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var fixture: String
        var container: Container.Kind
        var video: String
        var audio: String?
        var path: PlaybackPath                      // in the extended build
        var testDescription: String { fixture }
    }

    static let cases: [Case] = [
        Case(fixture: "fixture-avi-xvid", container: .avi, video: "mpeg4", audio: "ac3", path: .software),
        Case(fixture: "fixture-avi-h264", container: .avi, video: "h264", audio: "aac", path: .remux),
        Case(fixture: "fixture-flv", container: .flv, video: "flv1", audio: "aac", path: .software),
        Case(fixture: "fixture-realmedia", container: .realMedia, video: "rv20", audio: "ac3", path: .software),
        Case(fixture: "fixture-wmv", container: .asf, video: "wmv2", audio: "wmav2", path: .software),
        Case(fixture: "fixture-mpeg2", container: .mpegPS, video: "mpeg2video", audio: "mp2", path: .software),
        Case(fixture: "fixture-ogm", container: .ogg, video: "mpeg4", audio: nil, path: .software),
    ]

    @Test("the build knows which profiles it contains")
    func profiles() {
        let wanted: CodecProfile = ProcessInfo.processInfo.environment["MEDIAENGINE_PROFILE"] == "extended" ? [.core, .extended] : .core
        #expect(MediaEngine.availableProfiles == wanted, "\(MediaEngine.availableProfiles)")
    }

    @Test("RealMedia needs the extended build to be opened at all, and says so", .enabled(if: !isExtendedBuild))
    func realMediaInCore() async {
        let thrown = await #expect(throws: MediaError.self) { _ = try await Fixture.probe("fixture-realmedia") }
        guard case .unsupported(let detail)? = thrown else { Issue.record("got \(String(describing: thrown))"); return }
        #expect(detail.contains("RealMedia") && detail.contains("extended"), "\(detail)")
    }

    @Test("the container and codecs are reported, and the plan says which module is needed", arguments: cases.filter { $0.fixture != "fixture-realmedia" || isExtendedBuild })
    func plan(testCase: Case) async throws {
        let info = try await Fixture.probe(testCase.fixture)
        #expect(info.container.kind == testCase.container, "\(info.container)")
        #expect(info.videoTracks.first?.codec.name == testCase.video && info.audioTracks.first?.codec.name == testCase.audio)
        #expect(info.requiredProfile.contains(.extended), "legacy containers and codecs are grouped with the extended module")
        if isExtendedBuild {
            #expect(info.playbackPlan.path == testCase.path, "\(info.playbackPlan)")
            #expect(info.playbackPlan.blockingReason == nil)
        } else {
            let reason = try #require(info.playbackPlan.blockingReason, "\(info.playbackPlan)")
            #expect(info.playbackPlan.path == .unsupported && reason.code == .needsCodecProfile && reason.requires == .extended, "\(reason)")
        }
    }

    // MARK: Decoding (extended build only)

    /// Decodes the first video stream with FFmpeg's decoder and returns what came out.
    private func decodeVideo(_ name: String) throws -> (frames: Int, width: Int, height: Int, spread: Double) {
        let reader = try PacketReader(source: FileByteSource(url: Fixture.url(name)), cancellation: CancellationFlag())
        let index = try #require((0..<reader.streamCount).first { reader.parameters($0).pointee.codec_type == AVMEDIA_TYPE_VIDEO })
        let parameters = reader.parameters(index)
        let codec = try #require(avcodec_find_decoder(parameters.pointee.codec_id), "no decoder for \(name)")
        let context = try #require(avcodec_alloc_context3(codec))
        defer { var pointer: UnsafeMutablePointer<AVCodecContext>? = context; avcodec_free_context(&pointer) }
        try #require(avcodec_parameters_to_context(context, parameters) >= 0)
        try #require(avcodec_open2(context, codec, nil) >= 0)
        let frame = try #require(av_frame_alloc())
        defer { var pointer: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&pointer) }
        var count = 0, spread = 0.0, width = 0, height = 0
        func drain() {
            while avcodec_receive_frame(context, frame) >= 0 {
                if count == 0, let plane = frame.pointee.data.0 {
                    width = Int(frame.pointee.width); height = Int(frame.pointee.height)
                    // testsrc2 is a busy test pattern: the spread of luma values says the picture is not blank or garbage.
                    var low = 255, high = 0
                    for y in stride(from: 0, to: height, by: 4) { for x in stride(from: 0, to: width, by: 4) {
                        let value = Int(plane[y * Int(frame.pointee.linesize.0) + x]); low = min(low, value); high = max(high, value)
                    } }
                    spread = Double(high - low)
                }
                count += 1
            }
        }
        while let packet = try reader.next() {
            guard packet.stream == index else { continue }
            var av = AVPacket()
            guard av_new_packet(&av, Int32(packet.data.count)) >= 0 else { continue }
            packet.data.withUnsafeBytes { if let base = $0.baseAddress { memcpy(av.data, base, $0.count) } }
            av.pts = packet.pts; av.dts = packet.dts
            avcodec_send_packet(context, &av)
            av_packet_unref(&av)
            drain()
        }
        avcodec_send_packet(context, nil)
        drain()
        return (count, width, height, spread)
    }

    @Test("the software decoders decode their files: 3 s of 640 x 360 picture, not blank", .enabled(if: isExtendedBuild),
          arguments: ["fixture-avi-xvid", "fixture-flv", "fixture-realmedia", "fixture-wmv", "fixture-mpeg2", "fixture-ogm"])
    func decodes(name: String) throws {
        let result = try decodeVideo(name)
        #expect(result.width == 640 && result.height == 360, "\(result)")
        #expect((70...76).contains(result.frames), "\(name): \(result.frames) frames")
        #expect(result.spread > 100, "\(name): luma spread \(result.spread)")
    }

    @Test("the core build has no software video decoder: nothing decodes there", .enabled(if: !isExtendedBuild))
    func coreHasNoDecoders() {
        for id in [AV_CODEC_ID_MPEG4, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_FLV1, AV_CODEC_ID_VP9, AV_CODEC_ID_RV20, AV_CODEC_ID_WMV2] {
            #expect(avcodec_find_decoder(id) == nil, "decoder \(id) is compiled into the core build")
        }
    }
}

#if os(macOS)
/// Legacy containers whose contents Apple decodes play through the remux path (extended build only: the plan holds the
/// container back otherwise). Real-time AVPlayer test: listed in `PLAYBACK_SUITES` (scripts/lib/tests.sh).
@Suite("Legacy containers in AVPlayer", .serialized)
struct LegacyContainerPlaybackTests {
    @Test("AVI with H.264 and AAC plays, seeks and finishes after the remux", .enabled(if: isExtendedBuild))
    func aviWithH264() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-avi-h264"))
        defer { session.close() }
        let item = try await session.makePlayerItem()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        #expect(await waitUntil(15) { item.status != .unknown } && item.status == .readyToPlay, "\(String(describing: item.error))")
        guard item.status == .readyToPlay else { return }
        #expect(abs(item.duration.seconds - 3.08) < 0.2, "duration \(item.duration.seconds)")
        player.play()
        #expect(await waitUntil(15) { item.currentTime().seconds > 0.8 }, "did not start: \(String(describing: item.error))")
        await item.seek(to: CMTime(seconds: 1.8, preferredTimescale: 600))
        #expect(await waitUntil(15) { abs(item.currentTime().seconds - 1.8) < 0.6 && player.timeControlStatus == .playing },
                "after the seek: at \(item.currentTime().seconds), waiting for \(String(describing: player.reasonForWaitingToPlay))")
        #expect(await waitUntil(15) { item.currentTime().seconds >= item.duration.seconds - 0.15 || player.timeControlStatus == .paused })
        #expect(item.error == nil, "\(String(describing: item.error))")
        player.pause()
    }
}
#endif
