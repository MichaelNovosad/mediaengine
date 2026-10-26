import Foundation

/// One third-party component inside the engine's binaries: what an app must list in its licences screen.
///
/// The engine is built on FFmpeg under the LGPL and ships a few more libraries (see ``MediaEngine/acknowledgements``).
/// Show ``name``, ``license`` and ``licenseText`` for every entry, plus ``requiredNotice`` where it is not `nil`: some
/// licences (FreeType's, the LGPL's) make that a condition of shipping the binary.
public struct Acknowledgement: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    /// Display name, for example "FFmpeg (libavutil, libavcodec, libavformat, libswresample)".
    public var name: String
    public var version: String
    /// What the engine uses it for, in a sentence a person can read.
    public var usedFor: String
    /// SPDX identifier of the licence (`FTL` for the FreeType licence).
    public var license: String
    public var copyright: String?
    /// Words the licence asks every product that ships the component to show, for example FreeType's credit line.
    public var requiredNotice: String?
    /// Where the exact source archive this binary was built from can be downloaded.
    public var sourceURL: URL
    /// SHA-256 of that source archive.
    public var sha256: String
    /// The licence lets the person who receives the app replace this library with their own build (LGPL components).
    public var isReplaceable: Bool
    /// The full text of the licence.
    public var licenseText: String

    var includedIn: CodecProfile

    init(id: String, name: String, version: String, usedFor: String, license: String, copyright: String?, requiredNotice: String?,
         sourceURL: URL, sha256: String, isReplaceable: Bool, includedIn: CodecProfile, licenseText: String) {
        self.id = id; self.name = name; self.version = version; self.usedFor = usedFor; self.license = license
        self.copyright = copyright; self.requiredNotice = requiredNotice; self.sourceURL = sourceURL; self.sha256 = sha256
        self.isReplaceable = isReplaceable; self.includedIn = includedIn; self.licenseText = licenseText
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, usedFor, license, copyright, requiredNotice, sourceURL, sha256, isReplaceable, licenseText
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      version: values.decode(String.self, forKey: .version), usedFor: values.decode(String.self, forKey: .usedFor),
                      license: values.decode(String.self, forKey: .license), copyright: values.decodeIfPresent(String.self, forKey: .copyright),
                      requiredNotice: values.decodeIfPresent(String.self, forKey: .requiredNotice),
                      sourceURL: values.decode(URL.self, forKey: .sourceURL), sha256: values.decode(String.self, forKey: .sha256),
                      isReplaceable: values.decode(Bool.self, forKey: .isReplaceable), includedIn: .core,
                      licenseText: values.decode(String.self, forKey: .licenseText))
    }
}

extension MediaEngine {
    /// The third-party components inside the binaries of this build, with licence texts and source locations, for an app's
    /// licences screen. Only what is really linked is listed: the AV1 decoder appears in the extended build alone.
    ///
    /// ```swift
    /// ForEach(MediaEngine.acknowledgements) { item in
    ///     DisclosureGroup("\(item.name) \(item.version), \(item.license)") { Text(item.requiredNotice ?? ""); Text(item.licenseText) }
    /// }
    /// ```
    public static var acknowledgements: [Acknowledgement] {
        allAcknowledgements.filter { availableProfiles.isSuperset(of: $0.includedIn) }
    }
}
