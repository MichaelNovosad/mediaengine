internal import FFmpegLGPL
import Foundation

/// An opened FFmpeg format context reading through a ``ByteSource``. Owns everything it allocated and
/// releases it in the right order. Not thread-safe: use it from one thread (or one serial queue) at a time.
final class FormatContext {
    /// Upper bounds that keep opening fast: header data and the first packets are enough.
    static let probeSize = "4194304"            // 4 MB
    static let analyzeDuration = "2000000"      // 2 s of stream time, in microseconds

    let bridge: AVIOBridge
    private(set) var format: UnsafeMutablePointer<AVFormatContext>
    private var io: UnsafeMutablePointer<AVIOContext>?
    private var closed = false

    private init(bridge: AVIOBridge, format: UnsafeMutablePointer<AVFormatContext>, io: UnsafeMutablePointer<AVIOContext>) {
        self.bridge = bridge
        self.format = format
        self.io = io
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        var pointer: UnsafeMutablePointer<AVFormatContext>? = format
        avformat_close_input(&pointer)
        AVIOBridge.free(io)
        io = nil
    }

    /// Opens the source and reads enough to describe every stream. `quick` is for opening a file again whose duration is
    /// known already: FFmpeg then skips its duration estimate from the end of an MPEG transport or program stream, a jump
    /// to the end of the file and reads there (over a network, on every opening).
    static func open(source: any ByteSource, cancellation: CancellationFlag, quick: Bool = false) throws -> FormatContext {
        FFmpegLogging.ensureInstalled()
        let bridge = AVIOBridge(source: source, cancellation: cancellation)
        guard let io = bridge.makeContext() else { throw MediaError.engine(detail: "could not allocate I/O context") }
        guard let allocated = avformat_alloc_context() else {
            AVIOBridge.free(io)
            throw MediaError.engine(detail: "could not allocate format context")
        }
        allocated.pointee.pb = io
        allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        if quick { allocated.pointee.skip_estimate_duration_from_pts = 1 }

        var options: OpaquePointer?
        av_dict_set(&options, "probesize", probeSize, 0)
        av_dict_set(&options, "analyzeduration", analyzeDuration, 0)
        defer { av_dict_free(&options) }

        var opened: UnsafeMutablePointer<AVFormatContext>? = allocated
        let openResult = avformat_open_input(&opened, nil, nil, &options)
        guard openResult >= 0, let format = opened else {
            AVIOBridge.free(io)
            throw openError(openResult, bridge)
        }
        let context = FormatContext(bridge: bridge, format: format, io: io)

        let infoResult = avformat_find_stream_info(format, nil)
        if bridge.cancellation.isCancelled { throw MediaError.cancelled }
        if infoResult < 0, format.pointee.nb_streams == 0 { throw openError(infoResult, bridge) }
        guard format.pointee.nb_streams > 0 else { throw MediaError.corrupt(detail: "no tracks") }
        return context
    }

    static func openError(_ code: Int32, _ bridge: AVIOBridge) -> MediaError {
        if bridge.cancellation.isCancelled || code == AVError.exit { return .cancelled }
        if let failure = bridge.failure.withLock({ $0 }) {
            return (failure as? MediaError) ?? .unreadable(detail: "\(type(of: failure))")
        }
        if code == AVError.invalidData || code == AVError.eof { return .notMedia }
        return .corrupt(detail: AVError.describe(code))
    }
}
