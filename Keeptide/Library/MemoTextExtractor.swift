import AppKit
import Foundation

enum MemoTextExtractor {
    nonisolated static func editableText(from content: ResolvedContent) throws -> MemoExtractedText? {
        guard content.integrity == .complete,
              Set(content.representations.map(\.itemIndex)).count == 1 else {
            return nil
        }

        let representations = content.representations.sorted {
            if $0.itemIndex != $1.itemIndex { return $0.itemIndex < $1.itemIndex }
            return $0.representationIndex < $1.representationIndex
        }

        for representation in representations where ContentKind.isMarkdown(representation.typeIdentifier) {
            guard representation.storage == .portable,
                  let bytes = representation.bytes,
                  let text = String(data: bytes, encoding: .utf8) else {
                continue
            }
            return MemoExtractedText(
                text: text,
                sourceRepresentationType: representation.typeIdentifier
            )
        }

        for representation in representations where ClipboardTextDecoder.isTextType(representation.typeIdentifier) {
            guard representation.storage == .portable,
                  let bytes = representation.bytes,
                  let decoded = ClipboardTextDecoder.decodeText(
                    bytes,
                    typeIdentifier: representation.typeIdentifier,
                    maximumBytes: .max
                  ), !decoded.isTruncated else {
                continue
            }
            return MemoExtractedText(
                text: decoded.text,
                sourceRepresentationType: representation.typeIdentifier
            )
        }

        for representation in representations where isRTF(representation.typeIdentifier) {
            guard representation.storage == .portable,
                  let bytes = representation.bytes,
                  let text = rtfText(bytes) else {
                continue
            }
            return MemoExtractedText(text: text, sourceRepresentationType: representation.typeIdentifier)
        }

        for representation in representations where isHTML(representation.typeIdentifier) {
            guard representation.storage == .portable,
                  let bytes = representation.bytes,
                  let text = SafeHTMLTextParser.text(from: bytes) else {
                continue
            }
            return MemoExtractedText(text: text, sourceRepresentationType: representation.typeIdentifier)
        }

        return nil
    }

    private nonisolated static func isRTF(_ type: String) -> Bool {
        let normalized = type.lowercased()
        return normalized == "public.rtf" || normalized == "nsrtfpboardtype"
    }

    private nonisolated static func isHTML(_ type: String) -> Bool {
        let normalized = type.lowercased()
        return normalized == "public.html" || normalized == "apple html pasteboard type"
    }

    private nonisolated static func rtfText(_ data: Data) -> String? {
        guard !data.isEmpty,
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ) else {
            return nil
        }
        let range = NSRange(location: 0, length: attributed.length)
        var hasAttachment = false
        attributed.enumerateAttribute(.attachment, in: range) { value, _, stop in
            if value != nil {
                hasAttachment = true
                stop.pointee = true
            }
        }
        guard !hasAttachment,
              !attributed.string.unicodeScalars.contains(where: { $0.value == 0xFFFC }) else {
            return nil
        }
        return attributed.string
    }
}

/// A deliberately small text-only HTML reader. It does not instantiate WebKit or Foundation's HTML importer,
/// so markup cannot fetch subsidiary resources. Unsupported structure is rejected instead of being flattened
/// into text that might mean something different from the captured document.
private struct SafeHTMLTextParser {
    private static let inlineTags: Set<String> = [
        "a", "abbr", "b", "cite", "code", "del", "em", "i", "kbd", "mark", "q", "s", "small",
        "span", "strong", "sub", "sup", "time", "u", "var",
    ]
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "dd", "div", "dl", "dt", "figcaption",
        "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "html", "li", "main",
        "nav", "ol", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]
    private static let emptyTags: Set<String> = ["br", "hr"]

    private let input: String
    private var index: String.Index
    private var output = ""
    private var openTags: [String] = []

    private init(_ input: String) {
        self.input = input
        index = input.startIndex
    }

    nonisolated static func text(from data: Data) -> String? {
        guard let source = decode(data) else { return nil }
        var parser = Self(source)
        return parser.parse()
    }

    private nonisolated static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return String(data: data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0), encoding: .utf8)
    }

    private mutating func parse() -> String? {
        while index < input.endIndex {
            switch input[index] {
            case "<":
                guard parseTag() else { return nil }
            case "&":
                guard let entity = parseEntity() else { return nil }
                output.append(entity)
            default:
                output.append(input[index])
                index = input.index(after: index)
            }
        }
        guard openTags.isEmpty else { return nil }
        trimBoundaryNewlines()
        return output
    }

    private mutating func parseTag() -> Bool {
        if input[index...].hasPrefix("<!--") {
            guard let end = input[index...].range(of: "-->")?.upperBound else { return false }
            index = end
            return true
        }

        let contentStart = input.index(after: index)
        var cursor = contentStart
        var quote: Character?
        while cursor < input.endIndex {
            let character = input[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                break
            }
            cursor = input.index(after: cursor)
        }
        guard cursor < input.endIndex else { return false }
        let raw = input[contentStart..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
        index = input.index(after: cursor)
        guard !raw.isEmpty, raw.first != "!", raw.first != "?" else { return false }

        var body = raw[...]
        let isClosing = body.first == "/"
        if isClosing { body = body.dropFirst() }
        body = body.drop(while: { $0.isWhitespace })
        let name = String(body.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
        guard !name.isEmpty else { return false }
        guard Self.inlineTags.contains(name) || Self.blockTags.contains(name) || Self.emptyTags.contains(name) else {
            return false
        }

        let isEmpty = Self.emptyTags.contains(name) || raw.hasSuffix("/")
        if isClosing {
            guard !isEmpty, openTags.last == name else { return false }
            openTags.removeLast()
        } else if !isEmpty {
            openTags.append(name)
        }
        if Self.blockTags.contains(name) || Self.emptyTags.contains(name) {
            appendLineBreak()
        }
        return true
    }

    private mutating func parseEntity() -> Character? {
        let start = input.index(after: index)
        var end = start
        var length = 0
        while end < input.endIndex, input[end] != ";", length <= 16 {
            end = input.index(after: end)
            length += 1
        }
        guard end < input.endIndex, input[end] == ";", length <= 16 else { return nil }
        let token = String(input[start..<end])
        index = input.index(after: end)
        switch token {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            let value: UInt32?
            if token.hasPrefix("#x") || token.hasPrefix("#X") {
                value = UInt32(token.dropFirst(2), radix: 16)
            } else if token.hasPrefix("#") {
                value = UInt32(token.dropFirst(), radix: 10)
            } else {
                value = nil
            }
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
    }

    private mutating func appendLineBreak() {
        guard !output.isEmpty, output.last != "\n" else { return }
        output.append("\n")
    }

    private mutating func trimBoundaryNewlines() {
        while output.first == "\n" { output.removeFirst() }
        while output.last == "\n" { output.removeLast() }
    }
}
