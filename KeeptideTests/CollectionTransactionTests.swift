import Foundation
import XCTest
@testable import Keeptide

final class CollectionTransactionTests: XCTestCase {
    func testConcurrentAttachInvalidatesCollectionDeleteMembershipFence() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let original = try await insertMemo(in: controller, collectionID: collection.id)
            let repository = ContentRepository(controller: controller)
            let membership = try await repository.collectionMembershipFingerprint(collection.id)
            let collectionState = try await repository.recordState(.collection(collection.id))
            let originalState = try await repository.recordState(.item(original.item.id))

            let phantom = try await insertMemo(in: controller, collectionID: nil)
            let phantomState = try await repository.recordState(.item(phantom.item.id))
            var attached = phantom.item
            attached.collectionIDs = [collection.id]
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(.item(attached.id), fingerprint: phantomState.fingerprint),
                ],
                mutations: [.update(.item(attached))]
            ))

            var deletedCollection = collection
            deletedCollection.deletedAt = Date(timeIntervalSince1970: 500)
            var detachedOriginal = original.item
            detachedOriginal.collectionIDs = []
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [
                        .recordUnchanged(.collection(collection.id), fingerprint: collectionState.fingerprint),
                        .recordUnchanged(.item(original.item.id), fingerprint: originalState.fingerprint),
                        .collectionMembership(collection.id, fingerprint: membership),
                    ],
                    mutations: [
                        .update(.collection(deletedCollection)),
                        .update(.item(detachedOriginal)),
                    ]
                ))
                XCTFail("A member attached after the delete snapshot must invalidate the whole transaction")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            let unchangedCollection = try await collectionValue(collection.id, in: controller)
            let unchangedOriginal = try await itemValue(original.item.id, in: controller)
            let attachedPhantom = try await itemValue(phantom.item.id, in: controller)
            XCTAssertEqual(unchangedCollection, collection)
            XCTAssertEqual(unchangedOriginal.collectionIDs, [collection.id])
            XCTAssertEqual(attachedPhantom.collectionIDs, [collection.id])
        }
    }

    func testRequestedPostMutationFingerprintsMatchCommittedRecordsAndReopen() async throws {
        let directory = temporaryDirectory()
        var controller: PersistenceController? = try PersistenceController(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let live = try XCTUnwrap(controller)
        let collection = try await insertCollection(in: live)
        let fixture = try await insertMemo(in: live, collectionID: collection.id)
        let repository = ContentRepository(controller: live)
        let collectionState = try await repository.recordState(.collection(collection.id))
        let itemState = try await repository.recordState(.item(fixture.item.id))

        var renamed = collection
        renamed.name = "Receipt winner"
        var favorite = fixture.item
        favorite.isFavorite = true
        var transaction = StoreTransaction(
            identity: try await live.identity(),
            preconditions: [
                .recordUnchanged(.collection(collection.id), fingerprint: collectionState.fingerprint),
                .recordUnchanged(.item(fixture.item.id), fingerprint: itemState.fingerprint),
            ],
            mutations: [.update(.collection(renamed)), .update(.item(favorite))]
        )
        let requested: Set<RecordKey> = [.collection(collection.id), .item(fixture.item.id)]
        transaction.receiptFingerprintKeys = requested
        let receipt = try await WriteCoordinator(controller: live).commit(transaction)

        XCTAssertEqual(Set(receipt.postMutationFingerprints.keys), requested)
        for key in requested {
            let persisted = try await repository.recordState(key)
            XCTAssertEqual(receipt.postMutationFingerprints[key], persisted.fingerprint)
        }

        try await controller?.close()
        controller = nil
        let reopened = try PersistenceController(directory: directory)
        for key in requested {
            let persisted = try await ContentRepository(controller: reopened).recordState(key)
            XCTAssertEqual(receipt.postMutationFingerprints[key], persisted.fingerprint)
        }
        try await reopened.close()
    }

    func testInvalidReceiptFingerprintRequestsFailBeforeSaving() async throws {
        try await withStore { controller in
            let writer = WriteCoordinator(controller: controller)
            let untouched = CollectionValue(name: "Untouched", color: "blue")
            let mustRollBack = CollectionValue(name: "Must roll back", color: "red")
            var untouchedRequest = StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.collection(mustRollBack))]
            )
            untouchedRequest.receiptFingerprintKeys = [.collection(untouched.id)]
            await assertInvalidTransaction(untouchedRequest, writer: writer)
            try await assertMissing(.collection(untouched.id), in: controller)
            try await assertMissing(.collection(mustRollBack.id), in: controller)

            let body = Data("Unsupported receipt key".utf8)
            let memo = MemoValue(
                itemID: ItemID(),
                bodyMode: .ownedPlainText,
                body: body,
                version: ContentVersion(),
                digest: ContentDigest.sha256(body)
            )
            let memoItem = ItemValue(id: memo.itemID, memoID: memo.id)
            var unsupportedRequest = StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.memo(memo)), .insert(.item(memoItem))]
            )
            unsupportedRequest.receiptFingerprintKeys = [.memo(memo.id)]
            await assertInvalidTransaction(unsupportedRequest, writer: writer)
            try await assertMissing(.memo(memo.id), in: controller)
            try await assertMissing(.item(memo.itemID), in: controller)

            let collection = try await insertCollection(in: controller)
            let state = try await ContentRepository(controller: controller).recordState(.collection(collection.id))
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            var deletedRequest = StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(.collection(collection.id), fingerprint: state.fingerprint),
                ],
                mutations: [.delete(.collection(collection.id))],
                permit: permit
            )
            deletedRequest.receiptFingerprintKeys = [.collection(collection.id)]
            await assertInvalidTransaction(deletedRequest, writer: writer)
            let unchanged = try await collectionValue(collection.id, in: controller)
            XCTAssertEqual(unchanged, collection)
        }
    }

    func testItemCannotAttachToSoftDeletedCollection() async throws {
        try await withStore { controller in
            var collection = try await insertCollection(in: controller)
            let repository = ContentRepository(controller: controller)
            let collectionState = try await repository.recordState(.collection(collection.id))
            collection.deletedAt = Date(timeIntervalSince1970: 700)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(.collection(collection.id), fingerprint: collectionState.fingerprint),
                ],
                mutations: [.update(.collection(collection))]
            ))

            let fixture = try await insertMemo(in: controller, collectionID: nil)
            let itemState = try await repository.recordState(.item(fixture.item.id))
            var attached = fixture.item
            attached.collectionIDs = [collection.id]
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [
                        .recordUnchanged(.item(fixture.item.id), fingerprint: itemState.fingerprint),
                    ],
                    mutations: [.update(.item(attached))]
                ))
                XCTFail("New membership must not target a soft-deleted collection")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }

            let unchanged = try await itemValue(fixture.item.id, in: controller)
            XCTAssertEqual(unchanged.collectionIDs, [])
        }
    }

    func testSoftDeletedMemberParticipatesInDeleteAndExactUndoFences() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let fixture = try await insertMemo(
                in: controller,
                collectionID: collection.id,
                itemDeletedAt: Date(timeIntervalSince1970: 800)
            )
            let repository = ContentRepository(controller: controller)
            let membership = try await repository.collectionMembershipFingerprint(collection.id)
            let collectionState = try await repository.recordState(.collection(collection.id))
            let itemState = try await repository.recordState(.item(fixture.item.id))

            var deletedCollection = collection
            deletedCollection.deletedAt = Date(timeIntervalSince1970: 801)
            var detached = fixture.item
            detached.collectionIDs = []
            var deletion = StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(.collection(collection.id), fingerprint: collectionState.fingerprint),
                    .recordUnchanged(.item(fixture.item.id), fingerprint: itemState.fingerprint),
                    .collectionMembership(collection.id, fingerprint: membership),
                ],
                mutations: [.update(.collection(deletedCollection)), .update(.item(detached))]
            )
            let keys: Set<RecordKey> = [.collection(collection.id), .item(fixture.item.id)]
            deletion.receiptFingerprintKeys = keys
            let receipt = try await WriteCoordinator(controller: controller).commit(deletion)

            let detachedValue = try await itemValue(fixture.item.id, in: controller)
            XCTAssertEqual(detachedValue.collectionIDs, [])
            let emptyMembership = try await repository.collectionMembershipFingerprint(collection.id)
            var undo = StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(
                        .collection(collection.id),
                        fingerprint: try XCTUnwrap(receipt.postMutationFingerprints[.collection(collection.id)])
                    ),
                    .recordUnchanged(
                        .item(fixture.item.id),
                        fingerprint: try XCTUnwrap(receipt.postMutationFingerprints[.item(fixture.item.id)])
                    ),
                    .collectionMembership(collection.id, fingerprint: emptyMembership),
                ],
                mutations: [.update(.collection(collection)), .update(.item(fixture.item))]
            )
            undo.receiptFingerprintKeys = keys
            _ = try await WriteCoordinator(controller: controller).commit(undo)

            let restoredCollection = try await collectionValue(collection.id, in: controller)
            let restoredItem = try await itemValue(fixture.item.id, in: controller)
            XCTAssertEqual(restoredCollection, collection)
            XCTAssertEqual(restoredItem, fixture.item)
        }
    }

    func testMarkedMemberMakesWholeCollectionDeleteFail() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let fixture = try await insertMemo(in: controller, collectionID: collection.id)
            let repository = ContentRepository(controller: controller)
            let membership = try await repository.collectionMembershipFingerprint(collection.id)
            let collectionState = try await repository.recordState(.collection(collection.id))
            let itemState = try await repository.recordState(.item(fixture.item.id))
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.itemMarker(ItemDeletionMarkerValue(itemID: fixture.item.id)))],
                permit: permit
            ))

            var deletedCollection = collection
            deletedCollection.deletedAt = Date(timeIntervalSince1970: 900)
            var detached = fixture.item
            detached.collectionIDs = []
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [
                        .recordUnchanged(.collection(collection.id), fingerprint: collectionState.fingerprint),
                        .recordUnchanged(.item(fixture.item.id), fingerprint: itemState.fingerprint),
                        .collectionMembership(collection.id, fingerprint: membership),
                    ],
                    mutations: [.update(.collection(deletedCollection)), .update(.item(detached))]
                ))
                XCTFail("A marked member must make the whole delete fail")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            let unchangedCollection = try await collectionValue(collection.id, in: controller)
            let unchangedItem = try await itemValue(fixture.item.id, in: controller)
            XCTAssertEqual(unchangedCollection, collection)
            XCTAssertEqual(unchangedItem, fixture.item)
        }
    }
}

private extension CollectionTransactionTests {
    struct MemoFixture {
        var item: ItemValue
        var memo: MemoValue
    }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideCollectionTransactions-\(UUID().uuidString)", isDirectory: true)
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

    func insertCollection(in controller: PersistenceController) async throws -> CollectionValue {
        let value = CollectionValue(name: "Collection", color: "blue", sortOrder: 1)
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            mutations: [.insert(.collection(value))]
        ))
        return value
    }

    func insertMemo(
        in controller: PersistenceController,
        collectionID: CollectionID?,
        itemDeletedAt: Date? = nil
    ) async throws -> MemoFixture {
        let itemID = ItemID()
        let body = Data("Transaction fixture".utf8)
        let memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        let item = ItemValue(
            id: itemID,
            title: "Memo",
            memoID: memo.id,
            collectionIDs: collectionID.map { [$0] } ?? [],
            deletedAt: itemDeletedAt
        )
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(item))]
        ))
        return MemoFixture(item: item, memo: memo)
    }

    func itemValue(_ id: ItemID, in controller: PersistenceController) async throws -> ItemValue {
        guard case .item(let value) = try await ContentRepository(controller: controller)
            .recordState(.item(id)).value else {
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

    func assertMissing(_ key: RecordKey, in controller: PersistenceController) async throws {
        do {
            _ = try await ContentRepository(controller: controller).recordState(key)
            XCTFail("Unexpected record persisted: \(key)")
        } catch {
            XCTAssertEqual(error as? StoreError, .notFound)
        }
    }

    func assertInvalidTransaction(_ transaction: StoreTransaction, writer: WriteCoordinator) async {
        do {
            _ = try await writer.commit(transaction)
            XCTFail("Invalid receipt fingerprint request unexpectedly committed")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidTransaction)
        }
    }
}
