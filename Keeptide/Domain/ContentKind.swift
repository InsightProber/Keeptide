import Foundation
import UniformTypeIdentifiers

enum ContentKind: String, Codable, Sendable {
    case text, url, image, file, other

    /// Classifies a capture from its representation types alone, without reading payloads.
    static func classify(typeIdentifiers: [String], hasLocalReference: Bool) -> ContentKind {
        let lowered = typeIdentifiers.map { $0.lowercased() }
        if hasLocalReference || lowered.contains("public.file-url") { return .file }
        if typeIdentifiers.contains(where: { UTType($0)?.conforms(to: .image) == true }) { return .image }
        if lowered.contains("public.url") { return .url }
        if typeIdentifiers.contains(where: isText) { return .text }
        return .other
    }

    /// Whether a representation of this type holds text or a link: the rule that makes a capture `.text`.
    static func isText(_ typeIdentifier: String) -> Bool {
        ClipboardTextDecoder.isTextType(typeIdentifier) || UTType(typeIdentifier)?.conforms(to: .text) == true
    }
}
