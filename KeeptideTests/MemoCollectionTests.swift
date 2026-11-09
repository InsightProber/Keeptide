import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class MemoCollectionTests: XCTestCase {
    func testNewMemoUsesExplicitCollectionContextWhileNilRemainsUncategorized() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let service = LibraryService(controller: controller)

            let categorized = try await service.create(MemoDraft(
                body: "categorized", collectionIDs: [collection.id]
            ))
            let uncategorized = try await service.create(MemoDraft(body: "uncategorized"))
            let categorizedItem = try await item(categorized.itemID, in: controller)
            let uncategorizedItem = try await item(uncategorized.itemID, in: controller)

            XCTAssertEqual(categorizedItem.collectionIDs, [collection.id])
            XCTAssertEqual(uncategorizedItem.collectionIDs, [])
        }
    }

    func testDeletedCollectionRejectsRecoveredNewDraftAndKeepsRecoveryFile() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let identity = try await controller.identity()
            let draftDirectory = temporaryDirectory().appendingPathComponent("Drafts", isDirectory: true)
            let store = try DraftStore(directory: draftDirectory, identity: identity)
            let draft = makeRecoverableDraft(identity: identity, collectionID: collection.id)
            try await store.write(draft)
            try await softDelete(collection, in: controller)
            let coordinator = MemoCommitCoordinator(
                store: store,
                commit: LibraryService(controller: controller).submitDraft
            )
            _ = try await coordinator.restore()

            do {
                _ = try await coordinator.commitNow(draft.draftID)
                XCTFail("A draft was committed into a deleted collection")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            let recovered = try await store.load(draft.draftID)
            let itemCount = try await count("LibraryItem", in: controller)
            XCTAssertEqual(recovered, draft)
            XCTAssertEqual(itemCount, 0)
        }
    }

    func testStableItemRetryCannotChangeItsCollectionContext() async throws {
        try await withStore { controller in
            let firstCollection = try await insertCollection(name: "A", in: controller)
            let secondCollection = try await insertCollection(name: "B", in: controller)
            let service = LibraryService(controller: controller)
            let itemID = ItemID()
            let first = MemoDraft(
                itemID: itemID, body: "stable", collectionIDs: [firstCollection.id]
            )

            let created = try await service.create(first)
            let retry = try await service.create(first)
            XCTAssertEqual(created, retry)
            do {
                _ = try await service.create(MemoDraft(
                    itemID: itemID, body: "stable", collectionIDs: [secondCollection.id]
                ))
                XCTFail("A stable item retry silently changed collection context")
            } catch {
                XCTAssertEqual(error as? LibraryServiceError, .stableIdentityCollision)
            }
            let persisted = try await item(itemID, in: controller)
            XCTAssertEqual(persisted.collectionIDs, [firstCollection.id])
        }
    }

    func testActiveCollectionMetadataChangesDoNotInvalidateCreateOrStableRetry() async throws {
        try await withStore { controller in
            let original = try await insertCollection(name: "Original", in: controller)
            let service = LibraryService(controller: controller)
            let renamed = try await updateCollection(
                original, name: "Renamed", color: "purple", sortOrder: 20, in: controller
            )
            let draft = MemoDraft(
                itemID: ItemID(), body: "metadata independent", collectionIDs: [original.id]
            )

            let created = try await service.create(draft)
            _ = try await updateCollection(
                renamed, name: "Renamed again", color: "orange", sortOrder: 2, in: controller
            )
            let retry = try await service.create(draft)
            let persisted = try await item(created.itemID, in: controller)

            XCTAssertEqual(retry, created)
            XCTAssertEqual(persisted.collectionIDs, [original.id])
        }
    }

    func testOwnedConflictCopyRetainsLatestCollectionContextAndStableRetry() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let service = LibraryService(controller: controller)
            let original = try await service.create(MemoDraft(
                body: "base", collectionIDs: [collection.id]
            ))
            let stale = try await service.editingSnapshot(original)
            _ = try await service.commit(MemoEdit(
                title: "winner", body: "winner",
                expectedMemoFingerprint: stale.memoFingerprint
            ), base: original)
            let conflictID = ItemID()
            let edit = MemoEdit(
                title: "conflict", body: "conflict",
                expectedMemoFingerprint: stale.memoFingerprint,
                conflictItemID: conflictID
            )

            let first = try await service.commit(edit, base: original)
            let retry = try await service.commit(edit, base: original)
            guard case .conflictCopy(let firstRef) = first,
                  case .conflictCopy(let retryRef) = retry else {
                return XCTFail("A stale owned edit did not create a stable conflict copy")
            }
            let conflictItem = try await item(conflictID, in: controller)
            XCTAssertEqual(firstRef, retryRef)
            XCTAssertEqual(conflictItem.collectionIDs, [collection.id])
        }
    }

    func testInheritedConflictCopyRetainsLatestCollectionContextAndStableRetry() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let capture = try ContentStoreFixtures.capture([[
                ("public.utf8-plain-text", Data("inherited".utf8)),
            ]])
            let sourceItem = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(sourceItem, capture, into: controller)
            let service = LibraryService(controller: controller)
            let original = try await service.saveAsMemo(sourceItem.id).ref
            let collections = CollectionService(controller: controller)
            let available = try await collections.list()
            let target = try XCTUnwrap(available.first { $0.value.id == collection.id })
            _ = try await collections.move([original], to: target)
            let stale = try await service.editingSnapshot(original)
            _ = try await service.commit(MemoEdit(
                title: "winner", note: "winner",
                expectedMemoFingerprint: stale.memoFingerprint
            ), base: original)
            let conflictID = ItemID()
            let edit = MemoEdit(
                title: "conflict", note: "conflict",
                expectedMemoFingerprint: stale.memoFingerprint,
                conflictItemID: conflictID
            )

            let first = try await service.commit(edit, base: original)
            let retry = try await service.commit(edit, base: original)
            guard case .conflictCopy(let firstRef) = first,
                  case .conflictCopy(let retryRef) = retry else {
                return XCTFail("A stale inherited edit did not create a stable conflict copy")
            }
            let conflictItem = try await item(conflictID, in: controller)
            XCTAssertEqual(firstRef, retryRef)
            XCTAssertEqual(conflictItem.collectionIDs, [collection.id])
        }
    }

    func testDeletedCollectionRejectsConflictCopyAndKeepsRecoveredDraft() async throws {
        try await withStore { controller in
            let collection = try await insertCollection(in: controller)
            let service = LibraryService(controller: controller)
            let original = try await service.create(MemoDraft(
                body: "base", collectionIDs: [collection.id]
            ))
            let stale = try await service.editingSnapshot(original)
            let identity = try await controller.identity()
            let conflictID = ItemID()
            let draft = RecoverableDraft(
                draftID: UUID(), sessionID: UUID(), itemID: original.itemID,
                conflictItemID: conflictID, storeIdentity: identity,
                base: original, baseMemoFingerprint: stale.memoFingerprint,
                title: "conflict", body: "conflict", kind: .plainText,
                languageHint: nil, note: "", isComposing: false,
                revision: 1, savedAt: Date(), collectionID: collection.id
            )
            let draftDirectory = temporaryDirectory().appendingPathComponent("Drafts", isDirectory: true)
            let draftStore = try DraftStore(directory: draftDirectory, identity: identity)
            try await draftStore.write(draft)
            _ = try await service.commit(MemoEdit(
                title: "winner", body: "winner",
                expectedMemoFingerprint: stale.memoFingerprint
            ), base: original)
            try await softDelete(collection, in: controller)
            let coordinator = MemoCommitCoordinator(store: draftStore, commit: service.submitDraft)
            _ = try await coordinator.restore()

            do {
                _ = try await coordinator.commitNow(draft.draftID)
                XCTFail("A conflict copy was attached to a deleted collection")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            let recovered = try await draftStore.load(draft.draftID)
            let itemCount = try await count("LibraryItem", in: controller)
            XCTAssertEqual(recovered, draft)
            XCTAssertEqual(itemCount, 1)
        }
    }

    func testLegacyDraftWithoutCollectionFieldDecodesAsUncategorized() async throws {
        let directory = temporaryDirectory()
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: directory, identity: identity)
        let draft = makeRecoverableDraft(identity: identity, collectionID: CollectionID())
        try await store.write(draft)
        let url = store.fileURL(for: draft.draftID)
        let data = try Data(contentsOf: url)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload = try XCTUnwrap(envelope["draft"] as? [String: Any])
        payload.removeValue(forKey: "collectionID")
        envelope["draft"] = payload
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(
            to: url, options: [.atomic]
        )

        let decoded = try await store.load(draft.draftID)
        XCTAssertNil(decoded?.collectionID)
    }

    func testDraftRestartRetainsCollectionIdentity() async throws {
        let directory = temporaryDirectory()
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let collectionID = CollectionID()
        let draft = makeRecoverableDraft(identity: identity, collectionID: collectionID)
        try await DraftStore(directory: directory, identity: identity).write(draft)

        let reopened = try DraftStore(directory: directory, identity: identity)
        let restored = try await reopened.load(draft.draftID)
        XCTAssertEqual(restored?.collectionID, collectionID)
    }

    func testADraftKeepsEveryCollectionAcrossARestartAndAnOldDraftReadsItsOne() async throws {
        let directory = temporaryDirectory()
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let ids = CollectionID.sorted([CollectionID(), CollectionID(), CollectionID()])
        var draft = makeRecoverableDraft(identity: identity, collectionID: nil)
        draft.collectionIDs = ids.reversed()
        try await DraftStore(directory: directory, identity: identity).write(draft)

        let restored = try await DraftStore(directory: directory, identity: identity).load(draft.draftID)
        XCTAssertEqual(restored?.collectionIDs, ids)

        // A draft written when a snippet could be in one collection has that collection alone, under its old key.
        let one = CollectionID()
        let old = makeRecoverableDraft(identity: identity, collectionID: one)
        let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(old)) as? [String: Any]
        XCTAssertNil(encoded?["additionalCollectionIDs"])
        XCTAssertEqual(old.collectionIDs, [one])
    }

    func testNewEditorSessionCarriesInitialCollectionContext() {
        let collectionID = CollectionID()
        let session = MemoEditorSession(
            itemID: ItemID(), ref: nil, isReadOnly: false,
            title: "", body: "", note: "", kind: .plainText,
            storeIdentity: StoreIdentity(storeID: UUID(), generation: UUID()),
            collectionIDs: [collectionID]
        )

        XCTAssertEqual(session.collectionIDs, [collectionID])
    }

    private func withStore<T: Sendable>(
        _ body: (PersistenceController) async throws -> T
    ) async throws -> T {
        let directory = temporaryDirectory()
        let controller = try PersistenceController(directory: directory)
        do {
            let result = try await body(controller)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideMemoCollection-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func insertCollection(
        name: String = "Prompts", in controller: PersistenceController
    ) async throws -> CollectionValue {
        let value = CollectionValue(name: name, color: "blue")
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            mutations: [.insert(.collection(value))]
        ))
        return value
    }

    private func softDelete(
        _ collection: CollectionValue, in controller: PersistenceController
    ) async throws {
        let repository = ContentRepository(controller: controller)
        let state = try await repository.recordState(.collection(collection.id))
        var deleted = collection
        deleted.deletedAt = Date()
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            preconditions: [
                .recordUnchanged(.collection(collection.id), fingerprint: state.fingerprint),
            ],
            mutations: [.update(.collection(deleted))]
        ))
    }

    private func updateCollection(
        _ collection: CollectionValue,
        name: String,
        color: String,
        sortOrder: Double,
        in controller: PersistenceController
    ) async throws -> CollectionValue {
        let state = try await ContentRepository(controller: controller).recordState(.collection(collection.id))
        var updated = collection
        updated.name = name
        updated.color = color
        updated.sortOrder = sortOrder
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            preconditions: [
                .recordUnchanged(.collection(collection.id), fingerprint: state.fingerprint),
            ],
            mutations: [.update(.collection(updated))]
        ))
        return updated
    }

    private func item(
        _ id: ItemID, in controller: PersistenceController
    ) async throws -> ItemValue {
        let state = try await ContentRepository(controller: controller).recordState(.item(id))
        guard case .item(let value) = state.value else { throw StoreError.corruptStore }
        return value
    }

    private func count(_ entity: String, in controller: PersistenceController) async throws -> Int {
        try await controller.perform { context in
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))
        }
    }

    private func makeRecoverableDraft(
        identity: StoreIdentity, collectionID: CollectionID?
    ) -> RecoverableDraft {
        RecoverableDraft(
            draftID: UUID(), sessionID: UUID(), itemID: ItemID(), conflictItemID: ItemID(),
            storeIdentity: identity, base: nil, baseMemoFingerprint: nil,
            title: "Prompt", body: "recover me", kind: .prompt, languageHint: nil,
            note: "", isComposing: false, revision: 1, savedAt: Date(),
            collectionID: collectionID
        )
    }
}
