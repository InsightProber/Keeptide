import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class LifecycleCleanupPlannerTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSinceReferenceDate: 20_000_000)

    func testMemoPurgeUsesMemoIDNotBodyVersionAndPreservesHistory() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("history".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let collection = CollectionValue(name: "Pinned commands")
        item.collectionID = collection.id
        item.isFavorite = true
        let memo = ownedMemo(itemID: item.id, body: "old")
        item.memoID = memo.id
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [
                .insert(.capture(capture)),
                .insert(.memo(memo)),
                .insert(.collection(collection)),
                .insert(.item(item)),
            ]
        ))
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let target = try await LifecycleService(controller: store).remove(
            itemID: item.id,
            facet: .memo,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        ).target

        let memoState = try await ContentRepository(controller: store).recordState(.memo(memo.id))
        guard case .memo(var revisedMemo) = memoState.value else { return XCTFail("Missing soft-deleted memo") }
        let oldVersion = try XCTUnwrap(revisedMemo.version)
        let newBody = Data("new body revision".utf8)
        revisedMemo.body = newBody
        revisedMemo.version = ContentVersion()
        revisedMemo.digest = ContentDigest.sha256(newBody)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: identity,
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)],
            mutations: [.update(.memo(revisedMemo))]
        ))
        XCTAssertNotEqual(revisedMemo.version, oldVersion)

        let completed = try await LifecycleCleanupService(controller: store).purgeFacet(
            target,
            trigger: .explicitUserRequest,
            at: now + 1,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(completed.phase, .completed)
        let updated = try await itemValue(item.id, in: store)
        XCTAssertNil(updated.memoID)
        XCTAssertNil(updated.collectionID)
        XCTAssertFalse(updated.isFavorite)
        XCTAssertEqual(updated.captureID, capture.id)
        await assertMissing(.memo(memo.id), in: store)
        _ = try await ContentRepository(controller: store).read(ContentStoreFixtures.ref(item, capture))
        let markers = try await facetMarkers(itemID: item.id, in: store)
        XCTAssertEqual(markers.map(\.generationID), [memo.id])
        XCTAssertNotEqual(markers.first?.generationID, oldVersion.rawValue)
    }

    func testMemoPurgeAfterInheritedHistoryPurgeReclaimsSoleCapture() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("inherited".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        item.memoID = memo.id
        try await insert(item: item, capture: capture, memo: memo, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let lifecycle = LifecycleService(controller: store)
        let cleanup = LifecycleCleanupService(controller: store)

        let historyTarget = try await lifecycle.remove(
            itemID: item.id, facet: .history, at: now,
            expecting: identity, permit: try await gate.permit(.maintenance)
        ).target
        _ = try await cleanup.purgeFacet(
            historyTarget, trigger: .explicitUserRequest, at: now + 1,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )
        let afterHistoryPurge = try await itemValue(item.id, in: store)
        XCTAssertEqual(afterHistoryPurge.captureID, capture.id)

        let memoTarget = try await lifecycle.remove(
            itemID: item.id, facet: .memo, at: now + 2,
            expecting: identity, permit: try await gate.permit(.maintenance)
        ).target
        let completed = try await cleanup.purgeFacet(
            memoTarget, trigger: .explicitUserRequest, at: now + 3,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )

        XCTAssertEqual(completed.phase, .completed)
        let finalItem = try await itemValue(item.id, in: store)
        XCTAssertNil(finalItem.memoID)
        XCTAssertNil(finalItem.captureID)
        await assertMissing(.memo(memo.id), in: store)
        await assertMissing(.capture(capture.id), in: store)
    }

    func testMemoPurgeAfterPermanentHistoryMarkerDetachesButPreservesSharedCapture() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("shared inherited".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let sibling = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        item.memoID = memo.id
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [
                .insert(.capture(capture)), .insert(.memo(memo)),
                .insert(.item(item)), .insert(.item(sibling)),
            ]
        ))
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let lifecycle = LifecycleService(controller: store)
        let cleanup = LifecycleCleanupService(controller: store)
        let historyTarget = try await lifecycle.remove(
            itemID: item.id, facet: .history, at: now,
            expecting: identity, permit: try await gate.permit(.maintenance)
        ).target
        _ = try await cleanup.purgeFacet(
            historyTarget, trigger: .explicitUserRequest, at: now + 1,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )
        let memoTarget = try await lifecycle.remove(
            itemID: item.id, facet: .memo, at: now + 2,
            expecting: identity, permit: try await gate.permit(.maintenance)
        ).target
        _ = try await cleanup.purgeFacet(
            memoTarget, trigger: .explicitUserRequest, at: now + 3,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )

        let purgedItem = try await itemValue(item.id, in: store)
        let preservedSibling = try await itemValue(sibling.id, in: store)
        XCTAssertNil(purgedItem.captureID)
        XCTAssertEqual(preservedSibling.captureID, capture.id)
        _ = try await ContentRepository(controller: store).recordState(.capture(capture.id))
    }

    func testPreparedInheritedHistoryPlanFencesMemoCOWUntilResume() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("cow race".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        var memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        item.memoID = memo.id
        try await insert(item: item, capture: capture, memo: memo, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let historyTarget = try await LifecycleService(controller: store).remove(
            itemID: item.id, facet: .history, at: now,
            expecting: identity, permit: try await gate.permit(.maintenance)
        ).target
        let cleanup = LifecycleCleanupService(controller: store)
        let prepared = try await cleanup.prepareFacetPurge(
            historyTarget, trigger: .explicitUserRequest, at: now + 1,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )

        let memoState = try await ContentRepository(controller: store).recordState(.memo(memo.id))
        let body = Data("now owned".utf8)
        memo.bodyMode = .ownedPlainText
        memo.body = body
        memo.version = ContentVersion()
        memo.digest = ContentDigest.sha256(body)
        await XCTAssertThrowsErrorAsync {
            _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
                identity: identity,
                preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)],
                mutations: [.update(.memo(memo))]
            ))
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .maintenanceInProgress)
        }
        let completed = try await cleanup.resume(
            prepared.id, at: now + 2,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(completed.phase, .completed)

        let currentMemo = try await ContentRepository(controller: store).recordState(.memo(memo.id))
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: identity,
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: currentMemo.fingerprint)],
            mutations: [.update(.memo(memo))]
        ))
        let preservedItem = try await itemValue(item.id, in: store)
        XCTAssertEqual(preservedItem.captureID, capture.id)
        guard case .memo(let ownedMemo) = try await ContentRepository(controller: store)
            .recordState(.memo(memo.id)).value else {
            return XCTFail("Memo disappeared after the cleanup fence released")
        }
        XCTAssertEqual(ownedMemo.bodyMode, .ownedPlainText)
        _ = try await ContentRepository(controller: store).recordState(.capture(capture.id))
    }

    func testInheritedHistoryRequestRejectsMemoCOWBeforeIntentPreparation() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("pre-prepare cow".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        var memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        item.memoID = memo.id
        try await insert(item: item, capture: capture, memo: memo, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let permit = try await gate.permit(.maintenance)
        let target = try await LifecycleService(controller: store).remove(
            itemID: item.id,
            facet: .history,
            at: now,
            expecting: identity,
            permit: permit
        ).target
        let request = try await LifecycleCleanupPlanner(controller: store).facetRequest(
            target,
            trigger: .explicitUserRequest,
            at: now + 1,
            expecting: identity,
            permit: permit
        )

        let memoState = try await ContentRepository(controller: store).recordState(.memo(memo.id))
        let body = Data("owned before prepare".utf8)
        memo.bodyMode = .ownedPlainText
        memo.body = body
        memo.version = ContentVersion()
        memo.digest = ContentDigest.sha256(body)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: identity,
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)],
            mutations: [.update(.memo(memo))]
        ))

        await XCTAssertThrowsErrorAsync {
            _ = try await PayloadReclaimer(controller: store).prepare(
                request,
                expecting: identity,
                permit: permit,
                at: now + 2
            )
        } verify: { error in
            XCTAssertEqual(error as? CleanupError, .invalidPlan)
        }
        let intentCount = try await cleanupIntentCount(in: store)
        XCTAssertEqual(intentCount, 0)
        let preservedItem = try await itemValue(item.id, in: store)
        XCTAssertEqual(preservedItem.captureID, capture.id)
        _ = try await ContentRepository(controller: store).recordState(.capture(capture.id))
    }

    func testInheritedToOwnedMemoPurgeAfterHistoryMarkerReclaimsCapture() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("cow cleanup".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        var memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        item.memoID = memo.id
        try await insert(item: item, capture: capture, memo: memo, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let lifecycle = LifecycleService(controller: store)
        let cleanup = LifecycleCleanupService(controller: store)
        let historyTarget = try await lifecycle.remove(
            itemID: item.id, facet: .history, at: now,
            expecting: identity, permit: try await gate.permit(.maintenance)
        ).target
        _ = try await cleanup.purgeFacet(
            historyTarget, trigger: .explicitUserRequest, at: now + 1,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )

        let state = try await ContentRepository(controller: store).recordState(.memo(memo.id))
        let body = Data("owned after history purge".utf8)
        memo.bodyMode = .ownedPlainText
        memo.body = body
        memo.version = ContentVersion()
        memo.digest = ContentDigest.sha256(body)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: identity,
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: state.fingerprint)],
            mutations: [.update(.memo(memo))]
        ))
        let memoTarget = try await lifecycle.remove(
            itemID: item.id, facet: .memo, at: now + 2,
            expecting: identity, permit: try await gate.permit(.maintenance)
        ).target
        _ = try await cleanup.purgeFacet(
            memoTarget, trigger: .explicitUserRequest, at: now + 3,
            expecting: identity, permit: try await gate.permit(.maintenance)
        )

        let finalItem = try await itemValue(item.id, in: store)
        XCTAssertNil(finalItem.captureID)
        await assertMissing(.capture(capture.id), in: store)
    }

    func testPreparedAndCloudCommittedIntentsRefuseANewStoreGeneration() async throws {
        let preparedStore = try makeStore()
        let preparedFixture = try await makeSoftDeletedMemo(in: preparedStore, text: "prepared generation")
        let prepared = try await LifecycleCleanupService(controller: preparedStore).prepareFacetPurge(
            preparedFixture.target, trigger: .explicitUserRequest, at: now,
            expecting: preparedFixture.identity, permit: preparedFixture.permit
        )
        let preparedGate = StoreSafetyGate(controller: preparedStore)
        try await preparedGate.transition(to: .quarantined, expecting: preparedFixture.identity)
        try await preparedGate.transition(to: .active, expecting: try await preparedStore.identity())
        let preparedNewIdentity = try await preparedStore.identity()
        do {
            _ = try await PayloadReclaimer(controller: preparedStore).resume(
                prepared.id, expecting: preparedNewIdentity,
                permit: try await preparedGate.permit(.maintenance), at: now + 1
            )
            XCTFail("A prepared intent crossed into a new generation")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        _ = try await ContentRepository(controller: preparedStore).recordState(.memo(preparedFixture.memo.id))

        let committedStore = try makeStore()
        let committedFixture = try await makeSoftDeletedMemo(in: committedStore, text: "cloud committed generation")
        let committed = try await LifecycleCleanupService(controller: committedStore).prepareFacetPurge(
            committedFixture.target, trigger: .explicitUserRequest, at: now,
            expecting: committedFixture.identity, permit: committedFixture.permit
        )
        let injector = PlannerCleanupCheckpoint(target: .beforeLocalCompletionSave)
        do {
            _ = try await PayloadReclaimer(controller: committedStore, checkpoint: injector.hit).resume(
                committed.id, expecting: committedFixture.identity,
                permit: committedFixture.permit, at: now + 1
            )
            XCTFail("Synthetic local-cleanup crash did not fire")
        } catch is PlannerCleanupCrash {
            // CloudContent and the cloudCommitted phase are already durable.
        }
        let cloudCommitted = try await CleanupIntentStore(controller: committedStore).load(
            committed.id, expecting: committedFixture.identity
        )
        XCTAssertEqual(cloudCommitted.phase, .cloudCommitted)
        let committedGate = StoreSafetyGate(controller: committedStore)
        try await committedGate.transition(to: .quarantined, expecting: committedFixture.identity)
        try await committedGate.transition(to: .active, expecting: try await committedStore.identity())
        let committedNewIdentity = try await committedStore.identity()
        do {
            _ = try await PayloadReclaimer(controller: committedStore).resume(
                committed.id, expecting: committedNewIdentity,
                permit: try await committedGate.permit(.maintenance), at: now + 2
            )
            XCTFail("A cloud-committed intent cleaned local state in a new generation")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
    }

    func testInheritedMemoKeepsCaptureWhileSharedCaptureIsDetachedButNotDeleted() async throws {
        let inheritedStore = try makeStore()
        let inheritedCapture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("inherited".utf8))]])
        var inheritedItem = ContentStoreFixtures.item(inheritedCapture)
        let inheritedMemo = MemoValue(itemID: inheritedItem.id, bodyMode: .inheritedCapture)
        inheritedItem.memoID = inheritedMemo.id
        try await insert(item: inheritedItem, capture: inheritedCapture, memo: inheritedMemo, into: inheritedStore)
        let inheritedIdentity = try await inheritedStore.identity()
        let inheritedGate = StoreSafetyGate(controller: inheritedStore)
        let inheritedTarget = try await LifecycleService(controller: inheritedStore).remove(
            itemID: inheritedItem.id,
            facet: .history,
            at: now,
            expecting: inheritedIdentity,
            permit: try await inheritedGate.permit(.maintenance)
        ).target
        _ = try await LifecycleCleanupService(controller: inheritedStore).purgeFacet(
            inheritedTarget,
            trigger: .explicitUserRequest,
            at: now + 1,
            expecting: inheritedIdentity,
            permit: try await inheritedGate.permit(.maintenance)
        )
        let inheritedAfterPurge = try await itemValue(inheritedItem.id, in: inheritedStore)
        XCTAssertEqual(inheritedAfterPurge.captureID, inheritedCapture.id)
        _ = try await ContentRepository(controller: inheritedStore).recordState(.capture(inheritedCapture.id))

        let sharedStore = try makeStore()
        let sharedCapture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("shared".utf8))]])
        let first = ContentStoreFixtures.item(sharedCapture)
        let second = ContentStoreFixtures.item(sharedCapture)
        _ = try await WriteCoordinator(controller: sharedStore).commit(StoreTransaction(
            identity: try await sharedStore.identity(),
            mutations: [.insert(.capture(sharedCapture)), .insert(.item(first)), .insert(.item(second))]
        ))
        let sharedIdentity = try await sharedStore.identity()
        let sharedGate = StoreSafetyGate(controller: sharedStore)
        let sharedTarget = try await LifecycleService(controller: sharedStore).remove(
            itemID: first.id,
            facet: .history,
            at: now,
            expecting: sharedIdentity,
            permit: try await sharedGate.permit(.maintenance)
        ).target
        _ = try await LifecycleCleanupService(controller: sharedStore).purgeFacet(
            sharedTarget,
            trigger: .explicitUserRequest,
            at: now + 1,
            expecting: sharedIdentity,
            permit: try await sharedGate.permit(.maintenance)
        )
        let firstAfterPurge = try await itemValue(first.id, in: sharedStore)
        let secondAfterPurge = try await itemValue(second.id, in: sharedStore)
        XCTAssertNil(firstAfterPurge.captureID)
        XCTAssertEqual(secondAfterPurge.captureID, sharedCapture.id)
        _ = try await ContentRepository(controller: sharedStore).recordState(.capture(sharedCapture.id))
    }

    func testSnapshotLeaseBlocksSoleCapturePurgeUntilReleased() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("leased".utf8))]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await gate.permit(.completeArchive),
            lifetime: 60
        ))
        let target = try await LifecycleService(controller: store).remove(
            itemID: item.id,
            facet: .history,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        ).target

        await XCTAssertThrowsErrorAsync {
            _ = try await LifecycleCleanupService(controller: store).purgeFacet(
                target,
                trigger: .explicitUserRequest,
                at: now + 1,
                expecting: identity,
                permit: try await gate.permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .contentProtected)
        }
        let intentCount = try await cleanupIntentCount(in: store)
        XCTAssertEqual(intentCount, 0)
        await reader.end(lease)
        let completed = try await LifecycleCleanupService(controller: store).purgeFacet(
            target,
            trigger: .explicitUserRequest,
            at: now + 2,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(completed.phase, .completed)
        await assertMissing(.capture(capture.id), in: store)
    }

    func testAutomaticPurgeRequiresSevenDayBoundaryAndResumeIsIdempotent() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("deadline".utf8))]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let target = try await LifecycleService(controller: store).remove(
            itemID: item.id,
            facet: .history,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        ).target
        let deadline = now + DeletionWindow.duration

        await XCTAssertThrowsErrorAsync {
            _ = try await LifecycleCleanupService(controller: store).purgeFacet(
                target,
                trigger: .deletionWindowExpired,
                at: deadline - 1,
                expecting: identity,
                permit: try await gate.permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? LifecycleCleanupPlanningError, .deletionWindowStillOpen)
        }
        let service = LifecycleCleanupService(controller: store)
        let candidates = try await LifecycleCleanupPlanner(controller: store).candidates(
            policy: .days(30),
            at: deadline,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(candidates.candidates, [
            LifecycleCleanupCandidate(target: target, trigger: .deletionWindowExpired),
        ])
        let completed = try await service.purgeFacet(
            target,
            trigger: .deletionWindowExpired,
            at: deadline,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        let repeated = try await service.resume(
            completed.id,
            at: deadline + 1,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(repeated, completed)
    }

    func testNaturalExpirationHasNoTrashButCanBePurgedOnlyByExpiringPolicy() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("old".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        item.lastCopiedAt = now - 10 * day
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        _ = try await LifecycleService(controller: store).expireHistory(
            policy: .days(1),
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        let trash = try await LifecycleService(controller: store).trash(
            policy: .days(1),
            at: now,
            expecting: identity
        )
        XCTAssertTrue(trash.isEmpty)
        let target = DeletedFacetIdentity.history(itemID: item.id, captureID: capture.id)
        let rediscovered = try await LifecycleCleanupPlanner(controller: store).candidates(
            policy: .days(1),
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(rediscovered.candidates, [
            LifecycleCleanupCandidate(target: target, trigger: .naturalExpiration(.days(1))),
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await LifecycleCleanupService(controller: store).purgeFacet(
                target,
                trigger: .naturalExpiration(.permanent),
                at: now,
                expecting: identity,
                permit: try await gate.permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? LifecycleCleanupPlanningError, .historyNotExpired)
        }
        let completed = try await LifecycleCleanupService(controller: store).purgeFacet(
            target,
            trigger: .naturalExpiration(.days(1)),
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(completed.phase, .completed)
        await assertMissing(.capture(capture.id), in: store)
        let afterMarker = try await LifecycleCleanupPlanner(controller: store).candidates(
            policy: .days(1),
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertTrue(afterMarker.candidates.isEmpty)
    }

    func testCandidateDiscoveryIncludesExpiredHistoryAndMemoWindows() async throws {
        let store = try makeStore()
        let historyCapture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("h".utf8))]])
        let historyItem = ContentStoreFixtures.item(historyCapture)
        let memoCapture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("m".utf8))]])
        var memoItem = ContentStoreFixtures.item(memoCapture)
        let memo = ownedMemo(itemID: memoItem.id, body: "memo")
        memoItem.memoID = memo.id
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [
                .insert(.capture(historyCapture)), .insert(.item(historyItem)),
                .insert(.capture(memoCapture)), .insert(.memo(memo)), .insert(.item(memoItem)),
            ]
        ))
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let historyTarget = try await LifecycleService(controller: store).remove(
            itemID: historyItem.id,
            facet: .history,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        ).target
        let memoTarget = try await LifecycleService(controller: store).remove(
            itemID: memoItem.id,
            facet: .memo,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        ).target

        let page = try await LifecycleCleanupPlanner(controller: store).candidates(
            policy: .permanent,
            at: now + DeletionWindow.duration,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(Set(page.candidates.map(\.target)), Set([historyTarget, memoTarget]))
        XCTAssertTrue(page.candidates.allSatisfy { $0.trigger == .deletionWindowExpired })
        XCTAssertNil(page.next)
    }

    func testPreparedIntentFencesTargetChangesAndItemPurgeRequiresExplicitRequest() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("stale".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = ownedMemo(itemID: item.id, body: "memo")
        item.memoID = memo.id
        try await insert(item: item, capture: capture, memo: memo, into: store)
        let identity = try await store.identity()
        let gate = StoreSafetyGate(controller: store)
        let target = try await LifecycleService(controller: store).remove(
            itemID: item.id,
            facet: .memo,
            at: now,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        ).target
        let service = LifecycleCleanupService(controller: store)
        let prepared = try await service.prepareFacetPurge(
            target,
            trigger: .explicitUserRequest,
            at: now + 1,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        let itemState = try await ContentRepository(controller: store).recordState(.item(item.id))
        guard case .item(var changed) = itemState.value else { return XCTFail("Missing item") }
        changed.title = "changed after prepare"
        await XCTAssertThrowsErrorAsync {
            _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
                identity: identity,
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
                mutations: [.update(.item(changed))]
            ))
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .maintenanceInProgress)
        }
        let completed = try await service.resume(
            prepared.id,
            at: now + 2,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(completed.phase, .completed)
        await assertMissing(.memo(memo.id), in: store)

        await XCTAssertThrowsErrorAsync {
            _ = try await service.purgeItem(
                item.id,
                explicitlyRequested: false,
                at: now + 3,
                expecting: identity,
                permit: try await gate.permit(.maintenance)
            )
        } verify: { error in
            XCTAssertEqual(error as? LifecycleCleanupPlanningError, .explicitRequestRequired)
        }
        let itemCleanup = try await service.purgeItem(
            item.id,
            explicitlyRequested: true,
            at: now + 4,
            expecting: identity,
            permit: try await gate.permit(.maintenance)
        )
        XCTAssertEqual(itemCleanup.phase, .completed)
        await assertMissing(.item(item.id), in: store)
        await assertMissing(.memo(memo.id), in: store)
        await assertMissing(.capture(capture.id), in: store)
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-CleanupPlanner-\(UUID().uuidString)", isDirectory: true)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return store
    }

    private func ownedMemo(itemID: ItemID, body: String) -> MemoValue {
        let bytes = Data(body.utf8)
        return MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: bytes,
            version: ContentVersion(),
            digest: ContentDigest.sha256(bytes)
        )
    }

    private func insert(
        item: ItemValue,
        capture: CaptureValue,
        memo: MemoValue,
        into store: PersistenceController
    ) async throws {
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
        ))
    }

    private func makeSoftDeletedMemo(
        in store: PersistenceController,
        text: String
    ) async throws -> SoftDeletedMemoFixture {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = ownedMemo(itemID: item.id, body: text)
        item.memoID = memo.id
        try await insert(item: item, capture: capture, memo: memo, into: store)
        let identity = try await store.identity()
        let permit = try await StoreSafetyGate(controller: store).permit(.maintenance)
        let target = try await LifecycleService(controller: store).remove(
            itemID: item.id,
            facet: .memo,
            at: now,
            expecting: identity,
            permit: permit
        ).target
        return SoftDeletedMemoFixture(identity: identity, permit: permit, target: target, memo: memo)
    }

    private func itemValue(_ id: ItemID, in store: PersistenceController) async throws -> ItemValue {
        guard case .item(let item) = try await ContentRepository(controller: store).recordState(.item(id)).value else {
            throw StoreError.corruptStore
        }
        return item
    }

    private func facetMarkers(itemID: ItemID, in store: PersistenceController) async throws -> [FacetDeletionMarkerValue] {
        try await store.perform { context in
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

    private func cleanupIntentCount(in store: PersistenceController) async throws -> Int {
        try await store.perform { context in
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "CleanupIntent"))
        }
    }

    private func assertMissing(
        _ key: RecordKey,
        in store: PersistenceController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ContentRepository(controller: store).recordState(key)
            XCTFail("Record survived cleanup", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StoreError, .notFound, file: file, line: line)
        }
    }
}

private struct SoftDeletedMemoFixture {
    let identity: StoreIdentity
    let permit: StorePermit
    let target: DeletedFacetIdentity
    let memo: MemoValue
}

private struct PlannerCleanupCrash: Error {}

private final class PlannerCleanupCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let target: PayloadReclaimerCheckpoint
    private var fired = false

    init(target: PayloadReclaimerCheckpoint) {
        self.target = target
    }

    func hit(_ checkpoint: PayloadReclaimerCheckpoint) throws {
        let matches: Bool
        switch (target, checkpoint) {
        case (.afterPrepared, .afterPrepared),
             (.afterCloudCommitBeforePhaseRecord, .afterCloudCommitBeforePhaseRecord),
             (.beforeLocalCompletionSave, .beforeLocalCompletionSave):
            matches = true
        default:
            matches = false
        }
        try lock.withLock {
            guard matches, !fired else { return }
            fired = true
            throw PlannerCleanupCrash()
        }
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
