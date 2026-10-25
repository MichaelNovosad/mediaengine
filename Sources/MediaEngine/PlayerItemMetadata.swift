import AVFoundation
import CoreMedia
import Foundation

/// What the system player shows besides the picture: the title and cover for Now Playing and the lock screen.
/// AVFoundation does not read Matroska tags and attachments, so the engine builds the items from what it probed.
/// (Chapter markers cannot be handed to the system player: `navigationMarkerGroups` is tvOS-only; see `Chapter.kind`.)
enum PlayerItemMetadata {
    /// Title and artwork for `AVPlayerItem.externalMetadata`.
    static func external(title: String?, artwork: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let title, !title.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            item.extendedLanguageTag = "und"
            items.append(item.copy() as! AVMetadataItem)
        }
        if let artwork, let type = imageType(of: artwork) {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.value = artwork as NSData
            item.dataType = type
            item.extendedLanguageTag = "und"
            items.append(item.copy() as! AVMetadataItem)
        }
        return items
    }

    /// JPEG or PNG, by the first bytes (the container's MIME type is often wrong or missing).
    static func imageType(of data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return kCMMetadataBaseDataType_JPEG as String }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return kCMMetadataBaseDataType_PNG as String }
        return nil
    }
}
