internal import FFmpegLGPL
import Foundation
import os

/// Routes FFmpeg's own log output into `os.Logger` (privately), instead of printing to stderr.
enum FFmpegLogging {
    static let logger = Logger(subsystem: "dev.mediaengine", category: "ffmpeg")

    /// Installs the log callback once. Safe to call from any thread, any number of times.
    static func ensureInstalled() { _ = installed }

    private static let installed: Void = {
        av_log_set_level(AV_LOG_WARNING)
        av_log_set_callback(ffmpegLogCallback)
    }()
}

private func ffmpegLogCallback(_ context: UnsafeMutableRawPointer?, _ level: Int32, _ format: UnsafePointer<CChar>?, _ arguments: CVaListPointer?) {
    guard level <= AV_LOG_WARNING, let format, let arguments else { return }
    var buffer = [CChar](repeating: 0, count: 1024)
    _ = vsnprintf(&buffer, buffer.count, format, arguments)
    let message = String(cBuffer: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    if level <= AV_LOG_ERROR {
        FFmpegLogging.logger.error("\(message, privacy: .private)")
    } else {
        FFmpegLogging.logger.warning("\(message, privacy: .private)")
    }
}
