internal import FFmpegLGPL
import Foundation

/// Plays a play list (an ordered Matroska edition) as one file: the parts of this file and of other files, in order,
/// with timestamps on the play list's own timeline. The streams are the main file's; a part from another file is read
/// from the streams of that file that match them (same codec and configuration).
///
/// Parts start at the first video keyframe at or after their start (a part that begins in the middle of a GOP loses the
/// frames before the next keyframe) and end at their end time.
final class TimelineReader: PacketSource {
    struct Part {
        var source: Int                 // index into `readers`; 0 is the main file
        var start: Double               // seconds in the source's own time
        var end: Double
        var offset: Double              // seconds on the play list's timeline
        var duration: Double { end - start }
    }

    /// For one source: main stream -> the source's stream.
    private struct Mapping {
        var toSource: [Int: Int] = [:]
        var toMain: [Int: Int] = [:]
    }

    let parts: [Part]
    private let readers: [PacketReader]
    private let mappings: [Mapping]
    /// Parts whose source has no usable stream for the main file's video, left out.
    private(set) var incompatible: Set<Int> = []

    private var current = 0
    private var begun = false
    private var finished: Set<Int> = []
    private var awaitingKeyframe = false
    /// Main streams that are delivered, when ``limit(to:)`` narrowed them (the others never arrive, so nothing waits for them).
    private var limited: Set<Int>?
    private let epsilon = 0.001

    /// - Parameters:
    ///   - served: The main file's streams that matter: video, audio and subtitles, as stream indices.
    ///   - sources: The other files; `parts[i].source` counts the main file as 0 and these from 1.
    init(main: PacketReader, others: [PacketReader], parts: [Part], video: Int?, audio: [Int], subtitles: [Int]) {
        readers = [main] + others
        var maps: [Mapping] = []
        for (index, reader) in ([main] + others).enumerated() {
            if index == 0 {
                var identity = Mapping()
                for stream in [video].compactMap({ $0 }) + audio + subtitles { identity.toSource[stream] = stream; identity.toMain[stream] = stream }
                maps.append(identity)
            } else {
                maps.append(Self.match(main: main, other: reader, video: video, audio: audio, subtitles: subtitles))
            }
        }
        mappings = maps
        self.parts = parts
        for (index, part) in parts.enumerated() {
            if let video, maps[part.source].toSource[video] == nil { incompatible.insert(index) }
        }
    }

    /// Whether the part's source offers a stream for this main stream (false: that part has no sound or text for it).
    func covers(stream: Int, part index: Int) -> Bool { mappings[parts[index].source].toSource[stream] != nil }

    /// The main stream's coverage of the play list, as time ranges where it has data.
    func coverage(of stream: Int) -> [ClosedRange<Double>] {
        parts.indices.filter { !incompatible.contains($0) && covers(stream: stream, part: $0) }
            .map { parts[$0].offset...(parts[$0].offset + parts[$0].duration) }
    }

    // MARK: PacketSource (the main file's streams)

    func timeBase(_ index: Int) -> Rational { readers[0].timeBase(index) }
    func parameters(_ index: Int) -> UnsafeMutablePointer<AVCodecParameters> { readers[0].parameters(index) }
    func stream(_ index: Int) -> UnsafeMutablePointer<AVStream> { readers[0].stream(index) }

    func limit(to streams: Set<Int>) {
        limited = streams
        for (index, reader) in readers.enumerated() {
            reader.limit(to: Set(streams.compactMap { mappings[index].toSource[$0] }))
        }
    }

    func rewind() throws {
        current = 0
        begun = false
    }

    func seek(stream index: Int, to timestamp: Int64) throws {
        let seconds = timeBase(index).seconds(timestamp)
        guard let target = parts.indices.last(where: { !incompatible.contains($0) && parts[$0].offset <= seconds + epsilon }) else {
            current = 0; begun = false; return
        }
        let part = parts[target]
        current = target
        guard let sourceStream = mappings[part.source].toSource[index] ?? mappings[part.source].toSource.values.first else { begun = false; return }
        let reader = readers[part.source]
        let local = min(max(seconds - part.offset + part.start, part.start), part.end)
        if local <= epsilon { try reader.rewind() } else { try reader.seek(stream: sourceStream, to: reader.timeBase(sourceStream).ticks(seconds: local)) }
        begun = true
        awaitingKeyframe = false
        finished = []
    }

    func next() throws -> MediaPacket? {
        while current < parts.count {
            if incompatible.contains(current) { current += 1; begun = false; continue }
            let part = parts[current]
            let mapping = mappings[part.source]
            let reader = readers[part.source]
            if !begun { try begin(part, reader: reader, mapping: mapping) }

            guard var packet = try reader.next() else { advance(); continue }
            guard let main = mapping.toMain[packet.stream] else { continue }
            let sourceBase = reader.timeBase(packet.stream), mainBase = timeBase(main)
            let seconds = sourceBase.seconds(packet.pts)
            let length = sourceBase.seconds(max(packet.duration, 0))

            if seconds >= part.end - epsilon {
                finished.insert(main)
                if required(mapping).isSubset(of: finished) { advance() }
                continue
            }
            // A frame belongs to the part it starts in (the first part also keeps a frame that straddles its start).
            if part.start > epsilon ? seconds < part.start - epsilon : seconds + length <= part.start + epsilon { continue }
            if main == mappedVideo(mapping) {
                if awaitingKeyframe {
                    guard packet.isKeyframe, seconds >= part.start - epsilon else { continue }
                    awaitingKeyframe = false
                } else if seconds < part.start - epsilon, !packet.isKeyframe { continue }
            }

            let shift = part.offset - part.start
            packet.stream = main
            packet.pts = mainBase.ticks(seconds: seconds + shift)
            packet.dts = mainBase.ticks(seconds: sourceBase.seconds(packet.dts) + shift)
            packet.duration = max(packet.duration, 0) == 0 ? 0 : mainBase.ticks(seconds: length)
            packet.position = -1
            return packet
        }
        return nil
    }

    func keyframeIndex(stream index: Int, loadingIndexUpTo duration: Double?) -> [(timestamp: Int64, position: Int64?)] {
        defer { current = 0; begun = false }
        let mainBase = timeBase(index)
        var result: [(timestamp: Int64, position: Int64?)] = []
        for (number, part) in parts.enumerated() where !incompatible.contains(number) {
            let mapping = mappings[part.source]
            guard let sourceStream = mapping.toSource[index] else { continue }
            let reader = readers[part.source]
            let sourceBase = reader.timeBase(sourceStream)
            result.append((mainBase.ticks(seconds: part.offset), nil))                    // every part starts a segment
            for entry in reader.keyframeIndex(stream: sourceStream, loadingIndexUpTo: part.end) {
                let seconds = sourceBase.seconds(entry.timestamp)
                guard seconds > part.start + epsilon, seconds < part.end - epsilon else { continue }
                result.append((mainBase.ticks(seconds: seconds - part.start + part.offset), nil))
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: Internals

    private func begin(_ part: Part, reader: PacketReader, mapping: Mapping) throws {
        let anchor = mappedVideo(mapping).flatMap { mapping.toSource[$0] } ?? mapping.toSource.values.first
        if part.start <= epsilon || anchor == nil {
            try reader.rewind()
        } else if let anchor {
            try reader.seek(stream: anchor, to: reader.timeBase(anchor).ticks(seconds: part.start))
        }
        begun = true
        finished = []
        awaitingKeyframe = mappedVideo(mapping).map { limited?.contains($0) ?? true } ?? false
    }

    private func advance() {
        current += 1
        begun = false
    }

    private func mappedVideo(_ mapping: Mapping) -> Int? {
        for main in mapping.toMain.values where readers[0].parameters(main).pointee.codec_type == AVMEDIA_TYPE_VIDEO { return main }
        return nil
    }

    /// Main streams a part must have passed the end of before the next part starts: its video and audio.
    private func required(_ mapping: Mapping) -> Set<Int> {
        Set(mapping.toMain.values.filter {
            let type = readers[0].parameters($0).pointee.codec_type
            return (type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO) && (limited?.contains($0) ?? true)
        })
    }

    // MARK: Matching streams of another file to the main file's

    private static func match(main: PacketReader, other: PacketReader, video: Int?, audio: [Int], subtitles: [Int]) -> Mapping {
        var mapping = Mapping()
        var taken = Set<Int>()
        func language(_ reader: PacketReader, _ index: Int) -> String? {
            av_dict_get(reader.stream(index).pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) }
        }
        func extradata(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Data {
            par.pointee.extradata.map { Data(bytes: $0, count: Int(par.pointee.extradata_size)) } ?? Data()
        }
        func compatible(_ a: UnsafeMutablePointer<AVCodecParameters>, _ b: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
            guard a.pointee.codec_type == b.pointee.codec_type, a.pointee.codec_id == b.pointee.codec_id else { return false }
            switch a.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                return a.pointee.width == b.pointee.width && a.pointee.height == b.pointee.height && extradata(a) == extradata(b)
            case AVMEDIA_TYPE_AUDIO:
                return a.pointee.sample_rate == b.pointee.sample_rate && a.pointee.ch_layout.nb_channels == b.pointee.ch_layout.nb_channels
                    && extradata(a) == extradata(b)
            default:
                return true
            }
        }
        func assign(_ mainStream: Int) {
            let candidates = (0..<other.streamCount).filter { !taken.contains($0) && compatible(main.parameters(mainStream), other.parameters($0)) }
            let wanted = language(main, mainStream)
            guard let pick = candidates.first(where: { wanted != nil && language(other, $0) == wanted }) ?? candidates.first else { return }
            taken.insert(pick)
            mapping.toSource[mainStream] = pick
            mapping.toMain[pick] = mainStream
        }
        if let video { assign(video) }
        audio.forEach(assign)
        subtitles.forEach(assign)
        return mapping
    }
}
