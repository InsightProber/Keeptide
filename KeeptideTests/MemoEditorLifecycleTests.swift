import XCTest
@testable import Keeptide

final class MemoEditorLifecycleTests: XCTestCase {
    func testSavedEventArrivesAfterRecoveryFileWasRemoved() async throws {
        let harness = try SearchHarness.make(in: self)
        let identity = try await harness.controller.identity()
        let store = try DraftStore(directory: harness.directory.appendingPathComponent("Drafts"), identity: identity)
        let event = expectation(description: "coordinator reported completed save")
        let coordinator = MemoCommitCoordinator(store: store, onEvent: { update in
            if case .saved = update { event.fulfill() }
        }, commit: LibraryService(controller: harness.controller).submitDraft)
        let draft = draft(identity)
        await coordinator.update(draft)
        _ = try await coordinator.commitNow(draft.draftID)
        await fulfillment(of: [event], timeout: 1)
        let stored = try await store.load(draft.draftID)
        XCTAssertNil(stored)
    }

    func testPersistenceFailureIsReportedWithoutEnteringContentCommit() async throws {
        let event = expectation(description: "persistence failure")
        let coordinator = MemoCommitCoordinator(store: UnwritableDraftStore(), onEvent: { update in
            if case .failed(_, _, _, .persistence) = update { event.fulfill() }
        }, commit: { _ in XCTFail("No content write without a durable draft"); throw StoreError.operationDenied })
        let draft = draft(StoreIdentity(storeID: UUID(), generation: UUID()))
        await coordinator.update(draft)
        do { _ = try await coordinator.commitNow(draft.draftID); XCTFail("Expected disk failure") } catch {}
        await fulfillment(of: [event], timeout: 1)
        let remaining = await coordinator.latestDraft(draft.draftID)
        XCTAssertEqual(remaining?.body, "unsaved")
    }

    func testOnlyBlankUncommittedDraftMayBeDiscarded() async throws {
        let harness = try SearchHarness.make(in: self)
        let identity = try await harness.controller.identity()
        let store = try DraftStore(directory: harness.directory.appendingPathComponent("Drafts"), identity: identity)
        let coordinator = MemoCommitCoordinator(store: store, commit: LibraryService(controller: harness.controller).submitDraft)
        var empty = draft(identity); empty.body = " \n"; empty.title = ""
        await coordinator.update(empty)
        try await coordinator.cancel(empty.draftID)
        let discarded = try await coordinator.discardEmptyDraft(empty.draftID)
        XCTAssertTrue(discarded)
        let removed = try await store.load(empty.draftID)
        XCTAssertNil(removed)
        let nonempty = draft(identity)
        await coordinator.update(nonempty)
        let rejected = try await coordinator.discardEmptyDraft(nonempty.draftID)
        XCTAssertFalse(rejected)
        let retained = await coordinator.latestDraft(nonempty.draftID)
        XCTAssertEqual(retained?.body, "unsaved")
        try await coordinator.cancel(nonempty.draftID)
    }

    func testUndoNewSavePreservesHistoryAndRefusesAnEditedMemo() async throws {
        let harness = try SearchHarness.make(in: self)
        let library = LibraryService(controller: harness.controller)
        let identity = try await harness.controller.identity()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("original".utf8))]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        let saved = try await library.saveAsMemo(item.id).ref
        let snapshot = try await library.editingSnapshot(saved)
        try await library.undoSaveAsMemo(item.id, memoID: snapshot.memoID,
            expectedFingerprint: snapshot.memoFingerprint, expecting: identity)
        let original = try await ContentRepository(controller: harness.controller).read(ContentStoreFixtures.ref(item, capture))
        XCTAssertEqual(original.representations, capture.representations)
        let second = try await library.saveAsMemo(item.id).ref
        let before = try await library.editingSnapshot(second)
        let updated = try await library.commit(MemoEdit(title: "Changed", body: "owned",
            expectedMemoFingerprint: before.memoFingerprint), base: second).ref
        do {
            try await library.undoSaveAsMemo(item.id, memoID: before.memoID,
                expectedFingerprint: before.memoFingerprint, expecting: identity)
            XCTFail("Undo removed edited content")
        } catch {}
        let preserved = try await library.editingSnapshot(updated)
        XCTAssertEqual(preserved.body, "owned")
    }

    private func draft(_ identity: StoreIdentity) -> RecoverableDraft {
        RecoverableDraft(draftID: UUID(), sessionID: UUID(), itemID: ItemID(), conflictItemID: ItemID(),
            storeIdentity: identity, title: "", body: "unsaved", kind: .plainText, note: "",
            isComposing: false, revision: 1, savedAt: Date())
    }
}

private actor UnwritableDraftStore: DraftStoring {
    func write(_: RecoverableDraft) async throws { throw CocoaError(.fileWriteOutOfSpace) }
    func load(_: UUID) async throws -> RecoverableDraft? { nil }
    func loadAll() async throws -> [RecoverableDraft] { [] }
    func remove(_: UUID, ifStorageRevision _: UInt64) async throws -> Bool { false }
}
