import Foundation
import Testing
@testable import MediaEngine

@Suite("Decode timestamps")
struct DecodeTimestampTests {
    /// Packets in decode order; `dts` starts out equal to `pts`, as when the demuxer provides none.
    private func packets(_ frames: [Int64], unit: Int64 = 100) -> [MediaPacket] {
        frames.enumerated().map { index, frame in
            MediaPacket(stream: 0, data: Data(), pts: frame * unit, dts: frame * unit, duration: 0, isKeyframe: index == 0)
        }
    }

    private func repaired(_ frames: [Int64], declaredDelay: Int = 0) -> [Int64] {
        var list = packets(frames)
        ReorderModel.measure(list, declaredDelay: declaredDelay).repair(&list)
        return list.map(\.dts)
    }

    @Test("one B-frame between references: decode times start one frame early")
    func singleB() {
        #expect(repaired([0, 3, 1, 2, 6, 4, 5]) == [-100, 0, 100, 200, 300, 400, 500])
    }

    @Test("a reference pyramid needs two frames of lead")
    func pyramid() {
        #expect(repaired([0, 4, 2, 1, 3, 8, 6, 5, 7]) == [-200, -100, 0, 100, 200, 300, 400, 500, 600])
    }

    @Test("decode times never pass presentation times and always increase")
    func invariants() {
        for frames in [[0, 3, 1, 2, 6, 4, 5], [0, 4, 2, 1, 3, 8, 6, 5, 7], [0, 2, 1, 4, 3, 6, 5], [0, 1, 2, 3, 4]] as [[Int64]] {
            let list = packets(frames)
            var fixed = list
            ReorderModel.measure(list, declaredDelay: 0).repair(&fixed)
            for (a, b) in zip(fixed, fixed.dropFirst()) { #expect(a.dts < b.dts, "\(frames)") }
            for packet in fixed { #expect(packet.dts <= packet.pts, "\(frames)") }
        }
    }

    @Test("video without reordering and decode times that are already sound are left alone")
    func untouched() {
        #expect(repaired([0, 1, 2, 3, 4]) == [0, 100, 200, 300, 400])
        var real = packets([0, 3, 1, 2])
        for (index, dts) in [Int64(-100), 0, 100, 200].enumerated() { real[index].dts = dts }
        let before = real.map(\.dts)
        ReorderModel(delay: 1, frameTicks: 100).repair(&real)
        #expect(real.map(\.dts) == before)
    }

    @Test("the decoder's own idea of its reordering depth counts when the first run shows less")
    func declaredDelay() {
        let list = packets([0, 3, 1, 2])
        var fixed = list
        let model = ReorderModel.measure(list, declaredDelay: 2)
        #expect(model.delay == 2)
        model.repair(&fixed)
        #expect(fixed.map(\.dts) == [-200, -100, 0, 100])
    }

    @Test("neighbouring runs join without a gap, so segments built apart still tile")
    func runsJoin() {
        let model = ReorderModel.measure(packets([0, 3, 1, 2]), declaredDelay: 1)
        var first = packets([0, 3, 1, 2]), second = packets([4, 7, 5, 6])
        model.repair(&first); model.repair(&second)
        #expect(second[0].dts == first[3].dts + model.frameTicks)
    }

    @Test("equal presentation times still give increasing decode times")
    func ties() {
        var list = packets([0, 2, 1, 1])
        ReorderModel(delay: 1, frameTicks: 100).repair(&list)
        for (a, b) in zip(list, list.dropFirst()) { #expect(a.dts < b.dts) }
    }

    @Test("the frame gap is the typical gap, not the largest")
    func frameTicks() {
        let model = ReorderModel.measure(packets([0, 1, 2, 3, 12, 13]), declaredDelay: 0)
        #expect(model.frameTicks == 100)
    }
}
