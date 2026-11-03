import Foundation
import UniformTypeIdentifiers

struct ReadableExport: Equatable, Sendable {
    let data: Data
    let kind: ArchiveContentKind
    let representationID: UUID
}

struct ReadableExportEncoder: Sendable {
    private static let markdownType = UTType("net.daringfireball.markdown")

    func encode(content: ResolvedContent, records: [RecordValue]) -> ReadableExport? {
        let values = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        guard case .item(let item)? = values[.item(content.ref.itemID)] else { return nil }
        if content.ref.facet == .memo, let memoID = item.memoID,
           case .memo(let memo)? = values[.memo(memoID)], memo.bodyMode != .inheritedCapture,
           let body = memo.body {
            let kind: ArchiveContentKind = memo.bodyMode == .ownedMarkdown ? .markdown : .text
            return ReadableExport(data: body, kind: kind, representationID: memo.id)
        }
        guard let captureID = item.captureID,
              case .capture(let capture)? = values[.capture(captureID)] else { return nil }
        return capture.representations.sorted {
            let left = readableRank($0), right = readableRank($1)
            return left == right ? coordinateOrder($0, $1) : left < right
        }.compactMap(readable).first
    }

    private func readable(_ representation: RepresentationValue) -> ReadableExport? {
        guard representation.storage == .portable, let bytes = representation.bytes,
              let type = UTType(representation.typeIdentifier) else { return nil }
        let kind: ArchiveContentKind
        if Self.isMarkdown(type) { kind = .markdown }
        else if type.conforms(to: .url) { kind = .url }
        else if type.conforms(to: .text) { kind = .text }
        else { return nil }

        if type == .utf16PlainText || type == .utf16ExternalPlainText {
            guard let string = String(data: bytes, encoding: .utf16),
                  let converted = string.data(using: .utf8) else { return nil }
            return ReadableExport(data: converted, kind: kind, representationID: representation.id)
        }
        guard String(data: bytes, encoding: .utf8) != nil else { return nil }
        return ReadableExport(data: bytes, kind: kind, representationID: representation.id)
    }

    private func coordinateOrder(_ lhs: RepresentationValue, _ rhs: RepresentationValue) -> Bool {
        (lhs.itemIndex, lhs.representationIndex) < (rhs.itemIndex, rhs.representationIndex)
    }

    private func readableRank(_ representation: RepresentationValue) -> Int {
        guard representation.storage == .portable, let type = UTType(representation.typeIdentifier) else { return 3 }
        if Self.isMarkdown(type) { return 0 }
        if type.conforms(to: .url) || type.conforms(to: .text) { return 1 }
        return 2
    }

    private static func isMarkdown(_ type: UTType) -> Bool {
        guard let markdownType else { return type.identifier == "net.daringfireball.markdown" }
        return type.identifier == markdownType.identifier || type.conforms(to: markdownType)
    }
}
