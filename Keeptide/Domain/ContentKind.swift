import Foundation
import UniformTypeIdentifiers

enum ContentKind: String, Codable, Sendable {
    case text, url, image, file, other

    private static let markdownTypeIdentifiers: Set<String> = [
        "net.daringfireball.markdown",
        "text/markdown",
    ]

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

    /// True only for pasteboard representations that explicitly identify Markdown source.
    /// Visible syntax in plain text is never used to infer a memo's editing kind.
    nonisolated static func isMarkdown(_ typeIdentifier: String) -> Bool {
        markdownTypeIdentifiers.contains(typeIdentifier.lowercased())
    }
}
