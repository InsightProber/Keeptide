import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class StoreTransactionTests: XCTestCase {
    func testItemCannotDetachAStillPersistedMemo() async throws {
        try await withStore { controller in
            let (item, memo, ref) = try await insertOwnedMemo(into: controller, body: "attached memo")
            let itemState = try await ContentRepository(controller: controller).recordState(.item(item.id))
            var detached = item
            detached.memoID = nil

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
                    mutations: [.update(.item(detached))]
                ))
                XCTFail("An item detached a still-persisted memo")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }

            let currentItem = try await ContentRepository(controller: controller).recordState(.item(item.id))
            guard case .item(let persisted) = currentItem.value else {
                return XCTFail("The item changed type")
            }
            XCTAssertEqual(persisted.memoID, memo.id)
            let resolved = try await ContentRepository(controller: controller).read(ref)
            XCTAssertEqual(resolved.representations.first?.bytes, Data("attached memo".utf8))
        }
    }

    func testItemPhysicalDeletionCannotLeaveItsMemoOrphaned() async throws {
        try await withStore { controller in
            let (item, memo, _) = try await insertOwnedMemo(into: controller, body: "must retain owner")
            let repository = ContentRepository(controller: controller)
            let itemState = try await repository.recordState(.item(item.id))
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let marker = ItemDeletionMarkerValue(itemID: item.id, deletedAt: Date(timeIntervalSince1970: 500))

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
                    mutations: [.insert(.itemMarker(marker)), .delete(.item(item.id))],
                    permit: permit
                ))
                XCTFail("An owner item was deleted while its memo survived")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }

            _ = try await repository.recordState(.item(item.id))
            _ = try await repository.recordState(.memo(memo.id))
            try await assertMissing(.itemMarker(item.id), in: controller)
        }
    }

    func testItemAndOwnedMemoMayBeDeletedAtomically() async throws {
        try await withStore { controller in
            let (item, memo, _) = try await insertOwnedMemo(into: controller, body: "delete together")
            let repository = ContentRepository(controller: controller)
            let itemState = try await repository.recordState(.item(item.id))
            let memoState = try await repository.recordState(.memo(memo.id))
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let marker = ItemDeletionMarkerValue(itemID: item.id, deletedAt: Date(timeIntervalSince1970: 501))

            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint),
                    .recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)
                ],
                mutations: [
                    .insert(.itemMarker(marker)),
                    .delete(.item(item.id)),
                    .delete(.memo(memo.id))
                ],
                permit: permit
            ))

            try await assertMissing(.item(item.id), in: controller)
            try await assertMissing(.memo(memo.id), in: controller)
            _ = try await repository.recordState(.itemMarker(item.id))
        }
    }

    func testMemoReplacementMayInsertNewMemoAndDeleteOldMemoAtomically() async throws {
        try await withStore { controller in
            let (originalItem, oldMemo, _) = try await insertOwnedMemo(into: controller, body: "old body")
            let repository = ContentRepository(controller: controller)
            let itemState = try await repository.recordState(.item(originalItem.id))
            let oldMemoState = try await repository.recordState(.memo(oldMemo.id))
            let newBody = Data("new body".utf8)
            let newMemo = MemoValue(
                itemID: originalItem.id,
                bodyMode: .ownedPlainText,
                body: newBody,
                version: ContentVersion(),
                digest: ContentDigest.sha256(newBody)
            )
            var replacementItem = originalItem
            replacementItem.memoID = newMemo.id
            let oldMemoMarker = FacetDeletionMarkerValue(
                itemID: originalItem.id,
                facet: .memo,
                generationID: oldMemo.id,
                purgedAt: Date(timeIntervalSince1970: 502)
            )
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)

            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [
                    .recordUnchanged(.item(originalItem.id), fingerprint: itemState.fingerprint),
                    .recordUnchanged(.memo(oldMemo.id), fingerprint: oldMemoState.fingerprint)
                ],
                mutations: [
                    .insert(.memo(newMemo)),
                    .update(.item(replacementItem)),
                    .insert(.facetMarker(oldMemoMarker)),
                    .delete(.memo(oldMemo.id))
                ],
                permit: permit
            ))

            try await assertMissing(.memo(oldMemo.id), in: controller)
            let currentItem = try await repository.recordState(.item(originalItem.id))
            guard case .item(let persisted) = currentItem.value else {
                return XCTFail("The item changed type")
            }
            XCTAssertEqual(persisted.memoID, newMemo.id)
            let replacement = try await repository.read(ContentRef(
                itemID: originalItem.id,
                facet: .memo,
                version: try XCTUnwrap(newMemo.version),
                digest: try XCTUnwrap(newMemo.digest)
            ))
            XCTAssertEqual(replacement.representations.first?.bytes, newBody)
        }
    }

    func testPersistedPortableRepresentationIDCannotBeReusedByAnotherCapture() async throws {
        try await withStore { controller in
            let firstCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("first portable".utf8))]
            ])
            let firstItem = ContentStoreFixtures.item(firstCapture)
            try await ContentStoreFixtures.insert(firstItem, firstCapture, into: controller)
            let reusedID = try XCTUnwrap(firstCapture.representations.first?.id)
            var secondCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("second portable".utf8))]
            ])
            secondCapture.representations[0].id = reusedID
            let secondItem = ContentStoreFixtures.item(secondCapture)

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.capture(secondCapture)), .insert(.item(secondItem))]
                ))
                XCTFail("A persisted portable representation ID was reused by another capture")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            try await assertMissing(.capture(secondCapture.id), in: controller)
            try await assertMissing(.item(secondItem.id), in: controller)
            let representationRows = try await representationCount(id: reusedID, in: controller)
            XCTAssertEqual(representationRows, 1)
            let original = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(firstItem, firstCapture)
            )
            XCTAssertEqual(original.representations.first?.bytes, Data("first portable".utf8))
        }
    }

    func testPendingLocalRepresentationIDCollisionRollsBackTheWholeBatch() async throws {
        try await withStore { controller in
            let reusedID = UUID()
            let firstCapture = try localReferenceCapture(
                representationID: reusedID,
                syntheticBytes: Data("first local target".utf8)
            )
            let secondCapture = try localReferenceCapture(
                representationID: reusedID,
                syntheticBytes: Data("second local target".utf8)
            )
            let firstItem = ContentStoreFixtures.item(firstCapture)
            let secondItem = ContentStoreFixtures.item(secondCapture)

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [
                        .insert(.capture(firstCapture)), .insert(.item(firstItem)),
                        .insert(.capture(secondCapture)), .insert(.item(secondItem))
                    ]
                ))
                XCTFail("Two pending local representations reused one global ID")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            try await assertMissing(.capture(firstCapture.id), in: controller)
            try await assertMissing(.item(firstItem.id), in: controller)
            try await assertMissing(.capture(secondCapture.id), in: controller)
            try await assertMissing(.item(secondItem.id), in: controller)
            let representationRows = try await representationCount(id: reusedID, in: controller)
            XCTAssertEqual(representationRows, 0)
        }
    }

    func testFacetVisibleFalseAcceptsHiddenHistoryHiddenMemoAndMissingItem() async throws {
        try await withStore { controller in
            let writer = WriteCoordinator(controller: controller)
            let repository = ContentRepository(controller: controller)
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("hidden history".utf8))]
            ])
            var historyItem = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(historyItem, capture, into: controller)
            let historyState = try await repository.recordState(.item(historyItem.id))
            historyItem.historyEligible = false
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(historyItem.id), fingerprint: historyState.fingerprint)],
                mutations: [.update(.item(historyItem))]
            ))

            let memoHiddenItem = ItemValue(title: "no memo facet")
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.item(memoHiddenItem))]
            ))
            let missingItemID = ItemID()
            let sentinels = [
                CollectionValue(name: "history hidden precondition"),
                CollectionValue(name: "memo hidden precondition"),
                CollectionValue(name: "missing item precondition")
            ]
            let conditions: [StorePrecondition] = [
                .facetVisible(historyItem.id, .history, false),
                .facetVisible(memoHiddenItem.id, .memo, false),
                .facetVisible(missingItemID, .history, false)
            ]

            for (condition, sentinel) in zip(conditions, sentinels) {
                _ = try await writer.commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [condition],
                    mutations: [.insert(.collection(sentinel))]
                ))
                _ = try await repository.recordState(.collection(sentinel.id))
            }
        }
    }

    func testContentVersionNormalizesHiddenAndMissingContentToFailedPrecondition() async throws {
        try await withStore { controller in
            let writer = WriteCoordinator(controller: controller)
            let repository = ContentRepository(controller: controller)
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("stale history".utf8))]
            ])
            var historyItem = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(historyItem, capture, into: controller)
            let historyRef = ContentStoreFixtures.ref(historyItem, capture)
            let historyState = try await repository.recordState(.item(historyItem.id))
            historyItem.historyEligible = false
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(historyItem.id), fingerprint: historyState.fingerprint)],
                mutations: [.update(.item(historyItem))]
            ))

            let (_, originalMemo, memoRef) = try await insertOwnedMemo(
                into: controller,
                body: "stale memo"
            )
            let memoState = try await repository.recordState(.memo(originalMemo.id))
            var deletedMemo = originalMemo
            deletedMemo.deletedAt = Date(timeIntervalSince1970: 503)
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.memo(originalMemo.id), fingerprint: memoState.fingerprint)],
                mutations: [.update(.memo(deletedMemo))]
            ))

            let missingRef = ContentRef(
                itemID: ItemID(),
                facet: .history,
                version: ContentVersion(),
                digest: Data(repeating: 0x44, count: 32)
            )
            let refs = [historyRef, memoRef, missingRef]
            for (index, ref) in refs.enumerated() {
                let sentinel = CollectionValue(name: "stale content version \(index)")
                do {
                    _ = try await writer.commit(StoreTransaction(
                        identity: try await controller.identity(),
                        preconditions: [.contentVersion(ref)],
                        mutations: [.insert(.collection(sentinel))]
                    ))
                    XCTFail("Hidden or missing content satisfied contentVersion")
                } catch {
                    XCTAssertEqual(error as? StoreError, .preconditionFailed)
                }
                try await assertMissing(.collection(sentinel.id), in: controller)
            }
        }
    }

    func testMemoInsertRequiresItsOwnerItemToExistAndPointBackToIt() async throws {
        try await withStore { controller in
            let missingOwnerID = ItemID()
            let orphanBody = Data("orphan".utf8)
            let orphan = MemoValue(
                itemID: missingOwnerID,
                bodyMode: .ownedPlainText,
                body: orphanBody,
                version: ContentVersion(),
                digest: ContentDigest.sha256(orphanBody)
            )
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.memo(orphan))]
                ))
                XCTFail("A memo without an owner item was committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            try await assertMissing(.memo(orphan.id), in: controller)

            let owner = ItemValue(title: "does not reference the memo")
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.item(owner))]
            ))
            let mismatchedBody = Data("mismatched".utf8)
            let mismatched = MemoValue(
                itemID: owner.id,
                bodyMode: .ownedPlainText,
                body: mismatchedBody,
                version: ContentVersion(),
                digest: ContentDigest.sha256(mismatchedBody)
            )
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.memo(mismatched))]
                ))
                XCTFail("A memo whose owner does not point back to it was committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            try await assertMissing(.memo(mismatched.id), in: controller)
        }
    }

    func testMatchingMemoAndItemMayBeInsertedMemoFirstInOneTransaction() async throws {
        try await withStore { controller in
            let itemID = ItemID()
            let body = Data("owned body".utf8)
            let memo = MemoValue(
                itemID: itemID,
                bodyMode: .ownedPlainText,
                body: body,
                version: ContentVersion(),
                digest: ContentDigest.sha256(body)
            )
            let item = ItemValue(id: itemID, title: "owner", memoID: memo.id)

            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.memo(memo)), .insert(.item(item))]
            ))

            let resolved = try await ContentRepository(controller: controller).read(ContentRef(
                itemID: itemID,
                facet: .memo,
                version: try XCTUnwrap(memo.version),
                digest: try XCTUnwrap(memo.digest)
            ))
            XCTAssertEqual(resolved.representations.first?.bytes, body)
        }
    }

    func testMissingRecordUnchangedKeyIsAFailedPrecondition() async throws {
        try await withStore { controller in
            let missing = CollectionValue(name: "never inserted")
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [
                        .recordUnchanged(.collection(missing.id), fingerprint: Data("stale".utf8))
                    ],
                    mutations: [.update(.collection(missing))]
                ))
                XCTFail("A missing CAS target was updated")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            try await assertMissing(.collection(missing.id), in: controller)
        }
    }

    func testReusedGenerationMustNotReactivateOldTransactionOrMaintenancePermit() async throws {
        try await withStore { controller in
            let gate = StoreSafetyGate(controller: controller)
            let oldIdentity = try await controller.identity()
            let oldMaintenancePermit = try await gate.permit(.maintenance)
            let existing = CollectionValue(name: "must survive stale maintenance")
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: oldIdentity,
                mutations: [.insert(.collection(existing))]
            ))
            let existingState = try await ContentRepository(controller: controller).recordState(.collection(existing.id))

            try await gate.transition(to: .quarantined)
            let quarantinedIdentity = try await controller.identity()
            try await gate.transition(to: .active)
            let activeIdentity = try await controller.identity()
            XCTAssertNotEqual(quarantinedIdentity.generation, oldIdentity.generation)
            XCTAssertNotEqual(activeIdentity.generation, quarantinedIdentity.generation)
            XCTAssertNotEqual(activeIdentity.generation, oldIdentity.generation)

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: oldIdentity,
                    preconditions: [
                        .recordUnchanged(.collection(existing.id), fingerprint: existingState.fingerprint)
                    ],
                    mutations: [.delete(.collection(existing.id))],
                    permit: oldMaintenancePermit
                ))
                XCTFail("Generation reuse reactivated an old maintenance permit")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            _ = try await ContentRepository(controller: controller).recordState(.collection(existing.id))

            let staleInsert = CollectionValue(name: "stale writer")
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: oldIdentity,
                    mutations: [.insert(.collection(staleInsert))]
                ))
                XCTFail("Generation reuse reactivated an old writer")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            try await assertMissing(.collection(staleInsert.id), in: controller)
        }
    }

    func testFailureAfterEarlierMutationsRollsBackTheWholeTransaction() async throws {
        try await withStore { controller in
            let originalCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("original".utf8))]
            ])
            let originalItem = ContentStoreFixtures.item(originalCapture)
            try await ContentStoreFixtures.insert(originalItem, originalCapture, into: controller)

            let newCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("must roll back".utf8))]
            ])
            let invalidItem = ItemValue(
                title: "references a missing memo",
                captureID: newCapture.id,
                memoID: UUID(),
                historyEligible: true
            )
            let transaction = StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.capture(newCapture)), .insert(.item(invalidItem))]
            )

            do {
                _ = try await WriteCoordinator(controller: controller).commit(transaction)
                XCTFail("A transaction with a missing memo reference was committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }

            try await assertMissing(.capture(newCapture.id), in: controller)
            try await assertMissing(.item(invalidItem.id), in: controller)
            let recent = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertEqual(recent.map(\.itemID), [originalItem.id])
            let original = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(originalItem, originalCapture)
            )
            XCTAssertEqual(original.representations.first?.bytes, Data("original".utf8))
        }
    }

    func testCoreDataSaveValidationFailureRollsBackPriorMutationAcrossReopen() async throws {
        let directory = try makeDirectory()
        let model = try modelRejectingInvalidCollectionName()
        var controller: PersistenceController? = try PersistenceController(directory: directory, model: model)
        do {
            let active = try XCTUnwrap(controller)
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("stable payload".utf8))]
            ])
            let originalItem = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(originalItem, capture, into: active)
            let state = try await ContentRepository(controller: active).recordState(.item(originalItem.id))
            var changedItem = originalItem
            changedItem.title = "must not persist"
            let invalidCollection = CollectionValue(name: Self.invalidCollectionName)

            do {
                _ = try await WriteCoordinator(controller: active).commit(StoreTransaction(
                    identity: try await active.identity(),
                    preconditions: [.recordUnchanged(.item(originalItem.id), fingerprint: state.fingerprint)],
                    mutations: [.update(.item(changedItem)), .insert(.collection(invalidCollection))]
                ))
                XCTFail("The injected Core Data validation failure did not reach save")
            } catch {
                let validationError = error as NSError
                XCTAssertEqual(validationError.domain, NSCocoaErrorDomain)
                XCTAssertTrue(
                    validationError.code == NSManagedObjectValidationError
                        || validationError.code == NSValidationMultipleErrorsError,
                    "Unexpected save error: \(validationError)"
                )
            }

            try await active.close()
            controller = nil
            let reopened = try PersistenceController(directory: directory, model: model)
            let reopenedState = try await ContentRepository(controller: reopened).recordState(.item(originalItem.id))
            guard case .item(let persistedItem) = reopenedState.value else {
                return XCTFail("The original item changed type")
            }
            XCTAssertEqual(persistedItem.title, originalItem.title)
            XCTAssertEqual(persistedItem.captureID, capture.id)
            try await assertMissing(.collection(invalidCollection.id), in: reopened)
            let resolved = try await ContentRepository(controller: reopened).read(
                ContentStoreFixtures.ref(originalItem, capture)
            )
            XCTAssertEqual(resolved.representations.first?.bytes, Data("stable payload".utf8))
            try await reopened.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller?.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func testStaleRecordCASRejectsASecondWriterWithoutOverwritingTheWinner() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("payload".utf8))]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let staleState = try await ContentRepository(controller: controller).recordState(.item(item.id))

            var winner = item
            winner.title = "winner"
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: staleState.fingerprint)],
                mutations: [.update(.item(winner))]
            ))

            var staleLoser = item
            staleLoser.title = "stale loser"
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.item(item.id), fingerprint: staleState.fingerprint)],
                    mutations: [.update(.item(staleLoser))]
                ))
                XCTFail("A stale record fingerprint overwrote the winning writer")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }

            let current = try await ContentRepository(controller: controller).recordState(.item(item.id))
            guard case .item(let currentItem) = current.value else {
                return XCTFail("The item changed type")
            }
            XCTAssertEqual(currentItem.title, "winner")
        }
    }

    func testCandidateAndReferenceFingerprintsRejectIntentAfterTheirSetsChange() async throws {
        try await withStore { controller in
            let firstCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("first".utf8))]
            ])
            var firstItem = ContentStoreFixtures.item(firstCapture)
            try await ContentStoreFixtures.insert(firstItem, firstCapture, into: controller)
            let repository = ContentRepository(controller: controller)
            let oldCandidates = try await repository.candidateFingerprint()
            let oldReferences = try await repository.referenceFingerprint(snapshotID: firstCapture.id)

            let secondCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("second".utf8))]
            ])
            let secondItem = ContentStoreFixtures.item(secondCapture)
            try await ContentStoreFixtures.insert(secondItem, secondCapture, into: controller)
            let candidateSentinel = CollectionValue(name: "must not be inserted from stale candidates")
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.candidateSet(fingerprint: oldCandidates)],
                    mutations: [.insert(.collection(candidateSentinel))]
                ))
                XCTFail("A stale candidate-set intent was committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            try await assertMissing(.collection(candidateSentinel.id), in: controller)

            let itemState = try await repository.recordState(.item(firstItem.id))
            firstItem.historyEligible = false
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(firstItem.id), fingerprint: itemState.fingerprint)],
                mutations: [.update(.item(firstItem))]
            ))
            let referenceSentinel = CollectionValue(name: "must not be inserted from stale references")
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.referenceSet(snapshotID: firstCapture.id, fingerprint: oldReferences)],
                    mutations: [.insert(.collection(referenceSentinel))]
                ))
                XCTFail("A stale reference-set intent was committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            try await assertMissing(.collection(referenceSentinel.id), in: controller)
        }
    }

    func testQuarantineRejectsWritesAndCapturePayloadIsImmutable() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("immutable".utf8))]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let captureState = try await ContentRepository(controller: controller).recordState(.capture(capture.id))
            var replacement = capture
            replacement.representations[0].bytes = Data("replacement".utf8)
            replacement.representations[0].byteCount = Int64(replacement.representations[0].bytes?.count ?? 0)
            replacement.representations[0].digest = ContentDigest.sha256(replacement.representations[0].bytes ?? Data())
            replacement.manifest = CaptureManifest(
                itemCount: 1,
                entries: replacement.representations.map(ManifestEntry.init)
            )
            replacement.digest = ContentDigest.sha256(try replacement.manifest.canonicalData())

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.capture(capture.id), fingerprint: captureState.fingerprint)],
                    mutations: [.update(.capture(replacement))]
                ))
                XCTFail("An existing capture payload was updated")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            let original = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(original.representations.first?.bytes, Data("immutable".utf8))

            try await StoreSafetyGate(controller: controller).transition(to: .quarantined)
            let blocked = CollectionValue(name: "blocked")
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.collection(blocked))]
                ))
                XCTFail("Quarantine allowed a content write")
            } catch {
                XCTAssertEqual(error as? StoreError, .operationDenied)
            }
            try await assertMissing(.collection(blocked.id), in: controller)
        }
    }

    func testItemDeletionMarkerPreventsResurrectionAfterPhysicalDeletion() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("deleted item".utf8))]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let repository = ContentRepository(controller: controller)
            let gate = StoreSafetyGate(controller: controller)
            let permit = try await gate.permit(.maintenance)
            let itemState = try await repository.recordState(.item(item.id))
            var tombstoned = item
            tombstoned.deletedAt = Date(timeIntervalSince1970: 300)
            tombstoned.historyEligible = false
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
                mutations: [
                    .update(.item(tombstoned)),
                    .insert(.itemMarker(ItemDeletionMarkerValue(itemID: item.id, deletedAt: tombstoned.deletedAt!)))
                ],
                permit: permit
            ))
            let tombstonedState = try await repository.recordState(.item(item.id))
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: tombstonedState.fingerprint)],
                mutations: [.delete(.item(item.id))],
                permit: permit
            ))

            do {
                _ = try await repository.read(ContentStoreFixtures.ref(item, capture))
                XCTFail("A deleted item remained visible")
            } catch {
                XCTAssertEqual(error as? StoreError, .notFound)
            }
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    mutations: [.insert(.item(item))]
                ))
                XCTFail("An item deletion marker allowed resurrection")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            let recent = try await repository.recent(limit: 10)
            XCTAssertTrue(recent.isEmpty)
        }
    }

    func testFacetMarkerKeepsHistoryHiddenAndPreventsReenable() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("hidden history".utf8))]
            ])
            var item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let repository = ContentRepository(controller: controller)
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let visibleState = try await repository.recordState(.item(item.id))
            item.historyEligible = false
            item.historyDeletedAt = Date(timeIntervalSince1970: 400)
            let marker = FacetDeletionMarkerValue(
                itemID: item.id,
                facet: .history,
                generationID: capture.id,
                purgedAt: item.historyDeletedAt!
            )
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: visibleState.fingerprint)],
                mutations: [.update(.item(item)), .insert(.facetMarker(marker))],
                permit: permit
            ))

            do {
                _ = try await repository.read(ContentStoreFixtures.ref(item, capture))
                XCTFail("A facet deletion marker left history visible")
            } catch {
                XCTAssertEqual(error as? StoreError, .notFound)
            }
            let hiddenState = try await repository.recordState(.item(item.id))
            item.historyEligible = true
            item.historyDeletedAt = nil
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.item(item.id), fingerprint: hiddenState.fingerprint)],
                    mutations: [.update(.item(item))]
                ))
                XCTFail("A marked history facet was re-enabled")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
        }
    }

    func testEditingInheritedMemoCreatesOwnedBodyWithoutChangingHistoryBytes() async throws {
        try await withStore { controller in
            let historyBytes = Data("immutable history".utf8)
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", historyBytes)]
            ])
            let itemID = ItemID()
            var memo = MemoValue(itemID: itemID, bodyMode: .inheritedCapture)
            let item = ItemValue(
                id: itemID,
                title: "inherited memo",
                captureID: capture.id,
                memoID: memo.id,
                historyEligible: true
            )
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
            ))
            let memoState = try await ContentRepository(controller: controller).recordState(.memo(memo.id))
            let editedBody = Data("independent memo body".utf8)
            memo.bodyMode = .ownedPlainText
            memo.body = editedBody
            memo.version = ContentVersion()
            memo.digest = ContentDigest.sha256(editedBody)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)],
                mutations: [.update(.memo(memo))]
            ))

            let history = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(history.representations.first?.bytes, historyBytes)
            let memoContent = try await ContentRepository(controller: controller).read(ContentRef(
                itemID: itemID,
                facet: .memo,
                version: try XCTUnwrap(memo.version),
                digest: try XCTUnwrap(memo.digest)
            ))
            XCTAssertEqual(memoContent.representations.first?.bytes, editedBody)
        }
    }

    func testOwnedMemoBodyChangeCannotReuseItsCurrentVersion() async throws {
        try await withStore { controller in
            let itemID = ItemID()
            let originalBody = Data("original memo".utf8)
            var memo = MemoValue(
                itemID: itemID,
                bodyMode: .ownedPlainText,
                body: originalBody,
                version: ContentVersion(),
                digest: ContentDigest.sha256(originalBody)
            )
            let item = ItemValue(id: itemID, title: "owned memo", memoID: memo.id)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.memo(memo)), .insert(.item(item))]
            ))
            let originalRef = ContentRef(
                itemID: itemID,
                facet: .memo,
                version: try XCTUnwrap(memo.version),
                digest: try XCTUnwrap(memo.digest)
            )
            let memoState = try await ContentRepository(controller: controller).recordState(.memo(memo.id))
            let changedBody = Data("changed without a new version".utf8)
            memo.body = changedBody
            memo.digest = ContentDigest.sha256(changedBody)

            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: try await controller.identity(),
                    preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)],
                    mutations: [.update(.memo(memo))]
                ))
                XCTFail("A changed owned memo reused its current version")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }

            let original = try await ContentRepository(controller: controller).read(originalRef)
            XCTAssertEqual(original.representations.first?.bytes, originalBody)
        }
    }
}

private extension StoreTransactionTests {
    static let invalidCollectionName = "__synthetic_save_validation_failure__"

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
            .appendingPathComponent("StoreTransactionTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func modelRejectingInvalidCollectionName() throws -> NSManagedObjectModel {
        guard let model = try PersistenceController.loadModel().copy() as? NSManagedObjectModel,
              let name = model.entitiesByName["Collection"]?.attributesByName["name"] else {
            throw StoreTransactionTestFailure.invalidModelCopy
        }
        name.setValidationPredicates(
            [NSPredicate(format: "SELF != %@", Self.invalidCollectionName)],
            withValidationWarnings: ["Synthetic collection name rejected at save time"]
        )
        return model
    }

    func assertMissing(_ key: RecordKey, in controller: PersistenceController) async throws {
        do {
            _ = try await ContentRepository(controller: controller).recordState(key)
            XCTFail("Unexpected record persisted: \(key)")
        } catch {
            XCTAssertEqual(error as? StoreError, .notFound)
        }
    }

    func insertOwnedMemo(
        into controller: PersistenceController,
        body text: String
    ) async throws -> (ItemValue, MemoValue, ContentRef) {
        let itemID = ItemID()
        let body = Data(text.utf8)
        let memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        let item = ItemValue(id: itemID, title: "memo owner", memoID: memo.id)
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(item))]
        ))
        return (
            item,
            memo,
            ContentRef(
                itemID: itemID,
                facet: .memo,
                version: try XCTUnwrap(memo.version),
                digest: try XCTUnwrap(memo.digest)
            )
        )
    }

    func localReferenceCapture(
        representationID: UUID,
        syntheticBytes: Data
    ) throws -> CaptureValue {
        let captureID = UUID()
        let representation = RepresentationValue(
            id: representationID,
            snapshotID: captureID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: Int64(syntheticBytes.count),
            digest: ContentDigest.sha256(syntheticBytes),
            bytes: nil
        )
        let manifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(representation)])
        return CaptureValue(
            id: captureID,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: [representation]
        )
    }

    func representationCount(id: UUID, in controller: PersistenceController) async throws -> Int {
        try await controller.perform { context in
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            return try context.count(for: request)
        }
    }
}

private enum StoreTransactionTestFailure: Error {
    case invalidModelCopy
}
