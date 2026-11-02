import CoreData
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class LifecycleTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSinceReferenceDate: 10_000_000)

    func testNaturalExpirationHidesOnlyHistoryAndKeepsInheritedMemoCaptureAcrossReopen() async throws {
        let fixture = try await makeFixture(lastCopiedAt: now - 30 * day, memoMode: .inheritedCapture)
        let identity = try await fixture.store.identity()
        let service = LifecycleService(controller: fixture.store)
        let receipt = try await service.expireHistory(
            policy: .days(30),
            at: now,
            expecting: identity,
            permit: try await StoreSafetyGate(controller: fixture.store).permit(.maintenance)
        )

        XCTAssertEqual(receipt.changed, [.history(itemID: fixture.item.id, captureID: fixture.capture.id)])
        XCTAssertEqual(receipt.skippedConflicts, 0)
        guard case .item(let expired) = try await ContentRepository(controller: fixture.store)
            .recordState(.item(fixture.item.id)).value else { return XCTFail("Missing item") }
        XCTAssertFalse(expired.historyEligible)
        XCTAssertNil(expired.historyDeletedAt)
        XCTAssertNil(expired.historyPurgeAfter)
        XCTAssertEqual(expired.captureID, fixture.capture.id)
        _ = try await ContentRepository(controller: fixture.store).recordState(.capture(fixture.capture.id))
        _ = try await ContentRepository(controller: fixture.store).recordState(.memo(try XCTUnwrap(fixture.memo?.id)))
        let trash = try await service.trash(policy: .days(30), at: now, expecting: identity)
        let markerCount = try await facetMarkerCount(in: fixture.store)
        XCTAssertTrue(trash.isEmpty)
        XCTAssertEqual(markerCount, 0)

        let directory = fixture.directory
        try await fixture.store.close()
        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try? await reopened.close() }
        guard case .item(let afterReopen) = try await ContentRepository(controller: reopened)
            .recordState(.item(fixture.item.id)).value else { return XCTFail("Missing reopened item") }
        XCTAssertFalse(afterReopen.historyEligible)
        XCTAssertEqual(afterReopen.captureID, fixture.capture.id)
        _ = try await ContentRepository(controller: reopened).recordState(.capture(fixture.capture.id))
    }

    func testHistorySoftDeleteUsesExactCaptureGenerationAndRestoresOnlyInsideBothWindows() async throws {
        let fixture = try await makeFixture(lastCopiedAt: now - day / 2)
        let identity = try await fixture.store.identity()
        let gate = StoreSafetyGate(controller: fixture.store)
        let service = LifecycleService(controller: fixture.store)
        let removed = try await service.remove(
            itemID: fixture.item.id,
            facet: .history,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(removed.target, .history(itemID: fixture.item.id, captureID: fixture.capture.id))
        guard case .item(let softDeleted) = try await ContentRepository(controller: fixture.store)
            .recordState(.item(fixture.item.id)).value else { return XCTFail("Missing item") }
        XCTAssertFalse(softDeleted.historyEligible)

        let deadline = now + 7 * day
        let trash = try await service.trash(policy: .days(30), at: deadline - 1, expecting: identity)
        XCTAssertEqual(trash.map(\.identity), [removed.target])
        XCTAssertEqual(trash.first?.deletedAt, now)
        XCTAssertEqual(trash.first?.purgeAfter, deadline)
        XCTAssertEqual(trash.first?.canRestore, true)

        _ = try await service.restore(
            removed.target,
            policy: .days(30),
            at: deadline - 1,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        guard case .item(let restored) = try await ContentRepository(controller: fixture.store)
            .recordState(.item(fixture.item.id)).value else { return XCTFail("Missing item") }
        XCTAssertTrue(restored.historyEligible)
        XCTAssertNil(restored.historyDeletedAt)
        XCTAssertNil(restored.historyPurgeAfter)

        let removedAgain = try await service.remove(
            itemID: fixture.item.id,
            facet: .history,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await service.restore(
                removedAgain.target,
                policy: .days(30),
                at: deadline,
                expecting: identity,
                permit: try await gate.permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? LifecycleError, .notRestorable)
        }
        // The manual-deletion window is still open, but retention has expired:
        // lastCopiedAt is now 1.1 days old under a one-day policy.
        let naturallyExpired = now + 0.6 * day
        await XCTAssertThrowsErrorAsync {
            _ = try await service.restore(
                removedAgain.target,
                policy: .days(1),
                at: naturallyExpired,
                expecting: identity,
                permit: try await gate.permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? LifecycleError, .notRestorable)
        }
    }

    func testMemoSoftDeleteIsIndependentOfExpiredHistoryAndRestoresInsideSevenDays() async throws {
        let fixture = try await makeFixture(lastCopiedAt: now - 100 * day, memoMode: .ownedMarkdown)
        let memo = try XCTUnwrap(fixture.memo)
        let identity = try await fixture.store.identity()
        let gate = StoreSafetyGate(controller: fixture.store)
        let service = LifecycleService(controller: fixture.store)
        let removed = try await service.remove(
            itemID: fixture.item.id,
            facet: .memo,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(removed.target, .memo(itemID: fixture.item.id, memoID: memo.id))

        let trash = try await service.trash(policy: .days(1), at: now + day, expecting: identity)
        XCTAssertEqual(trash.first?.identity, removed.target)
        XCTAssertEqual(trash.first?.canRestore, true)
        let historyRef = ContentStoreFixtures.ref(fixture.item, fixture.capture)
        let history = try await ContentRepository(controller: fixture.store).read(historyRef)
        XCTAssertEqual(history.integrity, .complete)

        _ = try await service.restore(
            removed.target,
            policy: .days(1),
            at: now + day,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        guard case .memo(let restored) = try await ContentRepository(controller: fixture.store)
            .recordState(.memo(memo.id)).value else { return XCTFail("Missing memo") }
        XCTAssertNil(restored.deletedAt)
        XCTAssertNil(restored.purgeAfter)
    }

    func testExactSelectedMemoRefCannotDeleteANewerBodyVersion() async throws {
        let fixture = try await makeFixture(lastCopiedAt: now, memoMode: .ownedPlainText)
        var memo = try XCTUnwrap(fixture.memo)
        let oldRef = ContentRef(
            itemID: fixture.item.id,
            facet: .memo,
            version: try XCTUnwrap(memo.version),
            digest: try XCTUnwrap(memo.digest)
        )
        let state = try await ContentRepository(controller: fixture.store).recordState(.memo(memo.id))
        let newerBody = Data("newer selected body".utf8)
        memo.body = newerBody
        memo.version = ContentVersion()
        memo.digest = ContentDigest.sha256(newerBody)
        _ = try await WriteCoordinator(controller: fixture.store).commit(StoreTransaction(
            identity: try await fixture.store.identity(),
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: state.fingerprint)],
            mutations: [.update(.memo(memo))]
        ))

        await XCTAssertThrowsErrorAsync {
            _ = try await LifecycleService(controller: fixture.store).remove(
                ref: oldRef,
                at: now,
                expecting: try await fixture.store.identity(),
                permit: try await StoreSafetyGate(controller: fixture.store).permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        guard case .memo(let preserved) = try await ContentRepository(controller: fixture.store)
            .recordState(.memo(memo.id)).value else { return XCTFail("Missing memo") }
        XCTAssertEqual(preserved.version, memo.version)
        XCTAssertEqual(preserved.body, newerBody)
        XCTAssertNil(preserved.deletedAt)
        XCTAssertNil(preserved.purgeAfter)
    }

    func testExactFacetMarkerBlocksRestoreButAnOldMemoMarkerDoesNotBlockANewGeneration() async throws {
        let fixture = try await makeFixture(lastCopiedAt: now, memoMode: .ownedPlainText)
        let memo = try XCTUnwrap(fixture.memo)
        let identity = try await fixture.store.identity()
        let gate = StoreSafetyGate(controller: fixture.store)
        let service = LifecycleService(controller: fixture.store)
        let removed = try await service.remove(
            itemID: fixture.item.id,
            facet: .memo,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        let purged = try await LifecycleCleanupService(controller: fixture.store).purgeFacet(
            removed.target,
            trigger: .explicitUserRequest,
            at: now + 1,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(purged.phase, .completed)
        await XCTAssertThrowsErrorAsync {
            _ = try await service.restore(
                removed.target,
                policy: .permanent,
                at: now + 2,
                expecting: identity,
                permit: try await gate.permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .notFound)
        }

        let newMemo = ownedMemo(itemID: fixture.item.id, mode: .ownedPlainText, body: "new generation")
        let itemState = try await ContentRepository(controller: fixture.store).recordState(.item(fixture.item.id))
        guard case .item(var updatedItem) = itemState.value else { return XCTFail("Missing item after memo purge") }
        updatedItem.memoID = newMemo.id
        _ = try await WriteCoordinator(controller: fixture.store).commit(StoreTransaction(
            identity: identity,
            preconditions: [.recordUnchanged(.item(fixture.item.id), fingerprint: itemState.fingerprint)],
            mutations: [
                .insert(.memo(newMemo)),
                .update(.item(updatedItem)),
            ]
        ))
        let newRemoval = try await service.remove(
            itemID: fixture.item.id,
            facet: .memo,
            at: now + 3,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(newRemoval.target, .memo(itemID: fixture.item.id, memoID: newMemo.id))
    }

    func testStaleMaintenancePermitCannotSoftDeleteWithCurrentExpectedIdentity() async throws {
        let fixture = try await makeFixture(lastCopiedAt: now)
        let gate = StoreSafetyGate(controller: fixture.store)
        let stale = try await gate.permit(.maintenance)
        try await gate.transition(to: .quarantined, expecting: try await fixture.store.identity())
        try await gate.transition(to: .active, expecting: try await fixture.store.identity())
        let current = try await fixture.store.identity()

        await XCTAssertThrowsErrorAsync {
            _ = try await LifecycleService(controller: fixture.store).remove(
                itemID: fixture.item.id,
                facet: .history,
                at: now,
                expecting: current,
                permit: stale
            )
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        guard case .item(let unchanged) = try await ContentRepository(controller: fixture.store)
            .recordState(.item(fixture.item.id)).value else { return XCTFail("Missing item") }
        XCTAssertNil(unchanged.historyDeletedAt)
    }

    func testRetentionImpactCountsOnlyVisibleExpiredHistoryAndPermanentCountsNone() async throws {
        let store = try makeStore()
        for (offset, age) in [10.0, 40.0, 50.0].enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("c\(offset)".utf8))]])
            var item = ContentStoreFixtures.item(capture)
            item.lastCopiedAt = now - age * day
            try await ContentStoreFixtures.insert(item, capture, into: store)
            if offset == 2 {
                _ = try await LifecycleService(controller: store).remove(
                    itemID: item.id,
                    facet: .history,
                    at: now - day,
                    expecting: try await store.identity(),
                    permit: try await StoreSafetyGate(controller: store).permit(.maintenance)
                )
            }
        }
        let service = LifecycleService(controller: store)
        let identity = try await store.identity()
        let thirtyDayImpact = try await service.retentionImpact(policy: .days(30), at: now, expecting: identity)
        let permanentImpact = try await service.retentionImpact(policy: .permanent, at: now, expecting: identity)
        XCTAssertEqual(thirtyDayImpact.historyCount, 1)
        XCTAssertEqual(permanentImpact.historyCount, 0)
    }

    func testExpirationSkipsOneCASConflictAndContinuesTheBatch() async throws {
        let store = try makeStore()
        var itemIDs: [ItemID] = []
        for index in 0..<2 {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("c\(index)".utf8))]])
            var item = ContentStoreFixtures.item(capture)
            item.lastCopiedAt = now - 40 * day
            itemIDs.append(item.id)
            try await ContentStoreFixtures.insert(item, capture, into: store)
        }
        let conflict = LifecycleCommitConflict(controller: store)
        let service = LifecycleService(controller: store, commit: conflict.commit)
        let receipt = try await service.expireHistory(
            policy: .days(30),
            at: now,
            expecting: try await store.identity(),
            permit: try await StoreSafetyGate(controller: store).permit(.maintenance)
        )
        XCTAssertEqual(receipt.changed.count, 1)
        XCTAssertEqual(receipt.skippedConflicts, 1)
        var values: [RecordValue] = []
        for itemID in itemIDs {
            values.append(try await ContentRepository(controller: store).recordState(.item(itemID)).value)
        }
        XCTAssertEqual(values.compactMap { value -> Bool? in
            guard case .item(let item) = value else { return nil }
            return item.historyEligible
        }.filter { $0 }.count, 1)
    }

    func testExpirationUsesStablePagesAndStopsBeforeManyUnexpiredRows() async throws {
        let store = try makeStore()
        var mutations: [StoreMutation] = []
        var expiredItemIDs: [ItemID] = []
        var unexpiredItemIDs: [ItemID] = []
        for index in 0...LifecycleRepository.batchSize {
            let capture = try ContentStoreFixtures.capture([[
                ("public.utf8-plain-text", Data("batch-\(index)".utf8)),
            ]])
            var item = ContentStoreFixtures.item(capture)
            item.lastCopiedAt = now - 40 * day
            expiredItemIDs.append(item.id)
            mutations.append(.insert(.capture(capture)))
            mutations.append(.insert(.item(item)))
        }
        for index in 0..<(LifecycleRepository.batchSize * 2) {
            let capture = try ContentStoreFixtures.capture([[
                ("public.utf8-plain-text", Data("recent-\(index)".utf8)),
            ]])
            var item = ContentStoreFixtures.item(capture)
            item.lastCopiedAt = now - 2 * day
            unexpiredItemIDs.append(item.id)
            mutations.append(.insert(.capture(capture)))
            mutations.append(.insert(.item(item)))
        }
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: mutations
        ))

        let service = LifecycleService(controller: store)
        let receipt = try await service.expireHistory(
            policy: .days(30),
            at: now,
            expecting: try await store.identity(),
            permit: try await StoreSafetyGate(controller: store).permit(.maintenance)
        )

        XCTAssertEqual(receipt.changed.count, LifecycleRepository.batchSize + 1)
        XCTAssertEqual(receipt.skippedConflicts, 0)
        for itemID in expiredItemIDs {
            guard case .item(let item) = try await ContentRepository(controller: store)
                .recordState(.item(itemID)).value else { return XCTFail("Missing item") }
            XCTAssertFalse(item.historyEligible)
        }
        for itemID in unexpiredItemIDs {
            guard case .item(let item) = try await ContentRepository(controller: store)
                .recordState(.item(itemID)).value else { return XCTFail("Missing item") }
            XCTAssertTrue(item.historyEligible)
        }
    }

    private func makeFixture(lastCopiedAt: Date, memoMode: MemoBodyMode? = nil) async throws -> Fixture {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("source".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        item.lastCopiedAt = lastCopiedAt
        let memo = memoMode.map { mode in
            mode == .inheritedCapture
                ? MemoValue(itemID: item.id, bodyMode: mode)
                : ownedMemo(itemID: item.id, mode: mode, body: "memo body")
        }
        item.memoID = memo?.id
        var mutations: [StoreMutation] = [.insert(.capture(capture))]
        if let memo { mutations.append(.insert(.memo(memo))) }
        mutations.append(.insert(.item(item)))
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: mutations
        ))
        return Fixture(store: store, directory: store.contentStore.url!.deletingLastPathComponent(),
                       item: item, capture: capture, memo: memo)
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-Lifecycle-\(UUID().uuidString)", isDirectory: true)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return store
    }

    private func ownedMemo(itemID: ItemID, mode: MemoBodyMode, body: String) -> MemoValue {
        let bytes = Data(body.utf8)
        return MemoValue(itemID: itemID, bodyMode: mode, body: bytes,
                         version: ContentVersion(), digest: ContentDigest.sha256(bytes))
    }

    private func facetMarkerCount(in store: PersistenceController) async throws -> Int {
        try await store.perform { context in
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "FacetDeletionMarker")
            return try context.count(for: request)
        }
    }
}

private struct Fixture {
    let store: PersistenceController
    let directory: URL
    let item: ItemValue
    let capture: CaptureValue
    let memo: MemoValue?
}

private final class LifecycleCommitConflict: @unchecked Sendable {
    private let lock = NSLock()
    private let controller: PersistenceController
    private var hasConflicted = false

    init(controller: PersistenceController) {
        self.controller = controller
    }

    func commit(_ transaction: StoreTransaction) async throws -> StoreReceipt {
        let shouldConflict = lock.withLock { () -> Bool in
            guard !hasConflicted else { return false }
            hasConflicted = true
            return true
        }
        if shouldConflict,
           case .update(.item(let candidate))? = transaction.mutations.first {
            let repository = ContentRepository(controller: controller)
            let state = try await repository.recordState(.item(candidate.id))
            guard case .item(var changed) = state.value else { throw StoreError.corruptStore }
            changed.title += " changed concurrently"
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(changed.id), fingerprint: state.fingerprint)],
                mutations: [.update(.item(changed))]
            ))
        }
        return try await WriteCoordinator(controller: controller).commit(transaction)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
