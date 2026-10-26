import Foundation
import Testing
@testable import MediaEngine

private let isExtendedBuild = MediaEngine.availableProfiles.contains(.extended)

/// LIC-4: the third-party notices are available at run time as structured data and cannot drift from the pinned sources.
@Suite("Acknowledgements")
struct AcknowledgementsTests {
    private struct Pin { var version: String, url: String, sha256: String }

    private static func lock() throws -> [String: Pin] {
        let text = try String(contentsOf: Fixture.root.appendingPathComponent("third_party/sources.lock"), encoding: .utf8)
        var pins: [String: Pin] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields.count >= 4 { pins[fields[0]] = Pin(version: fields[1], url: fields[2], sha256: fields[3]) }
        }
        return pins
    }

    @Test("every entry matches the pinned source: version, archive address and checksum (run scripts/gen-acknowledgements.py after changing a pin)")
    func matchesPins() throws {
        let pins = try Self.lock()
        for entry in MediaEngine.allAcknowledgements {
            let pin = try #require(pins[entry.id], "no pin for \(entry.id)")
            #expect(entry.version == pin.version && entry.sourceURL.absoluteString == pin.url && entry.sha256 == pin.sha256, "\(entry.id) is stale")
        }
        let listed = Set(MediaEngine.allAcknowledgements.map(\.id))
        #expect(listed == Set(pins.keys), "pinned but not acknowledged: \(Set(pins.keys).subtracting(listed)), acknowledged but not pinned: \(listed.subtracting(pins.keys))")
    }

    @Test("what this build links is listed: FFmpeg and the subtitle libraries always, the AV1 decoder only in the extended build")
    func contentsFollowTheBuild() {
        let ids = Set(MediaEngine.acknowledgements.map(\.id))
        #expect(ids.isSuperset(of: ["ffmpeg", "libass", "freetype", "harfbuzz", "fribidi", "libunibreak"]))
        #expect(ids.contains("dav1d") == isExtendedBuild, "\(ids)")
    }

    @Test("FFmpeg's entry names the version that is linked and the LGPL, and says the library can be replaced")
    func ffmpegEntry() throws {
        let entry = try #require(MediaEngine.acknowledgements.first { $0.id == "ffmpeg" })
        #expect(entry.version == MediaEngine.buildInfo.ffmpegVersion)
        #expect(entry.license == "LGPL-2.1-or-later" && entry.isReplaceable)
        #expect(entry.licenseText.contains("GNU LESSER GENERAL PUBLIC LICENSE") && entry.licenseText.contains("Version 2.1"))
        #expect(entry.requiredNotice?.contains("LGPLv2.1") == true)
    }

    @Test("every entry carries its licence text, and FreeType its credit line")
    func texts() throws {
        let phrases = ["ffmpeg": "LESSER GENERAL PUBLIC LICENSE", "fribidi": "LESSER GENERAL PUBLIC LICENSE", "libass": "Permission to use, copy, modify",
                       "freetype": "FreeType", "harfbuzz": "Permission is hereby granted", "dav1d": "Redistribution and use in source and binary forms",
                       "libunibreak": "provided 'as-is'"]
        for entry in MediaEngine.acknowledgements {
            #expect(entry.licenseText.count > 500 && entry.licenseText.contains(phrases[entry.id] ?? "?"), "\(entry.id)")
            #expect(!entry.usedFor.isEmpty && entry.sha256.count == 64 && entry.sourceURL.scheme == "https")
        }
        let freetype = try #require(MediaEngine.acknowledgements.first { $0.id == "freetype" })
        #expect(freetype.requiredNotice?.contains("The FreeType Project") == true)
    }

    @Test("the list can be saved and read back (for an app that prints its own licences page)")
    func codable() throws {
        let data = try JSONEncoder().encode(MediaEngine.acknowledgements)
        let back = try JSONDecoder().decode([Acknowledgement].self, from: data)
        #expect(back.map(\.id) == MediaEngine.acknowledgements.map(\.id) && back.map(\.licenseText) == MediaEngine.acknowledgements.map(\.licenseText))
    }

    @Test("a GPL component never appears in the list")
    func noGPL() {
        for entry in MediaEngine.allAcknowledgements { #expect(!entry.license.contains("GPL") || entry.license.hasPrefix("LGPL"), "\(entry.id): \(entry.license)") }
    }
}
