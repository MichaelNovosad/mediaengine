import AVFoundation
import Foundation
import Testing
@testable import MediaEngine

@Suite("Chapters")
struct ChapterTests {
    private func kind(_ title: String?) -> Chapter.Kind { Chapter.Kind.classify(title) }

    @Test("openings and endings are recognised in the forms release groups use")
    func openingsAndEndings() {
        for title in ["Opening", "opening", "OP", "OP1", "OP 2", "Opening 2", "Opening Theme", "NCOP", "NCOP1", "Opening #3", "OP (Song Title)", "オープニング", "Опенинг"] {
            #expect(kind(title) == .opening, "\(title)")
        }
        for title in ["Ending", "ED", "ED2", "Ending 1", "Ending Theme", "NCED", "エンディング", "Эндинг 2"] {
            #expect(kind(title) == .ending, "\(title)")
        }
    }

    @Test("other skippable parts")
    func others() {
        #expect(kind("Credits") == .credits && kind("End Credits") == .credits && kind("Closing Credits") == .credits)
        #expect(kind("Staff Roll") == .credits && kind("スタッフロール") == .credits)
        #expect(kind("Intro") == .intro && kind("Title Sequence") == .intro)
        #expect(kind("Recap") == .recap && kind("Previously on Show") == .recap && kind("前回のあらすじ") == .recap)
        #expect(kind("Preview") == .preview && kind("Next Episode Preview") == .preview && kind("次回予告") == .preview && kind("Next") == .preview)
    }

    @Test("story chapters, near misses and empty titles stay content")
    func content() {
        for title in ["Part A", "Chapter 3", "Opening Scene", "Ending Explained", "The Opening of the Door", "Operation Overlord",
                      "Edward", "Edge of Tomorrow", "Creditors", "Nextdoor", "", "   "] {
            #expect(kind(title) == .content, "\(title)")
        }
        #expect(kind(nil) == .content)
    }

    @Test("a chapter knows its kind and whether an app would offer to skip it")
    func chapterProperties() {
        let opening = Chapter(id: 1, start: 0, end: 90, title: "OP")
        let story = Chapter(id: 2, start: 90, end: 1300, title: "Part A")
        #expect(opening.kind == .opening && opening.isSkippable)
        #expect(story.kind == .content && !story.isSkippable)
        #expect(Chapter(id: 3, start: 0, end: 1, title: nil).isSkippable == false)
    }

    @Test("the anime fixture reads as opening, story, ending")
    func fixture() async throws {
        let info = try await Fixture.probe("fixture-anime")
        #expect(info.chapters.map(\.title) == ["Opening", "Part A", "Ending"])
        #expect(info.chapters.map(\.kind) == [.opening, .content, .ending])
        #expect(info.chapters.map(\.isSkippable) == [true, false, true])
    }
}

@Suite("Attachments")
struct AttachmentTests {
    @Test("fonts and cover pictures can be read out of the container")
    func reading() async throws {
        let source = try await MediaSource(url: Fixture.url("fixture-anime"))
        let info = try await source.probe()
        let font = try #require(info.attachments.first { $0.kind == .font })
        let cover = try #require(info.attachments.first { $0.kind == .coverArt })

        let fontBytes = try await source.data(of: font)
        #expect(fontBytes.count == font.byteCount && fontBytes.count > 100)
        let original = try Data(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/FakeFont.ttf"))
        #expect(fontBytes == original)

        let coverBytes = try await source.data(of: cover)
        #expect(coverBytes.count == cover.byteCount)
        #expect(coverBytes.starts(with: [0xFF, 0xD8, 0xFF]), "a JPEG")
        let coverOriginal = try Data(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/cover.jpg"))
        #expect(coverBytes == coverOriginal)
    }

    @Test("something that is not an attachment is refused")
    func refusing() async throws {
        let source = try await MediaSource(url: Fixture.url("fixture-anime"))
        await #expect(throws: MediaError.self) { _ = try await source.data(of: Attachment(id: 0, kind: .other, filename: nil, mimeType: nil, byteCount: nil)) }   // the video track
        await #expect(throws: MediaError.self) { _ = try await source.data(of: Attachment(id: 99, kind: .other, filename: nil, mimeType: nil, byteCount: nil)) }
        await #expect(throws: MediaError.self) { _ = try await source.data(of: Attachment(id: -1, kind: .other, filename: nil, mimeType: nil, byteCount: nil)) }
    }
}

@Suite("Player item metadata")
struct PlayerItemMetadataTests {
    @Test("title and artwork become metadata items, with the image type taken from the bytes")
    func external() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let items = PlayerItemMetadata.external(title: "A Movie", artwork: jpeg)
        #expect(items.count == 2)
        let title = try #require(items.first { $0.identifier == .commonIdentifierTitle })
        #expect(try await title.load(.stringValue) == "A Movie")
        let artwork = try #require(items.first { $0.identifier == .commonIdentifierArtwork })
        #expect(try await artwork.load(.dataValue) == jpeg)
        #expect(artwork.dataType == PlayerItemMetadata.imageType(of: jpeg))
        #expect(PlayerItemMetadata.imageType(of: png) != PlayerItemMetadata.imageType(of: jpeg))
        #expect(PlayerItemMetadata.imageType(of: Data([1, 2, 3])) == nil)
    }

    @Test("no title or an unknown image format gives no item for it")
    func gaps() {
        #expect(PlayerItemMetadata.external(title: nil, artwork: nil).isEmpty)
        #expect(PlayerItemMetadata.external(title: "", artwork: nil).isEmpty)
        #expect(PlayerItemMetadata.external(title: "T", artwork: Data([9, 9, 9])).count == 1)
    }

    #if !os(macOS)
    @MainActor
    @Test("a remuxed item carries the file's title and cover")
    func item() async throws {
        let session = try await PlaybackSession(url: Fixture.url("fixture-anime"))
        defer { session.close() }
        let item = try await session.makePlayerItem()
        let title = try #require(item.externalMetadata.first { $0.identifier == .commonIdentifierTitle })
        #expect(try await title.load(.stringValue) == "fixture-anime", "no title tag: the file name")
        let artwork = try #require(item.externalMetadata.first { $0.identifier == .commonIdentifierArtwork })
        #expect(try await artwork.load(.dataValue) == (try Data(contentsOf: Fixture.root.appendingPathComponent("Fixtures/src/cover.jpg"))))

        let basic = try await PlaybackSession(url: Fixture.url("fixture-basic"))
        defer { basic.close() }
        let basicItem = try await basic.makePlayerItem()
        let basicTitle = try #require(basicItem.externalMetadata.first { $0.identifier == .commonIdentifierTitle })
        #expect(try await basicTitle.load(.stringValue) == "MediaEngine fixture basic", "the title tag wins over the file name")
        #expect(basicItem.externalMetadata.first { $0.identifier == .commonIdentifierArtwork } == nil)
    }
    #endif
}
