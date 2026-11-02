import Foundation

/// A local-only representation of the small Markdown subset Keeptide previews.
///
/// Parsing never resolves resources. Consumers render these value types with native
/// controls and copy `source` when the user asks to reuse the item.
struct MarkdownPreviewDocument: Equatable, Sendable {
    var source: String
    var blocks: [MarkdownBlock]

    /// Markdown previews do not have an external-resource loading phase.
    var externalResources: [URL] { [] }

    var copySource: String { source }
}

enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    case unorderedList([MarkdownListItem])
    case orderedList(start: Int, items: [MarkdownListItem])
    case quote([MarkdownInline])
    case codeBlock(language: String?, source: String)
}

struct MarkdownListItem: Equatable, Sendable {
    enum CheckState: Equatable, Sendable {
        case none
        case unchecked
        case checked
    }

    var checkState: CheckState
    var content: [MarkdownInline]
}

enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case link(label: String, destination: URL?)
}

enum MarkdownRenderer {
    /// Parses Keeptide's restricted Markdown subset without WebKit, networking, or
    /// attachment resolution. Unsupported and incomplete syntax remains visible text.
    static func parse(_ source: String) -> MarkdownPreviewDocument {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].isEmpty {
                index += 1
                continue
            }

            if let fence = fenceOpening(lines[index]) {
                var closingIndex = index + 1
                while closingIndex < lines.count, !isFenceClosing(lines[closingIndex]) {
                    closingIndex += 1
                }
                if closingIndex < lines.count {
                    let body = lines[(index + 1)..<closingIndex].joined(separator: "\n")
                    blocks.append(.codeBlock(language: fence.isEmpty ? nil : fence, source: body))
                    index = closingIndex + 1
                    continue
                }
            }

            if let heading = heading(lines[index]) {
                blocks.append(.heading(level: heading.level, content: parseInline(heading.content)))
                index += 1
                continue
            }

            if let item = unorderedItem(lines[index]) {
                var items = [listItem(item)]
                index += 1
                while index < lines.count, let next = unorderedItem(lines[index]) {
                    items.append(listItem(next))
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(lines[index]) {
                var items = [listItem(item.content)]
                index += 1
                while index < lines.count, let next = orderedItem(lines[index]) {
                    items.append(listItem(next.content))
                    index += 1
                }
                blocks.append(.orderedList(start: item.number, items: items))
                continue
            }

            if let quote = quote(lines[index]) {
                blocks.append(.quote(parseInline(quote)))
                index += 1
                continue
            }

            var paragraphLines: [Substring] = [lines[index]]
            index += 1
            while index < lines.count,
                  !lines[index].isEmpty,
                  !startsBlock(lines[index]) {
                paragraphLines.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(parseInline(paragraphLines.joined(separator: "\n"))))
        }

        return MarkdownPreviewDocument(source: source, blocks: blocks)
    }

    private static func startsBlock(_ line: Substring) -> Bool {
        fenceOpening(line) != nil
            || heading(line) != nil
            || unorderedItem(line) != nil
            || orderedItem(line) != nil
            || quote(line) != nil
    }

    private static func fenceOpening(_ line: Substring) -> String? {
        guard line.hasPrefix("```") else { return nil }
        let hint = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard !hint.contains("`") else { return nil }
        return hint
    }

    private static func isFenceClosing(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "```"
    }

    private static func heading(_ line: Substring) -> (level: Int, content: String)? {
        var level = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == "#", level < 6 {
            level += 1
            cursor = line.index(after: cursor)
        }
        guard level > 0, cursor < line.endIndex, line[cursor] == " " else { return nil }
        return (level, String(line[line.index(after: cursor)...]))
    }

    private static func unorderedItem(_ line: Substring) -> String? {
        guard line.count >= 2,
              let marker = line.first,
              marker == "-" || marker == "*" || marker == "+" else { return nil }
        let space = line.index(after: line.startIndex)
        guard line[space] == " " else { return nil }
        return String(line[line.index(after: space)...])
    }

    private static func orderedItem(_ line: Substring) -> (number: Int, content: String)? {
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor].isNumber {
            cursor = line.index(after: cursor)
        }
        guard cursor > line.startIndex,
              cursor < line.endIndex,
              line[cursor] == "." else { return nil }
        let space = line.index(after: cursor)
        guard space < line.endIndex, line[space] == " ",
              let number = Int(line[line.startIndex..<cursor]) else { return nil }
        return (number, String(line[line.index(after: space)...]))
    }

    private static func quote(_ line: Substring) -> String? {
        guard line.hasPrefix("> ") else { return nil }
        return String(line.dropFirst(2))
    }

    private static func listItem(_ source: String) -> MarkdownListItem {
        if source.hasPrefix("[ ] ") {
            return MarkdownListItem(checkState: .unchecked, content: parseInline(String(source.dropFirst(4))))
        }
        if source.hasPrefix("[x] ") || source.hasPrefix("[X] ") {
            return MarkdownListItem(checkState: .checked, content: parseInline(String(source.dropFirst(4))))
        }
        return MarkdownListItem(checkState: .none, content: parseInline(source))
    }

    private static func parseInline(_ source: String) -> [MarkdownInline] {
        if looksLikeRawHTML(source) { return [.text(source)] }

        let characters = Array(source)
        var result: [MarkdownInline] = []
        var text = ""
        var cursor = 0

        func flushText() {
            guard !text.isEmpty else { return }
            result.append(.text(text))
            text.removeAll(keepingCapacity: true)
        }

        while cursor < characters.count {
            guard characters[cursor] == "[",
                  (cursor == 0 || characters[cursor - 1] != "!") else {
                text.append(characters[cursor])
                cursor += 1
                continue
            }

            var labelEnd = cursor + 1
            while labelEnd < characters.count, characters[labelEnd] != "]" {
                labelEnd += 1
            }
            guard labelEnd < characters.count else {
                text.append(contentsOf: characters[cursor...])
                break
            }

            let opening = labelEnd + 1
            guard opening < characters.count, characters[opening] == "(" else {
                text.append(contentsOf: characters[cursor...labelEnd])
                cursor = opening
                continue
            }

            var destinationEnd = opening + 1
            var depth = 1
            while destinationEnd < characters.count, depth > 0 {
                switch characters[destinationEnd] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth > 0 { destinationEnd += 1 }
            }
            guard depth == 0 else {
                text.append(contentsOf: characters[cursor...])
                break
            }

            flushText()
            let label = String(characters[(cursor + 1)..<labelEnd])
            let destination = String(characters[(opening + 1)..<destinationEnd])
            result.append(.link(label: label, destination: safeURL(destination)))
            cursor = destinationEnd + 1
        }
        flushText()
        return result
    }

    private static func looksLikeRawHTML(_ source: String) -> Bool {
        guard let opening = source.firstIndex(of: "<") else { return false }
        return source[opening...].contains(">")
    }

    private static func safeURL(_ source: String) -> URL? {
        guard !source.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        guard let url = URL(string: source),
              let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https":
            return url.host == nil ? nil : url
        case "mailto":
            return url.path.isEmpty ? nil : url
        default:
            return nil
        }
    }
}
