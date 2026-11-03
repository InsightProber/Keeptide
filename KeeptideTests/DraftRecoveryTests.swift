import Foundation
import XCTest
@testable import Keeptide

final class DraftRecoveryTests: XCTestCase {
    func testDraftSurvivesStoreReopenAndKeepsIndependentSessions() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let first = fixture.draft(identity: identity, sessionID: UUID(), body: "first", revision: 1)
        let second = fixture.draft(identity: identity, sessionID: UUID(), body: "second", revision: 4)

        let writer = try DraftStore(directory: fixture.directory, identity: identity)
        try await writer.write(first)
        try await writer.write(second)

        let reopened = try DraftStore(directory: fixture.directory, identity: identity)
        let recovered = try await reopened.loadAll()
        XCTAssertEqual(recovered, [first, second].sorted { $0.draftID.uuidString < $1.draftID.uuidString })
        let recoveredFirst = try await reopened.load(first.draftID)
        let recoveredSecond = try await reopened.load(second.draftID)
        XCTAssertEqual(recoveredFirst, first)
        XCTAssertEqual(recoveredSecond, second)
    }

    func testDifferentLibraryIdentityCannotReadOrReplaceDraft() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let originalIdentity = StoreIdentity(storeID: UUID(), generation: UUID())
        let draft = fixture.draft(identity: originalIdentity, body: "private", revision: 1)
        let original = try DraftStore(directory: fixture.directory, identity: originalIdentity)
        try await original.write(draft)

        let otherIdentity = StoreIdentity(storeID: UUID(), generation: UUID())
        let other = try DraftStore(directory: fixture.directory, identity: otherIdentity)
        await XCTAssertThrowsDraftError(.storeIdentityMismatch) {
            _ = try await other.load(draft.draftID)
        }
        var replacement = draft
        replacement.storeIdentity = otherIdentity
        replacement.revision = 2
        await XCTAssertThrowsDraftError(.storeIdentityMismatch) {
            try await other.write(replacement)
        }
        let unchanged = try await original.load(draft.draftID)
        XCTAssertEqual(unchanged, draft)
    }

    func testCorruptAndUnsupportedFilesAreReportedInsteadOfDiscarded() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let corruptID = UUID()
        try Data("not json".utf8).write(to: store.fileURL(for: corruptID), options: .atomic)
        await XCTAssertThrowsDraftError(.corruptDraft(corruptID)) {
            _ = try await store.loadAll()
        }

        try FileManager.default.removeItem(at: store.fileURL(for: corruptID))
        let unsupportedID = UUID()
        let unsupported = "{\"schemaVersion\":99,\"draftID\":\"\(unsupportedID.uuidString)\"}"
        try Data(unsupported.utf8).write(to: store.fileURL(for: unsupportedID), options: .atomic)
        await XCTAssertThrowsDraftError(.unsupportedSchema(99)) {
            _ = try await store.load(unsupportedID)
        }
    }

    func testBestEffortRestoreKeepsCorruptEvidenceAndReturnsHealthyDrafts() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let healthy = fixture.draft(identity: identity, body: "healthy", revision: 1)
        try await store.write(healthy)
        let corruptID = UUID()
        let corruptURL = store.fileURL(for: corruptID)
        try Data("not json".utf8).write(to: corruptURL, options: .atomic)

        let result = try await store.loadAllBestEffort()

        XCTAssertEqual(result.drafts, [healthy])
        XCTAssertEqual(result.failedIDs, [corruptID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    func testConditionalRemoveDoesNotDeleteNewerRevision() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        var draft = fixture.draft(identity: identity, body: "old", revision: 1)
        try await store.write(draft)
        draft.body = "new"
        draft.revision = 2
        draft.storageRevision = 2
        try await store.write(draft)

        let removedOld = try await store.remove(draft.draftID, ifStorageRevision: 1)
        let afterOldRemove = try await store.load(draft.draftID)
        let removedCurrent = try await store.remove(draft.draftID, ifStorageRevision: 2)
        let afterCurrentRemove = try await store.load(draft.draftID)
        XCTAssertFalse(removedOld)
        XCTAssertEqual(afterOldRemove?.body, "new")
        XCTAssertTrue(removedCurrent)
        XCTAssertNil(afterCurrentRemove)
    }

    func testMetadataOnlyDraftWithNoEditableBodySurvivesRecovery() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        var draft = fixture.draft(identity: identity, body: "unused", revision: 1)
        draft.body = nil
        draft.title = "Image reference"
        try await store.write(draft)

        let reopened = try DraftStore(directory: fixture.directory, identity: identity)
        let recovered = try await reopened.load(draft.draftID)
        XCTAssertEqual(recovered, draft)
        XCTAssertNil(recovered?.body)
    }

    func testCurrentDateRoundTripsExactlyAndSameRevisionRewriteRemainsIdempotent() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        var draft = fixture.draft(identity: identity, body: "precise", revision: 1)
        draft.savedAt = Date()

        try await store.write(draft)
        let recovered = try await store.load(draft.draftID)
        XCTAssertEqual(recovered?.savedAt, draft.savedAt)
        XCTAssertEqual(recovered, draft)
        try await store.write(draft)
    }

    func testCoordinatorDebouncesPersistenceAndCommitWithInjectedSleeper() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let sleeper = ControlledDraftSleeper()
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: store,
            sleep: { delay in try await sleeper.sleep(for: delay) },
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { draft in await commits.commit(draft) }
        )
        var draft = fixture.draft(identity: identity, body: "a", revision: 1)
        await coordinator.update(draft)
        draft.body = "ab"
        draft.revision = 2
        await coordinator.update(draft)
        let draftID = draft.draftID

        try await eventually { await sleeper.pending(matching: .milliseconds(300)) > 0 }
        await sleeper.resumeAll(matching: .milliseconds(300))
        try await eventually { try await store.load(draftID)?.revision == 2 }
        let countBeforeCommit = await commits.count
        XCTAssertEqual(countBeforeCommit, 0)

        try await eventually { await sleeper.pending(matching: .seconds(1)) > 0 }
        await sleeper.resumeAll(matching: .seconds(1))
        try await eventually { await commits.count == 1 }
        let committedBodies = await commits.bodies
        let afterCommit = try await store.load(draftID)
        XCTAssertEqual(committedBodies, ["ab"])
        XCTAssertNil(afterCommit)
    }

    func testContinuedEditingAfterSuccessfulAutosaveKeepsCommittedIdentity() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let sleeper = ControlledDraftSleeper()
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: store,
            sleep: { delay in try await sleeper.sleep(for: delay) },
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { draft in await commits.commit(draft) }
        )
        var callerDraft = fixture.draft(identity: identity, body: "first", revision: 1)
        await coordinator.update(callerDraft)
        let draftID = callerDraft.draftID
        try await eventually { await sleeper.pending(matching: .seconds(1)) == 1 }
        await sleeper.resumeAll(matching: .seconds(1))
        try await eventually { await coordinator.latestDraft(draftID) == nil }
        let recordedFirstReceipt = await commits.receipts.first
        let firstReceipt = try XCTUnwrap(recordedFirstReceipt)

        callerDraft.body = "second"
        callerDraft.revision = 2
        await coordinator.update(callerDraft)
        let latestContinuedDraft = await coordinator.latestDraft(draftID)
        let continued = try XCTUnwrap(latestContinuedDraft)
        XCTAssertEqual(continued.itemID, firstReceipt.ref.itemID)
        XCTAssertEqual(continued.base, firstReceipt.ref)
        XCTAssertEqual(continued.baseMemoFingerprint, firstReceipt.memoFingerprint)
        _ = try await coordinator.commitNow(draftID)

        let committedDrafts = await commits.drafts
        XCTAssertEqual(committedDrafts.map(\.body), ["first", "second"])
        XCTAssertEqual(committedDrafts[1].itemID, committedDrafts[0].itemID)
        XCTAssertEqual(committedDrafts[1].base, firstReceipt.ref)
        await sleeper.resumeAll()
    }

    func testEndSessionRefusesPendingDraftAndReleasesCommittedLineage() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: store,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { draft in await commits.commit(draft) }
        )
        var callerDraft = fixture.draft(identity: identity, body: "first", revision: 1)
        await coordinator.update(callerDraft)
        let endedWithPendingDraft = await coordinator.endSession(callerDraft.draftID)
        XCTAssertFalse(endedWithPendingDraft)

        _ = try await coordinator.commitNow(callerDraft.draftID)
        let endedAfterCommit = await coordinator.endSession(callerDraft.draftID)
        XCTAssertTrue(endedAfterCommit)

        callerDraft.body = "new session"
        callerDraft.revision = 2
        await coordinator.update(callerDraft)
        let latest = await coordinator.latestDraft(callerDraft.draftID)
        XCTAssertNil(latest?.base)
        XCTAssertNil(latest?.baseMemoFingerprint)
        try await coordinator.cancel(callerDraft.draftID)
    }

    func testComposingDraftPersistsButDoesNotCommitUntilCompositionEnds() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: store,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        var draft = fixture.draft(identity: identity, body: "ni", revision: 1, isComposing: true)

        await coordinator.update(draft)
        let composingResult = try await coordinator.focusLost(draft.draftID)
        let composingStored = try await store.load(draft.draftID)
        let composingCommitCount = await commits.count
        XCTAssertNil(composingResult)
        XCTAssertEqual(composingStored, draft)
        XCTAssertEqual(composingCommitCount, 0)

        draft.body = "你"
        draft.revision = 2
        draft.isComposing = false
        await coordinator.update(draft)
        _ = try await coordinator.commitNow(draft.draftID)
        let bodiesAfterComposition = await commits.bodies
        let storedAfterComposition = try await store.load(draft.draftID)
        XCTAssertEqual(bodiesAfterComposition, ["你"])
        XCTAssertNil(storedAfterComposition)
    }

    func testFailedPersistencePreventsCommitAndKeepsRecoverableDraft() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let failing = FailingDraftStore(backing: backing)
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: failing,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "keep me", revision: 1)
        await failing.failNextWrite()
        await coordinator.update(draft)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.commitNow(draft.draftID)
        }
        let countAfterFailure = await commits.count
        let latestAfterFailure = await coordinator.latestDraft(draft.draftID)
        XCTAssertEqual(countAfterFailure, 0)
        XCTAssertEqual(latestAfterFailure, draft)

        _ = try await coordinator.commitNow(draft.draftID)
        let countAfterRetry = await commits.count
        let storedAfterRetry = try await backing.load(draft.draftID)
        XCTAssertEqual(countAfterRetry, 1)
        XCTAssertNil(storedAfterRetry)
    }

    func testCommitFailureLeavesDraftAndNewEditSurvivesOldCommitCompletion() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let gate = GatedDraftCommit()
        let coordinator = MemoCommitCoordinator(
            store: store,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        var first = fixture.draft(identity: identity, body: "before", revision: 1)
        await coordinator.update(first)
        let firstDraftID = first.draftID
        let pending = Task { @Sendable in try await coordinator.commitNow(firstDraftID) }
        try await gate.waitUntilStarted()

        first.body = "after"
        first.revision = 2
        await coordinator.update(first)
        await gate.releaseSuccess()
        let receipt = try await pending.value

        let storedAfterOldCommit = try await store.load(first.draftID)
        let latestAfterOldCommit = await coordinator.latestDraft(first.draftID)
        XCTAssertEqual(storedAfterOldCommit?.body, "after")
        XCTAssertEqual(latestAfterOldCommit?.body, "after")
        XCTAssertEqual(latestAfterOldCommit?.revision, 2)
        XCTAssertEqual(latestAfterOldCommit?.storageRevision, 3)
        XCTAssertEqual(latestAfterOldCommit?.base, receipt?.ref)
        XCTAssertEqual(latestAfterOldCommit?.baseMemoFingerprint, receipt?.memoFingerprint)

        await gate.failNext()
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.commitNow(first.draftID)
        }
        let storedAfterCommitFailure = try await store.load(first.draftID)
        XCTAssertEqual(storedAfterCommitFailure?.body, "after")
    }

    func testExplicitCommitJoinsScheduledCommitAlreadyInFlight() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let sleeper = ControlledDraftSleeper()
        let gate = GatedDraftCommit()
        let coordinator = MemoCommitCoordinator(
            store: store,
            sleep: { delay in try await sleeper.sleep(for: delay) },
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "once", revision: 1)
        await coordinator.update(draft)
        try await eventually { await sleeper.pending(matching: .seconds(1)) == 1 }
        await sleeper.resumeAll(matching: .seconds(1))
        try await gate.waitUntilStarted()

        let explicit = Task { @Sendable in try await coordinator.commitNow(draft.draftID) }
        await gate.releaseSuccess()
        _ = try await explicit.value
        try await eventually { await coordinator.latestDraft(draft.draftID) == nil }
        let commitCount = await gate.count
        XCTAssertEqual(commitCount, 1)
        await sleeper.resumeAll()
    }

    func testConcurrentExplicitCommitsCannotBothStartAfterAwaitingPersistence() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let barrierStore = TwoActualWriteBarrierStore(backing: backing)
        let gate = GatedDraftCommit()
        let coordinator = MemoCommitCoordinator(
            store: barrierStore,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "only once", revision: 1)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let first = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await barrierStore.waitUntilFirstActualWriteStarted()
        let second = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await barrierStore.waitUntilBothActualWritesStarted()
        await barrierStore.releaseWrites()
        try await gate.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(50))
        let actualCommitCount = await gate.count
        await gate.releaseSuccess()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(actualCommitCount, 1)
    }

    func testLateWritePausedBeforeDiskCannotResurrectSuccessfullyCommittedDraft() async throws {
        try await assertLateWriteAcrossSuccessfulCommit(mode: .beforeBackingWrite)
    }

    func testCancelDrainsComposingEditsThatArriveDuringPersistence() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let gated = GatedNthWriteStore(backing: backing, gatedWrite: 1, phase: .beforeBackingWrite)
        let coordinator = MemoCommitCoordinator(store: gated, persistDelay: .seconds(60),
            commit: { _ in XCTFail("Composing text must not commit"); throw StoreError.operationDenied })
        var draft = fixture.draft(identity: identity, body: "first", revision: 1, isComposing: true)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let closing = Task { try await coordinator.cancel(draftID) }
        try await gated.waitUntilGatedWriteStarted()
        draft.body = "latest composing text"
        draft.revision = 2
        await coordinator.update(draft)
        await gated.releaseWrite()
        try await closing.value
        let disk = try await backing.load(draftID)
        XCTAssertEqual(disk?.body, "latest composing text")
        XCTAssertEqual(disk?.revision, 2)
    }

    func testLateWritePausedAfterDiskReturnsCompletedReceiptWithoutFalseFailure() async throws {
        try await assertLateWriteAcrossSuccessfulCommit(mode: .afterBackingWrite)
    }

    func testInternalCommitWriteReturningAfterAnotherCommitUsesCompletedReceipt() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let staggeredStore = StaggeredActualWriteStore(backing: backing)
        let gate = GatedDraftCommit()
        let coordinator = MemoCommitCoordinator(
            store: staggeredStore,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "committed", revision: 1)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let first = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await staggeredStore.waitUntilFirstActualWriteStarted()
        let late = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await staggeredStore.waitUntilLateActualWriteReturnedFromDisk()

        await staggeredStore.releaseFirstActualWrite()
        try await gate.waitUntilStarted()
        await gate.releaseSuccess()
        let firstReceipt = try await first.value
        let latestAfterCommit = await coordinator.latestDraft(draftID)
        XCTAssertNil(latestAfterCommit)

        await staggeredStore.releaseLateActualWrite()
        let lateReceipt = try await late.value
        let stored = try await backing.load(draftID)
        let commitCount = await gate.count
        XCTAssertEqual(lateReceipt, firstReceipt)
        XCTAssertNil(stored)
        XCTAssertEqual(commitCount, 1)
    }

    func testJoinedCommitPersistsNewestGenerationBeforeStartingNextCommit() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let gatedStore = GatedRevisionWriteStore(backing: backing, gatedStorageRevision: 3)
        let commits = DurableDraftCommit(backing: backing)
        let coordinator = MemoCommitCoordinator(
            store: gatedStore,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await commits.commit($0) }
        )
        var draft = fixture.draft(identity: identity, body: "one", revision: 1)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let first = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await commits.waitUntilFirstCommitStarted()

        draft.body = "two"
        draft.revision = 2
        await coordinator.update(draft)
        let joined = Task { @Sendable in try await coordinator.commitNow(draftID) }
        await commits.releaseFirstCommit()
        try await gatedStore.waitUntilGatedWriteStarted()

        draft.body = "three"
        draft.revision = 3
        await coordinator.update(draft)
        await gatedStore.releaseWrite()
        _ = try await first.value
        _ = try await joined.value

        let committedBodies = await commits.bodies
        XCTAssertEqual(committedBodies, ["one", "three"])
        let latest = await coordinator.latestDraft(draftID)
        let stored = try await backing.load(draftID)
        XCTAssertNil(latest)
        XCTAssertNil(stored)
    }

    func testJoinedCommitDoesNotCommitNewerComposingGeneration() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let gatedStore = GatedRevisionWriteStore(backing: backing, gatedStorageRevision: 3)
        let gate = GatedDraftCommit()
        let coordinator = MemoCommitCoordinator(
            store: gatedStore,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        var draft = fixture.draft(identity: identity, body: "one", revision: 1)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let first = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await gate.waitUntilStarted()

        draft.body = "two"
        draft.revision = 2
        await coordinator.update(draft)
        let joined = Task { @Sendable in try await coordinator.commitNow(draftID) }
        await gate.releaseSuccess()
        try await gatedStore.waitUntilGatedWriteStarted()

        draft.body = "n"
        draft.revision = 3
        draft.isComposing = true
        await coordinator.update(draft)
        await gatedStore.releaseWrite()
        _ = try await first.value
        _ = try await joined.value
        try await Task.sleep(for: .milliseconds(50))

        let commitCount = await gate.count
        let latest = await coordinator.latestDraft(draftID)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(latest?.body, "n")
        XCTAssertTrue(latest?.isComposing == true)
    }

    func testEditArrivingWhileCommittedDraftIsBeingRemovedIsPreserved() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let gatedStore = GatedRemoveDraftStore(backing: backing)
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: gatedStore,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        var draft = fixture.draft(identity: identity, body: "old", revision: 1)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let pending = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await gatedStore.waitUntilRemoveStarted()

        draft.body = "new while removing"
        draft.revision = 2
        await coordinator.update(draft)
        await gatedStore.releaseRemove()
        let receipt = try await pending.value

        let latest = await coordinator.latestDraft(draftID)
        let stored = try await backing.load(draftID)
        XCTAssertEqual(latest?.body, "new while removing")
        XCTAssertEqual(latest?.revision, 2)
        XCTAssertEqual(latest?.storageRevision, 3)
        XCTAssertEqual(latest?.base, receipt?.ref)
        XCTAssertEqual(stored, latest)
    }

    func testAdvancingAfterOldCommitReschedulesPersistenceAndAutomaticCommit() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let sleeper = ControlledDraftSleeper()
        let gate = GatedDraftCommit()
        let coordinator = MemoCommitCoordinator(
            store: store,
            sleep: { delay in try await sleeper.sleep(for: delay) },
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        var draft = fixture.draft(identity: identity, body: "first", revision: 1)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let pending = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await gate.waitUntilStarted()

        draft.body = "second"
        draft.revision = 2
        await coordinator.update(draft)
        await gate.releaseSuccess()
        _ = try await pending.value
        let advanced = await coordinator.latestDraft(draftID)
        XCTAssertEqual(advanced?.revision, 2)
        XCTAssertEqual(advanced?.storageRevision, 3)

        try await eventually { await sleeper.pending(matching: .milliseconds(300)) > 0 }
        await sleeper.resumeAll(matching: .milliseconds(300))
        try await eventually { try await store.load(draftID)?.storageRevision == 3 }
        try await eventually { await sleeper.pending(matching: .seconds(1)) > 0 }
        await sleeper.resumeAll(matching: .seconds(1))
        try await eventually { await coordinator.latestDraft(draftID) == nil }
        let commitCount = await gate.count
        XCTAssertEqual(commitCount, 2)
    }

    func testScheduledPersistenceFailureIsObservableAndRetryClearsIt() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let failing = FailingDraftStore(backing: backing)
        let sleeper = ControlledDraftSleeper()
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: failing,
            sleep: { delay in try await sleeper.sleep(for: delay) },
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "visible failure", revision: 1)
        await failing.failNextWrite()
        await coordinator.update(draft)
        try await eventually { await sleeper.pending(matching: .milliseconds(300)) == 1 }
        await sleeper.resumeAll(matching: .milliseconds(300))
        try await eventually {
            await coordinator.lastFailure(draft.draftID)
                == DraftCoordinationFailure(
                    stage: .persistence,
                    draftID: draft.draftID,
                    revision: 1,
                    storageRevision: 1
                )
        }
        let latestAfterFailure = await coordinator.latestDraft(draft.draftID)
        XCTAssertEqual(latestAfterFailure, draft)

        _ = try await coordinator.commitNow(draft.draftID)
        let failureAfterRetry = await coordinator.lastFailure(draft.draftID)
        let storedAfterRetry = try await backing.load(draft.draftID)
        XCTAssertNil(failureAfterRetry)
        XCTAssertNil(storedAfterRetry)
        await sleeper.resumeAll()
    }

    func testRestoreDoesNotOverwriteNewerInMemoryEdit() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let sleeper = ControlledDraftSleeper()
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: store,
            sleep: { delay in try await sleeper.sleep(for: delay) },
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        var diskDraft = fixture.draft(identity: identity, body: "disk", revision: 1)
        try await store.write(diskDraft)
        diskDraft.body = "memory"
        diskDraft.revision = 2
        await coordinator.update(diskDraft)

        let restored = try await coordinator.restore()
        diskDraft.storageRevision = 2
        XCTAssertEqual(restored, [diskDraft])
        let latest = await coordinator.latestDraft(diskDraft.draftID)
        XCTAssertEqual(latest, diskDraft)
        try await coordinator.cancel(diskDraft.draftID)
        await sleeper.resumeAll()
    }

    func testConflictCopyAdvancesIdentityAndNextCallerEditIsNotDropped() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let gate = GatedDraftCommit(returnsConflictCopy: true, gatesEveryCommit: true)
        let coordinator = MemoCommitCoordinator(
            store: store,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        var callerDraft = fixture.draft(identity: identity, body: "first", revision: 1)
        callerDraft.base = ContentRef(
            itemID: callerDraft.itemID,
            facet: .memo,
            version: ContentVersion(),
            digest: Data("old digest".utf8)
        )
        callerDraft.baseMemoFingerprint = Data("old fingerprint".utf8)
        await coordinator.update(callerDraft)
        let draftID = callerDraft.draftID
        let pending = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await gate.waitUntilStarted()

        callerDraft.body = "second"
        callerDraft.revision = 2
        await coordinator.update(callerDraft)
        await gate.releaseSuccess()
        let pendingReceipt = try await pending.value
        let latestAfterConflict = await coordinator.latestDraft(draftID)
        let receipt = try XCTUnwrap(pendingReceipt)
        let advanced = try XCTUnwrap(latestAfterConflict)
        XCTAssertEqual(advanced.itemID, receipt.ref.itemID)
        XCTAssertNotEqual(advanced.itemID, callerDraft.itemID)
        XCTAssertNotEqual(advanced.conflictItemID, advanced.itemID)
        XCTAssertEqual(advanced.revision, 2)
        XCTAssertEqual(advanced.storageRevision, 3)

        callerDraft.body = "third"
        callerDraft.revision = 3
        await coordinator.update(callerDraft)
        let latestAfterNextEdit = await coordinator.latestDraft(draftID)
        let next = try XCTUnwrap(latestAfterNextEdit)
        XCTAssertEqual(next.body, "third")
        XCTAssertEqual(next.revision, 3)
        XCTAssertEqual(next.storageRevision, 4)
        XCTAssertEqual(next.itemID, advanced.itemID)
        XCTAssertEqual(next.base, advanced.base)
        XCTAssertEqual(next.baseMemoFingerprint, advanced.baseMemoFingerprint)
        XCTAssertEqual(next.conflictItemID, advanced.conflictItemID)

        let secondConflictTarget = next.conflictItemID
        let secondPending = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await gate.waitUntilCommitCount(2)
        callerDraft.body = "fourth"
        callerDraft.revision = 4
        await coordinator.update(callerDraft)
        await gate.releaseSuccess()
        let secondPendingReceipt = try await secondPending.value
        let latestAfterSecondConflict = await coordinator.latestDraft(draftID)
        let secondReceipt = try XCTUnwrap(secondPendingReceipt)
        let twiceAdvanced = try XCTUnwrap(latestAfterSecondConflict)
        XCTAssertEqual(secondReceipt.ref.itemID, secondConflictTarget)
        XCTAssertEqual(twiceAdvanced.itemID, secondConflictTarget)
        XCTAssertNotEqual(twiceAdvanced.conflictItemID, twiceAdvanced.itemID)
        XCTAssertNotEqual(twiceAdvanced.conflictItemID, advanced.conflictItemID)
        XCTAssertEqual(twiceAdvanced.body, "fourth")
        XCTAssertEqual(twiceAdvanced.revision, 4)
        XCTAssertEqual(twiceAdvanced.storageRevision, 6)
    }

    func testCancelStopsTimersWithoutDiscardingRecoveredDraft() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let store = try DraftStore(directory: fixture.directory, identity: identity)
        let sleeper = ControlledDraftSleeper()
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: store,
            sleep: { delay in try await sleeper.sleep(for: delay) },
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "recover", revision: 1)
        await coordinator.update(draft)
        try await coordinator.cancel(draft.draftID)
        let storedAfterCancel = try await store.load(draft.draftID)
        XCTAssertEqual(storedAfterCancel, draft)
        await sleeper.resumeAll()
        let countAfterCancel = await commits.count
        XCTAssertEqual(countAfterCancel, 0)
        let reopened = MemoCommitCoordinator(
            store: store,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        let restored = try await reopened.restore()
        XCTAssertEqual(restored, [draft])
    }

    func testCancelReportsDiskFailureAndKeepsDraftInMemory() async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let failing = FailingDraftStore(backing: backing)
        let commits = DraftCommitRecorder()
        let coordinator = MemoCommitCoordinator(
            store: failing,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { await commits.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "unsaved", revision: 1)
        await coordinator.update(draft)
        await failing.failNextWrite()

        await XCTAssertThrowsErrorAsync {
            try await coordinator.cancel(draft.draftID)
        }
        let latest = await coordinator.latestDraft(draft.draftID)
        XCTAssertEqual(latest, draft)
    }

    private func assertLateWriteAcrossSuccessfulCommit(mode: GatedWritePhase) async throws {
        let fixture = try DraftFixture()
        defer { fixture.remove() }
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let backing = try DraftStore(directory: fixture.directory, identity: identity)
        let gatedStore = GatedNthWriteStore(backing: backing, gatedWrite: 3, phase: mode)
        let gate = GatedDraftCommit()
        let coordinator = MemoCommitCoordinator(
            store: gatedStore,
            now: { Date(timeIntervalSinceReferenceDate: 123) },
            commit: { try await gate.commit($0) }
        )
        let draft = fixture.draft(identity: identity, body: "committed", revision: 1)
        await coordinator.update(draft)
        let draftID = draft.draftID
        let first = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await gate.waitUntilStarted()
        let late = Task { @Sendable in try await coordinator.commitNow(draftID) }
        try await gatedStore.waitUntilGatedWriteStarted()

        await gate.releaseSuccess()
        let firstReceipt = try await first.value
        let latestAfterCommit = await coordinator.latestDraft(draftID)
        let endedWithLateWrite = await coordinator.endSession(draftID)
        XCTAssertNil(latestAfterCommit)
        XCTAssertFalse(endedWithLateWrite)
        await gatedStore.releaseWrite()
        let lateReceipt = try await late.value

        let stored = try await backing.load(draftID)
        let failure = await coordinator.lastFailure(draftID)
        let commitCount = await gate.count
        XCTAssertEqual(lateReceipt, firstReceipt)
        XCTAssertNil(stored)
        XCTAssertNil(failure)
        XCTAssertEqual(commitCount, 1)
    }
}

private struct DraftFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func draft(
        identity: StoreIdentity,
        sessionID: UUID = UUID(),
        body: String,
        revision: UInt64,
        isComposing: Bool = false
    ) -> RecoverableDraft {
        let itemID = ItemID()
        let conflictItemID = ItemID()
        precondition(itemID != conflictItemID)
        return RecoverableDraft(
            draftID: UUID(), sessionID: sessionID, itemID: itemID, conflictItemID: conflictItemID, storeIdentity: identity,
            base: nil, baseMemoFingerprint: nil, title: "Title", body: body, kind: .plainText,
            languageHint: nil, note: "Note", isComposing: isComposing, revision: revision,
            savedAt: Date(timeIntervalSinceReferenceDate: 123)
        )
    }
}

private actor DraftCommitRecorder {
    private(set) var drafts: [RecoverableDraft] = []
    private(set) var receipts: [MemoCommitReceipt] = []
    var bodies: [String?] { drafts.map(\.body) }
    var count: Int { bodies.count }

    func commit(_ draft: RecoverableDraft) -> MemoCommitReceipt {
        drafts.append(draft)
        let body = draft.body ?? ""
        let ref = ContentRef(itemID: draft.itemID, facet: .memo, version: ContentVersion(), digest: ContentDigest.sha256(Data(body.utf8)))
        let receipt = MemoCommitReceipt(ref: ref, memoFingerprint: Data("fingerprint-\(bodies.count)".utf8))
        receipts.append(receipt)
        return receipt
    }
}

private actor ControlledDraftSleeper {
    private struct Waiter {
        let token: UUID
        let delay: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    func sleep(for delay: Duration) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(token: token, delay: delay, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }

    func pending(matching delay: Duration) -> Int {
        waiters.filter { $0.delay == delay }.count
    }

    func resumeAll(matching delay: Duration) {
        let matching = waiters.filter { $0.delay == delay }
        waiters.removeAll { $0.delay == delay }
        matching.forEach { $0.continuation.resume() }
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    private func cancel(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor FailingDraftStore: DraftStoring {
    let backing: DraftStore
    private var shouldFailWrite = false
    init(backing: DraftStore) { self.backing = backing }
    func failNextWrite() { shouldFailWrite = true }
    func write(_ draft: RecoverableDraft) async throws {
        if shouldFailWrite {
            shouldFailWrite = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try await backing.write(draft)
    }
    func load(_ id: UUID) async throws -> RecoverableDraft? { try await backing.load(id) }
    func loadAll() async throws -> [RecoverableDraft] { try await backing.loadAll() }
    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool {
        try await backing.remove(id, ifStorageRevision: ifStorageRevision)
    }
}

private actor GatedRemoveDraftStore: DraftStoring {
    enum Failure: Error { case didNotStart }
    let backing: DraftStore
    private var removeStarted = false
    private var removeContinuation: CheckedContinuation<Void, Never>?

    init(backing: DraftStore) { self.backing = backing }
    func write(_ draft: RecoverableDraft) async throws { try await backing.write(draft) }
    func load(_ id: UUID) async throws -> RecoverableDraft? { try await backing.load(id) }
    func loadAll() async throws -> [RecoverableDraft] { try await backing.loadAll() }
    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool {
        removeStarted = true
        await withCheckedContinuation { removeContinuation = $0 }
        return try await backing.remove(id, ifStorageRevision: ifStorageRevision)
    }
    func waitUntilRemoveStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !removeStarted {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func releaseRemove() {
        removeContinuation?.resume()
        removeContinuation = nil
    }
}

private actor GatedRevisionWriteStore: DraftStoring {
    enum Failure: Error { case didNotStart }
    let backing: DraftStore
    private let gatedStorageRevision: UInt64
    private var didGate = false
    private var writeStarted = false
    private var writeContinuation: CheckedContinuation<Void, Never>?

    init(backing: DraftStore, gatedStorageRevision: UInt64) {
        self.backing = backing
        self.gatedStorageRevision = gatedStorageRevision
    }

    func write(_ draft: RecoverableDraft) async throws {
        if draft.storageRevision == gatedStorageRevision, !didGate {
            didGate = true
            writeStarted = true
            await withCheckedContinuation { writeContinuation = $0 }
        }
        try await backing.write(draft)
    }

    func load(_ id: UUID) async throws -> RecoverableDraft? { try await backing.load(id) }
    func loadAll() async throws -> [RecoverableDraft] { try await backing.loadAll() }
    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool {
        try await backing.remove(id, ifStorageRevision: ifStorageRevision)
    }

    func waitUntilGatedWriteStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !writeStarted {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
    }
}

private actor TwoActualWriteBarrierStore: DraftStoring {
    enum Failure: Error { case didNotStart }
    let backing: DraftStore
    private var writeCount = 0
    private var blockedWrites = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(backing: DraftStore) { self.backing = backing }

    func write(_ draft: RecoverableDraft) async throws {
        writeCount += 1
        if writeCount == 2 || writeCount == 4 {
            blockedWrites += 1
            await withCheckedContinuation { continuations.append($0) }
        }
        try await backing.write(draft)
    }

    func load(_ id: UUID) async throws -> RecoverableDraft? { try await backing.load(id) }
    func loadAll() async throws -> [RecoverableDraft] { try await backing.loadAll() }
    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool {
        try await backing.remove(id, ifStorageRevision: ifStorageRevision)
    }

    func waitUntilFirstActualWriteStarted() async throws { try await waitForBlockedWrites(1) }
    func waitUntilBothActualWritesStarted() async throws { try await waitForBlockedWrites(2) }

    func releaseWrites() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    private func waitForBlockedWrites(_ expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while blockedWrites < expected {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor StaggeredActualWriteStore: DraftStoring {
    enum Failure: Error { case didNotStart }
    let backing: DraftStore
    private var writeCount = 0
    private var firstActualStarted = false
    private var lateActualReturnedFromDisk = false
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var lateContinuation: CheckedContinuation<Void, Never>?

    init(backing: DraftStore) { self.backing = backing }

    func write(_ draft: RecoverableDraft) async throws {
        writeCount += 1
        let ordinal = writeCount
        if ordinal == 2 {
            firstActualStarted = true
            await withCheckedContinuation { firstContinuation = $0 }
        }
        try await backing.write(draft)
        if ordinal == 4 {
            lateActualReturnedFromDisk = true
            await withCheckedContinuation { lateContinuation = $0 }
        }
    }

    func load(_ id: UUID) async throws -> RecoverableDraft? { try await backing.load(id) }
    func loadAll() async throws -> [RecoverableDraft] { try await backing.loadAll() }
    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool {
        try await backing.remove(id, ifStorageRevision: ifStorageRevision)
    }

    func waitUntilFirstActualWriteStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !firstActualStarted {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilLateActualWriteReturnedFromDisk() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !lateActualReturnedFromDisk {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstActualWrite() { firstContinuation?.resume(); firstContinuation = nil }
    func releaseLateActualWrite() { lateContinuation?.resume(); lateContinuation = nil }
}

private enum GatedWritePhase: Equatable, Sendable {
    case beforeBackingWrite
    case afterBackingWrite
}

private actor GatedNthWriteStore: DraftStoring {
    enum Failure: Error { case didNotStart }
    let backing: DraftStore
    private let gatedWrite: Int
    private let phase: GatedWritePhase
    private var writeCount = 0
    private var writeStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(backing: DraftStore, gatedWrite: Int, phase: GatedWritePhase) {
        self.backing = backing
        self.gatedWrite = gatedWrite
        self.phase = phase
    }

    func write(_ draft: RecoverableDraft) async throws {
        writeCount += 1
        let shouldGate = writeCount == gatedWrite
        if shouldGate, phase == .beforeBackingWrite {
            try await pauseWrite()
        }
        try await backing.write(draft)
        if shouldGate, phase == .afterBackingWrite {
            try await pauseWrite()
        }
    }

    func load(_ id: UUID) async throws -> RecoverableDraft? { try await backing.load(id) }
    func loadAll() async throws -> [RecoverableDraft] { try await backing.loadAll() }
    func remove(_ id: UUID, ifStorageRevision: UInt64) async throws -> Bool {
        try await backing.remove(id, ifStorageRevision: ifStorageRevision)
    }

    func waitUntilGatedWriteStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !writeStarted {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseWrite() {
        continuation?.resume()
        continuation = nil
    }

    private func pauseWrite() async throws {
        writeStarted = true
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor DurableDraftCommit {
    enum Failure: Error { case didNotStart, draftWasNotDurable }
    let backing: DraftStore
    private(set) var bodies: [String?] = []
    private var firstStarted = false
    private var firstContinuation: CheckedContinuation<Void, Never>?

    init(backing: DraftStore) { self.backing = backing }

    func commit(_ draft: RecoverableDraft) async throws -> MemoCommitReceipt {
        if bodies.isEmpty {
            firstStarted = true
            await withCheckedContinuation { firstContinuation = $0 }
        } else {
            let durable = try await backing.load(draft.draftID)
            guard durable == draft else {
                throw Failure.draftWasNotDurable
            }
        }
        bodies.append(draft.body)
        let body = draft.body ?? ""
        let ref = ContentRef(
            itemID: draft.itemID,
            facet: .memo,
            version: ContentVersion(),
            digest: ContentDigest.sha256(Data(body.utf8))
        )
        return MemoCommitReceipt(ref: ref, memoFingerprint: Data("durable fingerprint".utf8))
    }

    func waitUntilFirstCommitStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !firstStarted {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstCommit() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor GatedDraftCommit {
    enum Failure: Error { case rejected, didNotStart }
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldGate = true
    private var shouldFail = false
    private(set) var count = 0
    private let returnsConflictCopy: Bool
    private let gatesEveryCommit: Bool

    init(returnsConflictCopy: Bool = false, gatesEveryCommit: Bool = false) {
        self.returnsConflictCopy = returnsConflictCopy
        self.gatesEveryCommit = gatesEveryCommit
    }

    func commit(_ draft: RecoverableDraft) async throws -> MemoCommitReceipt {
        count += 1
        if shouldFail {
            shouldFail = false
            throw Failure.rejected
        }
        if shouldGate || gatesEveryCommit {
            shouldGate = false
            await withCheckedContinuation { continuation = $0 }
        }
        let body = draft.body ?? ""
        let itemID = returnsConflictCopy ? draft.conflictItemID : draft.itemID
        let ref = ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(), digest: ContentDigest.sha256(Data(body.utf8)))
        return MemoCommitReceipt(ref: ref, memoFingerprint: Data("next fingerprint".utf8))
    }

    func waitUntilStarted() async throws {
        try await waitUntilCommitCount(1)
    }

    func waitUntilCommitCount(_ expectedCount: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while count < expectedCount {
            guard ContinuousClock.now < deadline else { throw Failure.didNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func releaseSuccess() { continuation?.resume(); continuation = nil }
    func failNext() { shouldFail = true }
}

private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { XCTFail("Condition did not become true"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func XCTAssertThrowsDraftError(
    _ expected: DraftStoreError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as DraftStoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync(
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
