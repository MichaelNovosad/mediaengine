import CoreVideo
import Foundation

/// What the software player does with pictures that are made of two interlaced fields.
public enum Deinterlacing: Sendable, Equatable {
    /// Pictures the file marks as interlaced are cleaned of combing, progressive pictures are left alone (the default).
    case automatic
    /// Every picture is shown as it was decoded.
    case off
}

/// Removes the combing of interlaced pictures with the engine's own code (never FFmpeg's GPL filters such as `yadif`).
///
/// The two fields of an interlaced picture were captured one field period apart. The field that was captured first is
/// kept as it is; each line of the other field is looked at against the kept lines above and below it. Where it lies
/// outside the range of its neighbours by more than a threshold it is a comb tooth of something that moved, and it is
/// replaced by an interpolation of the kept lines (along the direction of the edge that fits best); where it agrees with
/// them nothing moved, the line is kept, and still pictures keep their full vertical resolution. Single rate: one clean
/// picture per interlaced picture, so frame pacing is untouched.
enum Deinterlacer {
    /// How far a line may stick out of its neighbours, in 8-bit steps, before it counts as combing.
    static let threshold = 10

    /// Cleans `buffer` in place. `bits` is 8, or 10 for the P010-style buffers (samples in the upper bits of 16-bit words).
    static func apply(to buffer: CVPixelBuffer, topFieldFirst: Bool, bits: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane), height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let channels = plane == 0 ? 1 : 2                       // chroma is interleaved CbCr
            if bits == 8 {
                clean(base.assumingMemoryBound(to: UInt8.self), samplesPerRow: width * channels, rowStride: stride, height: height,
                      channels: channels, keepParity: topFieldFirst ? 0 : 1, threshold: threshold)
            } else {
                clean(base.assumingMemoryBound(to: UInt16.self), samplesPerRow: width * channels, rowStride: stride / 2, height: height,
                      channels: channels, keepParity: topFieldFirst ? 0 : 1, threshold: threshold << 8)
            }
        }
    }

    private static func clean<T: FixedWidthInteger & UnsignedInteger>(
        _ base: UnsafeMutablePointer<T>, samplesPerRow: Int, rowStride: Int, height: Int, channels: Int, keepParity: Int, threshold: Int
    ) {
        guard height >= 3, samplesPerRow > 0 else { return }
        var comb = [Bool](repeating: false, count: samplesPerRow)
        for y in 0..<height where y & 1 != keepParity {
            let own = base + y * rowStride
            let above = base + (y > 0 ? y - 1 : y + 1) * rowStride
            let below = base + (y + 1 < height ? y + 1 : y - 1) * rowStride
            // Where does the line stick out of the kept lines around it?
            var any = false
            for i in 0..<samplesPerRow {
                let a = Int(above[i]), b = Int(below[i]), w = Int(own[i])
                let isComb = w < min(a, b) - threshold || w > max(a, b) + threshold
                comb[i] = isComb
                any = any || isComb
            }
            guard any else { continue }
            for i in 0..<samplesPerRow {
                // A tooth of the comb, or next to one (the same channel one pixel away): flicker-free decisions.
                let near = comb[i] || (i >= channels && comb[i - channels]) || (i + channels < samplesPerRow && comb[i + channels])
                guard near else { continue }
                var bestSum = Int(above[i]) + Int(below[i])
                var bestDifference = abs(Int(above[i]) - Int(below[i]))
                // Edge-directed: along which diagonal do the kept lines agree best?
                if i >= channels, i + channels < samplesPerRow {
                    let left = i - channels, right = i + channels
                    let down = abs(Int(above[left]) - Int(below[right]))            // edge running from upper left to lower right
                    if down + threshold / 2 < bestDifference { bestDifference = down; bestSum = Int(above[left]) + Int(below[right]) }
                    let up = abs(Int(above[right]) - Int(below[left]))              // edge running from lower left to upper right
                    if up + threshold / 2 < bestDifference { bestDifference = up; bestSum = Int(above[right]) + Int(below[left]) }
                }
                own[i] = T(truncatingIfNeeded: (bestSum + 1) >> 1)
            }
        }
    }
}
