import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class LibraryWorkspaceTests: XCTestCase {
    func testOlderCommitReceiptAdvancesBaselineWithoutMarkingNewerTextSaved() {
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let itemID = ItemID()
        let session = MemoEditorSession(
            itemID: itemID, ref: nil, isReadOnly: false, title: "", body: "", note: "",
            kind: .plainText, storeIdentity: identity
        )
        session.setBody("first", isComposing: false)
        session.setBody("newest", isComposing: false)
        let firstRef = ContentRef(
            itemID: itemID, facet: .memo, version: ContentVersion(), digest: Data(repeating: 1, count: 32)
        )

        session.markSaved(
            MemoCommitReceipt(ref: firstRef, memoFingerprint: Data(repeating: 2, count: 32)),
            revision: 1
        )

        XCTAssertEqual(session.ref, firstRef)
        XCTAssertEqual(session.body, "newest")
        XCTAssertEqual(session.status, .saving)
    }

    func testLateOlderReceiptCannotRegressNewerCommittedBaseline() {
        let identity = StoreIdentity(storeID: UUID(), generation: UUID())
        let itemID = ItemID()
        let session = MemoEditorSession(
            itemID: itemID, ref: nil, isReadOnly: false, title: "", body: "", note: "",
            kind: .plainText, storeIdentity: identity
        )
        session.setBody("first", isComposing: false)
        session.setBody("second", isComposing: false)
        let olderRef = ContentRef(
            itemID: itemID, facet: .memo, version: ContentVersion(), digest: Data(repeating: 1, count: 32)
        )
        let newerRef = ContentRef(
            itemID: itemID, facet: .memo, version: ContentVersion(), digest: Data(repeating: 3, count: 32)
        )

        session.markSaved(
            MemoCommitReceipt(ref: newerRef, memoFingerprint: Data(repeating: 4, count: 32)),
            revision: 2
        )
        session.markSaved(
            MemoCommitReceipt(ref: olderRef, memoFingerprint: Data(repeating: 2, count: 32)),
            revision: 1
        )

        XCTAssertEqual(session.ref, newerRef)
        XCTAssertEqual(session.status, .saved)
    }

    func testSelectingHistoryIsReadOnlyAndDoesNotCreateMemo() async throws {
        let harness = try SearchHarness.make(in: self)
        let (item, _) = try await insertHistory("source", into: harness)
        let workspace = try await makeWorkspace(harness)

        await workspace.reload()
        await workspace.select(item.id)

        XCTAssertEqual(workspace.editor?.ref?.facet, .history)
        XCTAssertEqual(workspace.editor?.isReadOnly, true)
        let state = try await ContentRepository(controller: harness.controller).recordState(.item(item.id))
        guard case .item(let stored) = state.value else { return XCTFail("Missing item") }
        XCTAssertNil(stored.memoID)
    }

    func testSavingSelectedHistoryCreatesOneEditableMemoAndIsIdempotent() async throws {
        let harness = try SearchHarness.make(in: self)
        let (item, _) = try await insertHistory("keep this", into: harness)
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        await workspace.select(item.id)

        let first = try await workspace.saveSelectedHistory()
        let second = try await workspace.saveSelectedHistory()

        guard case .created(let created) = first else { return XCTFail("First save did not create") }
        guard case .existing(let existing) = second else { return XCTFail("Second save was not idempotent") }
        XCTAssertEqual(created, existing)
        XCTAssertEqual(workspace.editor?.ref, existing)
        XCTAssertEqual(workspace.editor?.isReadOnly, false)
    }

    func testUndoNewSaveRestoresHistoryWithoutDeletingChangedMemo() async throws {
        let harness = try SearchHarness.make(in: self)
        let (item, _) = try await insertHistory("undo source", into: harness)
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        await workspace.select(item.id)
        _ = try await workspace.saveSelectedHistory()

        let undone = try await workspace.undoNewSave()
        XCTAssertTrue(undone)
        XCTAssertEqual(workspace.editor?.ref?.facet, .history)
        let undoneState = try await ContentRepository(controller: harness.controller).recordState(.item(item.id))
        guard case .item(let undoneItem) = undoneState.value else { return XCTFail("Missing item") }
        XCTAssertNil(undoneItem.memoID)

        _ = try await workspace.saveSelectedHistory()
        workspace.editor?.setTitle("changed after save")
        do {
            _ = try await workspace.undoNewSave()
            XCTFail("Changed memo must not be removed by undo")
        } catch {
            XCTAssertNotNil(workspace.message)
        }
        let changedState = try await ContentRepository(controller: harness.controller).recordState(.item(item.id))
        guard case .item(let changedItem) = changedState.value else { return XCTFail("Missing changed item") }
        XCTAssertNotNil(changedItem.memoID)
    }

    func testBlankNewEditorDoesNotCreateARecord() async throws {
        let harness = try SearchHarness.make(in: self)
        let workspace = try await makeWorkspace(harness)

        await workspace.startNew()
        workspace.editor?.setBody("temporary", isComposing: false)
        workspace.editor?.setBody("", isComposing: false)
        let result = try await workspace.flush()
        let recent = try await ContentRepository(controller: harness.controller).recent(limit: 10)

        XCTAssertNil(result)
        XCTAssertTrue(recent.isEmpty)
    }

    func testExistingMemoEditCommitsAndReopens() async throws {
        let harness = try SearchHarness.make(in: self)
        let ref = try await LibraryService(controller: harness.controller).create(
            MemoDraft(title: "Command", body: "git status", kind: .code)
        )
        let workspace = try await makeWorkspace(harness)
        await workspace.open(ref)
        workspace.editor?.setBody("git status --short", isComposing: false)

        let updatedValue = try await workspace.flush()
        let updated = try XCTUnwrap(updatedValue)
        let snapshot = try await LibraryService(controller: harness.controller).editingSnapshot(updated)

        XCTAssertEqual(updated.itemID, ref.itemID)
        XCTAssertEqual(snapshot.body, "git status --short")
        XCTAssertEqual(workspace.editor?.status, .saved)
    }

    func testConcurrentMemoEditsPreserveWinnerAndCreateConflictCopy() async throws {
        let harness = try SearchHarness.make(in: self)
        let original = try await LibraryService(controller: harness.controller).create(
            MemoDraft(title: "Prompt", body: "original")
        )
        let first = try await makeWorkspace(harness)
        let second = try await makeWorkspace(harness)
        await first.open(original)
        await second.open(original)
        first.editor?.setBody("first", isComposing: false)
        second.editor?.setBody("second", isComposing: false)

        let winnerValue = try await first.flush()
        let conflictValue = try await second.flush()
        let winner = try XCTUnwrap(winnerValue)
        let conflict = try XCTUnwrap(conflictValue)
        let winnerSnapshot = try await LibraryService(controller: harness.controller).editingSnapshot(winner)
        let conflictSnapshot = try await LibraryService(controller: harness.controller).editingSnapshot(conflict)

        XCTAssertEqual(winner.itemID, original.itemID)
        XCTAssertNotEqual(conflict.itemID, original.itemID)
        XCTAssertEqual(winnerSnapshot.body, "first")
        XCTAssertEqual(conflictSnapshot.body, "second")
    }

    func testNewMemoCommitsThroughCoordinatorAndSurvivesReopen() async throws {
        let harness = try SearchHarness.make(in: self)
        let workspace = try await makeWorkspace(harness)
        await workspace.startNew()
        workspace.editor?.setTitle("Prompt")
        workspace.editor?.setBody("Explain concurrency", isComposing: false)
        workspace.editor?.setKind(.prompt)

        let committed = try await workspace.flush()
        let ref = try XCTUnwrap(committed)
        let reopened = try await LibraryService(controller: harness.controller).editingSnapshot(ref)

        XCTAssertEqual(reopened.title, "Prompt")
        XCTAssertEqual(reopened.body, "Explain concurrency")
        XCTAssertEqual(reopened.kind, .prompt)
        XCTAssertEqual(workspace.editor?.status, .saved)
    }

    func testMarkedTextPersistsAsDraftButDoesNotCommitUntilCompositionEnds() async throws {
        let harness = try SearchHarness.make(in: self)
        let workspace = try await makeWorkspace(harness)
        await workspace.startNew()
        workspace.editor?.setBody("ni", isComposing: true)

        let composingResult = try await workspace.flush()
        let beforeCommit = try await ContentRepository(controller: harness.controller).recent(limit: 10)
        XCTAssertNil(composingResult)
        XCTAssertTrue(beforeCommit.isEmpty)

        workspace.editor?.setBody("你", isComposing: false)
        let committed = try await workspace.flush()
        let ref = try XCTUnwrap(committed)
        let snapshot = try await LibraryService(controller: harness.controller).editingSnapshot(ref)
        XCTAssertEqual(snapshot.body, "你")
    }

    func testRecoveredDraftIsOfferedAndCommitsWithoutChangingItsIdentity() async throws {
        let harness = try SearchHarness.make(in: self)
        let identity = try await harness.controller.identity()
        let draftDirectory = harness.directory.appendingPathComponent("Drafts")
        let store = try DraftStore(directory: draftDirectory, identity: identity)
        let draft = RecoverableDraft(
            draftID: UUID(), sessionID: UUID(), itemID: ItemID(), conflictItemID: ItemID(),
            storeIdentity: identity, base: nil, baseMemoFingerprint: nil, title: "Recovered",
            body: "restore me", kind: .plainText, languageHint: nil, note: "",
            isComposing: false, revision: 1, savedAt: Date()
        )
        try await store.write(draft)
        let workspace = try await LibraryWorkspace.make(
            controller: harness.controller, draftDirectory: draftDirectory,
            searchService: harness.service
        )

        XCTAssertEqual(workspace.recoveredDrafts.map(\.id), [draft.draftID])
        await workspace.recoverDraft(draft.draftID)
        let committed = try await workspace.flush()
        let ref = try XCTUnwrap(committed)

        XCTAssertEqual(ref.itemID, draft.itemID)
        let snapshot = try await LibraryService(controller: harness.controller).editingSnapshot(ref)
        XCTAssertEqual(snapshot.body, "restore me")
    }

    func testRecoveredCompositionIsNormalizedAndCanBeEditedAfterRestart() async throws {
        let harness = try SearchHarness.make(in: self)
        let identity = try await harness.controller.identity()
        let draftDirectory = harness.directory.appendingPathComponent("Drafts")
        let store = try DraftStore(directory: draftDirectory, identity: identity)
        let draft = RecoverableDraft(
            draftID: UUID(), sessionID: UUID(), itemID: ItemID(), conflictItemID: ItemID(),
            storeIdentity: identity, base: nil, baseMemoFingerprint: nil, title: "Composing",
            body: "ni", kind: .plainText, languageHint: nil, note: "",
            isComposing: true, revision: 1, savedAt: Date()
        )
        try await store.write(draft)
        let workspace = try await LibraryWorkspace.make(
            controller: harness.controller, draftDirectory: draftDirectory,
            searchService: harness.service
        )

        await workspace.recoverDraft(draft.draftID)
        XCTAssertEqual(workspace.editor?.isComposing, false)
        workspace.editor?.setBody("你", isComposing: false)
        let committedValue = try await workspace.flush()
        let committed = try XCTUnwrap(committedValue)
        let snapshot = try await LibraryService(controller: harness.controller).editingSnapshot(committed)
        XCTAssertEqual(snapshot.body, "你")
    }

    func testCorruptDraftDoesNotHideHealthyRecoveryOrBlockWorkspaceStartup() async throws {
        let harness = try SearchHarness.make(in: self)
        let identity = try await harness.controller.identity()
        let draftDirectory = harness.directory.appendingPathComponent("Drafts")
        let store = try DraftStore(directory: draftDirectory, identity: identity)
        let healthy = RecoverableDraft(
            draftID: UUID(), sessionID: UUID(), itemID: ItemID(), conflictItemID: ItemID(),
            storeIdentity: identity, base: nil, baseMemoFingerprint: nil, title: "Healthy",
            body: "recover me", kind: .plainText, languageHint: nil, note: "",
            isComposing: false, revision: 1, savedAt: Date()
        )
        try await store.write(healthy)
        let corruptID = UUID()
        let corruptURL = draftDirectory.appendingPathComponent("\(corruptID.uuidString).json")
        try Data("not-json".utf8).write(to: corruptURL, options: .atomic)

        let workspace = try await LibraryWorkspace.make(
            controller: harness.controller, draftDirectory: draftDirectory,
            searchService: harness.service
        )

        XCTAssertEqual(workspace.recoveredDrafts.map(\.id), [healthy.draftID])
        XCTAssertNotNil(workspace.recoveryNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptURL.path))

        await workspace.reload()
        XCTAssertNotNil(workspace.recoveryNotice)
    }

    func testComposingClosePersistsDraftAndWorkspaceCanResume() async throws {
        let harness = try SearchHarness.make(in: self)
        let workspace = try await makeWorkspace(harness)
        await workspace.startNew()
        workspace.editor?.setBody("ni", isComposing: true)

        let canClose = await workspace.prepareToClose()
        XCTAssertTrue(canClose)
        XCTAssertTrue(workspace.isClosing)

        workspace.resumeAfterCloseCancellation()
        XCTAssertFalse(workspace.isClosing)
        workspace.editor?.setBody("你", isComposing: false)
        let committed = try await workspace.flush()
        XCTAssertNotNil(committed)
    }

    func testClosingWhileCopyReadIsInFlightPreventsPasteboardWrite() async throws {
        let harness = try SearchHarness.make(in: self)
        let (item, _) = try await insertHistory("must not copy after close", into: harness)
        let repository = ContentRepository(controller: harness.controller)
        let gate = BlockingClipboardRead()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("keeptide.close-test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let pasteService = PasteService(
            pasteboard: pasteboard,
            read: { ref in
                await gate.block()
                return try await repository.read(ref)
            },
            recordUse: { _ in },
            didWrite: { _ in }
        )
        let workspace = try await LibraryWorkspace.make(
            controller: harness.controller,
            draftDirectory: harness.directory.appendingPathComponent("Drafts"),
            searchService: harness.service,
            pasteService: pasteService,
            refreshSearch: { try await harness.consumer.synchronize() }
        )
        await workspace.reload()
        await workspace.select(item.id)

        let copy = Task { await workspace.copyCurrent() }
        await gate.waitUntilBlocked()
        let canClose = await workspace.prepareToClose()
        await gate.release()
        let outcome = await copy.value

        XCTAssertTrue(canClose)
        XCTAssertEqual(outcome, .refused(.stale))
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    func testMemoQueryUsesSearchResultsAndDropsAStaleSelection() async throws {
        let harness = try SearchHarness.make(in: self)
        _ = try await LibraryService(controller: harness.controller).create(
            MemoDraft(title: "First", body: "alpha")
        )
        let wanted = try await LibraryService(controller: harness.controller).create(
            MemoDraft(title: "Second", body: "并发提示")
        )
        let workspace = try await makeWorkspace(harness)

        await workspace.setScope(.allSnippets)
        await workspace.setQuery("并发")

        XCTAssertEqual(workspace.entries.map(\.ref), [wanted])
        XCTAssertNil(workspace.selectedEntryID)
    }

    func testMemoSearchPaginatesWithoutDuplicatingRows() async throws {
        let harness = try SearchHarness.make(in: self)
        for index in 0..<105 {
            _ = try await LibraryService(controller: harness.controller).create(
                MemoDraft(title: "Memo \(index)", body: "body \(index)")
            )
        }
        try await harness.consumer.synchronize()
        let workspace = try await makeWorkspace(harness)

        await workspace.setScope(.allSnippets)
        XCTAssertEqual(workspace.entries.count, 100)
        XCTAssertTrue(workspace.hasMoreEntries)

        await workspace.loadMore()
        XCTAssertEqual(workspace.entries.count, 105)
        XCTAssertEqual(Set(workspace.entries.map(\.ref)).count, 105)
        XCTAssertFalse(workspace.hasMoreEntries)
    }

    func testTypingQueriesDoesNotForceIndexSynchronizationButExplicitReloadDoes() async throws {
        let harness = try SearchHarness.make(in: self)
        let counter = SearchRefreshCounter()
        let workspace = try await LibraryWorkspace.make(
            controller: harness.controller,
            draftDirectory: harness.directory.appendingPathComponent("Drafts"),
            searchService: harness.service,
            refreshSearch: { await counter.increment() }
        )

        await workspace.setQuery("a")
        await workspace.setQuery("ab")
        let afterTyping = await counter.value
        XCTAssertEqual(afterTyping, 0)

        await workspace.reload()
        let afterReload = await counter.value
        XCTAssertEqual(afterReload, 1)
    }

    private func makeWorkspace(_ harness: SearchHarness) async throws -> LibraryWorkspace {
        try await LibraryWorkspace.make(
            controller: harness.controller,
            draftDirectory: harness.directory.appendingPathComponent("Drafts"),
            searchService: harness.service,
            refreshSearch: { try await harness.consumer.synchronize() }
        )
    }

    func testNativeQueryPublishesSynchronouslyAndLatestInputWins() async throws {
        let harness = try SearchHarness.make(in: self)
        _ = try await insertHistory("abc final query", into: harness)
        _ = try await insertHistory("ab intermediate query", into: harness)
        try await harness.consumer.synchronize()
        let workspace = try await makeWorkspace(harness)

        workspace.updateQuery("a")
        XCTAssertEqual(workspace.query, "a")
        workspace.updateQuery("ab")
        XCTAssertEqual(workspace.query, "ab")
        workspace.updateQuery("abc")
        XCTAssertEqual(workspace.query, "abc")
        await workspace.setQuery("abc")
        XCTAssertEqual(workspace.query, "abc")
        XCTAssertEqual(workspace.entries.count, 1)
        XCTAssertEqual(workspace.entries.first?.title, "abc final query")
    }

    func testReopenRestartsQueryCancelledDuringClose() async throws {
        let harness = try SearchHarness.make(in: self)
        _ = try await insertHistory("abc target", into: harness)
        _ = try await insertHistory("other item", into: harness)
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        XCTAssertEqual(workspace.entries.count, 2)

        workspace.updateQuery("abc")
        let closed = await workspace.prepareToClose()
        XCTAssertTrue(closed)
        workspace.resumeAfterCloseCancellation()
        await workspace.setQuery("abc")
        XCTAssertEqual(workspace.query, "abc")
        XCTAssertEqual(workspace.entries.map(\.title), ["abc target"])
    }

    private func insertHistory(
        _ text: String, into harness: SearchHarness
    ) async throws -> (ItemValue, CaptureValue) {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        return (item, capture)
    }
}

private actor BlockingClipboardRead {
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        isBlocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor SearchRefreshCounter {
    private(set) var value = 0

    func increment() { value += 1 }
}
