import XCTest
@testable import Keeptide

final class MemoDraftIntegrationTests: XCTestCase {
    func testTypingAfterCompletedAutosaveContinuesTheSameMemo() async throws {
        try await verifyContinuedTyping(afterConflict: false)
    }

    func testTypingAfterCompletedConflictAutosaveContinuesTheConflictCopy() async throws {
        try await verifyContinuedTyping(afterConflict: true)
    }

    private func verifyContinuedTyping(afterConflict: Bool) async throws {
        let harness = try SearchHarness.make(in: self)
        let identity = try await harness.controller.identity()
        let store = try DraftStore(directory: harness.directory.appendingPathComponent("Drafts"), identity: identity)
        let library = LibraryService(controller: harness.controller)
        let saved = expectation(description: "Automatic save reaches the content store")
        let coordinator = MemoCommitCoordinator(store: store, persistDelay: .milliseconds(5),
            commitDelay: .milliseconds(10), commit: { draft in
                let receipt = try await library.submitDraft(draft)
                if draft.revision == 1 { saved.fulfill() }
                return receipt
            })
        var draft = makeDraft(identity: identity)
        var winner: ContentRef?
        if afterConflict {
            let original = try await library.create(MemoDraft(body: "original"))
            let snapshot = try await library.editingSnapshot(original)
            draft.itemID = original.itemID
            draft.base = original
            draft.baseMemoFingerprint = snapshot.memoFingerprint
            winner = try await library.commit(MemoEdit(title: "Another window", body: "winner",
                expectedMemoFingerprint: snapshot.memoFingerprint), base: original).ref
        }
        let expectedItemID = afterConflict ? draft.conflictItemID : draft.itemID
        await coordinator.update(draft)
        await fulfillment(of: [saved], timeout: 3)
        // Wait for the automatic save to finish without initiating another save.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await coordinator.latestDraft(draft.draftID) != nil {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Automatic save did not finish recovery-file cleanup")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let recovery = try await store.load(draft.draftID)
        XCTAssertNil(recovery)

        // An automatic save does not return a receipt to the text-input caller.
        // The caller still holds its original base=nil and item identity.
        draft.revision += 1
        draft.body = "continued typing after a pause"
        await coordinator.update(draft)
        let result = try await coordinator.commitNow(draft.draftID)
        let receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.ref.itemID, expectedItemID)
        let content = try await ContentRepository(controller: harness.controller).read(receipt.ref)
        XCTAssertEqual(content.representations.first?.bytes, Data("continued typing after a pause".utf8))
        let rows = try await ContentRepository(controller: harness.controller).recent(limit: 10)
        XCTAssertEqual(rows.count, afterConflict ? 2 : 1)
        if let winner {
            let original = try await library.editingSnapshot(winner)
            XCTAssertEqual(original.body, "winner")
            XCTAssertEqual(original.title, "Another window")
        }
    }

    func testRecoveredDraftCommitsThroughRealServiceAndIsRemovedOnlyAfterSuccess() async throws {
        let harness = try SearchHarness.make(in: self)
        let library = LibraryService(controller: harness.controller)
        let identity = try await harness.controller.identity()
        let directory = harness.directory.appendingPathComponent("Drafts")
        let store = try DraftStore(directory: directory, identity: identity)
        let draft = makeDraft(identity: identity)
        try await store.write(draft)
        let reopened = try DraftStore(directory: directory, identity: identity)
        let coordinator = MemoCommitCoordinator(store: reopened, commit: library.submitDraft)
        let recovered = try await coordinator.restore()
        XCTAssertEqual(recovered, [draft])
        let result = try await coordinator.commitNow(draft.draftID)
        let receipt = try XCTUnwrap(result)
        XCTAssertEqual(receipt.ref.itemID, draft.itemID)
        let remaining = try await reopened.load(draft.draftID)
        XCTAssertNil(remaining)
        let content = try await ContentRepository(controller: harness.controller).read(receipt.ref)
        XCTAssertEqual(content.representations.first?.bytes, Data("recover 中文".utf8))
        try await harness.consumer.synchronize()
        let page = try await harness.search("中文", scope: .memo)
        XCTAssertEqual(page.results.first?.ref, receipt.ref)
        let replay = try await library.submitDraft(draft)
        XCTAssertEqual(replay, receipt)
    }

    func testTwoRecoveredWindowsKeepIndependentConflictingContent() async throws {
        let harness = try SearchHarness.make(in: self)
        let library = LibraryService(controller: harness.controller)
        let identity = try await harness.controller.identity()
        let base = try await library.create(MemoDraft(body: "base"))
        let snapshot = try await library.editingSnapshot(base)
        var first = makeDraft(identity: identity)
        first.itemID = base.itemID
        first.base = base
        first.baseMemoFingerprint = snapshot.memoFingerprint
        first.body = "winner"
        var second = first
        second.draftID = UUID()
        second.sessionID = UUID()
        second.conflictItemID = ItemID()
        second.body = "preserved conflict"
        let one = try await library.submitDraft(first)
        let two = try await library.submitDraft(second)
        XCTAssertEqual(one.ref.itemID, base.itemID)
        XCTAssertEqual(two.ref.itemID, second.conflictItemID)
        let replay = try await library.submitDraft(second)
        XCTAssertEqual(replay.ref, two.ref)
        let content = try await ContentRepository(controller: harness.controller).read(one.ref)
        XCTAssertEqual(content.representations.first?.bytes, Data("winner".utf8))
    }

    func testCompositionAndForeignLibraryAreRejectedAtSubmissionBoundary() async throws {
        let harness = try SearchHarness.make(in: self)
        let library = LibraryService(controller: harness.controller)
        var draft = makeDraft(identity: try await harness.controller.identity())
        draft.isComposing = true
        do { _ = try await library.submitDraft(draft); XCTFail("Composition committed") } catch {}
        draft.isComposing = false
        draft.storeIdentity = StoreIdentity(storeID: UUID(), generation: UUID())
        do { _ = try await library.submitDraft(draft); XCTFail("Foreign draft committed") } catch {}
        let items = try await ContentRepository(controller: harness.controller).recent(limit: 10)
        XCTAssertTrue(items.isEmpty)
    }

    func testFailedRealContentWriteKeepsDraftForRecoveryAfterStoreReopens() async throws {
        let harness = try SearchHarness.make(in: self)
        let identity = try await harness.controller.identity()
        let store = try DraftStore(directory: harness.directory.appendingPathComponent("Drafts"), identity: identity)
        let library = LibraryService(controller: harness.controller)
        let coordinator = MemoCommitCoordinator(store: store, commit: library.submitDraft)
        let draft = makeDraft(identity: identity)
        await coordinator.update(draft)
        await harness.consumer.stopAndDrain()
        try await harness.controller.close()
        do { _ = try await coordinator.commitNow(draft.draftID); XCTFail("Closed content store accepted write") } catch {}
        let retained = try await store.load(draft.draftID)
        XCTAssertEqual(retained?.body, draft.body)
        let reopened = try PersistenceController(directory: harness.directory)
        addTeardownBlock { try? await reopened.close() }
        let recovered = MemoCommitCoordinator(store: store, commit: LibraryService(controller: reopened).submitDraft)
        _ = try await recovered.restore()
        let result = try await recovered.commitNow(draft.draftID)
        let receipt = try XCTUnwrap(result)
        let content = try await ContentRepository(controller: reopened).read(receipt.ref)
        XCTAssertEqual(content.representations.first?.bytes, Data("recover 中文".utf8))
    }

    private func makeDraft(identity: StoreIdentity) -> RecoverableDraft {
        RecoverableDraft(draftID: UUID(), sessionID: UUID(), itemID: ItemID(), conflictItemID: ItemID(),
            storeIdentity: identity, base: nil, baseMemoFingerprint: nil, title: "Recovered", body: "recover 中文",
            kind: .prompt, languageHint: nil, note: "", isComposing: false, revision: 1, savedAt: Date())
    }
}
