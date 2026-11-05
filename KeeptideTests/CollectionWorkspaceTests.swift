import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class CollectionWorkspaceTests: XCTestCase {
    func testCreateCategoryAndNewSnippetInItsContext() async throws {
        let harness = try SearchHarness.make(in: self)
        let workspace = try await workspace(harness)
        let draft = CollectionDraft(name: "部署命令", color: "blue")
        let created = await workspace.createCollection(draft)
        XCTAssertTrue(created)
        XCTAssertEqual(workspace.collections.map(\.value.id), [draft.id])
        await workspace.setScope(.collection(draft.id))
        await workspace.startNew()
        XCTAssertEqual(workspace.editor?.collectionID, draft.id)
        workspace.editor?.setBody("echo synthetic", isComposing: false)
        let saved = try await workspace.flush()
        let ref = try XCTUnwrap(saved)
        let stored = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let item) = stored.value else { return XCTFail("Expected item") }
        XCTAssertEqual(item.collectionID, draft.id)
        XCTAssertEqual(workspace.entries.map(\.ref), [ref])
    }

    func testCollectionChangesAreToldOnce() async throws {
        let harness = try SearchHarness.make(in: self)
        let workspace = try await workspace(harness)
        let told = Told()
        workspace.onCollectionsChanged = { told.count += 1 }

        let created = await workspace.createCollection(CollectionDraft(name: "Prompts", color: "blue"))
        XCTAssertTrue(created)
        XCTAssertEqual(told.count, 1)

        // A reload that finds the same collections says nothing.
        await workspace.reload()
        XCTAssertEqual(told.count, 1)
        await workspace.refreshCollections()
        XCTAssertEqual(told.count, 1)
    }

    func testFavoritesAndCollectionFiltersPreserveGlobalQueryAcrossMoves() async throws {
        let harness = try SearchHarness.make(in: self)
        let service = CollectionService(controller: harness.controller)
        let a = try await service.create(CollectionDraft(name: "A", color: "blue"))
        let b = try await service.create(CollectionDraft(name: "B", color: "green"))
        let ref = try await LibraryService(controller: harness.controller).create(
            MemoDraft(body: "deploy 合成", collectionID: a.value.id)
        )
        let workspace = try await workspace(harness)
        await workspace.setScope(.collection(a.value.id))
        await workspace.setQuery("合成")
        XCTAssertEqual(workspace.entries.map(\.ref), [ref])
        let starred = await workspace.setFavorite([ref], isFavorite: true)
        XCTAssertTrue(starred)
        await workspace.setScope(.favorites)
        XCTAssertEqual(workspace.entries.map(\.ref), [ref])
        XCTAssertTrue(workspace.entries.allSatisfy(\.isFavorite))
        let moved = await workspace.moveItems([ref], to: b)
        XCTAssertTrue(moved)
        XCTAssertEqual(workspace.query, "合成")
        XCTAssertEqual(workspace.entries.map(\.ref), [ref])
        await workspace.setScope(.collection(a.value.id))
        XCTAssertTrue(workspace.entries.isEmpty)
        await workspace.setScope(.collection(b.value.id))
        XCTAssertEqual(workspace.entries.map(\.ref), [ref])
    }

    func testDeleteCategoryAndUndoPreserveMemoAndSearch() async throws {
        let harness = try SearchHarness.make(in: self)
        let category = try await CollectionService(controller: harness.controller).create(
            CollectionDraft(name: "Temporary", color: "orange")
        )
        let ref = try await LibraryService(controller: harness.controller).create(
            MemoDraft(body: "keep these bytes", collectionID: category.value.id)
        )
        let workspace = try await workspace(harness)
        await workspace.setScope(.collection(category.value.id))
        let deleted = await workspace.deleteCollection(category)
        XCTAssertTrue(deleted)
        XCTAssertEqual(workspace.scope, .uncategorized)
        XCTAssertEqual(workspace.entries.map(\.ref), [ref])
        XCTAssertTrue(workspace.canUndoCollectionChange)
        let undone = await workspace.undoCollectionChange()
        XCTAssertTrue(undone)
        XCTAssertEqual(workspace.collections.map(\.value.id), [category.value.id])
        let content = try await ContentRepository(controller: harness.controller).read(ref)
        XCTAssertEqual(content.representations.first?.bytes, Data("keep these bytes".utf8))
    }

    func testNewUsesVisibleScopeBeforeAnyResultsFinishLoading() async throws {
        let harness = try SearchHarness.make(in: self)
        let collection = try await CollectionService(controller: harness.controller).create(
            CollectionDraft(name: "Visible", color: "green")
        )
        let workspace = try await workspace(harness)
        await workspace.startNew(in: .collection(collection.value.id))
        XCTAssertEqual(workspace.scope, .collection(collection.value.id))
        XCTAssertEqual(workspace.editor?.collectionID, collection.value.id)
    }

    func testScopeChangeInvalidatesNewDraftWaitingForPriorSave() async throws {
        try await assertScopeChangeInvalidatesPendingNavigation(openExisting: false)
    }

    func testScopeChangeInvalidatesOpenWaitingForPriorSave() async throws {
        try await assertScopeChangeInvalidatesPendingNavigation(openExisting: true)
    }

    private func assertScopeChangeInvalidatesPendingNavigation(openExisting: Bool) async throws {
        let harness = try SearchHarness.make(in: self)
        let collections = CollectionService(controller: harness.controller)
        let a = try await collections.create(CollectionDraft(name: "A", color: "blue"))
        let b = try await collections.create(CollectionDraft(name: "B", color: "green"))
        let other = try await LibraryService(controller: harness.controller).create(
            MemoDraft(body: "different existing snippet", collectionID: a.value.id)
        )
        let workspace = try await workspace(harness)
        await workspace.setScope(.collection(a.value.id))
        await workspace.startNew()
        let draftID = try XCTUnwrap(workspace.editor?.draftID)
        workspace.editor?.setBody("preserve this in-flight draft", isComposing: false)

        let releaseWriter = DispatchSemaphore(value: 0)
        let writerBlocked = expectation(description: "Writer occupied before navigation")
        let writerBlock = Task {
            try await harness.controller.perform { _ in
                writerBlocked.fulfill()
                _ = releaseWriter.wait(timeout: .now() + 10)
            }
        }
        await fulfillment(of: [writerBlocked], timeout: 3)
        let navigationEntered = expectation(description: "Navigation starts before scope change")
        let navigation = Task { @MainActor in
            navigationEntered.fulfill()
            if openExisting { await workspace.open(other) }
            else { await workspace.startNew() }
        }
        await fulfillment(of: [navigationEntered], timeout: 3)
        workspace.updateScope(.collection(b.value.id))
        XCTAssertEqual(workspace.scope, .collection(b.value.id))
        releaseWriter.signal()
        try await writerBlock.value
        await navigation.value
        XCTAssertEqual(workspace.editor?.draftID, draftID,
                       "A late navigation must not replace the editor after scope changed")
        XCTAssertEqual(workspace.editor?.body, "preserve this in-flight draft")
    }

    func testCloseWaitsForOutstandingCollectionChangeAndKeepsItsResult() async throws {
        let harness = try SearchHarness.make(in: self)
        let gate = CollectionRefreshGate()
        let workspace = try await LibraryWorkspace.make(
            controller: harness.controller,
            draftDirectory: harness.directory.appendingPathComponent("Drafts"),
            searchService: harness.service,
            refreshSearch: {
                await gate.block()
                try await harness.consumer.synchronize()
            }
        )
        let draft = CollectionDraft(name: "Persist before closing", color: "blue")
        let mutation = Task { await workspace.createCollection(draft) }
        await gate.waitUntilBlocked()
        let closingEntered = expectation(description: "Close starts while mutation is pending")
        var closeReturned = false
        let closing = Task { @MainActor in
            closingEntered.fulfill()
            let result = await workspace.prepareToClose()
            closeReturned = true
            return result
        }
        await fulfillment(of: [closingEntered], timeout: 3)
        XCTAssertFalse(closeReturned, "Close must wait for the owned mutation")
        await gate.release()
        let changed = await mutation.value
        let closed = await closing.value
        XCTAssertTrue(changed)
        XCTAssertTrue(closed)
        let stored = try await CollectionService(controller: harness.controller).list()
        XCTAssertEqual(stored.map(\.value.id), [draft.id])
    }

    private func workspace(_ harness: SearchHarness) async throws -> LibraryWorkspace {
        try await LibraryWorkspace.make(
            controller: harness.controller,
            draftDirectory: harness.directory.appendingPathComponent("Drafts"),
            searchService: harness.service,
            refreshSearch: { try await harness.consumer.synchronize() }
        )
    }
}

private actor CollectionRefreshGate {
    private var blocked = false
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var listeners: [CheckedContinuation<Void, Never>] = []

    func block() async {
        guard !released else { return }
        blocked = true
        listeners.forEach { $0.resume() }
        listeners.removeAll()
        await withCheckedContinuation { waiting.append($0) }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { listeners.append($0) }
    }

    func release() {
        released = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

@MainActor
private final class Told {
    var count = 0
}
