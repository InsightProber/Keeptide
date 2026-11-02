import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class PayloadReclaimerTests: XCTestCase {
    func testPreparedCrashReopensAndCompletesWithoutSweepingUnrelatedFileAccess() async throws {
        try await proveCrashRecovery(at: .afterPrepared)
    }

    func testCloudCommitCrashReopensRecognizesPoststateAndCompletes() async throws {
        try await proveCrashRecovery(at: .afterCloudCommitBeforePhaseRecord)
    }

    func testLocalCleanupCrashRollsBackDeletesAndReopensIdempotently() async throws {
        try await proveCrashRecovery(at: .beforeLocalCompletionSave)
    }

    func testHiddenHistoryMemoCaptureReclaimPreparedCrashReopensAndConverges() async throws {
        try await proveHiddenHistoryMemoCrashRecovery(at: .afterPrepared)
    }

    func testHiddenHistoryMemoCaptureReclaimCloudCommitCrashReopensAndConverges() async throws {
        try await proveHiddenHistoryMemoCrashRecovery(at: .afterCloudCommitBeforePhaseRecord)
    }

    func testHiddenHistoryMemoCaptureReclaimLocalCleanupCrashReopensAndConverges() async throws {
        try await proveHiddenHistoryMemoCrashRecovery(at: .beforeLocalCompletionSave)
    }

    func testExactEnvelopeMismatchBlocksAndPreservesLocalEvidence() async throws {
        let directory = try makeDirectory()
        let controller = try PersistenceController(directory: directory)
        do {
            let fixture = try await makeFixture(controller)
            let intent = try await PayloadReclaimer(controller: controller).prepare(
                fixture.request,
                expecting: fixture.identity,
                permit: fixture.permit,
                at: fixture.now
            )
            try await controller.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
                request.predicate = NSPredicate(
                    format: "id == %@",
                    fixture.representationID as NSUUID
                )
                let row = try XCTUnwrap(context.fetch(request).first)
                row.setValue(Data("tampered envelope".utf8), forKey: "bytes")
                try context.save()
                context.reset()
            }

            do {
                _ = try await PayloadReclaimer(controller: controller).resume(
                    intent.id,
                    expecting: fixture.identity,
                    permit: fixture.permit,
                    at: fixture.now.addingTimeInterval(1)
                )
                XCTFail("Mismatched local evidence was treated as completed")
            } catch {
                XCTAssertEqual(error as? CleanupError, .blocked)
            }
            let blocked = try await CleanupIntentStore(controller: controller).load(
                intent.id,
                expecting: fixture.identity
            )
            XCTAssertEqual(blocked.phase, .blocked)
            let preservedEvidence = try await FileAccessStore(controller: controller).read(
                representationID: fixture.representationID
            )
            XCTAssertNotNil(preservedEvidence)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func proveCrashRecovery(at checkpoint: PayloadReclaimerCheckpoint) async throws {
        let directory = try makeDirectory()
        var controller = try PersistenceController(directory: directory)
        do {
            let fixture = try await makeFixture(controller)
            let injector = CleanupCrashInjector(target: checkpoint)
            do {
                _ = try await PayloadReclaimer(controller: controller, checkpoint: injector.hit).reclaim(
                    fixture.request,
                    expecting: fixture.identity,
                    permit: fixture.permit,
                    at: fixture.now
                )
                XCTFail("Synthetic crash point was not reached")
            } catch is SyntheticCleanupCrash {
                // Expected: every crash point is after a durable boundary or before one atomic LocalState save.
            }

            let intentID = try await onlyIntentID(controller)
            let payloadBeforeResume = try await FileAccessStore(controller: controller).read(
                representationID: fixture.representationID
            )
            XCTAssertNotNil(payloadBeforeResume)
            let usageBeforeResume = try await LocalUsageStore(controller: controller).summaries(for: [fixture.ref])
            XCTAssertEqual(usageBeforeResume.count, 1)
            let unrelatedBeforeResume = try await FileAccessStore(controller: controller).read(
                representationID: fixture.unrelatedRepresentationID
            )
            XCTAssertNotNil(unrelatedBeforeResume)
            try await controller.close()

            controller = try PersistenceController(directory: directory)
            let completed = try await PayloadReclaimer(controller: controller).resume(
                intentID,
                expecting: fixture.identity,
                permit: fixture.permit,
                at: fixture.now.addingTimeInterval(2)
            )
            XCTAssertEqual(completed.phase, .completed)
            let removedPayload = try await FileAccessStore(controller: controller).read(
                representationID: fixture.representationID
            )
            XCTAssertNil(removedPayload)
            let usageAfterResume = try await LocalUsageStore(controller: controller).summaries(for: [fixture.ref])
            XCTAssertTrue(usageAfterResume.isEmpty)
            let unrelatedAfterResume = try await FileAccessStore(controller: controller).read(
                representationID: fixture.unrelatedRepresentationID
            )
            XCTAssertNotNil(unrelatedAfterResume)

            let repeated = try await PayloadReclaimer(controller: controller).resume(
                intentID,
                expecting: fixture.identity,
                permit: fixture.permit,
                at: fixture.now.addingTimeInterval(3)
            )
            XCTAssertEqual(repeated.phase, .completed)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func proveHiddenHistoryMemoCrashRecovery(
        at checkpoint: PayloadReclaimerCheckpoint
    ) async throws {
        let directory = try makeDirectory()
        var controller = try PersistenceController(directory: directory)
        do {
            let fixture = try await makeHiddenHistoryMemoFixture(controller)
            let injector = CleanupCrashInjector(target: checkpoint)
            do {
                _ = try await PayloadReclaimer(controller: controller, checkpoint: injector.hit).reclaim(
                    fixture.request,
                    expecting: fixture.identity,
                    permit: fixture.permit,
                    at: fixture.memoPurgedAt
                )
                XCTFail("Synthetic hidden-history memo cleanup crash point was not reached")
            } catch is SyntheticCleanupCrash {
                // Every checkpoint is either before CloudContent mutation or after a durable boundary.
            }

            let pending = try await CleanupIntentStore(controller: controller).pendingIDs(
                expecting: fixture.identity,
                permit: fixture.permit
            )
            XCTAssertEqual(pending.count, 1)
            let intentID = try XCTUnwrap(pending.first)
            let accessBeforeResume = try await FileAccessStore(controller: controller).read(
                representationID: fixture.representationID
            )
            XCTAssertNotNil(accessBeforeResume)
            let usageBeforeResume = try await LocalUsageStore(controller: controller).summaries(
                for: [fixture.memoRef]
            )
            XCTAssertEqual(usageBeforeResume.count, 1)
            try await controller.close()

            controller = try PersistenceController(directory: directory)
            let reopenedIdentity = try await controller.identity()
            XCTAssertEqual(reopenedIdentity, fixture.identity)
            let reopenedPermit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let completed = try await PayloadReclaimer(controller: controller).resume(
                intentID,
                expecting: reopenedIdentity,
                permit: reopenedPermit,
                at: fixture.memoPurgedAt + 1
            )
            XCTAssertEqual(completed.phase, .completed)

            guard case .item(let finalItem) = try await ContentRepository(controller: controller)
                .recordState(.item(fixture.item.id)).value else {
                return XCTFail("Hidden-history memo cleanup removed its owning item")
            }
            var expectedItem = fixture.item
            expectedItem.captureID = nil
            expectedItem.memoID = nil
            expectedItem.historyEligible = false
            expectedItem.historyDeletedAt = nil
            expectedItem.historyPurgeAfter = nil
            expectedItem.collectionID = nil
            expectedItem.isFavorite = false
            XCTAssertEqual(finalItem, expectedItem)
            await assertMissing(.memo(fixture.memo.id), in: controller)
            await assertMissing(.capture(fixture.capture.id), in: controller)
            let cloudRepresentationCount = try await controller.perform { context in
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
                request.predicate = NSPredicate(
                    format: "snapshotID == %@",
                    fixture.capture.id as NSUUID
                )
                return try context.count(for: request)
            }
            XCTAssertEqual(cloudRepresentationCount, 0)

            let removedAccess = try await FileAccessStore(controller: controller).read(
                representationID: fixture.representationID
            )
            XCTAssertNil(removedAccess)
            let unrelatedAccess = try await FileAccessStore(controller: controller).read(
                representationID: fixture.unrelatedRepresentationID
            )
            XCTAssertNotNil(unrelatedAccess)
            let usageAfterResume = try await LocalUsageStore(controller: controller).summaries(
                for: [fixture.historyRef, fixture.memoRef]
            )
            XCTAssertTrue(usageAfterResume.isEmpty)

            let markers = try await facetMarkers(itemID: fixture.item.id, in: controller)
            XCTAssertEqual(markers.count, 2)
            let historyMarker = try XCTUnwrap(markers.first { $0.facet == .history })
            XCTAssertEqual(historyMarker.id, LifecycleCleanupMarkerID.facet(fixture.historyTarget))
            XCTAssertEqual(historyMarker.generationID, fixture.capture.id)
            XCTAssertEqual(historyMarker.purgedAt, fixture.historyPurgedAt)
            let memoMarker = try XCTUnwrap(markers.first { $0.facet == .memo })
            XCTAssertEqual(memoMarker.id, LifecycleCleanupMarkerID.facet(fixture.memoTarget))
            XCTAssertEqual(memoMarker.generationID, fixture.memo.id)
            XCTAssertEqual(memoMarker.purgedAt, fixture.memoPurgedAt)

            let repeated = try await PayloadReclaimer(controller: controller).resume(
                intentID,
                expecting: reopenedIdentity,
                permit: reopenedPermit,
                at: fixture.memoPurgedAt + 2
            )
            XCTAssertEqual(repeated.phase, .completed)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func makeFixture(_ controller: PersistenceController) async throws -> CleanupFixture {
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        let capture = try ContentStoreFixtures.localReferenceCapture()
        let item = ContentStoreFixtures.item(capture)
        let representation = try XCTUnwrap(capture.representations.first)
        let ref = ContentStoreFixtures.ref(item, capture)
        try await ContentStoreFixtures.insertLocalReference(item, capture, into: controller)
        try await LocalUsageStore(controller: controller).record(UseReceipt(ref: ref, outcome: .success))

        let unrelatedRepresentationID = UUID()
        try await FileAccessStore(controller: controller).put(
            LocalFileAccess(
                id: unrelatedRepresentationID,
                snapshotID: UUID(),
                bytes: Data("file:///Synthetic/prepared-unrelated.txt".utf8)
            ),
            expecting: identity
        )

        let repository = ContentRepository(controller: controller)
        let itemState = try await repository.recordState(.item(item.id))
        let captureState = try await repository.recordState(.capture(capture.id))
        let references = try await repository.referenceFingerprint(snapshotID: capture.id)
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        var hidden = item
        hidden.captureID = nil
        hidden.historyEligible = false
        hidden.historyDeletedAt = nil
        hidden.historyPurgeAfter = nil
        let marker = FacetDeletionMarkerValue(
            itemID: item.id,
            facet: .history,
            generationID: capture.id,
            purgedAt: now
        )
        return CleanupFixture(
            identity: identity,
            permit: permit,
            request: CleanupRequest(
                target: .facet(.history(itemID: item.id, captureID: capture.id)),
                preconditions: [
                    .recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint),
                    .recordUnchanged(.capture(capture.id), fingerprint: captureState.fingerprint),
                    .referenceSet(snapshotID: capture.id, fingerprint: references),
                ],
                mutations: [
                    .insert(.facetMarker(marker)),
                    .update(.item(hidden)),
                    .delete(.capture(capture.id)),
                ]
            ),
            ref: ref,
            representationID: representation.id,
            unrelatedRepresentationID: unrelatedRepresentationID,
            now: now
        )
    }

    private func makeHiddenHistoryMemoFixture(
        _ controller: PersistenceController
    ) async throws -> HiddenHistoryMemoCleanupFixture {
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        let capture = try ContentStoreFixtures.localReferenceCapture()
        let representation = try XCTUnwrap(capture.representations.first)
        var item = ContentStoreFixtures.item(capture)
        item.collectionID = CollectionID()
        item.isFavorite = true
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        item.memoID = memo.id
        try await FileAccessStore(controller: controller).put(
            LocalFileAccess(
                id: representation.id,
                snapshotID: capture.id,
                bytes: Data("file:///Synthetic/hidden-history-memo.txt".utf8)
            ),
            expecting: identity
        )
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: identity,
            mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
        ))
        let historyRef = ContentStoreFixtures.ref(item, capture)
        let memoRef = ContentStoreFixtures.ref(item, capture, facet: .memo)
        try await LocalUsageStore(controller: controller).record(
            UseReceipt(ref: historyRef, outcome: .success)
        )
        try await LocalUsageStore(controller: controller).record(
            UseReceipt(ref: memoRef, outcome: .success)
        )
        let unrelatedRepresentationID = UUID()
        try await FileAccessStore(controller: controller).put(
            LocalFileAccess(
                id: unrelatedRepresentationID,
                snapshotID: UUID(),
                bytes: Data("file:///Synthetic/unrelated-hidden-history.txt".utf8)
            ),
            expecting: identity
        )

        let lifecycle = LifecycleService(controller: controller)
        let historyRemovedAt = Date(timeIntervalSinceReferenceDate: 31_000_000)
        let historyPurgedAt = historyRemovedAt + 1
        let historyTarget = try await lifecycle.remove(
            itemID: item.id,
            facet: .history,
            at: historyRemovedAt,
            expecting: identity,
            permit: permit
        ).target
        _ = try await LifecycleCleanupService(controller: controller).purgeFacet(
            historyTarget,
            trigger: .explicitUserRequest,
            at: historyPurgedAt,
            expecting: identity,
            permit: permit
        )
        let historyUsage = try await LocalUsageStore(controller: controller).summaries(for: [historyRef])
        XCTAssertTrue(historyUsage.isEmpty)
        let retainedAccess = try await FileAccessStore(controller: controller).read(
            representationID: representation.id
        )
        XCTAssertNotNil(retainedAccess)

        let memoRemovedAt = historyPurgedAt + 1
        let memoPurgedAt = memoRemovedAt + 1
        let memoTarget = try await lifecycle.remove(
            itemID: item.id,
            facet: .memo,
            at: memoRemovedAt,
            expecting: identity,
            permit: permit
        ).target
        let request = try await LifecycleCleanupPlanner(controller: controller).facetRequest(
            memoTarget,
            trigger: .explicitUserRequest,
            at: memoPurgedAt,
            expecting: identity,
            permit: permit
        )
        XCTAssertTrue(request.mutations.contains(.delete(.capture(capture.id))))
        XCTAssertTrue(request.mutations.contains(.delete(.memo(memo.id))))

        return HiddenHistoryMemoCleanupFixture(
            identity: identity,
            permit: permit,
            request: request,
            item: item,
            capture: capture,
            memo: memo,
            historyRef: historyRef,
            memoRef: memoRef,
            representationID: representation.id,
            unrelatedRepresentationID: unrelatedRepresentationID,
            historyTarget: historyTarget,
            memoTarget: memoTarget,
            historyPurgedAt: historyPurgedAt,
            memoPurgedAt: memoPurgedAt
        )
    }

    private func onlyIntentID(_ controller: PersistenceController) async throws -> UUID {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")
            let rows = try context.fetch(request)
            guard rows.count == 1, let id = rows.first?.value(forKey: "id") as? UUID else {
                throw StoreError.corruptStore
            }
            return id
        }
    }

    private func facetMarkers(
        itemID: ItemID,
        in controller: PersistenceController
    ) async throws -> [FacetDeletionMarkerValue] {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FacetDeletionMarker")
            request.predicate = NSPredicate(format: "itemID == %@", itemID.rawValue as NSUUID)
            return try context.fetch(request).map { object in
                guard let id = object.value(forKey: "id") as? UUID,
                      let rawItemID = object.value(forKey: "itemID") as? UUID,
                      let rawFacet = object.value(forKey: "facet") as? String,
                      let facet = ContentFacet(rawValue: rawFacet),
                      let generationID = object.value(forKey: "generationID") as? UUID,
                      let purgedAt = object.value(forKey: "purgedAt") as? Date else {
                    throw StoreError.corruptStore
                }
                return FacetDeletionMarkerValue(
                    id: id,
                    itemID: ItemID(rawValue: rawItemID),
                    facet: facet,
                    generationID: generationID,
                    purgedAt: purgedAt
                )
            }
        }
    }

    private func assertMissing(
        _ key: RecordKey,
        in controller: PersistenceController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ContentRepository(controller: controller).recordState(key)
            XCTFail("Record survived cleanup", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StoreError, .notFound, file: file, line: line)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PayloadReclaimerTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct CleanupFixture: Sendable {
    let identity: StoreIdentity
    let permit: StorePermit
    let request: CleanupRequest
    let ref: ContentRef
    let representationID: UUID
    let unrelatedRepresentationID: UUID
    let now: Date
}

private struct HiddenHistoryMemoCleanupFixture: Sendable {
    let identity: StoreIdentity
    let permit: StorePermit
    let request: CleanupRequest
    let item: ItemValue
    let capture: CaptureValue
    let memo: MemoValue
    let historyRef: ContentRef
    let memoRef: ContentRef
    let representationID: UUID
    let unrelatedRepresentationID: UUID
    let historyTarget: DeletedFacetIdentity
    let memoTarget: DeletedFacetIdentity
    let historyPurgedAt: Date
    let memoPurgedAt: Date
}

private struct SyntheticCleanupCrash: Error {}

private final class CleanupCrashInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let target: PayloadReclaimerCheckpoint
    private var fired = false

    init(target: PayloadReclaimerCheckpoint) {
        self.target = target
    }

    func hit(_ checkpoint: PayloadReclaimerCheckpoint) throws {
        try lock.withLock {
            guard checkpoint == target, !fired else { return }
            fired = true
            throw SyntheticCleanupCrash()
        }
    }
}
