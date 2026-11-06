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

    func testExplicitMarkdownHistoryAndSavedMemoRemainExactEditableMarkdown() async throws {
        for type in ["net.daringfireball.markdown", "text/markdown"] {
            let harness = try SearchHarness.make(in: self)
            let source = "## \(type)\n\n- [ ] keep exact\n"
            let capture = try ContentStoreFixtures.capture([[(type, Data(source.utf8))]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
            let workspace = try await makeWorkspace(harness)

            await workspace.reload()
            await workspace.select(item.id)
            XCTAssertEqual(workspace.editor?.ref?.facet, .history, type)
            XCTAssertEqual(workspace.editor?.kind, .markdown, type)
            XCTAssertEqual(workspace.editor?.body, source, type)
            XCTAssertEqual(workspace.editor?.isReadOnly, true, type)

            _ = try await workspace.saveSelectedHistory()
            XCTAssertEqual(workspace.editor?.ref?.facet, .memo, type)
            XCTAssertEqual(workspace.editor?.kind, .markdown, type)
            XCTAssertEqual(workspace.editor?.body, source, type)
            XCTAssertEqual(workspace.editor?.isReadOnly, false, type)
        }
    }

    func testMovingDirtyMemoToRecentlyDeletedFlushesExactItemAndEndsEditorSession() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = LibraryService(controller: harness.controller)
        let original = try await service.create(MemoDraft(title: "Command", body: "before"))
        let workspace = try await makeWorkspace(harness)
        await workspace.open(original)
        let detachedEditor = try XCTUnwrap(workspace.editor)
        detachedEditor.setBody("after flush", isComposing: false)
        var removedRef: ContentRef?

        let removed = await workspace.moveToRecentlyDeleted(original) { ref in
            removedRef = ref
            return true
        }

        let exactRef = try XCTUnwrap(removedRef)
        XCTAssertTrue(removed)
        XCTAssertEqual(exactRef.itemID, original.itemID)
        XCTAssertEqual(exactRef.facet, .memo)
        XCTAssertNotEqual(exactRef.version, original.version)
        XCTAssertNil(workspace.editor)
        let savedAfterFlush = try await service.editingSnapshot(exactRef)
        XCTAssertEqual(savedAfterFlush.body, "after flush")

        // A detached native editor callback queued after deletion cannot recreate a draft or commit another body.
        detachedEditor.setBody("late detached change", isComposing: false)
        try await Task.sleep(for: .milliseconds(1_100))
        let savedAfterDetachedEdit = try await service.editingSnapshot(exactRef)
        XCTAssertEqual(savedAfterDetachedEdit.body, "after flush")
    }

    func testMovingComposingMemoToRecentlyDeletedIsRefusedWithoutCallingBackend() async throws {
        let harness = try SearchHarness.make(in: self)
        let ref = try await LibraryService(controller: harness.controller).create(
            MemoDraft(title: "IME", body: "start")
        )
        let workspace = try await makeWorkspace(harness)
        await workspace.open(ref)
        workspace.editor?.setBody("ni", isComposing: true)
        var backendCalled = false

        let removed = await workspace.moveToRecentlyDeleted(ref) { _ in
            backendCalled = true
            return true
        }

        XCTAssertFalse(removed)
        XCTAssertFalse(backendCalled)
        XCTAssertEqual(workspace.editor?.ref, ref)
        XCTAssertTrue(workspace.editor?.isComposing == true)
        XCTAssertNotNil(workspace.message)
    }

    func testFailedEditorFlushRefusesSoftDeleteAndKeepsEditorVisible() async throws {
        let harness = try SearchHarness.make(in: self)
        let ref = try await LibraryService(controller: harness.controller).create(
            MemoDraft(title: "Unsaved", body: "before")
        )
        let workspace = try await makeWorkspace(harness)
        await workspace.open(ref)
        try await harness.controller.close()
        workspace.editor?.setBody("must survive failed flush", isComposing: false)
        var backendCalled = false

        let removed = await workspace.moveToRecentlyDeleted(ref) { _ in
            backendCalled = true
            return true
        }

        XCTAssertFalse(removed)
        XCTAssertFalse(backendCalled)
        XCTAssertEqual(workspace.editor?.body, "must survive failed flush")
        XCTAssertEqual(workspace.editor?.status, .failed)
        XCTAssertNotNil(workspace.message)
    }

    func testConflictCopyRefusesToDeleteTheOriginalMemoIdentity() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = LibraryService(controller: harness.controller)
        let original = try await service.create(MemoDraft(title: "Shared", body: "base"))
        let workspace = try await makeWorkspace(harness)
        await workspace.open(original)
        let externalBase = try await service.editingSnapshot(original)
        workspace.editor?.setBody("local edit", isComposing: false)
        _ = try await service.commit(MemoEdit(
            title: "External", body: "external edit",
            expectedMemoFingerprint: externalBase.memoFingerprint
        ), base: original)
        var backendCalled = false

        let removed = await workspace.moveToRecentlyDeleted(original) { _ in
            backendCalled = true
            return true
        }

        XCTAssertFalse(removed)
        XCTAssertFalse(backendCalled)
        XCTAssertNotEqual(workspace.editor?.ref?.itemID, original.itemID)
        XCTAssertNotNil(workspace.message)
    }

    func testRecentlyDeletedScopeClearsSearchAndDoesNotLoadActiveEntries() async throws {
        let harness = try SearchHarness.make(in: self)
        _ = try await insertHistory("still active", into: harness)
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        workspace.updateQuery("active")

        await workspace.setScope(.recentlyDeleted)

        XCTAssertEqual(workspace.scope, .recentlyDeleted)
        XCTAssertEqual(workspace.query, "")
        XCTAssertTrue(workspace.entries.isEmpty)
        XCTAssertFalse(workspace.hasMoreEntries)
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
        let (item, capture) = try await insertHistory("abc final query", into: harness)
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
        XCTAssertEqual(workspace.entries.map(\.ref), [ContentStoreFixtures.ref(item, capture)])
    }

    func testReopenRestartsQueryCancelledDuringClose() async throws {
        let harness = try SearchHarness.make(in: self)
        let (item, capture) = try await insertHistory("abc target", into: harness)
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
        XCTAssertEqual(workspace.entries.map(\.ref), [ContentStoreFixtures.ref(item, capture)])
    }

    func testSavingHistoryRefreshesTheRowMarker() async throws {
        let harness = try SearchHarness.make(in: self)
        let (item, _) = try await insertHistory("mark me", into: harness)
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        await workspace.select(item.id)
        XCTAssertEqual(workspace.entries.first { $0.id == item.id }?.isMemo, false)

        _ = try await workspace.saveSelectedHistory()

        XCTAssertEqual(workspace.entries.first { $0.id == item.id }?.isMemo, true)
        XCTAssertEqual(workspace.selectedEntryID, item.id)
        XCTAssertEqual(workspace.editor?.ref?.facet, .memo)
    }

    func testSnippetScopesOrderByLastUse() async throws {
        let harness = try SearchHarness.make(in: self)
        let older = try await insertOwnedMemo("older", copiedAt: Date(timeIntervalSince1970: 1_000), into: harness)
        let newer = try await insertOwnedMemo("newer", copiedAt: Date(timeIntervalSince1970: 2_000), into: harness)
        try await LocalUsageStore(controller: harness.controller).record(
            UseReceipt(ref: older.memo, occurredAt: Date(timeIntervalSince1970: 3_000), outcome: .success),
            now: Date(timeIntervalSince1970: 3_000)
        )
        let workspace = try await makeWorkspace(harness)

        await workspace.setScope(.allSnippets)
        XCTAssertEqual(workspace.entries.map(\.ref), [older.memo, newer.memo])

        await workspace.setScope(.recentClips)
        XCTAssertEqual(workspace.entries.map(\.ref), [newer.history, older.history])
    }

    func testSavingSelectedHistoryIntoACollectionAsFavorite() async throws {
        let harness = try SearchHarness.make(in: self)
        let collection = try await CollectionService(controller: harness.controller)
            .create(CollectionDraft(name: "Prompts", color: "blue"))
        let (item, _) = try await insertHistory("file me", into: harness)
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        await workspace.select(item.id)

        let outcome = try await workspace.saveSelectedHistory(collectionID: collection.value.id, isFavorite: true)

        guard case .created = outcome else { return XCTFail("Expected a new snippet") }
        XCTAssertEqual(workspace.editor?.isReadOnly, false)
        XCTAssertTrue(workspace.canUndoNewSave)
        let saved = try await storedItem(item.id, in: harness)
        XCTAssertEqual(saved.collectionID, collection.value.id)
        XCTAssertTrue(saved.isFavorite)

        let undone = try await workspace.undoNewSave()

        XCTAssertTrue(undone)
        let restored = try await storedItem(item.id, in: harness)
        XCTAssertNil(restored.memoID)
        XCTAssertNil(restored.collectionID)
        XCTAssertFalse(restored.isFavorite)
    }

    func testBatchSaveStopsAtFirstFailureAndReportsSaved() async throws {
        let harness = try SearchHarness.make(in: self)
        let (first, firstCapture) = try await insertHistory("first", into: harness)
        let (already, alreadyCapture) = try await insertHistory("already a snippet", into: harness)
        let (trashed, trashedCapture) = try await insertHistory("its snippet is in recently deleted", into: harness)
        let (last, lastCapture) = try await insertHistory("last", into: harness)
        let library = LibraryService(controller: harness.controller)
        let alreadyRef = try await library.saveAsMemo(already.id).ref
        let trashedMemo = try await library.saveAsMemo(trashed.id).ref
        let identity = try await harness.controller.identity()
        _ = try await LifecycleService(controller: harness.controller).remove(
            ref: trashedMemo, at: Date(), expecting: identity,
            permit: StoreSafetyGate(controller: harness.controller).permit(.maintenance)
        )
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        let refs = [
            ContentStoreFixtures.ref(first, firstCapture), ContentStoreFixtures.ref(already, alreadyCapture),
            ContentStoreFixtures.ref(trashed, trashedCapture), ContentStoreFixtures.ref(last, lastCapture),
        ]

        let outcome = await workspace.saveCheckedHistory(refs)

        XCTAssertEqual(outcome.saved.map(\.itemID), [first.id])
        XCTAssertEqual(outcome.saved.map(\.facet), [.memo])
        XCTAssertEqual(outcome.alreadySaved, [alreadyRef])
        XCTAssertEqual(outcome.failure?.ref, refs[2])
        XCTAssertEqual(outcome.failure?.error as? StoreError, .staleReference)
        let savedFirst = try await storedItem(first.id, in: harness)
        XCTAssertNotNil(savedFirst.memoID)
        let untouchedLast = try await storedItem(last.id, in: harness)
        XCTAssertNil(untouchedLast.memoID)
        XCTAssertFalse(workspace.canUndoNewSave)
        XCTAssertNil(workspace.editor)
        XCTAssertEqual(workspace.entries.first { $0.id == first.id }?.isMemo, true)
    }

    func testBatchSaveRefusesAClipWhoseSnippetIsInRecentlyDeleted() async throws {
        let harness = try SearchHarness.make(in: self)
        let (fine, fineCapture) = try await insertHistory("fine", into: harness)
        let (trashed, trashedCapture) = try await insertHistory("its snippet is in recently deleted", into: harness)
        let trashedMemo = try await LibraryService(controller: harness.controller).saveAsMemo(trashed.id).ref
        let identity = try await harness.controller.identity()
        _ = try await LifecycleService(controller: harness.controller).remove(
            ref: trashedMemo, at: Date(), expecting: identity,
            permit: StoreSafetyGate(controller: harness.controller).permit(.maintenance)
        )
        let workspace = try await makeWorkspace(harness)
        let refs = [ContentStoreFixtures.ref(fine, fineCapture), ContentStoreFixtures.ref(trashed, trashedCapture)]

        let outcome = await workspace.saveHistory(refs)

        XCTAssertTrue(outcome.saved.isEmpty)
        XCTAssertEqual(outcome.failure?.ref, refs[1])
        XCTAssertEqual(outcome.failure?.error as? LibraryWorkspaceError, .snippetInRecentlyDeleted)
        let untouched = try await storedItem(fine.id, in: harness)
        XCTAssertNil(untouched.memoID)
    }

    func testSavingHistoryKeepsTheLoadedPagesAndTheSelection() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 105, prefix: "clip")
        let workspace = try await makeWorkspace(harness)
        await workspace.reload()
        await workspace.loadMore()
        XCTAssertEqual(workspace.entries.count, 105)
        let beyondTheFirstPage = try XCTUnwrap(workspace.entries.last)
        await workspace.select(beyondTheFirstPage.id)
        XCTAssertEqual(workspace.selectedEntryID, beyondTheFirstPage.id)

        _ = try await workspace.saveSelectedHistory()

        XCTAssertEqual(workspace.entries.count, 105)
        XCTAssertEqual(workspace.selectedEntryID, beyondTheFirstPage.id)
        XCTAssertEqual(workspace.entries.last?.id, beyondTheFirstPage.id)
        XCTAssertEqual(workspace.entries.last?.isMemo, true)
        XCTAssertEqual(workspace.editor?.ref?.facet, .memo)
    }

    func testBatchSaveRefusesAnUnavailableClipBeforeSavingAnything() async throws {
        let harness = try SearchHarness.make(in: self)
        let (fine, fineCapture) = try await insertHistory("fine", into: harness)
        let capture = try ContentStoreFixtures.localReferenceCapture()
        let reference = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insertLocalReference(reference, capture, into: harness.controller)
        // Without its local file access the reference has to be relocated before its content can be used.
        try await FileAccessStore(controller: harness.controller).remove(
            representationID: try XCTUnwrap(capture.representations.first).id,
            permit: StoreSafetyGate(controller: harness.controller).permit(.maintenance)
        )
        let workspace = try await makeWorkspace(harness)
        let refs = [ContentStoreFixtures.ref(fine, fineCapture), ContentStoreFixtures.ref(reference, capture)]

        let outcome = await workspace.saveHistory(refs)

        XCTAssertTrue(outcome.saved.isEmpty)
        XCTAssertEqual(outcome.failure?.ref, refs[1])
        XCTAssertEqual(outcome.failure?.error as? LibraryWorkspaceError, .contentUnavailable)
        let untouched = try await storedItem(fine.id, in: harness)
        XCTAssertNil(untouched.memoID)
    }

    func testEntriesCarrySourceAppAndCollection() async throws {
        let harness = try SearchHarness.make(in: self)
        let collection = try await CollectionService(controller: harness.controller)
            .create(CollectionDraft(name: "Prompts", color: "blue"))
        let filed = try await insertOwnedMemo("filed", copiedAt: Date(timeIntervalSince1970: 1_000),
                                              collectionID: collection.value.id, into: harness)
        let workspace = try await makeWorkspace(harness)

        await workspace.setScope(.collection(collection.value.id))
        XCTAssertEqual(workspace.entries.map(\.ref), [filed.memo])
        XCTAssertEqual(workspace.entries.first?.collectionID, collection.value.id)
        XCTAssertEqual(workspace.entries.first?.sourceApp, "test.source")

        await workspace.setScope(.recentClips)
        XCTAssertEqual(workspace.entries.map(\.ref), [filed.history])
        XCTAssertEqual(workspace.entries.first?.sourceApp, "test.source")
        XCTAssertNil(workspace.entries.first?.collectionID)
    }

    func testDeletingTheLastCollectionLeavesUnfiled() async throws {
        let harness = try SearchHarness.make(in: self)
        let prompts = try await CollectionService(controller: harness.controller)
            .create(CollectionDraft(name: "Prompts", color: "blue"))
        let filed = try await LibraryService(controller: harness.controller)
            .create(MemoDraft(body: "filed", collectionID: prompts.value.id))
        let unfiled = try await LibraryService(controller: harness.controller).create(MemoDraft(body: "unfiled"))
        let workspace = try await makeWorkspace(harness)
        await workspace.refreshCollections()
        await workspace.setScope(.uncategorized)
        XCTAssertEqual(workspace.entries.map(\.ref), [unfiled])

        let deleted = await workspace.deleteCollection(prompts)

        // Unfiled hides with the last collection; its snippets are all unfiled now, so All Snippets shows them.
        XCTAssertTrue(deleted)
        XCTAssertEqual(workspace.scope, .allSnippets)
        XCTAssertEqual(Set(workspace.entries.map(\.ref.itemID)), [filed.itemID, unfiled.itemID])
    }

    func testDeletingTheCollectionShownGoesToUnfiledWhileAnotherRemains() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = CollectionService(controller: harness.controller)
        let prompts = try await service.create(CollectionDraft(name: "Prompts", color: "blue"))
        _ = try await service.create(CollectionDraft(name: "Drafts", color: "green"))
        let filed = try await LibraryService(controller: harness.controller)
            .create(MemoDraft(body: "filed", collectionID: prompts.value.id))
        let workspace = try await makeWorkspace(harness)
        await workspace.refreshCollections()
        await workspace.setScope(.collection(prompts.value.id))

        let deleted = await workspace.deleteCollection(prompts)

        XCTAssertTrue(deleted)
        XCTAssertEqual(workspace.scope, .uncategorized)
        XCTAssertEqual(workspace.entries.map(\.ref.itemID), [filed.itemID])
    }

    func testDeletingAnotherCollectionKeepsTheListShown() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = CollectionService(controller: harness.controller)
        let prompts = try await service.create(CollectionDraft(name: "Prompts", color: "blue"))
        let drafts = try await service.create(CollectionDraft(name: "Drafts", color: "green"))
        let workspace = try await makeWorkspace(harness)
        await workspace.refreshCollections()
        await workspace.setScope(.collection(drafts.value.id))

        let deleted = await workspace.deleteCollection(prompts)

        XCTAssertTrue(deleted)
        XCTAssertEqual(workspace.scope, .collection(drafts.value.id))
    }

    private func storedItem(_ id: ItemID, in harness: SearchHarness) async throws -> ItemValue {
        let state = try await ContentRepository(controller: harness.controller).recordState(.item(id))
        guard case .item(let value) = state.value else { throw StoreError.corruptStore }
        return value
    }

    /// A clip whose snippet was edited: one item with a history facet and an owned memo facet.
    private func insertOwnedMemo(
        _ text: String, copiedAt: Date, collectionID: CollectionID? = nil, into harness: SearchHarness
    ) async throws -> (history: ContentRef, memo: ContentRef, itemID: ItemID) {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let itemID = ItemID()
        let body = Data("memo \(text)".utf8)
        let memo = MemoValue(itemID: itemID, title: text, bodyMode: .ownedPlainText, body: body,
                             version: ContentVersion(), digest: ContentDigest.sha256(body))
        let item = ItemValue(id: itemID, sourceApp: "test.source", title: text, captureID: capture.id, memoID: memo.id,
                             collectionID: collectionID, historyEligible: true, lastCopiedAt: copiedAt, copyCount: 1)
        try await harness.commit([.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))])
        let memoRef = ContentRef(itemID: itemID, facet: .memo, version: try XCTUnwrap(memo.version),
                                 digest: try XCTUnwrap(memo.digest))
        return (ContentStoreFixtures.ref(item, capture), memoRef, itemID)
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
