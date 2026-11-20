internal import FFmpegLGPL
import AudioToolbox
import CoreMedia
import Foundation
import VideoToolbox

/// "Apple first" (owner, 2026-11-12): whether this device's own decoders (VideoToolbox, AudioToolbox, AVPlayer) can decode a stream.
/// The planner sends a stream to the engine's own decoders only when the answer is no. Asked once per stream at probe time; streams
/// in the profiles Apple always decodes are not asked (`nil`).
enum AppleDecoding {
    /// H.264 profiles every supported Apple device decodes: Baseline, Main, Extended, High (8-bit 4:2:0).
    static let alwaysH264Profiles: Set<Int> = [66, 77, 88, 100]
    /// HEVC profiles every supported Apple device decodes: Main, Main 10, Main Still Picture.
    static let alwaysHEVCProfiles: Set<Int> = [1, 2, 3]
    /// FFmpeg's AAC profiles (object type minus one) that Apple's AAC decoder does not play [believe]: Main, SSR, LTP.
    /// Apple plays LC, HE, HE v2, LD, ELD and xHE.
    static let aacProfilesAppleSkips: Set<Int> = [0, 2, 3]

    /// Whether Apple decodes this video stream, asked only outside the profiles above; `nil` when not asked or not askable.
    static func video(_ par: UnsafePointer<AVCodecParameters>, codec: Codec) -> Bool? {
        switch codec.name {
        case "h264":
            if let profile = codec.profileIdentifier, alwaysH264Profiles.contains(profile) { return nil }
            return decodesVideo(par, type: kCMVideoCodecType_H264, atom: "avcC")
        case "hevc":
            if let profile = codec.profileIdentifier, alwaysHEVCProfiles.contains(profile) { return nil }
            return decodesVideo(par, type: kCMVideoCodecType_HEVC, atom: "hvcC")
        default:
            return nil
        }
    }

    /// Whether Apple plays this audio stream; `nil` for codecs this question is not about.
    static func audio(_ codec: Codec) -> Bool? {
        switch codec.name {
        case "aac":
            guard hasAudioDecoder(kAudioFormatMPEG4AAC) else { return false }
            if let profile = codec.profileIdentifier, aacProfilesAppleSkips.contains(profile) { return false }
            return true
        case "ac3": return hasAudioDecoder(kAudioFormatAC3)
        case "eac3": return hasAudioDecoder(kAudioFormatEnhancedAC3)
        default: return nil
        }
    }

    /// Whether this device decodes Dolby Vision (profiles 5 and 8 are then passed to AVPlayer as Dolby Vision).
    static var decodesDolbyVision: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC) }

    /// A VideoToolbox decoder session (hardware or Apple's software decoder) for the stream's own format description, built from
    /// its `avcC`/`hvcC` record. Streams whose extradata is not such a record (Annex B parameter sets, as in MPEG-TS) are not asked.
    private static func decodesVideo(_ par: UnsafePointer<AVCodecParameters>, type: CMVideoCodecType, atom: String) -> Bool? {
        guard let pointer = par.pointee.extradata, par.pointee.extradata_size > 0, pointer[0] == 1,
              let format = formatDescription(par, type: type, atom: atom) else { return nil }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        return status == noErr
    }

    /// The format description VideoToolbox decodes an H.264 or HEVC stream with: from its `avcC`/`hvcC` record (Matroska, MP4), or
    /// from the parameter sets of Annex B extradata (MPEG-TS and the like, whose packets ``PacketReader`` hands out with four-byte
    /// lengths). `nil` for other codecs or when a needed parameter set is missing.
    static func formatDescription(_ par: UnsafePointer<AVCodecParameters>) -> CMVideoFormatDescription? {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_H264: return formatDescription(par, type: kCMVideoCodecType_H264, atom: "avcC")
        case AV_CODEC_ID_HEVC: return formatDescription(par, type: kCMVideoCodecType_HEVC, atom: "hvcC")
        default: return nil
        }
    }

    private static func formatDescription(_ par: UnsafePointer<AVCodecParameters>, type: CMVideoCodecType, atom: String) -> CMVideoFormatDescription? {
        guard let pointer = par.pointee.extradata, par.pointee.extradata_size > 0, par.pointee.width > 0, par.pointee.height > 0 else { return nil }
        var format: CMVideoFormatDescription?
        if pointer[0] == 1 {
            let record = Data(bytes: pointer, count: Int(par.pointee.extradata_size))
            let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [atom: record]] as CFDictionary
            guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: type, width: par.pointee.width, height: par.pointee.height,
                                                 extensions: extensions, formatDescriptionOut: &format) == noErr else { return nil }
            return format
        }
        // Annex B: the parameter sets in the order the decoder wants them (H.264: SPS, PPS; HEVC: VPS, SPS, PPS).
        let codec: AnnexB.Codec = type == kCMVideoCodecType_H264 ? .h264 : .hevc
        let buffer = UnsafeBufferPointer(start: pointer, count: Int(par.pointee.extradata_size))
        var sets: [Int: [[UInt8]]] = [:]
        for range in AnnexB.units(in: buffer) {
            let kind = AnnexB.nalType(buffer[range.lowerBound], codec)
            if AnnexB.isParameterSet(kind, codec) { sets[kind, default: []].append(Array(buffer[range])) }
        }
        let order = codec == .h264 ? [7, 8] : [32, 33, 34]
        guard order.allSatisfy({ !(sets[$0] ?? []).isEmpty }) else { return nil }
        let units = order.flatMap { sets[$0] ?? [] }
        let joined = units.flatMap { $0 }
        let sizes = units.map(\.count)
        let status = joined.withUnsafeBufferPointer { all -> OSStatus in
            guard let base = all.baseAddress else { return -1 }
            var offset = 0
            let pointers = sizes.map { size -> UnsafePointer<UInt8> in defer { offset += size }; return base + offset }
            if codec == .h264 {
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: units.count, parameterSetPointers: pointers,
                                                                           parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: units.count, parameterSetPointers: pointers,
                                                                       parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                                                                       formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// Whether AudioToolbox has a decoder for the format.
    private static func hasAudioDecoder(_ formatID: AudioFormatID) -> Bool {
        var id = formatID
        var size: UInt32 = 0
        let status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, UInt32(MemoryLayout<AudioFormatID>.size), &id, &size)
        return status == noErr && size > 0
    }
}
