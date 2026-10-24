internal import FFmpegLGPL
import Foundation
import Synchronization

/// FFmpeg error codes that are C macros and therefore not importable into Swift.
enum AVError {
    static let eof: Int32 = -541_478_725            // AVERROR_EOF
    static let exit: Int32 = -1_414_092_869         // AVERROR_EXIT
    static let invalidData: Int32 = -1_094_995_529  // AVERROR_INVALIDDATA
    static let io: Int32 = -5                       // AVERROR(EIO)
    static let again: Int32 = -35                   // AVERROR(EAGAIN) on Darwin

    static func describe(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return String(cBuffer: buffer)
    }
}

/// A flag that long-running engine work polls. Set from any thread.
final class CancellationFlag: Sendable {
    private let state = Mutex(false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// Connects a ``ByteSource`` to FFmpeg's custom I/O. One bridge serves one open file and is only read
/// from the thread that runs the demuxer, so `position` needs no lock.
final class AVIOBridge: @unchecked Sendable {
    let source: any ByteSource
    let cancellation: CancellationFlag
    /// The first error the byte source threw, so it can be reported instead of a generic I/O error.
    let failure = Mutex<(any Error)?>(nil)
    private var position: Int64 = 0

    init(source: any ByteSource, cancellation: CancellationFlag) {
        self.source = source
        self.cancellation = cancellation
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) -> Int32 {
        if cancellation.isCancelled { return AVError.exit }
        do {
            let count = try source.read(at: position, into: buffer)
            if cancellation.isCancelled { return AVError.exit }
            if count <= 0 { return AVError.eof }
            position += Int64(count)
            return Int32(count)
        } catch {
            failure.withLock { if $0 == nil { $0 = error } }
            return AVError.io
        }
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & AVSEEK_SIZE != 0 { return source.length ?? -1 }
        let target: Int64
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END:
            guard let length = source.length else { return -1 }
            target = length + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = target
        return target
    }

    /// Allocates the FFmpeg I/O context. The caller owns it and must free it with ``free(_:)`` after the
    /// format context is closed.
    func makeContext(bufferSize: Int = 64 * 1024) -> UnsafeMutablePointer<AVIOContext>? {
        guard let raw = av_malloc(bufferSize) else { return nil }
        let context = avio_alloc_context(
            raw.assumingMemoryBound(to: UInt8.self), Int32(bufferSize), 0,
            Unmanaged.passUnretained(self).toOpaque(), avioReadCallback, nil, avioSeekCallback)
        if context == nil { av_free(raw) }
        return context
    }

    static func free(_ context: UnsafeMutablePointer<AVIOContext>?) {
        guard let context else { return }
        av_free(context.pointee.buffer)
        var pointer: UnsafeMutablePointer<AVIOContext>? = context
        avio_context_free(&pointer)
    }
}

private func avioReadCallback(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buffer else { return AVError.io }
    let bridge = Unmanaged<AVIOBridge>.fromOpaque(opaque).takeUnretainedValue()
    return bridge.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(size)))
}

private func avioSeekCallback(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return -1 }
    return Unmanaged<AVIOBridge>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
}
