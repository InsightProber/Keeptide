import Foundation

struct TextRepresentation: Equatable, Sendable {
    let itemIndex: Int
    let representationIndex: Int
    let typeIdentifier: String
    let byteCount: Int64
    let digest: Data
    let bytes: Data
}

/// A kept result of text recognized in an image, as stored: its UTF-8 bytes and their SHA-256, checked and decoded
/// when the document is built.
struct RecognizedTextRow: Hashable, Sendable {
    let id: UUID
    /// The content it was made from, version and digest included.
    let source: ContentRef
    let bytes: Data
    let digest: Data
}

/// What one projection read: the inputs of the visible items among the first `processed` asked for, and, for each of
/// those items, the results of text recognized in it, by facet, which its documents are made with.
struct SearchProjectionBatch: Sendable {
    let inputs: [SearchProjectionInput]
    let processed: Int
    let recognizedResults: [ItemID: [ContentFacet: UUID]]
}

struct MemoProjection: Equatable, Sendable {
    let ref: ContentRef
    let memoID: UUID
    let title: String
    let note: String
    let isInherited: Bool
    /// UTF-8 body of an owned memo; nil for an inherited memo.
    let body: Data?
    /// Text recognized in an inherited memo's image, made from exactly this content.
    var recognizedText: RecognizedTextRow? = nil
}

/// Raw values copied out of Core Data for one item. Decoding, digest checks and
/// normalization happen later, away from the store's writer queue.
struct SearchProjectionInput: Equatable, Sendable {
    let itemID: ItemID
    let title: String
    let sourceApp: String?
    /// The memo's collections, sorted; empty when it is in none.
    let collectionIDs: [CollectionID]
    var isFavorite: Bool = false
    let lastCopiedAt: Date
    let history: ContentRef?
    let memo: MemoProjection?
    let captureID: UUID?
    let representationTypes: [String]
    let hasLocalReference: Bool
    /// Portable text and URL representations only.
    let textRepresentations: [TextRepresentation]
    /// Text recognized in the history row's image, made from exactly this content; nil without a history row.
    var recognizedText: RecognizedTextRow? = nil
}

struct SearchDocument: Equatable, Sendable {
    let ref: ContentRef
    let captureID: UUID?
    let memoID: UUID?
    /// An inherited memo also shown through its item's history row.
    let merged: Bool
    /// A history row whose item also has a memo; an inherited memo lends it its title and note.
    let savedAsMemo: Bool
    let kind: ContentKind
    let sourceApp: String?
    /// Sorted; a history row is never in a collection.
    let collectionIDs: [CollectionID]
    var isFavorite: Bool = false
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
    /// 3: an image's body ends with the text recognized in it.
    static let extractorVersion = 3
    static let bodyByteLimit = 1_048_576

    static func documents(for input: SearchProjectionInput) -> [SearchDocument] {
        let capture = captureText(input.textRepresentations)
        let captureKind = ContentKind.classify(typeIdentifiers: input.representationTypes,
                                               hasLocalReference: input.hasLocalReference)
        let merged = input.memo?.isInherited == true && input.history != nil
        var documents: [SearchDocument] = []
        if let history = input.history {
            let memo = merged ? input.memo : nil
            documents.append(document(
                ref: history, input: input, captureID: input.captureID, memoID: memo?.memoID,
                merged: false, savedAsMemo: input.memo != nil, kind: captureKind, collectionIDs: [],
                isFavorite: false,
                title: memo.map { title(of: $0, input: input) } ?? input.title,
                // A clip and the snippet that inherits it are the same image: each takes the text recognized in
                // either, its own first, as the clip stands for both in All.
                text: captureKind == .image
                    ? appending([input.recognizedText, memo?.recognizedText], to: capture) : capture,
                note: memo?.note ?? ""
            ))
        }
        if let memo = input.memo {
            documents.append(document(
                ref: memo.ref, input: input, captureID: memo.isInherited ? input.captureID : nil,
                memoID: memo.memoID, merged: merged, savedAsMemo: false,
                kind: memo.isInherited ? captureKind : .text, collectionIDs: input.collectionIDs,
                isFavorite: input.isFavorite,
                title: title(of: memo, input: input),
                text: memo.isInherited
                    ? (captureKind == .image
                        ? appending([memo.recognizedText, input.recognizedText], to: capture) : capture)
                    : ownedText(memo.body),
                note: memo.note
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
        merged: Bool, savedAsMemo: Bool, kind: ContentKind, collectionIDs: [CollectionID], isFavorite: Bool,
        title: String, text: ExtractedText, note: String
    ) -> SearchDocument {
        SearchDocument(
            ref: ref, captureID: captureID, memoID: memoID, merged: merged, savedAsMemo: savedAsMemo,
            kind: kind, sourceApp: input.sourceApp, collectionIDs: collectionIDs, isFavorite: isFavorite,
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

    /// An image's own text and, after it, each text recognized in it that is intact and not there already, each on a
    /// line of its own, within the body's limit. Chinese or Japanese that wraps onto the next line is joined again, so
    /// a phrase is found across the wrap.
    private static func appending(_ rows: [RecognizedTextRow?], to text: ExtractedText) -> ExtractedText {
        var recognized: [String] = []
        for row in rows.compactMap({ $0 }) {
            guard ContentDigest.sha256(row.bytes) == row.digest,
                  let decoded = String(data: row.bytes, encoding: .utf8) else { continue }
            let joined = joiningWrappedLines(decoded)
            if !joined.isEmpty, !recognized.contains(joined) { recognized.append(joined) }
        }
        guard !recognized.isEmpty else { return text }
        var text = text
        let capped = cap(([text.body] + recognized).filter { !$0.isEmpty }.joined(separator: "\n"))
        text.body = capped.text
        text.partial = text.partial || capped.cut
        return text
    }

    /// Removes a line break beside Chinese or Japanese, which wrap without a space, unless a space or another break is
    /// on its other side: the text is searched as one line there, digits and Latin letters in it included. A break
    /// between words written with spaces, such as Latin or Korean ones, stays, and so does a blank line.
    private static func joiningWrappedLines(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var joined = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\n", index > 0, index + 1 < scalars.count {
                let (before, after) = (scalars[index - 1], scalars[index + 1])
                if !before.properties.isWhitespace, !after.properties.isWhitespace,
                   wrapsWithoutSpace(before) || wrapsWithoutSpace(after) { continue }
            }
            joined.append(scalar)
        }
        return String(joined)
    }

    /// Han and kana, and the punctuation and full-width forms written with them. Hangul is written with spaces between
    /// words, so a line break there stands for one.
    private static func wrapsWithoutSpace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3001...0x30FF, 0x31F0...0x31FF, 0xFF01...0xFF9F: return true
        default: return false
        }
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
}
