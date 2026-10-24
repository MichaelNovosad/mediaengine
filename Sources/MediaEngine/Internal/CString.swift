import Foundation

extension String {
    /// Builds a string from a null-terminated C character buffer.
    init(cBuffer buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
