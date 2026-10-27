import Foundation
import UniformTypeIdentifiers

enum ContentKind: String, Codable, Sendable {
    case text, url, image, file, other
}

struct TextRepresentation: Equatable, Sendable {
    let itemIndex: Int
    let representationIndex: Int
    let typeIdentifier: String
    let byteCount: Int64
    let digest: Data
    let bytes: Data
}

struct MemoProjection: Equatable, Sendable {
    let ref: ContentRef
    let memoID: UUID
    let title: String
    let note: String
    let isInherited: Bool
    /// UTF-8 body of an owned memo; nil for an inherited memo.
    let body: Data?
}

/// Raw values copied out of Core Data for one item. Decoding, digest checks and
/// normalization happen later, away from the store's writer queue.
struct SearchProjectionInput: Equatable, Sendable {
    let itemID: ItemID
    let title: String
    let sourceApp: String?
    let collectionID: CollectionID?
    let lastCopiedAt: Date
    let history: ContentRef?
    let memo: MemoProjection?
    let captureID: UUID?
    let representationTypes: [String]
    let hasLocalReference: Bool
    /// Portable text and URL representations only.
    let textRepresentations: [TextRepresentation]
}

struct SearchDocument: Equatable, Sendable {
    let ref: ContentRef
    let captureID: UUID?
    let memoID: UUID?
    /// An inherited memo also shown through its item's history row.
    let merged: Bool
    /// A history row that carries its inherited memo's title and note.
    let savedAsMemo: Bool
    let kind: ContentKind
    let sourceApp: String?
    let collectionID: CollectionID?
    let lastCopiedAt: Date
    let title: String
    let body: String
    let url: String
    let note: String
    let bodyPartial: Bool
    let textUnavailable: Bool
    let normalizedTitle: String
    let normalizedBody: String
    let normalizedURL: String
    let normalizedNote: String
}

enum SearchDocumentBuilder {
    static let extractorVersion = 1
    static let bodyByteLimit = 1_048_576

    static func documents(for input: SearchProjectionInput) -> [SearchDocument] {
        let capture = captureText(input.textRepresentations)
        let captureKind = kind(types: input.representationTypes, hasLocalReference: input.hasLocalReference)
        let merged = input.memo?.isInherited == true && input.history != nil
        var documents: [SearchDocument] = []
        if let history = input.history {
            let memo = merged ? input.memo : nil
            documents.append(document(
                ref: history, input: input, captureID: input.captureID, memoID: memo?.memoID,
                merged: false, savedAsMemo: merged, kind: captureKind, collectionID: nil,
                title: memo.map { title(of: $0, input: input) } ?? input.title,
                text: capture, note: memo?.note ?? ""
            ))
        }
        if let memo = input.memo {
            documents.append(document(
                ref: memo.ref, input: input, captureID: memo.isInherited ? input.captureID : nil,
                memoID: memo.memoID, merged: merged, savedAsMemo: false,
                kind: memo.isInherited ? captureKind : .text, collectionID: input.collectionID,
                title: title(of: memo, input: input),
                text: memo.isInherited ? capture : ownedText(memo.body), note: memo.note
            ))
        }
        return documents
    }

    private struct ExtractedText {
        var body = ""
        var url = ""
        var partial = false
        var unavailable = false
    }

    private static func document(
        ref: ContentRef, input: SearchProjectionInput, captureID: UUID?, memoID: UUID?,
        merged: Bool, savedAsMemo: Bool, kind: ContentKind, collectionID: CollectionID?,
        title: String, text: ExtractedText, note: String
    ) -> SearchDocument {
        SearchDocument(
            ref: ref, captureID: captureID, memoID: memoID, merged: merged, savedAsMemo: savedAsMemo,
            kind: kind, sourceApp: input.sourceApp, collectionID: collectionID,
            lastCopiedAt: input.lastCopiedAt, title: title, body: text.body, url: text.url, note: note,
            bodyPartial: text.partial, textUnavailable: text.unavailable,
            normalizedTitle: SearchNormalizer.normalize(title),
            normalizedBody: SearchNormalizer.normalize(text.body),
            normalizedURL: SearchNormalizer.normalize(text.url),
            normalizedNote: SearchNormalizer.normalize(note)
        )
    }

    private static func title(of memo: MemoProjection, input: SearchProjectionInput) -> String {
        memo.title.isEmpty ? input.title : memo.title
    }

    private static func captureText(_ representations: [TextRepresentation]) -> ExtractedText {
        guard representations.allSatisfy(isIntact) else { return ExtractedText(unavailable: true) }
        let byItem = Dictionary(grouping: representations, by: \.itemIndex)
        var bodies: [String] = []
        var urls: [String] = []
        var truncated = false
        for itemIndex in byItem.keys.sorted() {
            let item = byItem[itemIndex, default: []].sorted { $0.representationIndex < $1.representationIndex }
            if let body = item.lazy.filter({ !isURL($0) }).compactMap(decode).first {
                bodies.append(body.text)
                truncated = truncated || body.isTruncated
            }
            urls.append(contentsOf: item.filter(isURL).compactMap(decode).map(\.text))
        }
        let body = cap(bodies.joined(separator: "\n"))
        return ExtractedText(
            body: body.text, url: cap(urls.joined(separator: "\n")).text, partial: truncated || body.cut
        )
    }

    private static func ownedText(_ body: Data?) -> ExtractedText {
        guard let body, let text = String(data: body, encoding: .utf8) else {
            return ExtractedText(unavailable: true)
        }
        let capped = cap(String(text.unicodeScalars.filter { $0.value != 0 }))
        return ExtractedText(body: capped.text, partial: capped.cut)
    }

    private static func isIntact(_ representation: TextRepresentation) -> Bool {
        Int64(representation.bytes.count) == representation.byteCount
            && ContentDigest.sha256(representation.bytes) == representation.digest
    }

    private static func isURL(_ representation: TextRepresentation) -> Bool {
        representation.typeIdentifier.lowercased() == "public.url"
    }

    private static func decode(_ representation: TextRepresentation) -> ClipTextPreview? {
        // UTF-16 needs up to twice the bytes to fill the UTF-8 limit; cap() trims the rest.
        ClipboardTextDecoder.decodeText(
            representation.bytes, typeIdentifier: representation.typeIdentifier,
            maximumBytes: bodyByteLimit * 2
        )
    }

    /// Truncates on a Character boundary so no scalar or grapheme is split.
    private static func cap(_ text: String) -> (text: String, cut: Bool) {
        guard text.utf8.count > bodyByteLimit else { return (text, false) }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: bodyByteLimit)
        while end > text.startIndex, end.samePosition(in: text) == nil {
            end = text.utf8.index(before: end)
        }
        return (String(text[..<end]), true)
    }

    private static func kind(types: [String], hasLocalReference: Bool) -> ContentKind {
        let lowered = types.map { $0.lowercased() }
        if hasLocalReference || lowered.contains("public.file-url") { return .file }
        if types.contains(where: { UTType($0)?.conforms(to: .image) == true }) { return .image }
        if lowered.contains("public.url") { return .url }
        if types.contains(where: { ClipboardTextDecoder.isTextType($0) || UTType($0)?.conforms(to: .text) == true }) {
            return .text
        }
        return .other
    }
}
