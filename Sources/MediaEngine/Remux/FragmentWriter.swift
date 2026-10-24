import Foundation

/// Writes media fragments (`moof` + `mdat`) for one track whose initialization segment came from
/// ``InitSegmentBuilder``. Each fragment stands alone, so segments can be produced in any order.
struct FragmentWriter: Sendable {
    var trackID: UInt32
    var timescale: Int32
    /// Time base of the packets handed in.
    var timeBase: Rational
    /// Video needs composition time offsets (frames are shown later than they are decoded).
    var hasCompositionOffsets: Bool
    /// Added to every timestamp, in `timeBase` ticks (same value for every track of a session).
    var shift: Int64

    private static let syncSample: UInt32 = 0x0200_0000
    private static let nonSyncSample: UInt32 = 0x0101_0000

    /// - Parameter nextDecodeTime: Decode time (in `timeBase` ticks, before `shift`) of the first sample of the
    ///   following segment, which fixes the last sample's duration exactly.
    /// - Returns: `nil` when there are no packets.
    func fragment(sequence: UInt32, packets: [MediaPacket], nextDecodeTime: Int64? = nil) -> Data? {
        guard !packets.isEmpty else { return nil }
        let target = Rational(num: 1, den: Int64(timescale))
        func convert(_ ticks: Int64) -> Int64 { timeBase.convert(ticks + shift, to: target) }

        let decodeTimes = packets.map { convert($0.dts) }
        var durations: [UInt32] = []
        for index in packets.indices {
            let following: Int64? = index + 1 < packets.count ? decodeTimes[index + 1] : nextDecodeTime.map(convert)
            let measured = following.map { $0 - decodeTimes[index] }
            let fallback = packets[index].duration > 0 ? timeBase.convert(packets[index].duration, to: target) : (durations.last.map(Int64.init) ?? 0)
            durations.append(UInt32(max(measured ?? fallback, 0)))
        }
        let offsets: [Int32] = packets.indices.map { Int32(clamping: convert(packets[$0].pts) - decodeTimes[$0]) }
        let baseDecodeTime = UInt64(max(decodeTimes[0], 0))

        func moof(dataOffset: Int32) -> Data {
            var writer = ByteWriter()
            writer.box("moof") { moof in
                moof.box("mfhd") { box in box.u32(0); box.u32(sequence) }
                moof.box("traf") { traf in
                    traf.box("tfhd") { box in box.u32(0x0002_0000); box.u32(trackID) }          // default-base-is-moof
                    traf.box("tfdt") { box in box.u32(0x0100_0000); box.u64(baseDecodeTime) }  // version 1
                    traf.box("trun") { box in
                        box.u32(hasCompositionOffsets ? 0x0100_0F01 : 0x0100_0701)              // version 1 + field flags
                        box.u32(UInt32(packets.count))
                        box.i32(dataOffset)
                        for index in packets.indices {
                            box.u32(durations[index])
                            box.u32(UInt32(packets[index].data.count))
                            box.u32(packets[index].isKeyframe || !hasCompositionOffsets ? Self.syncSample : Self.nonSyncSample)
                            if hasCompositionOffsets { box.i32(offsets[index]) }
                        }
                    }
                }
            }
            return writer.data
        }

        let moofSize = moof(dataOffset: 0).count
        let payload = packets.reduce(0) { $0 + $1.data.count }
        var output = ByteWriter(capacity: moofSize + 8 + payload)
        output.append(moof(dataOffset: Int32(moofSize + 8)))             // samples start right after the mdat header
        output.u32(UInt32(8 + payload))
        output.fourCC("mdat")
        for packet in packets { output.append(packet.data) }
        return output.data
    }
}
