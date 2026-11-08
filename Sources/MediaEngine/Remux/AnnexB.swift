internal import FFmpegLGPL
import Foundation

/// H.264 and HEVC as MPEG-TS, AVI and raw streams carry them ("Annex B": NAL units behind start codes, parameter sets
/// inside the stream) have to become what MP4 and fragmented MP4 hold (NAL units behind four-byte lengths, parameter
/// sets in the decoder configuration), because AVPlayer reads only that. Matroska and MP4 already store the second form.
enum AnnexB {
    enum Codec { case h264, hevc }

    /// The codec of a stream that needs converting: H.264 or HEVC without a decoder configuration record (avcC and hvcC
    /// start with the version byte 1; Annex B extradata starts with a start code, or there is none).
    static func codec(for parameters: UnsafeMutablePointer<AVCodecParameters>) -> Codec? {
        let codec: Codec
        switch parameters.pointee.codec_id {
        case AV_CODEC_ID_H264: codec = .h264
        case AV_CODEC_ID_HEVC: codec = .hevc
        default: return nil
        }
        if parameters.pointee.extradata_size > 0, let data = parameters.pointee.extradata, data[0] == 1 { return nil }
        return codec
    }

    static func nalType(_ firstByte: UInt8, _ codec: Codec) -> Int {
        codec == .h264 ? Int(firstByte & 0x1F) : Int((firstByte >> 1) & 0x3F)
    }

    static func isParameterSet(_ type: Int, _ codec: Codec) -> Bool { codec == .h264 ? (type == 7 || type == 8) : (32...34).contains(type) }
    private static func isDelimiter(_ type: Int, _ codec: Codec) -> Bool { codec == .h264 ? type == 9 : type == 35 }

    /// The NAL units of an Annex B buffer, as ranges without their start codes (three- and four-byte start codes, trailing
    /// zero bytes removed). Empty when the buffer holds no start code.
    static func units(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        var index = 0
        let count = bytes.count
        func close(at limit: Int) {
            guard let begin = start else { return }
            var end = limit
            while end > begin, bytes[end - 1] == 0 { end -= 1 }
            if end > begin { result.append(begin..<end) }
        }
        while index + 2 < count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                close(at: index)
                start = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        close(at: count)
        return result
    }

    /// An access unit as length-prefixed NAL units, without delimiters. Parameter sets the decoder configuration holds
    /// (`configuration`, by NAL type) are dropped: they live there. A stream that brings different ones keeps them in its
    /// samples from then on (`keepsSets` turns on and stays on), so the decoder reads every frame with the sets that belong to
    /// it: Blu-ray files often start with a separately encoded opening, and dropping the film's own sets made every frame
    /// after the first group of pictures undecodable (2026-11-08). Data without start codes comes back unchanged.
    static func convert(_ data: Data, codec: Codec, configuration: [Int: [Data]], keepsSets: inout Bool) -> Data {
        data.withUnsafeBytes { raw -> Data in
            let bytes = raw.bindMemory(to: UInt8.self)
            let units = units(in: bytes)
            guard !units.isEmpty else { return data }
            if !keepsSets {
                for range in units {
                    let type = nalType(bytes[range.lowerBound], codec)
                    if isParameterSet(type, codec), !(configuration[type] ?? []).contains(Data(bytes[range])) { keepsSets = true; break }
                }
            }
            var output = Data()
            output.reserveCapacity(data.count + 16)
            for range in units {
                let type = nalType(bytes[range.lowerBound], codec)
                if isParameterSet(type, codec), !keepsSets { continue }
                if isDelimiter(type, codec) { continue }
                var length = UInt32(range.count).bigEndian
                withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
                output.append(contentsOf: bytes[range])
            }
            return output
        }
    }

    /// The decoder configuration in Annex B form (what the MP4 muxer turns into avcC or hvcC), or `nil` while a needed
    /// parameter set is missing (H.264: SPS and PPS; HEVC: VPS, SPS and PPS).
    static func extradata(from sets: [Int: [Data]], codec: Codec) -> Data? {
        let order = codec == .h264 ? [7, 8] : [32, 33, 34]
        guard order.allSatisfy({ !(sets[$0] ?? []).isEmpty }) else { return nil }
        var output = Data()
        for type in order { for unit in sets[type] ?? [] { output.append(contentsOf: [0, 0, 0, 1]); output.append(unit) } }
        return output
    }
}
