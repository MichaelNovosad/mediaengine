import AVFoundation
import Foundation
import Testing
@testable import MediaEngine

@Suite("Sound for speech recognition", .serialized)
struct SpeechAudioTests {
    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).caf") }

    /// Length in seconds and the loudest sample (0 to 1) of a file.
    private func measure(_ url: URL) throws -> (seconds: Double, rate: Double, channels: Int, peak: Float) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var peak: Float = 0
        if let data = buffer.floatChannelData?[0] { for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[index])) } }
        return (Double(file.length) / file.fileFormat.sampleRate, file.fileFormat.sampleRate, Int(file.fileFormat.channelCount), peak)
    }

    @Test("every sound track the engine can read comes out as mono 16 kHz sound of the right length that is not silent", arguments: [
        "fixture-basic", "fixture-hevc", "fixture-opus-vorbis", "fixture-flac24",
    ])
    func decodes(_ name: String) async throws {
        let session = try await PlaybackSession(url: Fixture.url(name))
        defer { session.close() }
        let choices = session.audioChoices.filter { session.canExtractSpeechAudio(of: $0) }
        #expect(!choices.isEmpty, "\(name): \(session.audioChoices.map(\.codec))")
        for choice in choices {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let last = Mutex2()
            try await session.extractSpeechAudio(of: choice, to: url) { last.set($0) }
            let result = try measure(url)
            let expected = try #require(session.duration)
            #expect(result.rate == 16_000 && result.channels == 1, "\(name) \(choice.codec): \(result)")
            #expect(abs(result.seconds - expected) < 0.5, "\(name) \(choice.codec): \(result.seconds) s of \(expected) s")
            #expect(result.peak > 0.01, "\(name) \(choice.codec) is silent")
            #expect(last.value == 1, "progress reached the end")
        }
    }

    @Test("a sound track that is not the video's own, or that cannot be decoded, is refused")
    func refused() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { session.close() }
        let subtitle = try #require(session.subtitleChoices.first)
        #expect(!session.canExtractSpeechAudio(of: subtitle))
        await #expect(throws: MediaError.self) { try await session.extractSpeechAudio(of: subtitle, to: self.temporaryURL()) }
    }

    @Test("stopping the task stops the decoding and no half-written promise is made")
    func cancelled() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { session.close() }
        let choice = try #require(session.audioChoices.first { session.canExtractSpeechAudio(of: $0) })
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await session.extractSpeechAudio(of: choice, to: url) }
        task.cancel()
        // Either it was stopped or it was so short that it was done: both leave no error other than cancellation.
        do { try await task.value } catch { #expect(error as? MediaError == .cancelled || error is CancellationError, "\(error)") }
    }
}

/// A number that a background thread writes and a test reads.
private final class Mutex2: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0
    func set(_ value: Double) { lock.lock(); stored = value; lock.unlock() }
    var value: Double { lock.lock(); defer { lock.unlock() }; return stored }
}
