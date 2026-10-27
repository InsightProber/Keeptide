import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class StoreChangeReaderTests: XCTestCase {
    func testReplayIdentifiesRecordsDeletedBeforeTheFirstRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let collection = CollectionValue(name: "temporary synthetic collection")
        let writer = WriteCoordinator(controller: store)
        _ = try await writer.commit(StoreTransaction(identity: try await store.identity(),
            mutations: [.insert(.collection(collection))]))
        let state = try await ContentRepository(controller: store).recordState(.collection(collection.id))
        _ = try await writer.commit(StoreTransaction(identity: try await store.identity(),
            preconditions: [.recordUnchanged(.collection(collection.id), fingerprint: state.fingerprint)],
            mutations: [.delete(.collection(collection.id))],
            permit: try await StoreSafetyGate(controller: store).permit(.maintenance)))
        let batch = try await StoreChangeReader(controller: store).read(after: nil)
        let changes = batch.transactions.flatMap(\.changes)
        XCTAssertEqual(changes.map(\.id), [collection.id.rawValue, collection.id.rawValue])
        XCTAssertEqual(changes.map(\.deleted), [false, true])
        XCTAssertEqual(Set(changes.map(\.entity)), ["Collection"])
    }

    func testLocalUsageAndFileAccessDoNotEnterContentHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let ref = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data([1]))
        try await LocalUsageStore(controller: store).record(UseReceipt(executionID: UUID(), ref: ref,
            occurredAt: Date(), outcome: .success))
        try await FileAccessStore(controller: store).put(
            LocalFileAccess(id: UUID(), snapshotID: UUID(), bytes: Data("synthetic-file-reference".utf8),
                            bookmark: Data([1, 2]), localPath: "/synthetic/example"),
            expecting: try await store.identity()
        )
        let batch = try await StoreChangeReader(controller: store).read(after: nil)
        XCTAssertTrue(batch.transactions.isEmpty)
        XCTAssertNil(batch.token)
    }

    func testPersistentHistoryResumesAfterReopenAndRejectsForeignStoreAndGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close() }
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("not in change feed".utf8))]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let first = try await StoreChangeReader(controller: store).read(after: nil)
        XCTAssertTrue(first.transactions.flatMap(\.changes).contains { $0.id == item.id.rawValue && $0.entity == "LibraryItem" })
        let token = try XCTUnwrap(first.token)
        var legacyEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: token) as? [String: Any])
        legacyEnvelope["version"] = 1
        let legacyToken = try JSONSerialization.data(withJSONObject: legacyEnvelope, options: [.sortedKeys])
        do { _ = try await StoreChangeReader(controller: store).read(after: legacyToken); XCTFail("Legacy checkpoint was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        var tamperedEnvelope = legacyEnvelope
        tamperedEnvelope["version"] = 2
        let sequence = try XCTUnwrap(tamperedEnvelope["transactionNumber"] as? NSNumber)
        tamperedEnvelope["transactionNumber"] = sequence.int64Value + 1
        let tamperedToken = try JSONSerialization.data(withJSONObject: tamperedEnvelope, options: [.sortedKeys])
        do { _ = try await StoreChangeReader(controller: store).read(after: tamperedToken); XCTFail("Mismatched token/sequence was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        let empty = try await StoreChangeReader(controller: store).read(after: token)
        XCTAssertTrue(empty.transactions.isEmpty)
        try await store.close()
        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try await reopened.close() }
        let collection = CollectionValue(name: "new")
        _ = try await WriteCoordinator(controller: reopened).commit(StoreTransaction(identity: try await reopened.identity(),
            mutations: [.insert(.collection(collection))]))
        let next = try await StoreChangeReader(controller: reopened).read(after: token)
        XCTAssertEqual(next.transactions.flatMap(\.changes).map(\.id), [collection.id.rawValue])
        XCTAssertGreaterThan(next.transactions.first!.sequence, first.transactions.last!.sequence)
        let foreign = try PersistenceController(directory: otherDirectory)
        addTeardownBlock { try await foreign.close() }
        do { _ = try await StoreChangeReader(controller: foreign).read(after: token); XCTFail("Foreign token was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        try await foreign.close()
        try await StoreSafetyGate(controller: reopened).transition(
            to: .active,
            expecting: try await reopened.identity()
        )
        do { _ = try await StoreChangeReader(controller: reopened).read(after: token); XCTFail("Old generation token was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        do { _ = try await StoreChangeReader(controller: reopened).read(after: Data([1, 2, 3])); XCTFail("Bad token was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        try await reopened.close()
    }

    func testMalformedHistoryRequiresRecoveryInsteadOfBeingReportedAsAnInvalidCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        try await store.perform { context in
            let row = NSEntityDescription.insertNewObject(forEntityName: "Collection", into: context)
            row.setValue("synthetic imported row without an id", forKey: "name")
            try context.save()
            context.reset()
        }

        let recoveryCheckpoint: Data
        do {
            _ = try await StoreChangeReader(controller: store).read(after: nil)
            XCTFail("Malformed history was silently accepted")
            return
        } catch StoreError.historyRequiresRebuild(let checkpoint) {
            recoveryCheckpoint = try XCTUnwrap(checkpoint)
        } catch {
            XCTFail("Unexpected history error: \(error)")
            return
        }

        let collection = CollectionValue(name: "valid transaction after malformed history")
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.collection(collection))]
        ))
        let recovered = try await StoreChangeReader(controller: store).read(after: recoveryCheckpoint)
        XCTAssertEqual(recovered.transactions.flatMap(\.changes).map(\.id), [collection.id.rawValue])
        let nextCheckpoint = try XCTUnwrap(recovered.token)
        let caughtUp = try await StoreChangeReader(controller: store).read(after: nextCheckpoint)
        XCTAssertTrue(caughtUp.transactions.isEmpty)
    }

    func testLargeTransactionPreservesEveryChangeAndItsOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let collections = (0..<300).map { CollectionValue(name: "synthetic collection \($0)") }
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: collections.map { .insert(.collection($0)) }
        ))

        let batch = try await StoreChangeReader(controller: store).read(after: nil)
        let collectionChanges = batch.transactions.flatMap(\.changes).filter { $0.entity == "Collection" }

        XCTAssertEqual(collectionChanges.count, collections.count)
        XCTAssertEqual(Set(collectionChanges.map(\.id)), Set(collections.map(\.id.rawValue)))
        XCTAssertEqual(batch.transactions.map(\.sequence), batch.transactions.map(\.sequence).sorted())
        XCTAssertNotNil(batch.token)
    }

    func testDistinctTransactionsAreReturnedInBoundedPagesWithoutOmissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let collections = (0..<300).map { CollectionValue(name: "paged synthetic collection \($0)") }
        let writer = WriteCoordinator(controller: store)
        for collection in collections {
            _ = try await writer.commit(StoreTransaction(
                identity: try await store.identity(),
                mutations: [.insert(.collection(collection))]
            ))
        }

        let reader = StoreChangeReader(controller: store)
        var token: Data?
        var observed: [StoreChange] = []
        var nonemptyPageCount = 0
        while true {
            let batch = try await reader.read(after: token)
            XCTAssertLessThanOrEqual(batch.transactions.count, 128)
            if batch.transactions.isEmpty {
                XCTAssertEqual(batch.token, token, "An empty terminal page must not invent a checkpoint")
                break
            }
            nonemptyPageCount += 1
            XCTAssertNotEqual(batch.token, token, "Every nonempty page must advance the checkpoint")
            observed.append(contentsOf: batch.transactions.flatMap(\.changes).filter { $0.entity == "Collection" })
            token = try XCTUnwrap(batch.token)
        }

        XCTAssertEqual(nonemptyPageCount, 3)
        XCTAssertEqual(observed.count, collections.count)
        XCTAssertEqual(observed.map(\.id), collections.map(\.id.rawValue))
        XCTAssertTrue(observed.allSatisfy { !$0.deleted })
    }

    func testInitialReadSeeksAcrossPrunedTransactionNumberGapWithoutMaterializingUnboundedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        for index in 0..<650 {
            let collection = CollectionValue(name: "pruned history \(index)")
            _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
                identity: try await store.identity(),
                mutations: [.insert(.collection(collection))]
            ))
        }
        let firstRetainedSequence = try await store.perform { context -> Int64 in
            let fetch = NSPersistentHistoryChangeRequest.fetchHistory(after: nil as NSPersistentHistoryToken?)
            fetch.affectedStores = [store.contentStore]
            fetch.resultType = .transactionsOnly
            guard let result = try context.execute(fetch) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction],
                  transactions.count == 650 else {
                throw StoreChangeReaderTestFailure.missingFixture
            }
            let boundary = transactions[600]
            let deletion = NSPersistentHistoryChangeRequest.deleteHistory(before: boundary.token)
            deletion.affectedStores = [store.contentStore]
            _ = try context.execute(deletion)
            return boundary.transactionNumber
        }

        let batch = try await StoreChangeReader(controller: store).read(after: nil)

        XCTAssertFalse(batch.transactions.isEmpty)
        XCTAssertLessThanOrEqual(batch.transactions.count, 128)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(batch.transactions.first?.sequence), firstRetainedSequence)
    }

    func testEarlierInsertKeepsItsLogicalIDWhenTheObjectIsDeletedOnALaterPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let writer = WriteCoordinator(controller: store)
        let target = CollectionValue(name: "deleted after the first page")
        _ = try await writer.commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.collection(target))]
        ))
        let targetState = try await ContentRepository(controller: store).recordState(.collection(target.id))
        for index in 0..<128 {
            let filler = CollectionValue(name: "delete-page filler \(index)")
            _ = try await writer.commit(StoreTransaction(
                identity: try await store.identity(),
                mutations: [.insert(.collection(filler))]
            ))
        }
        _ = try await writer.commit(StoreTransaction(
            identity: try await store.identity(),
            preconditions: [.recordUnchanged(.collection(target.id), fingerprint: targetState.fingerprint)],
            mutations: [.delete(.collection(target.id))],
            permit: try await StoreSafetyGate(controller: store).permit(.maintenance)
        ))

        let reader = StoreChangeReader(controller: store)
        let first = try await reader.read(after: nil)
        XCTAssertEqual(first.transactions.count, 128)
        XCTAssertTrue(first.transactions.flatMap(\.changes).contains {
            $0.entity == "Collection" && $0.id == target.id.rawValue && !$0.deleted
        })

        let second = try await reader.read(after: try XCTUnwrap(first.token))
        XCTAssertLessThanOrEqual(second.transactions.count, 128)
        XCTAssertTrue(second.transactions.flatMap(\.changes).contains {
            $0.entity == "Collection" && $0.id == target.id.rawValue && $0.deleted
        })
        let terminal = try await reader.read(after: try XCTUnwrap(second.token))
        XCTAssertTrue(terminal.transactions.isEmpty)
    }

    func testInverseOnlyPageAdvancesCheckpointBeforeTheNextContentTransaction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("inverse page".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        let firstCollection = CollectionValue(name: "inverse first")
        let secondCollection = CollectionValue(name: "inverse second")
        item.memoID = memo.id
        item.collectionID = firstCollection.id
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [
                .insert(.capture(capture)),
                .insert(.memo(memo)),
                .insert(.collection(firstCollection)),
                .insert(.collection(secondCollection)),
                .insert(.item(item))
            ]
        ))
        let reader = StoreChangeReader(controller: store)
        let initial = try await reader.read(after: nil)
        let initialToken = try XCTUnwrap(initial.token)
        let itemID = item.id
        let collectionIDs = [firstCollection.id, secondCollection.id]
        for index in 0..<128 {
            try await store.perform { context in
                context.reset()
                guard let itemObject = try StoredRecords.object(.item(itemID), in: context),
                      let collectionObject = try StoredRecords.object(
                        .collection(collectionIDs[(index + 1) % collectionIDs.count]),
                        in: context
                      ) else {
                    throw StoreChangeReaderTestFailure.missingFixture
                }
                itemObject.setValue(collectionObject, forKey: "collection")
                try context.save()
            }
        }
        let visible = CollectionValue(name: "after inverse-only page")
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.collection(visible))]
        ))

        let inverseOnly = try await reader.read(after: initialToken)
        XCTAssertTrue(inverseOnly.transactions.isEmpty)
        XCTAssertNotEqual(inverseOnly.token, initialToken)

        let next = try await reader.read(after: try XCTUnwrap(inverseOnly.token))
        XCTAssertEqual(
            next.transactions.flatMap(\.changes).filter { $0.entity == "Collection" }.map(\.id),
            [visible.id.rawValue]
        )
    }

    func testInverseRelationshipUpdatesAreFilteredWithoutHidingContentUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("relationship history".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        let firstCollection = CollectionValue(name: "first")
        let secondCollection = CollectionValue(name: "second")
        item.memoID = memo.id
        item.collectionID = firstCollection.id
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [
                .insert(.capture(capture)),
                .insert(.memo(memo)),
                .insert(.collection(firstCollection)),
                .insert(.collection(secondCollection)),
                .insert(.item(item))
            ]
        ))
        let initial = try await StoreChangeReader(controller: store).read(after: nil)
        let initialToken = try XCTUnwrap(initial.token)
        let itemState = try await ContentRepository(controller: store).recordState(.item(item.id))
        item.collectionID = secondCollection.id
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
            mutations: [.update(.item(item))]
        ))

        let relationshipBatch = try await StoreChangeReader(controller: store).read(after: initialToken)
        let relationshipChanges = relationshipBatch.transactions.flatMap(\.changes)
        XCTAssertEqual(relationshipChanges.count, 1)
        XCTAssertEqual(relationshipChanges.first?.entity, "LibraryItem")
        XCTAssertEqual(relationshipChanges.first?.id, item.id.rawValue)

        let relationshipToken = try XCTUnwrap(relationshipBatch.token)
        let collectionState = try await ContentRepository(controller: store).recordState(.collection(secondCollection.id))
        var renamed = secondCollection
        renamed.name = "second renamed"
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            preconditions: [.recordUnchanged(.collection(renamed.id), fingerprint: collectionState.fingerprint)],
            mutations: [.update(.collection(renamed))]
        ))

        let contentBatch = try await StoreChangeReader(controller: store).read(after: relationshipToken)
        XCTAssertTrue(contentBatch.transactions.flatMap(\.changes).contains {
            $0.entity == "Collection" && $0.id == renamed.id.rawValue
        })
    }
}

private enum StoreChangeReaderTestFailure: Error {
    case missingFixture
}
