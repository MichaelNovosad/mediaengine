import Foundation

/// Another file ("segment") that a Matroska file plays parts of. Identified by the segment UID the files carry.
public struct LinkedSegment: Sendable, Equatable, Hashable, Codable {
    /// The segment identifier as 32 hexadecimal digits.
    public var uid: String

    public init(uid: String) { self.uid = uid }
    init(data: Data) { uid = data.map { String(format: "%02x", $0) }.joined() }
}

/// The playback timeline of a Matroska file with an **ordered edition**: its chapters are a play list. Each chapter
/// plays a time range of this file or of another file, one after the other, and the file's own timeline is not the one
/// the viewer sees. (FFmpeg lists the chapters but plays the file straight through.)
public struct OrderedChapters: Sendable, Equatable, Codable {
    public struct Piece: Sendable, Equatable, Codable, Identifiable {
        public var id: Int
        public var title: String?
        /// The file this part comes from, or `nil` for this file.
        public var segment: LinkedSegment?
        /// The part's range in the time of its own file, in seconds.
        public var start: TimeInterval
        public var end: TimeInterval
        /// Where the part starts on the playback timeline.
        public var offset: TimeInterval
        public var duration: TimeInterval { end - start }
    }

    public var pieces: [Piece]
    /// Length of the whole play list, in seconds.
    public var duration: TimeInterval
    /// The other files the play list needs, each once, in order of first use.
    public var segments: [LinkedSegment]

    /// The play list of the edition that applies (the default one, else the first), or `nil` when the file has no ordered
    /// edition or its ordered edition just plays the file from start to end.
    static func make(editions: [MatroskaEdition], ownUID: Data?) -> OrderedChapters? {
        guard let edition = editions.first(where: \.isDefault) ?? editions.first, edition.isOrdered else { return nil }
        var pieces: [Piece] = []
        var offset = 0.0
        for atom in edition.atoms where atom.isEnabled {
            guard let end = atom.end, end > atom.start else { continue }
            var segment: LinkedSegment?
            if let uid = atom.segmentUID, !uid.isEmpty, !uid.allSatisfy({ $0 == 0 }), uid != ownUID { segment = LinkedSegment(data: uid) }
            pieces.append(Piece(id: pieces.count, title: atom.title, segment: segment, start: atom.start, end: end, offset: offset))
            offset += end - atom.start
        }
        guard !pieces.isEmpty else { return nil }
        // One piece of this very file, from its start: nothing to reorder.
        if pieces.count == 1, pieces[0].segment == nil, pieces[0].start == 0 { return nil }
        var segments: [LinkedSegment] = []
        for case let segment? in pieces.map(\.segment) where !segments.contains(segment) { segments.append(segment) }
        return OrderedChapters(pieces: pieces, duration: offset, segments: segments)
    }

    /// The same list with the parts of segments that are not available left out and the timeline closed up.
    func available(_ have: (LinkedSegment) -> Bool) -> OrderedChapters {
        var kept: [Piece] = []
        var offset = 0.0
        for var piece in pieces where piece.segment.map(have) ?? true {
            piece.id = kept.count
            piece.offset = offset
            offset += piece.duration
            kept.append(piece)
        }
        return OrderedChapters(pieces: kept, duration: offset, segments: segments.filter(have))
    }
}
