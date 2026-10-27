import Foundation
import XCTest
@testable import Keeptide

final class SQLiteSearchIndexTests: XCTestCase {
    func testFreshIndexHasNoMetadataUntilReset() throws {
        let index = try makeIndex()
        XCTAssertNil(try index.metadata())

        let identity = SearchTestSupport.identity()
        try index.reset(identity: identity)
        let building = try XCTUnwrap(index.metadata())

        XCTAssertEqual(building.state, .building)
        XCTAssertNil(building.checkpoint)
        XCTAssertEqual(building.schemaVersion, 1)
        XCTAssertEqual(building.normalizerVersion, 1)
        XCTAssertEqual(building.extractorVersion, 1)
        XCTAssertEqual(building.tokenizer, "trigram case_sensitive 1")
        XCTAssertEqual(building.identity, identity)
        XCTAssertFalse(building.isUsable(for: identity))

        try index.finishBuild(checkpoint: Data("token".utf8))
        let ready = try XCTUnwrap(index.metadata())
        XCTAssertEqual(ready.checkpoint, Data("token".utf8))
        XCTAssertTrue(ready.isUsable(for: identity))
        XCTAssertFalse(ready.isUsable(for: SearchTestSupport.identity()))
    }

    func testMetadataAndDocumentsSurviveReopen() throws {
        let directory = SearchTestSupport.directory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let identity = SearchTestSupport.identity()
        let document = SearchTestSupport.document(title: "persisted")
        do {
            let index = try SQLiteSearchIndex(directory: directory)
            try index.reset(identity: identity)
            try index.apply([IndexedItemChange(itemID: document.ref.itemID, documents: [document])],
                            sequence: 1, checkpoint: .keep)
            try index.finishBuild(checkpoint: Data("one".utf8))
            index.close()
        }

        let reopened = try SQLiteSearchIndex(directory: directory)
        defer { reopened.close() }

        XCTAssertEqual(try reopened.metadata()?.checkpoint, Data("one".utf8))
        XCTAssertEqual(try reopened.allDocuments(), [document])
    }

    func testApplyReplacesItemDocumentsAndCheckpointAtomically() throws {
        let index = try makeReadyIndex()
        let itemID = ItemID()
        let history = SearchTestSupport.document(itemID: itemID, facet: .history, title: "history")
        let memo = SearchTestSupport.document(itemID: itemID, facet: .memo, title: "memo", memoID: UUID())

        try index.apply([IndexedItemChange(itemID: itemID, documents: [history, memo])],
                        sequence: 1, checkpoint: .set(Data("token1".utf8)))
        XCTAssertEqual(Set(try index.allDocuments().map(\.title)), ["history", "memo"])
        XCTAssertEqual(try index.metadata()?.checkpoint, Data("token1".utf8))

        try index.apply([IndexedItemChange(itemID: itemID, documents: [])], sequence: 2, checkpoint: .keep)
        XCTAssertEqual(try index.allDocuments(), [])
        XCTAssertEqual(try index.metadata()?.checkpoint, Data("token1".utf8))
    }

    func testOlderSequenceCannotOverwriteNewerProjection() throws {
        let index = try makeReadyIndex()
        let itemID = ItemID()

        try index.apply([IndexedItemChange(itemID: itemID, documents: [
            SearchTestSupport.document(itemID: itemID, title: "new"),
        ])], sequence: 10, checkpoint: .keep)
        try index.apply([IndexedItemChange(itemID: itemID, documents: [
            SearchTestSupport.document(itemID: itemID, title: "old"),
        ])], sequence: 5, checkpoint: .keep)

        XCTAssertEqual(try index.allDocuments().map(\.title), ["new"])
    }

    func testReverseLookupFindsItemsByCaptureOrMemoID() throws {
        let index = try makeReadyIndex()
        let captureItem = ItemID()
        let memoItem = ItemID()
        let captureID = UUID()
        let memoID = UUID()
        try index.apply([
            IndexedItemChange(itemID: captureItem, documents: [
                SearchTestSupport.document(itemID: captureItem, captureID: captureID),
            ]),
            IndexedItemChange(itemID: memoItem, documents: [
                SearchTestSupport.document(itemID: memoItem, facet: .memo, captureID: nil, memoID: memoID),
            ]),
        ], sequence: 1, checkpoint: .keep)

        XCTAssertEqual(try index.itemIDs(referencing: [captureID]), [captureItem])
        XCTAssertEqual(try index.itemIDs(referencing: [memoID, captureID, UUID()]), [captureItem, memoItem])
        XCTAssertEqual(try index.itemIDs(referencing: []), [])
    }

    func testReplaceUsageReplacesWholeMirror() throws {
        let index = try makeReadyIndex()
        let first = ItemID()
        let second = ItemID()
        try index.replaceUsage([
            UsageSummary(itemID: first, facet: .history, lastUsedAt: Date(timeIntervalSince1970: 10), useCount: 1),
        ])
        try index.replaceUsage([
            UsageSummary(itemID: second, facet: .memo, lastUsedAt: Date(timeIntervalSince1970: 20), useCount: 4),
        ])

        let reader = try index.openReader()
        defer { reader.close() }
        let rows = try reader.rows("SELECT item_id, facet, use_count FROM usage ORDER BY item_id", [])

        XCTAssertEqual(rows, [[.text(second.rawValue.uuidString), .text("memo"), .integer(4)]])
    }

    func testCorruptFileIsReportedAsCorrupt() throws {
        let directory = SearchTestSupport.directory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data(String(repeating: "not a database ", count: 274).utf8.prefix(4_096))
        try garbage.write(to: directory.appendingPathComponent(SQLiteSearchIndex.fileName))

        do {
            let index = try SQLiteSearchIndex(directory: directory)
            defer { index.close() }
            _ = try index.metadata()
            XCTFail("A corrupt index file was accepted")
        } catch {
            XCTAssertEqual(error as? SearchIndexError, .corrupt)
        }
    }

    func testResetDeletesOnlyIndexFiles() throws {
        let directory = SearchTestSupport.directory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteSearchIndex(directory: directory)
        defer { index.close() }
        let keep = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        try index.reset(identity: SearchTestSupport.identity())
        let itemID = ItemID()
        try index.apply([IndexedItemChange(itemID: itemID, documents: [
            SearchTestSupport.document(itemID: itemID),
        ])], sequence: 1, checkpoint: .keep)

        try index.reset(identity: SearchTestSupport.identity())

        XCTAssertEqual(try Data(contentsOf: keep), Data("keep".utf8))
        XCTAssertEqual(try index.allDocuments(), [])
    }

    func testFTSStaysInSyncThroughInsertReplaceAndDelete() throws {
        let index = try makeReadyIndex()
        let items = (0..<50).map { _ in ItemID() }
        for (round, keyword) in ["first", "second", "third"].enumerated() {
            try index.apply(items.enumerated().map { offset, itemID in
                let documents = offset % 3 == round ? [] : [
                    SearchTestSupport.document(itemID: itemID, body: "\(keyword) round body \(offset)"),
                ]
                return IndexedItemChange(itemID: itemID, documents: documents)
            }, sequence: Int64(round + 1), checkpoint: .keep)
        }

        XCTAssertNoThrow(try index.integrityCheck())
        let reader = try index.openReader()
        defer { reader.close() }
        let staleMatches = try reader.rows(
            "SELECT count(*) FROM doc_fts WHERE doc_fts MATCH ?", [.text("\"second\"")]
        )
        let currentMatches = try reader.rows(
            "SELECT count(*) FROM doc_fts WHERE doc_fts MATCH ?", [.text("\"third\"")]
        )
        XCTAssertEqual(staleMatches, [[.integer(0)]])
        XCTAssertEqual(currentMatches, [[.integer(Int64(items.indices.filter { $0 % 3 != 2 }.count))]])
    }

    private func makeIndex() throws -> SQLiteSearchIndex {
        let directory = SearchTestSupport.directory()
        let index = try SQLiteSearchIndex(directory: directory)
        addTeardownBlock {
            index.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return index
    }

    private func makeReadyIndex() throws -> SQLiteSearchIndex {
        let index = try makeIndex()
        try index.reset(identity: SearchTestSupport.identity())
        try index.finishBuild(checkpoint: nil)
        return index
    }
}
