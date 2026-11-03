import Foundation
import SwiftUI

/// Native, read-only rendering for an already parsed Markdown document.
/// Parsing belongs outside `body` so large documents can be prepared off the main actor.
struct MarkdownPreviewView: View {
    let document: MarkdownPreviewDocument

    init(document: MarkdownPreviewDocument) {
        self.document = document
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(document.blocks.indices, id: \.self) { index in
                blockView(document.blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(headingFont(level))
                .fontWeight(level < 4 ? .semibold : .medium)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let content):
            inlineText(content)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(3)

        case .unorderedList(let items):
            list(items: items, start: nil)

        case .orderedList(let start, let items):
            list(items: items, start: start)

        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.tertiary)
                    .frame(width: 3)
                    .accessibilityHidden(true)
                inlineText(content)
                    .font(.body)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)

        case .codeBlock(let language, let source):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(verbatim: language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(verbatim: "Code language: \(language)"))
                }
                ScrollView(.horizontal) {
                    Text(verbatim: source)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(Text(verbatim: "Code"))
                .accessibilityValue(Text(verbatim: source))
            }
        }
    }

    private func list(items: [MarkdownListItem], start: Int?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items.indices, id: \.self) { offset in
                let item = items[offset]
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    listMarker(item: item, number: start.map { $0 + offset })
                        .frame(minWidth: 20, alignment: .trailing)
                    inlineText(item.content)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    @ViewBuilder
    private func listMarker(item: MarkdownListItem, number: Int?) -> some View {
        switch item.checkState {
        case .unchecked:
            Image(systemName: "square")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: "Not completed"))
        case .checked:
            Image(systemName: "checkmark.square")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: "Completed"))
        case .none:
            if let number {
                Text(verbatim: "\(number).")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: "Item \(number)"))
            } else {
                Text(verbatim: "•")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: "List item"))
            }
        }
    }

    private func inlineText(_ content: [MarkdownInline]) -> Text {
        var attributed = AttributedString()
        for inline in content {
            switch inline {
            case .text(let value):
                attributed.append(AttributedString(value))
            case .link(let label, let destination):
                var piece = AttributedString(label)
                piece.link = destination.flatMap(safeDestination)
                attributed.append(piece)
            }
        }
        return Text(attributed)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }

    /// Keep the view safe even if a document is assembled without `MarkdownRenderer`.
    private func safeDestination(_ url: URL) -> URL? {
        let source = url.absoluteString
        guard !source.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        guard let scheme = url.scheme?.lowercased() else { return nil }
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
