import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class TransactionReviewTests: XCTestCase {
    func testMarkedItemAndItsMemoRejectFurtherUpdatesAtomically() async throws {
        try await withStore { controller in
            let writer = WriteCoordinator(controller: controller)
            let repository = ContentRepository(controller: controller)
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)

            let item = ItemValue(title: "marked item")
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.item(item))]
            ))
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.itemMarker(ItemDeletionMarkerValue(itemID: item.id)))],
                permit: permit
            ))
            let markedItemState = try await repository.recordState(.item(item.id))
            var changedItem = item
            changedItem.title = "must not persist"

            do {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.item(item.id), fingerprint: markedItemState.fingerprint)],
                    mutations: [.update(.item(changedItem))]
                ))
                XCTFail("An item deletion marker allowed a later item update")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            guard case .item(let persistedItem) = try await repository.recordState(.item(item.id)).value else {
                return XCTFail("The marked item changed type")
            }
            XCTAssertEqual(persistedItem.title, item.title)

            let memoItemID = ItemID()
            let memoBody = Data("marked memo".utf8)
            let memo = MemoValue(
                itemID: memoItemID,
                bodyMode: .ownedPlainText,
                body: memoBody,
                version: ContentVersion(),
                digest: ContentDigest.sha256(memoBody)
            )
            let memoItem = ItemValue(id: memoItemID, title: "memo owner", memoID: memo.id)
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.memo(memo)), .insert(.item(memoItem))]
            ))
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.itemMarker(ItemDeletionMarkerValue(itemID: memoItemID)))],
                permit: permit
            ))
            let markedMemoState = try await repository.recordState(.memo(memo.id))
            var changedMemo = memo
            changedMemo.note = "must not persist"

            do {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: markedMemoState.fingerprint)],
                    mutations: [.update(.memo(changedMemo))]
                ))
                XCTFail("An owner item deletion marker allowed a later memo update")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            guard case .memo(let persistedMemo) = try await repository.recordState(.memo(memo.id)).value else {
                return XCTFail("The marked memo changed type")
            }
            XCTAssertEqual(persistedMemo.note, memo.note)
        }
    }

    func testStringsContainingNULAreRejectedWithoutPartialPersistence() async throws {
        try await withStore { controller in
            let nul = "before\0after"
            var sourceAppItem = ItemValue(title: "source app")
            sourceAppItem.sourceApp = nul
            var titleItem = ItemValue(title: nul)
            titleItem.sourceApp = "synthetic.test"

            let memoTitle = makeOwnedMemoValues { $0.title = nul }
            let memoSourceType = makeOwnedMemoValues { $0.sourceRepresentationType = nul }
            let memoLanguage = makeOwnedMemoValues { $0.languageHint = nul }
            let memoNote = makeOwnedMemoValues { $0.note = nul }

            var capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("portable".utf8))]
            ])
            capture.representations[0].typeIdentifier = nul
            capture.manifest = CaptureManifest(
                itemCount: 1,
                entries: capture.representations.map(ManifestEntry.init)
            )
            capture.digest = ContentDigest.sha256(try capture.manifest.canonicalData())

            let cases: [(String, [RecordValue])] = [
                ("item.sourceApp", [.item(sourceAppItem)]),
                ("item.title", [.item(titleItem)]),
                ("memo.title", memoTitle),
                ("memo.sourceRepresentationType", memoSourceType),
                ("memo.languageHint", memoLanguage),
                ("memo.note", memoNote),
                ("capture.typeIdentifier", [.capture(capture)]),
                ("collection.name", [.collection(CollectionValue(name: nul))]),
                ("collection.color", [.collection(CollectionValue(name: "color", color: nul))])
            ]

            for (field, values) in cases {
                await assertInvalidTransaction(
                    values,
                    field: field,
                    controller: controller
                )
            }

            let itemID = ItemID()
            let body = Data([0x61, 0x00, 0x62])
            let memo = MemoValue(
                itemID: itemID,
                bodyMode: .ownedPlainText,
                body: body,
                version: ContentVersion(),
                digest: ContentDigest.sha256(body)
            )
            let item = ItemValue(id: itemID, title: "NUL data is valid", memoID: memo.id)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.memo(memo)), .insert(.item(item))]
            ))
            let content = try await ContentRepository(controller: controller).read(ContentRef(
                itemID: itemID,
                facet: .memo,
                version: try XCTUnwrap(memo.version),
                digest: try XCTUnwrap(memo.digest)
            ))
            XCTAssertEqual(content.representations.first?.bytes, body)
        }
    }

    func testCapturePurgeDeletesRelationshipChildrenWhoseSnapshotIDIsInconsistentAcrossReopen() async throws {
        let directory = try makeDirectory()
        var controller: PersistenceController? = try PersistenceController(directory: directory)
        var reopenedController: PersistenceController?
        do {
            let active = try XCTUnwrap(controller)
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("purge target".utf8))]
            ])
            var item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: active)
            let repository = ContentRepository(controller: active)
            let itemState = try await repository.recordState(.item(item.id))
            item.historyEligible = false
            item.captureID = nil
            _ = try await WriteCoordinator(controller: active).commit(StoreTransaction(
                identity: try await active.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
                mutations: [.update(.item(item))]
            ))
            let captureState = try await repository.recordState(.capture(capture.id))

            let anomalousRepresentationID = UUID()
            try await active.perform { context in
                context.reset()
                guard let captureObject = try StoredRecords.object(.capture(capture.id), in: context) else {
                    throw StoreError.notFound
                }
                let bytes = Data("relationship-only child".utf8)
                let child = NSEntityDescription.insertNewObject(
                    forEntityName: "CaptureRepresentation",
                    into: context
                )
                child.setValue(anomalousRepresentationID, forKey: "id")
                child.setValue(UUID(), forKey: "snapshotID")
                child.setValue(Int64(0), forKey: "itemIndex")
                child.setValue(Int64(0), forKey: "representationIndex")
                child.setValue("public.utf8-plain-text", forKey: "typeIdentifier")
                child.setValue(RepresentationStorage.portable.rawValue, forKey: "storage")
                child.setValue(Int64(bytes.count), forKey: "byteCount")
                child.setValue(ContentDigest.sha256(bytes), forKey: "digest")
                child.setValue(bytes, forKey: "bytes")
                child.setValue(captureObject, forKey: "snapshot")
                try context.save()
                context.reset()
            }

            let references = try await repository.referenceFingerprint(snapshotID: capture.id)
            let permit = try await StoreSafetyGate(controller: active).permit(.maintenance)
            _ = try await WriteCoordinator(controller: active).commit(StoreTransaction(
                identity: try await active.identity(),
                preconditions: [
                    .recordUnchanged(.capture(capture.id), fingerprint: captureState.fingerprint),
                    .referenceSet(snapshotID: capture.id, fingerprint: references)
                ],
                mutations: [.delete(.capture(capture.id))],
                permit: permit
            ))

            try await active.close()
            controller = nil
            let reopened = try PersistenceController(directory: directory)
            reopenedController = reopened
            let remaining = try await representationCount(id: anomalousRepresentationID, in: reopened)
            XCTAssertEqual(remaining, 0, "Capture purge left a relationship child with an inconsistent snapshotID")
            try await reopened.close()
            reopenedController = nil
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller?.close()
            try? await reopenedController?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func testDetachedItemCannotRebindToAnotherCaptureEvenWhenTheOldGenerationIsMarked() async throws {
        try await withStore { controller in
            let writer = WriteCoordinator(controller: controller)
            let repository = ContentRepository(controller: controller)
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let originalCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("original generation".utf8))]
            ])
            var item = ContentStoreFixtures.item(originalCapture)
            try await ContentStoreFixtures.insert(item, originalCapture, into: controller)
            let originalState = try await repository.recordState(.item(item.id))
            item.captureID = nil
            item.historyEligible = false
            let oldGenerationMarker = FacetDeletionMarkerValue(
                itemID: item.id,
                facet: .history,
                generationID: originalCapture.id
            )
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: originalState.fingerprint)],
                mutations: [.update(.item(item)), .insert(.facetMarker(oldGenerationMarker))],
                permit: permit
            ))

            let replacementCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("replacement generation".utf8))]
            ])
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.capture(replacementCapture))]
            ))
            let detachedState = try await repository.recordState(.item(item.id))
            var rebound = item
            rebound.captureID = replacementCapture.id
            rebound.historyEligible = true

            do {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.item(item.id), fingerprint: detachedState.fingerprint)],
                    mutations: [.update(.item(rebound))]
                ))
                XCTFail("An existing item rebound from X through nil to Y")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            guard case .item(let persisted) = try await repository.recordState(.item(item.id)).value else {
                return XCTFail("The detached item changed type")
            }
            XCTAssertNil(persisted.captureID)
            XCTAssertFalse(persisted.historyEligible)
        }
    }

    func testDuplicateMutationKeysAreRejectedBeforeExecutionAndCreateNoHistory() async throws {
        try await withStore { controller in
            let writer = WriteCoordinator(controller: controller)
            let repository = ContentRepository(controller: controller)
            let reader = StoreChangeReader(controller: controller)
            let baseline = try await reader.read(after: nil)
            let duplicateInsert = CollectionValue(name: "duplicate insert")

            do {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.collection(duplicateInsert)), .insert(.collection(duplicateInsert))]
                ))
                XCTFail("Duplicate insert keys were accepted")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            try await assertMissing(.collection(duplicateInsert.id), in: controller)
            let insertFailureHistory = try await reader.read(after: baseline.token)
            XCTAssertTrue(insertFailureHistory.transactions.isEmpty)

            let duplicateDelete = CollectionValue(name: "duplicate delete")
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.collection(duplicateDelete))]
            ))
            let deleteBaseline = try await reader.read(after: baseline.token)
            let state = try await repository.recordState(.collection(duplicateDelete.id))
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            do {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [
                        .recordUnchanged(.collection(duplicateDelete.id), fingerprint: state.fingerprint)
                    ],
                    mutations: [.delete(.collection(duplicateDelete.id)), .delete(.collection(duplicateDelete.id))],
                    permit: permit
                ))
                XCTFail("Duplicate delete keys were accepted")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            _ = try await repository.recordState(.collection(duplicateDelete.id))
            let deleteFailureHistory = try await reader.read(after: deleteBaseline.token)
            XCTAssertTrue(deleteFailureHistory.transactions.isEmpty)

            let duplicateUpdate = CollectionValue(name: "duplicate update")
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.collection(duplicateUpdate))]
            ))
            let updateState = try await repository.recordState(.collection(duplicateUpdate.id))
            let updateBaseline = try await reader.read(after: deleteBaseline.token)
            var updated = duplicateUpdate
            updated.name = "must roll back"
            do {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [
                        .recordUnchanged(.collection(duplicateUpdate.id), fingerprint: updateState.fingerprint)
                    ],
                    mutations: [.update(.collection(updated)), .update(.collection(updated))]
                ))
                XCTFail("Duplicate update keys were accepted")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            guard case .collection(let persisted) = try await repository.recordState(
                .collection(duplicateUpdate.id)
            ).value else {
                return XCTFail("The duplicate-update collection changed type")
            }
            XCTAssertEqual(persisted.name, duplicateUpdate.name)
            let updateFailureHistory = try await reader.read(after: updateBaseline.token)
            XCTAssertTrue(updateFailureHistory.transactions.isEmpty)
        }
    }

    func testCoordinatorClearsTransactionAuthorBeforeAnUncoordinatedSave() async throws {
        try await withStore { controller in
            let writer = WriteCoordinator(controller: controller)
            let coordinated = CollectionValue(name: "coordinated")
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.collection(coordinated))]
            ))
            let direct = CollectionValue(name: "direct")
            let directKey = RecordKey.collection(direct.id)
            try await controller.perform { context in
                context.reset()
                let object = NSEntityDescription.insertNewObject(forEntityName: directKey.entity, into: context)
                try StoredRecords.write(.collection(direct), to: object, in: context)
                try context.save()
                context.reset()
            }

            let history = try await StoreChangeReader(controller: controller).read(after: nil)
            let directTransaction = history.transactions.first { transaction in
                transaction.changes.contains {
                    $0.entity == directKey.entity && $0.id == direct.id.rawValue
                }
            }
            XCTAssertNotNil(directTransaction)
            XCTAssertNil(directTransaction?.author, "A direct save inherited the prior coordinator transaction author")

            let invalidItem = ItemValue(title: "failed coordinator write", memoID: UUID())
            do {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.item(invalidItem))]
                ))
                XCTFail("The synthetic coordinator failure unexpectedly committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            let directAfterFailure = CollectionValue(name: "direct after failure")
            let failureKey = RecordKey.collection(directAfterFailure.id)
            try await controller.perform { context in
                context.reset()
                let object = NSEntityDescription.insertNewObject(
                    forEntityName: failureKey.entity,
                    into: context
                )
                try StoredRecords.write(.collection(directAfterFailure), to: object, in: context)
                try context.save()
                context.reset()
            }
            let historyAfterFailure = try await StoreChangeReader(controller: controller).read(after: history.token)
            let postFailureTransaction = historyAfterFailure.transactions.first { transaction in
                transaction.changes.contains {
                    $0.entity == failureKey.entity && $0.id == directAfterFailure.id.rawValue
                }
            }
            XCTAssertNotNil(postFailureTransaction)
            XCTAssertNil(
                postFailureTransaction?.author,
                "A direct save inherited the author of a rolled-back coordinator transaction"
            )
        }
    }

    func testEveryTransactionDateMustBeFiniteAndInvalidDatesRollBack() async throws {
        try await withStore { controller in
            let invalid = Date(timeIntervalSince1970: .nan)
            var createdAt = ItemValue(title: "createdAt")
            createdAt.createdAt = invalid
            var historyDeletedAt = ItemValue(title: "historyDeletedAt")
            historyDeletedAt.historyDeletedAt = invalid
            var historyPurgeAfter = ItemValue(title: "historyPurgeAfter")
            historyPurgeAfter.historyPurgeAfter = invalid
            var deletedAt = ItemValue(title: "deletedAt")
            deletedAt.deletedAt = invalid
            var lastCopiedAt = ItemValue(title: "lastCopiedAt")
            lastCopiedAt.lastCopiedAt = invalid

            let memoDeletedAt = makeOwnedMemoValues { $0.deletedAt = invalid }
            let memoPurgeAfter = makeOwnedMemoValues { $0.purgeAfter = invalid }
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let marker = ItemDeletionMarkerValue(itemID: ItemID(), deletedAt: invalid)
            let facetMarker = FacetDeletionMarkerValue(
                itemID: ItemID(),
                facet: .history,
                generationID: UUID(),
                purgedAt: invalid
            )

            let ordinaryCases: [(String, [RecordValue])] = [
                ("item.createdAt", [.item(createdAt)]),
                ("item.historyDeletedAt", [.item(historyDeletedAt)]),
                ("item.historyPurgeAfter", [.item(historyPurgeAfter)]),
                ("item.deletedAt", [.item(deletedAt)]),
                ("item.lastCopiedAt", [.item(lastCopiedAt)]),
                ("memo.deletedAt", memoDeletedAt),
                ("memo.purgeAfter", memoPurgeAfter),
                ("collection.deletedAt", [.collection(CollectionValue(name: "invalid date", deletedAt: invalid))])
            ]
            for (field, values) in ordinaryCases {
                await assertInvalidTransaction(values, field: field, controller: controller)
            }
            await assertInvalidTransaction(
                [.itemMarker(marker)],
                field: "itemMarker.deletedAt",
                controller: controller,
                permit: permit
            )
            await assertInvalidTransaction(
                [.facetMarker(facetMarker)],
                field: "facetMarker.purgedAt",
                controller: controller,
                permit: permit
            )

            for seconds in [Double.infinity, -Double.infinity] {
                var item = ItemValue(title: "infinite date")
                item.lastCopiedAt = Date(timeIntervalSince1970: seconds)
                await assertInvalidTransaction(
                    [.item(item)],
                    field: "item.lastCopiedAt=\(seconds)",
                    controller: controller
                )
            }
        }
    }

    func testMetadataOnlyUpdateAllowsAnUnchangedRecoveringReference() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("temporarily unavailable".utf8))]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            try await controller.perform { context in
                context.reset()
                guard let captureObject = try StoredRecords.object(.capture(capture.id), in: context) else {
                    throw StoreError.notFound
                }
                context.delete(captureObject)
                try context.save()
                context.reset()
            }

            let repository = ContentRepository(controller: controller)
            let state = try await repository.recordState(.item(item.id))
            var renamed = item
            renamed.title = "metadata survives recovery"
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: state.fingerprint)],
                mutations: [.update(.item(renamed))]
            ))

            guard case .item(let persisted) = try await repository.recordState(.item(item.id)).value else {
                return XCTFail("The recovering item changed type")
            }
            XCTAssertEqual(persisted.title, renamed.title)
            XCTAssertEqual(persisted.captureID, capture.id)
        }
    }

    func testDeletionOrderIsPartOfTheTransactionContractAndReverseOrderRollsBack() async throws {
        try await withStore { controller in
            let item = ItemValue(title: "ordered deletion")
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.item(item))]
            ))
            let repository = ContentRepository(controller: controller)
            let state = try await repository.recordState(.item(item.id))
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let marker = ItemDeletionMarkerValue(itemID: item.id)

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.item(item.id), fingerprint: state.fingerprint)],
                    mutations: [.delete(.item(item.id)), .insert(.itemMarker(marker))],
                    permit: permit
                ))
                XCTFail("Reverse mutation order unexpectedly behaved as an unordered transaction")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            _ = try await repository.recordState(.item(item.id))
            try await assertMissing(.itemMarker(item.id), in: controller)
        }
    }

    func testMultipleInvaliditiesHaveNoDiagnosticPriorityButStillRollBack() async throws {
        try await withStore { controller in
            let value = CollectionValue(name: "ambiguous failure")
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.exists(.collection(CollectionID()))],
                    mutations: [.insert(.collection(value)), .insert(.collection(value))]
                ))
                XCTFail("A transaction with multiple invalidities committed")
            } catch {
                XCTAssertTrue(
                    error as? StoreError == .preconditionFailed || error as? StoreError == .invalidTransaction,
                    "The contract does not prioritize which invalidity is reported, but requires a StoreError"
                )
            }
            try await assertMissing(.collection(value.id), in: controller)
        }
    }
}

private extension TransactionReviewTests {
    func withStore<T: Sendable>(
        _ body: (PersistenceController) async throws -> T
    ) async throws -> T {
        let directory = try makeDirectory()
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

    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransactionReviewTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func makeOwnedMemoValues(
        configure: (inout MemoValue) -> Void
    ) -> [RecordValue] {
        let itemID = ItemID()
        let body = Data("valid body".utf8)
        var memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        configure(&memo)
        let item = ItemValue(id: itemID, title: "memo owner", memoID: memo.id)
        return [.memo(memo), .item(item)]
    }

    func assertInvalidTransaction(
        _ values: [RecordValue],
        field: String,
        controller: PersistenceController,
        permit: StorePermit? = nil
    ) async {
        do {
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: values.map(StoreMutation.insert),
                permit: permit
            ))
            XCTFail("Invalid transaction field was persisted: \(field)")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidTransaction, "Unexpected error for \(field)")
        }
        for value in values {
            do {
                _ = try await ContentRepository(controller: controller).recordState(value.key)
                XCTFail("Invalid field \(field) left persisted record \(value.key)")
            } catch {
                XCTAssertEqual(error as? StoreError, .notFound, "Unexpected read error for \(field)")
            }
        }
    }

    func assertMissing(_ key: RecordKey, in controller: PersistenceController) async throws {
        do {
            _ = try await ContentRepository(controller: controller).recordState(key)
            XCTFail("Unexpected record persisted: \(key)")
        } catch {
            XCTAssertEqual(error as? StoreError, .notFound)
        }
    }

    func representationCount(id: UUID, in controller: PersistenceController) async throws -> Int {
        try await controller.perform { context in
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            return try context.count(for: request)
        }
    }
}
