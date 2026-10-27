import Foundation
@testable import Keeptide

enum SearchTestSupport {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideSearch-\(UUID().uuidString)", isDirectory: true)
    }

    static func identity() -> StoreIdentity {
        StoreIdentity(storeID: UUID(), generation: UUID())
    }

    static func document(
        itemID: ItemID = ItemID(),
        facet: ContentFacet = .history,
        version: ContentVersion = ContentVersion(),
        title: String = "",
        body: String = "",
        url: String = "",
        note: String = "",
        captureID: UUID? = UUID(),
        memoID: UUID? = nil,
        merged: Bool = false,
        savedAsMemo: Bool = false,
        kind: ContentKind = .text,
        sourceApp: String? = "test.source",
        collectionID: CollectionID? = nil,
        lastCopiedAt: Date = Date(timeIntervalSince1970: 1_000),
        bodyPartial: Bool = false
    ) -> SearchDocument {
        SearchDocument(
            ref: ContentRef(itemID: itemID, facet: facet, version: version, digest: Data(repeating: 7, count: 32)),
            captureID: captureID, memoID: memoID, merged: merged, savedAsMemo: savedAsMemo, kind: kind,
            sourceApp: sourceApp, collectionID: collectionID, lastCopiedAt: lastCopiedAt,
            title: title, body: body, url: url, note: note, bodyPartial: bodyPartial, textUnavailable: false,
            normalizedTitle: SearchNormalizer.normalize(title), normalizedBody: SearchNormalizer.normalize(body),
            normalizedURL: SearchNormalizer.normalize(url), normalizedNote: SearchNormalizer.normalize(note)
        )
    }
}
