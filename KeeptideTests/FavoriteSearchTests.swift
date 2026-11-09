import Foundation
import XCTest
@testable import Keeptide

final class FavoriteSearchTests: XCTestCase {
    func testRealStoreFavoriteSurvivesCollectionMoveAndFreshIndexRebuild() async throws {
        let harness = try SearchHarness.make(in: self)
        let fixture = try await harness.insertItemWithOwnedMemo(text: "常用部署命令")
        let firstCollection = CollectionValue(name: "Commands")
        let secondCollection = CollectionValue(name: "Archive")
        try await harness.commit([
            .insert(.collection(firstCollection)), .insert(.collection(secondCollection)),
        ])
        var favorite = fixture.item
        favorite.collectionIDs = [firstCollection.id]
        favorite.isFavorite = true
        try await harness.update(.item(favorite.id), to: .item(favorite))
        try await harness.consumer.synchronize()

        let beforeMove = try await favorites(in: harness.service, query: "部署")
        XCTAssertEqual(beforeMove.results.map(\.ref.facet), [.memo])
        XCTAssertEqual(beforeMove.results.map(\.ref.itemID), [favorite.id])

        var moved = favorite
        moved.collectionIDs = [secondCollection.id]
        try await harness.update(.item(moved.id), to: .item(moved))
        try await harness.consumer.synchronize()
        let afterMove = try await favorites(in: harness.service, query: "部署")
        XCTAssertEqual(afterMove.results.map(\.ref.itemID), [favorite.id])
        XCTAssertTrue(afterMove.results.allSatisfy(\.isFavorite))

        let rebuilt = try await SearchHarness.freshDocuments(for: harness.controller)
        let rebuiltMemo = try XCTUnwrap(rebuilt.first { $0.ref.itemID == favorite.id && $0.ref.facet == .memo })
        XCTAssertTrue(rebuiltMemo.isFavorite)
        XCTAssertEqual(rebuiltMemo.collectionIDs, [secondCollection.id])
        XCTAssertFalse(rebuilt.contains { $0.ref.itemID == favorite.id && $0.ref.facet == .history && $0.isFavorite })
    }

    func testFavoritesFilterReturnsOnlyFavoriteMemoAcrossIndexedAndShortChineseQueries() async throws {
        let favorite = document(facet: .memo, body: "常用部署提示", isFavorite: true)
        let ordinaryMemo = SearchTestSupport.document(
            facet: .memo, body: "常用部署普通项", memoID: UUID()
        )
        let history = SearchTestSupport.document(body: "常用部署历史")
        let service = try makeService([favorite, ordinaryMemo, history])

        for query in ["部署", "常用部署"] {
            let page = try await lastPage(service, SearchRequest(
                query: query, scope: .all, favoritesOnly: true, generation: 1
            ))
            XCTAssertEqual(page.results.map(\.ref), [favorite.ref], query)
            XCTAssertTrue(page.results.allSatisfy(\.isFavorite), query)
        }
    }

    func testFavoriteFlagSurvivesIndexRoundTripAndCollectionChange() throws {
        let directory = SearchTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteSearchIndex(directory: directory)
        defer { index.close() }
        let itemID = ItemID()
        let memoID = UUID()
        let first = document(itemID: itemID, facet: .memo, version: ContentVersion(), body: "saved command",
                             memoID: memoID, collectionID: CollectionID(), isFavorite: true)
        let moved = document(itemID: itemID, facet: .memo, version: first.ref.version, body: first.body,
                             memoID: memoID, collectionID: CollectionID(), isFavorite: true)
        try index.reset(identity: SearchTestSupport.identity())
        try index.apply([IndexedItemChange(itemID: itemID, documents: [first])], sequence: 1, checkpoint: .keep)
        try index.apply([IndexedItemChange(itemID: itemID, documents: [moved])], sequence: 2, checkpoint: .keep)

        let stored = try XCTUnwrap(index.allDocuments().first)
        XCTAssertEqual(stored.collectionIDs, moved.collectionIDs)
        XCTAssertTrue(stored.isFavorite)
    }

    func testSchemaVersionChangeMakesOlderIndexMetadataUnusable() throws {
        let current = SearchIndexMetadata(
            schemaVersion: SQLiteSearchIndex.schemaVersion - 1,
            normalizerVersion: SearchNormalizer.version,
            extractorVersion: SearchDocumentBuilder.extractorVersion,
            tokenizer: SQLiteSearchIndex.tokenizer,
            identity: SearchTestSupport.identity(), checkpoint: nil, state: .ready
        )
        XCTAssertFalse(current.isUsable(for: current.identity))
    }

    private func makeService(_ documents: [SearchDocument]) throws -> SearchService {
        let directory = SearchTestSupport.directory()
        let index = try SQLiteSearchIndex(directory: directory)
        addTeardownBlock {
            index.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try index.reset(identity: SearchTestSupport.identity())
        try index.apply(
            Dictionary(grouping: documents, by: { $0.ref.itemID }).map {
                IndexedItemChange(itemID: $0.key, documents: $0.value)
            }, sequence: 1, checkpoint: .keep
        )
        try index.finishBuild(checkpoint: nil)
        return SearchService(index: index, status: SearchIndexStatus(.ready))
    }

    private func document(
        itemID: ItemID = ItemID(), facet: ContentFacet, version: ContentVersion = ContentVersion(),
        body: String, memoID: UUID? = nil, collectionID: CollectionID? = nil, isFavorite: Bool
    ) -> SearchDocument {
        SearchDocument(
            ref: ContentRef(itemID: itemID, facet: facet, version: version,
                            digest: Data(repeating: 7, count: 32)),
            captureID: facet == .history ? UUID() : nil, memoID: memoID,
            merged: false, savedAsMemo: false, kind: .text, sourceApp: "test.source",
            collectionIDs: collectionID.map { [$0] } ?? [], isFavorite: isFavorite,
            lastCopiedAt: Date(timeIntervalSince1970: 1_000), title: "", body: body, url: "", note: "",
            bodyPartial: false, textUnavailable: false,
            normalizedTitle: "", normalizedBody: SearchNormalizer.normalize(body),
            normalizedURL: "", normalizedNote: ""
        )
    }

    private func lastPage(_ service: SearchService, _ request: SearchRequest) async throws -> SearchPage {
        var last: SearchPage?
        for try await page in service.search(request) { last = page }
        return try XCTUnwrap(last)
    }

    private func favorites(in service: SearchService, query: String) async throws -> SearchPage {
        try await lastPage(service, SearchRequest(query: query, favoritesOnly: true, generation: 1))
    }
}
