import Darwin
import Foundation

/// Reads a local file with positional reads, so several threads can read it at once.
///
/// Security-scoped URLs (from the system file picker) are handled: access is started when the source is
/// created and stopped when it is released, so keep the source alive while the file is in use.
public final class FileByteSource: ByteSource {
    public let length: Int64?
    private let descriptor: Int32
    private let scopedURL: URL?

    public init(url: URL) throws {
        guard url.isFileURL else { throw MediaError.unreadable(detail: "not a file URL") }
        let scoped = url.startAccessingSecurityScopedResource()
        let fd = Darwin.open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw MediaError.unreadable(detail: "open failed: \(reason)")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw MediaError.unreadable(detail: "not a regular file")
        }
        self.descriptor = fd
        self.length = Int64(info.st_size)
        self.scopedURL = scoped ? url : nil
    }

    deinit {
        Darwin.close(descriptor)
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard offset >= 0 else { throw MediaError.unreadable(detail: "negative offset") }
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        while true {
            let count = pread(descriptor, base, buffer.count, off_t(offset))
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw MediaError.unreadable(detail: "read failed: \(String(cString: strerror(errno)))")
        }
    }
}
