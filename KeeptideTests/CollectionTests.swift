import Foundation
import XCTest
@testable import Keeptide

final class CollectionTests: XCTestCase {
    func testCRUDReorderAndReopenPreserveStableIdentityAndExactValues() async throws {
        let directory = temporaryDirectory()
        var controller: PersistenceController? = try PersistenceController(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let service = CollectionService(controller: try XCTUnwrap(controller))
        let ids = (0..<21).map { _ in CollectionID() }
        var snapshots: [CollectionSnapshot] = []
        for index in ids.indices {
            snapshots.append(try await service.create(CollectionDraft(
                id: ids[index],
                name: "Collection \(index)",
                color: index.isMultiple(of: 2) ? "blue" : "orange"
            )))
        }

        let longName = String(repeating: "长期保留的中文分类", count: 24)
        snapshots[10] = try await service.edit(snapshots[10], name: longName, color: "purple")
        let reversed = try await service.reorder(Array(snapshots.reversed()))

        XCTAssertEqual(reversed.map(\.value.id), Array(ids.reversed()))
        XCTAssertEqual(reversed[10].value.name, longName)
        XCTAssertEqual(reversed[10].value.color, "purple")
        XCTAssertEqual(Set(reversed.map(\.value.id)).count, 21)

        try await controller?.close()
        controller = nil
        let reopened = try PersistenceController(directory: directory)
        defer { Task { try? await reopened.close() } }
        let persisted = try await CollectionService(controller: reopened).list()
        XCTAssertEqual(persisted.map(\.value.id), reversed.map(\.value.id))
        XCTAssertEqual(persisted[10].value.name, longName)

        do {
            _ = try await CollectionService(controller: reopened).create(
                CollectionDraft(id: ids[0], name: "Different retry", color: "red")
            )
            XCTFail("A stable identity retry must not overwrite a different collection")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
    }

    func testStaleReorderFailsWithoutPartiallyChangingAnySortOrder() async throws {
        try await withStore { controller in
            let originals = try await seedCollections(3, in: controller)
            let service = CollectionService(controller: controller)
            var winner = originals
            winner[0] = try await service.edit(winner[0], name: "Winner", color: winner[0].value.color)

            do {
                _ = try await service.reorder(Array(originals.reversed()))
                XCTFail("A stale collection snapshot must reject the entire reorder")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            let persisted = try await service.list()
            XCTAssertEqual(persisted.map(\.value.id), originals.map(\.value.id))
            XCTAssertEqual(persisted.map(\.value.sortOrder), originals.map(\.value.sortOrder))
            XCTAssertEqual(persisted[0].value.name, winner[0].value.name)
        }
    }

    func testMoveChangesOnlySingleMembershipAndPreservesContentAndHistoryMetadata() async throws {
        try await withStore { controller in
            let collections = try await seedCollections(2, in: controller)
            let fixture = try await seedMemo(in: controller, collectionID: collections[0].value.id, favorite: true)
            let before = try await states(for: fixture, in: controller)
            let service = CollectionService(controller: controller)

            let change = try await service.move([fixture.memoRef], to: collections[1])
            let moved = try await item(fixture.item.id, in: controller)
            let after = try await states(for: fixture, in: controller)

            XCTAssertEqual(change.affectedItems, [fixture.item.id])
            XCTAssertEqual(moved.collectionIDs, [collections[1].value.id])
            XCTAssertTrue(moved.isFavorite)
            assertMetadataUnchanged(before.item, moved, exceptCollection: true, exceptFavorite: false)
            XCTAssertEqual(after.capture, before.capture)
            XCTAssertEqual(after.memo, before.memo)

            _ = try await service.move([fixture.memoRef], to: nil)
            let uncategorized = try await item(fixture.item.id, in: controller)
            XCTAssertEqual(uncategorized.collectionIDs, [])
        }
    }

    func testMixedMemoAndHistoryMoveIsRejectedAtomically() async throws {
        try await withStore { controller in
            let collection = try await seedCollections(1, in: controller)[0]
            let memo = try await seedMemo(in: controller, collectionID: nil)
            let historyCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("history only".utf8))]
            ])
            let historyItem = ContentStoreFixtures.item(historyCapture)
            try await ContentStoreFixtures.insert(historyItem, historyCapture, into: controller)

            do {
                _ = try await CollectionService(controller: controller).move(
                    [memo.memoRef, ContentStoreFixtures.ref(historyItem, historyCapture)],
                    to: collection
                )
                XCTFail("Collection membership accepts active memo content only")
            } catch {
                XCTAssertEqual(error as? CollectionServiceError, .invalidContent)
            }

            let unchangedMemo = try await item(memo.item.id, in: controller)
            let unchangedHistory = try await item(historyItem.id, in: controller)
            XCTAssertEqual(unchangedMemo.collectionIDs, [])
            XCTAssertEqual(unchangedHistory.collectionIDs, [])
        }
    }

    func testDeleteSoftDeletesCollectionDetachesMembersAndUndoRestoresExactState() async throws {
        try await withStore { controller in
            let collection = try await seedCollections(1, in: controller)[0]
            let first = try await seedMemo(in: controller, collectionID: collection.value.id, favorite: true)
            let second = try await seedMemo(in: controller, collectionID: collection.value.id)
            let firstBefore = try await states(for: first, in: controller)
            let secondBefore = try await states(for: second, in: controller)
            let service = CollectionService(controller: controller)

            let deletion = try await service.delete(collection)
            let deletedCollection = try await collectionValue(collection.value.id, in: controller)
            let detachedFirst = try await item(first.item.id, in: controller)
            let detachedSecond = try await item(second.item.id, in: controller)
            let firstAfterDelete = try await states(for: first, in: controller)
            let secondAfterDelete = try await states(for: second, in: controller)

            XCTAssertNotNil(deletedCollection.deletedAt)
            XCTAssertEqual(detachedFirst.collectionIDs, [])
            XCTAssertEqual(detachedSecond.collectionIDs, [])
            XCTAssertEqual(firstAfterDelete.capture, firstBefore.capture)
            XCTAssertEqual(firstAfterDelete.memo, firstBefore.memo)
            XCTAssertEqual(secondAfterDelete.capture, secondBefore.capture)
            XCTAssertEqual(secondAfterDelete.memo, secondBefore.memo)
            XCTAssertTrue(detachedFirst.isFavorite)

            _ = try await service.undo(deletion.undoToken)
            let restoredCollection = try await collectionValue(collection.value.id, in: controller)
            let restoredFirst = try await item(first.item.id, in: controller)
            let restoredSecond = try await item(second.item.id, in: controller)
            XCTAssertEqual(restoredCollection, collection.value)
            XCTAssertEqual(restoredFirst.collectionIDs, [collection.value.id])
            XCTAssertEqual(restoredSecond.collectionIDs, [collection.value.id])
        }
    }

    func testDeleteUndoRejectsChangedMemberAndRestoresNothingPartially() async throws {
        try await withStore { controller in
            let collection = try await seedCollections(1, in: controller)[0]
            let first = try await seedMemo(in: controller, collectionID: collection.value.id)
            let second = try await seedMemo(in: controller, collectionID: collection.value.id)
            let service = CollectionService(controller: controller)
            let deletion = try await service.delete(collection)

            let repository = ContentRepository(controller: controller)
            let secondState = try await repository.recordState(.item(second.item.id))
            var changed = try await item(second.item.id, in: controller)
            changed.title = "Concurrent winner"
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(changed.id), fingerprint: secondState.fingerprint)],
                mutations: [.update(.item(changed))]
            ))

            do {
                _ = try await service.undo(deletion.undoToken)
                XCTFail("Undo must compare every exact post-mutation fingerprint")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            let stillDeleted = try await collectionValue(collection.value.id, in: controller)
            let unchangedFirst = try await item(first.item.id, in: controller)
            let winningSecond = try await item(second.item.id, in: controller)
            XCTAssertNotNil(stillDeleted.deletedAt)
            XCTAssertEqual(unchangedFirst.collectionIDs, [])
            XCTAssertEqual(winningSecond.collectionIDs, [])
            XCTAssertEqual(winningSecond.title, "Concurrent winner")
        }
    }

    func testASnippetJoinsAndLeavesCollectionsOneByOneAndDeletingOneKeepsTheOthers() async throws {
        try await withStore { controller in
            let collections = try await seedCollections(3, in: controller)
            let ids = collections.map(\.value.id)
            let fixture = try await seedMemo(in: controller, collectionID: nil)
            let service = CollectionService(controller: controller)

            _ = try await service.add([fixture.memoRef], to: collections[0])
            _ = try await service.add([fixture.memoRef], to: collections[1])
            let again = try await service.add([fixture.memoRef], to: collections[1])
            XCTAssertEqual(again.affectedItems, [])
            var value = try await item(fixture.item.id, in: controller)
            XCTAssertEqual(value.collectionIDs, CollectionID.sorted([ids[0], ids[1]]))

            // Deleting a collection takes its snippets out of it alone; undoing it puts them back.
            let deletion = try await service.delete(collections[0])
            value = try await item(fixture.item.id, in: controller)
            XCTAssertEqual(value.collectionIDs, [ids[1]])
            _ = try await service.undo(deletion.undoToken)
            value = try await item(fixture.item.id, in: controller)
            XCTAssertEqual(value.collectionIDs, CollectionID.sorted([ids[0], ids[1]]))

            let removal = try await service.remove([fixture.memoRef], from: ids[1])
            value = try await item(fixture.item.id, in: controller)
            XCTAssertEqual(value.collectionIDs, [ids[0]])
            _ = try await service.undo(removal.undoToken)
            value = try await item(fixture.item.id, in: controller)
            XCTAssertEqual(value.collectionIDs, CollectionID.sorted([ids[0], ids[1]]))

            // Moving puts it in the one collection chosen, out of every other.
            _ = try await service.move([fixture.memoRef], to: collections[2])
            value = try await item(fixture.item.id, in: controller)
            XCTAssertEqual(value.collectionIDs, [ids[2]])
            let members = try await ContentRepository(controller: controller).collectionMembershipSnapshot(ids[0])
            XCTAssertEqual(members.members.count, 0)
        }
    }

    func testSaveAsMemoIntoCollectionRequiresActiveCollection() async throws {
        try await withStore { controller in
            let collections = try await seedCollections(2, in: controller)
            _ = try await CollectionService(controller: controller).delete(collections[0])
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("clip".utf8))]])
            let clip = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(clip, capture, into: controller)
            let library = LibraryService(controller: controller)

            do {
                _ = try await library.saveAsMemo(clip.id, collectionIDs: [collections[0].value.id], isFavorite: true)
                XCTFail("A deleted collection must not receive a new snippet")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            let untouched = try await item(clip.id, in: controller)
            XCTAssertNil(untouched.memoID)
            XCTAssertEqual(untouched.collectionIDs, [])
            XCTAssertFalse(untouched.isFavorite)

            let outcome = try await library.saveAsMemo(clip.id, collectionIDs: [collections[1].value.id], isFavorite: true)
            guard case .created(let created) = outcome else { return XCTFail("Expected a new snippet") }
            let saved = try await item(clip.id, in: controller)
            XCTAssertNotNil(saved.memoID)
            XCTAssertEqual(saved.collectionIDs, [collections[1].value.id])
            XCTAssertTrue(saved.isFavorite)

            let repeated = try await library.saveAsMemo(clip.id, collectionIDs: [], isFavorite: false)
            guard case .existing(let existing) = repeated else { return XCTFail("A second save must not create") }
            XCTAssertEqual(existing, created)
            let kept = try await item(clip.id, in: controller)
            XCTAssertEqual(kept.collectionIDs, [collections[1].value.id])
            XCTAssertTrue(kept.isFavorite)
        }
    }

    func testFavoriteIsIdempotentIndependentOfMembershipAndPersistsAfterReopen() async throws {
        let directory = temporaryDirectory()
        var controller: PersistenceController? = try PersistenceController(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let live = try XCTUnwrap(controller)
        let collections = try await seedCollections(2, in: live)
        let fixture = try await seedMemo(in: live, collectionID: collections[0].value.id)
        let service = CollectionService(controller: live)

        _ = try await service.setFavorite([fixture.memoRef], isFavorite: true)
        _ = try await service.setFavorite([fixture.memoRef], isFavorite: true)
        _ = try await service.move([fixture.memoRef], to: collections[1])
        let movedFavorite = try await item(fixture.item.id, in: live)
        XCTAssertTrue(movedFavorite.isFavorite)

        try await controller?.close()
        controller = nil
        let reopened = try PersistenceController(directory: directory)
        defer { Task { try? await reopened.close() } }
        let persisted = try await item(fixture.item.id, in: reopened)
        XCTAssertTrue(persisted.isFavorite)
        XCTAssertEqual(persisted.collectionIDs, [collections[1].value.id])
    }

    func testNoOpMoveStillAtomicallyValidatesItsTargetSnapshot() async throws {
        try await withStore { controller in
            let target = try await seedCollections(1, in: controller)[0]
            let fixture = try await seedMemo(in: controller, collectionID: target.value.id)
            let repository = ContentRepository(controller: controller)
            var concurrentWinner = target.value
            concurrentWinner.name = "Concurrent winner"
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(.collection(target.value.id), fingerprint: target.fingerprint),
                ],
                mutations: [.update(.collection(concurrentWinner))]
            ))

            do {
                _ = try await CollectionService(controller: controller).move(
                    [fixture.memoRef],
                    to: target
                )
                XCTFail("A no-op batch must not skip its stale target CAS")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            let persistedItem = try await item(fixture.item.id, in: controller)
            let persistedCollection = try await repository.recordState(.collection(target.value.id))
            XCTAssertEqual(persistedItem.collectionIDs, [target.value.id])
            XCTAssertEqual(persistedCollection.value, .collection(concurrentWinner))
        }
    }

    func testOperationCannotAdoptAReplacementStoreGeneration() async throws {
        try await withStore { controller in
            let service = CollectionService(controller: controller)
            let gate = StoreSafetyGate(controller: controller)
            let originalIdentity = try await controller.identity()
            try await gate.transition(to: .quarantined, expecting: originalIdentity)
            let quarantinedIdentity = try await controller.identity()
            try await gate.transition(to: .active, expecting: quarantinedIdentity)

            do {
                _ = try await service.create(
                    CollectionDraft(name: "Must not cross generations", color: "blue"),
                    expecting: originalIdentity
                )
                XCTFail("An operation from an old store generation was committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            let collections = try await service.list()
            XCTAssertTrue(collections.isEmpty)
        }
    }
}

private extension CollectionTests {
    struct MemoFixture {
        var item: ItemValue
        var capture: CaptureValue
        var memo: MemoValue
        var memoRef: ContentRef
    }

    struct FixtureStates {
        var item: ItemValue
        var capture: PersistedRecord
        var memo: PersistedRecord
    }

    struct PersistedRecord: Equatable {
        var value: RecordValue
        var fingerprint: Data
    }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideCollections-\(UUID().uuidString)", isDirectory: true)
    }

    func withStore<T: Sendable>(
        _ body: (PersistenceController) async throws -> T
    ) async throws -> T {
        let directory = temporaryDirectory()
        let controller = try PersistenceController(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let result = try await body(controller)
            try await controller.close()
            return result
        } catch {
            try? await controller.close()
            throw error
        }
    }

    func seedCollections(_ count: Int, in controller: PersistenceController) async throws -> [CollectionSnapshot] {
        let values = (0..<count).map {
            CollectionValue(name: "Collection \($0)", color: "blue", sortOrder: Double($0))
        }
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            mutations: values.map { .insert(.collection($0)) }
        ))
        let repository = ContentRepository(controller: controller)
        return try await values.asyncMap { value in
            let state = try await repository.recordState(.collection(value.id))
            return CollectionSnapshot(value: value, fingerprint: state.fingerprint)
        }
    }

    func seedMemo(
        in controller: PersistenceController,
        collectionID: CollectionID?,
        favorite: Bool = false
    ) async throws -> MemoFixture {
        let body = Data("Reusable prompt".utf8)
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("Original clipboard text".utf8))]
        ])
        let itemID = ItemID()
        let memo = MemoValue(
            itemID: itemID,
            title: "Prompt",
            bodyMode: .ownedMarkdown,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body),
            note: "Keep exactly"
        )
        let item = ItemValue(
            id: itemID,
            createdAt: Date(timeIntervalSince1970: 100),
            sourceApp: "test.source",
            title: "Stable title",
            captureID: capture.id,
            memoID: memo.id,
            collectionIDs: collectionID.map { [$0] } ?? [],
            isFavorite: favorite,
            historyEligible: true,
            lastCopiedAt: Date(timeIntervalSince1970: 200),
            copyCount: 17
        )
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
        ))
        return MemoFixture(
            item: item,
            capture: capture,
            memo: memo,
            memoRef: ContentRef(
                itemID: itemID,
                facet: .memo,
                version: try XCTUnwrap(memo.version),
                digest: try XCTUnwrap(memo.digest)
            )
        )
    }

    func states(for fixture: MemoFixture, in controller: PersistenceController) async throws -> FixtureStates {
        let repository = ContentRepository(controller: controller)
        let capture = try await repository.recordState(.capture(fixture.capture.id))
        let memo = try await repository.recordState(.memo(fixture.memo.id))
        return FixtureStates(
            item: try await item(fixture.item.id, in: controller),
            capture: PersistedRecord(value: capture.value, fingerprint: capture.fingerprint),
            memo: PersistedRecord(value: memo.value, fingerprint: memo.fingerprint)
        )
    }

    func item(_ id: ItemID, in controller: PersistenceController) async throws -> ItemValue {
        guard case .item(let value) = try await ContentRepository(controller: controller).recordState(.item(id)).value else {
            throw StoreError.corruptStore
        }
        return value
    }

    func collectionValue(_ id: CollectionID, in controller: PersistenceController) async throws -> CollectionValue {
        guard case .collection(let value) = try await ContentRepository(controller: controller)
            .recordState(.collection(id)).value else {
            throw StoreError.corruptStore
        }
        return value
    }

    func assertMetadataUnchanged(
        _ before: ItemValue,
        _ after: ItemValue,
        exceptCollection: Bool,
        exceptFavorite: Bool
    ) {
        var expected = after
        if exceptCollection { expected.collectionIDs = before.collectionIDs }
        if exceptFavorite { expected.isFavorite = before.isFavorite }
        XCTAssertEqual(expected, before)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
