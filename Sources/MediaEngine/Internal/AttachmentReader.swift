internal import FFmpegLGPL
import Foundation

/// Reads one attachment (font, cover art) out of an opened container.
enum AttachmentReader {
    static let sizeLimit = 32 * 1024 * 1024

    static func read(_ attachment: Attachment, from source: any ByteSource, cancellation: CancellationFlag) throws -> Data {
        let context = try FormatContext.open(source: source, cancellation: cancellation, quick: true)
        return try bytes(of: attachment, in: context)
    }

    /// Several attachments (the fonts of a subtitle track) with one opening of the file instead of one each; the ones that
    /// cannot be read are left out.
    static func read(_ attachments: [Attachment], from source: any ByteSource, cancellation: CancellationFlag) throws -> [Int: Data] {
        let context = try FormatContext.open(source: source, cancellation: cancellation, quick: true)
        var result: [Int: Data] = [:]
        for attachment in attachments { result[attachment.id] = try? bytes(of: attachment, in: context) }
        return result
    }

    private static func bytes(of attachment: Attachment, in context: FormatContext) throws -> Data {
        let format = context.format
        guard attachment.id >= 0, attachment.id < Int(format.pointee.nb_streams),
              let stream = format.pointee.streams[attachment.id], let parameters = stream.pointee.codecpar else {
            throw MediaError.unsupported(detail: "no such attachment")
        }
        // Fonts and other attachments keep their bytes in the codec's extradata; cover pictures are attached packets.
        if parameters.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT {
            let size = Int(parameters.pointee.extradata_size)
            guard size <= sizeLimit else { throw MediaError.unsupported(detail: "attachment is too large") }
            guard let bytes = parameters.pointee.extradata, size > 0 else { return Data() }
            return Data(bytes: bytes, count: size)
        }
        if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
            let size = Int(stream.pointee.attached_pic.size)
            guard size <= sizeLimit else { throw MediaError.unsupported(detail: "attachment is too large") }
            guard let bytes = stream.pointee.attached_pic.data, size > 0 else { return Data() }
            return Data(bytes: bytes, count: size)
        }
        throw MediaError.unsupported(detail: "not an attachment")
    }
}
