import CoreData
import Foundation
import SQLite3
import XCTest
@testable import Keeptide

/// Each scenario ends by comparing the recovered index with one built from scratch.
final class IndexRecoveryTests: XCTestCase {
    func testFactsCommittedWhileIndexerStoppedAreReplayed() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 10, prefix: "before")
        try await harness.consumer.synchronize()
        await harness.consumer.stopAndDrain()
        try await harness.insertTextItems(count: 50, prefix: "while stopped")

        let restarted = HistoryConsumer(controller: harness.controller, index: harness.index, status: harness.status)
        try await restarted.synchronize()
        await restarted.stopAndDrain()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 60)
    }

    func testDocumentsWithoutCheckpointAreReplayedIdempotently() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 5, prefix: "indexed")
        try await harness.consumer.synchronize()
        let checkpoint = try harness.index.metadata()?.checkpoint
        try await harness.insertTextItems(count: 5, prefix: "written without checkpoint")
        let ids = try await harness.controller.perform { context in try StoredRecords.searchAllItemIDs(in: context) }
        let inputs = try await harness.controller.perform { context in
            try StoredRecords.searchProjection(itemIDs: ids, in: context)
        }
        let documents = Dictionary(grouping: inputs.flatMap(SearchDocumentBuilder.documents(for:)), by: \.ref.itemID.rawValue)
        try harness.index.apply(ids.map { IndexedItemChange(itemID: $0, documents: documents[$0.rawValue] ?? []) },
                                sequence: 0, checkpoint: .keep)
        XCTAssertEqual(try harness.index.metadata()?.checkpoint, checkpoint)

        try await harness.consumer.synchronize()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 10)
    }

    func testLostCheckpointTriggersRebuild() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 8, prefix: "lost")
        try await harness.consumer.synchronize()
        try execute(on: harness, "DELETE FROM meta WHERE key = 'checkpoint'")
        try await harness.insertTextItems(count: 2, prefix: "after loss")

        try await harness.consumer.synchronize()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 10)
        XCTAssertEqual(try harness.index.metadata()?.state, .ready)
    }

    func testInvalidCheckpointTriggersRebuild() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 8, prefix: "invalid")
        try await harness.consumer.synchronize()
        let random = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        try execute(on: harness, "UPDATE meta SET value = ? WHERE key = 'checkpoint'", [.blob(random)])

        try await harness.consumer.synchronize()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertNotEqual(try harness.index.metadata()?.checkpoint, random)
    }

    func testHistoryRequiresRebuildUsesProvidedBoundary() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 4, prefix: "before malformed")
        try await harness.consumer.synchronize()
        try await harness.controller.perform { context in
            let row = NSEntityDescription.insertNewObject(forEntityName: "Collection", into: context)
            row.setValue("synthetic imported row without an id", forKey: "name")
            try context.save()
            context.reset()
        }
        try await harness.insertTextItems(count: 3, prefix: "after malformed")

        try await harness.consumer.synchronize()
        try await harness.insertTextItems(count: 2, prefix: "later")
        try await harness.consumer.synchronize()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 9)
    }

    func testCorruptIndexFileIsRebuilt() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 12, prefix: "corrupt")
        try await harness.consumer.synchronize()
        await harness.consumer.stopAndDrain()
        harness.index.close()
        let search = harness.directory.appendingPathComponent("Search", isDirectory: true)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: search.appendingPathComponent(SQLiteSearchIndex.fileName + suffix))
        }
        try Data(String(repeating: "not a database ", count: 300).utf8)
            .write(to: search.appendingPathComponent(SQLiteSearchIndex.fileName))

        let index = try SQLiteSearchIndex(directory: search)
        defer { index.close() }
        let consumer = HistoryConsumer(controller: harness.controller, index: index, status: SearchIndexStatus())
        try await consumer.synchronize()
        await consumer.stopAndDrain()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 12)
    }

    func testInterruptedBuildRestartsFromScratch() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 20, prefix: "interrupted")
        try harness.index.reset(identity: try await harness.controller.identity())
        let ids = try await harness.controller.perform { context in try StoredRecords.searchAllItemIDs(in: context) }
        let half = Array(ids.prefix(10))
        let inputs = try await harness.controller.perform { context in
            try StoredRecords.searchProjection(itemIDs: half, in: context)
        }
        try harness.index.apply(inputs.map {
            IndexedItemChange(itemID: $0.itemID, documents: SearchDocumentBuilder.documents(for: $0))
        }, sequence: 0, checkpoint: .keep)
        XCTAssertEqual(try harness.index.metadata()?.state, .building)

        try await harness.consumer.synchronize()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 20)
        XCTAssertEqual(try harness.index.metadata()?.state, .ready)
    }

    func testStopAndDrainDuringRebuildLeavesRestartableIndex() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 3_000, prefix: "drain")
        await harness.consumer.start()
        try await Task.sleep(for: .milliseconds(50))

        let started = ContinuousClock.now
        await harness.consumer.stopAndDrain()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))

        let restarted = HistoryConsumer(controller: harness.controller, index: harness.index, status: harness.status)
        try await restarted.synchronize()
        await restarted.stopAndDrain()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 3_000)
    }

    func testStaleProjectionCannotOverwriteCurrentVersion() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 3, prefix: "current")
        try await harness.consumer.synchronize()
        let current = try harness.index.allDocuments()
        let target = try XCTUnwrap(current.first)

        let stale = SearchTestSupport.document(itemID: target.ref.itemID, title: "stale version")
        try harness.index.apply([IndexedItemChange(itemID: target.ref.itemID, documents: [stale])],
                                sequence: 0, checkpoint: .keep)

        XCTAssertEqual(try harness.index.allDocuments(), current)
    }

    private func execute(on harness: SearchHarness, _ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let path = harness.directory.appendingPathComponent("Search/\(SQLiteSearchIndex.fileName)").path
        let connection = try SQLiteConnection(path: path, flags: SQLITE_OPEN_READWRITE)
        defer { connection.close() }
        try connection.run(sql, bindings)
    }
}
