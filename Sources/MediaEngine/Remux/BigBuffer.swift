import Darwin
import Foundation

/// Memory for buffers of megabytes that goes back to the system the moment it is released.
///
/// Blocks that `malloc` hands out for such sizes are kept by the allocator after they are freed, and the process
/// footprint (what iOS counts against the app) keeps them. A segment is built and dropped over and over, so those
/// blocks pile up; pages from `mmap` do not.
enum BigBuffer {
    /// Below this size an ordinary `Data` is fine.
    static let threshold = 512 * 1024

    /// A `Data` of `count` bytes that `fill` writes. It is not growable, which suits finished fragments.
    static func make(count: Int, _ fill: (UnsafeMutableRawBufferPointer) -> Void) -> Data {
        if count >= threshold {
            let page = Int(getpagesize())
            let mapped = (count + page - 1) / page * page
            let base = mmap(nil, mapped, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
            if let base, base != MAP_FAILED {
                fill(UnsafeMutableRawBufferPointer(start: base, count: count))
                return Data(bytesNoCopy: base, count: count, deallocator: .custom { pointer, _ in munmap(pointer, mapped) })
            }
        }
        var data = Data(count: count)
        data.withUnsafeMutableBytes(fill)
        return data
    }
}
