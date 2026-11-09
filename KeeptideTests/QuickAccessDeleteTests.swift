import AppKit
import XCTest
@testable import Keeptide

/// Move to Recently Deleted from quick access, its undo, and Remove from a collection, over a real temporary store and
/// the library's own maintenance.
@MainActor
final class QuickAccessDeleteTests: XCTestCase {
    func testMovingTheSelectedClipToRecentlyDeletedTakesItOffTheStripAndSelectsTheOlderOne() async throws {
        let fixture = try await makeFixture(["oldest", "older", "newest"])
        let state = fixture.state
        XCTAssertEqual(state.selection.selectedRow?.title, "newest")
        var announced: [String] = []
        state.announce = { announced.append($0) }

        let deletion = await state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))?.value

        XCTAssertNotNil(deletion)
        XCTAssertEqual(state.selection.rows.map(\.title), ["older", "oldest"])
        // Older clips stand right of newer ones: the one beside it takes the selection, and can be acted on at once.
        XCTAssertEqual(state.selection.selectedRow?.title, "older")
        XCTAssertEqual(state.copyTarget?.ref, state.selection.selectedRow?.ref)
        XCTAssertEqual(state.saveMessage, "Moved to Recently Deleted")
        XCTAssertEqual(announced, ["Moved “newest” to Recently Deleted"])
        // A manual deletion: the clip leaves the history and waits in Recently Deleted until its purge date.
        let item = try await fixture.item("newest")
        XCTAssertFalse(item.historyEligible)
        XCTAssertNotNil(item.historyDeletedAt)
        XCTAssertNotNil(item.historyPurgeAfter)
        XCTAssertEqual(fixture.maintenance.trash.map(\.identity.itemID), [item.id])
        // The refresh the move sets off agrees with the strip.
        try await SearchTestSupport.waitUntil { fixture.refreshes > 0 }
        XCTAssertEqual(state.selection.rows.map(\.title), ["older", "oldest"])
        XCTAssertEqual(state.selection.selectedRow?.title, "older")
    }

    func testUndoPutsTheClipBackWhereItWasAndSelectsIt() async throws {
        let fixture = try await makeFixture(["oldest", "older", "newest"])
        let state = fixture.state
        XCTAssertEqual(state.moveSelection(by: 1), .moved)
        XCTAssertEqual(state.selection.selectedRow?.title, "older")
        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        let moved = await moving?.value
        let deletion = try XCTUnwrap(moved)
        XCTAssertEqual(state.selection.selectedRow?.title, "oldest")
        var announced: [String] = []
        state.announce = { announced.append($0) }

        let undone = await state.undoMoveToRecentlyDeleted(deletion)

        XCTAssertTrue(undone)
        XCTAssertEqual(state.selection.rows.map(\.title), ["newest", "older", "oldest"])
        XCTAssertEqual(state.selection.selectedRow?.title, "older")
        XCTAssertEqual(state.copyTarget?.ref, deletion.ref)
        XCTAssertEqual(state.saveMessage, "Recovered from Recently Deleted")
        XCTAssertEqual(announced, ["Recovered “older”"])
        let item = try await fixture.item("older")
        XCTAssertTrue(item.historyEligible)
        XCTAssertNil(item.historyDeletedAt)
        XCTAssertEqual(fixture.maintenance.trash, [])
    }

    func testMovesOneAfterAnotherAllReachRecentlyDeletedAndUndoInReverse() async throws {
        let fixture = try await makeFixture(["a", "b", "c", "d"])
        let state = fixture.state
        // ⌘⌫ pressed three times in a row: each card leaves the strip as its key is pressed, so the next press acts on
        // the clip that took its place. The library takes one action at a time, and none is refused for coming while
        // another runs.
        let movingD = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.selection.selectedRow?.title, "c")
        let movingC = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        let movingB = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.selection.rows.map(\.title), ["a"])
        let moves = [await movingD?.value, await movingC?.value, await movingB?.value]

        XCTAssertEqual(moves.compactMap { $0?.title }, ["d", "c", "b"])
        XCTAssertEqual(state.selection.rows.map(\.title), ["a"])
        XCTAssertEqual(state.selection.selectedRow?.title, "a")
        XCTAssertEqual(Set(fixture.maintenance.trash.map(\.title)), ["b", "c", "d"])

        for move in moves.reversed() {
            let undone = await state.undoMoveToRecentlyDeleted(try XCTUnwrap(move))
            XCTAssertTrue(undone)
        }
        XCTAssertEqual(state.selection.rows.map(\.title), ["d", "c", "b", "a"])
        XCTAssertEqual(state.selection.selectedRow?.title, "d")
        XCTAssertEqual(fixture.maintenance.trash, [])
    }

    func testMovingAClipToRecentlyDeletedKeepsTheSnippetItWasSavedAs() async throws {
        let fixture = try await makeFixture(["newest"])
        let state = fixture.state
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")

        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        let moved = await moving?.value
        XCTAssertNotNil(moved)

        let item = try await fixture.item("newest")
        XCTAssertFalse(item.historyEligible)
        let memo = try await fixture.memo(of: item)
        XCTAssertNil(memo.deletedAt, "The snippet saved from the clip stays in Snippets")
        XCTAssertEqual(state.selection.rows, [])
        XCTAssertEqual(state.phase, .noContent)
    }

    func testMovingASnippetsCardToRecentlyDeletedMovesTheSnippetAndKeepsTheClip() async throws {
        let fixture = try await makeFixture(["older", "newest"])
        let state = fixture.state
        let clip = try XCTUnwrap(state.copyTarget?.ref)
        _ = try await LibraryService(controller: fixture.harness.controller).saveAsMemo(clip.itemID)
        try await fixture.harness.consumer.synchronize()
        state.setList(.snippets)
        try await SearchTestSupport.waitUntil { state.phase == .results && state.copyTarget?.ref.facet == .memo }

        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        let moved = await moving?.value
        XCTAssertNotNil(moved)

        let item = try await fixture.item("newest")
        let memo = try await fixture.memo(of: item)
        XCTAssertNotNil(memo.deletedAt)
        XCTAssertTrue(item.historyEligible, "The clip the snippet was saved from stays in the history")
        XCTAssertEqual(state.selection.rows, [])
        XCTAssertEqual(state.phase, .noContent)
        XCTAssertEqual(fixture.maintenance.trash.map(\.identity.facet), [.memo])
    }

    func testAMoveTheLibraryRefusesKeepsTheCardAndSaysSo() async throws {
        let fixture = try await makeFixture(["older", "newest"])
        let state = fixture.state
        let target = try XCTUnwrap(state.copyTarget)
        // The library's maintenance stopped, as when the library closes.
        await fixture.maintenance.stopAndDrain()

        let deletion = await state.moveToRecentlyDeleted(target)?.value

        XCTAssertNil(deletion)
        XCTAssertEqual(state.selection.rows.map(\.title), ["newest", "older"])
        XCTAssertEqual(state.copyTarget, target)
        XCTAssertEqual(state.saveMessage, "This item could not be moved to Recently Deleted.")
        let item = try await fixture.item("newest")
        XCTAssertTrue(item.historyEligible)
    }

    func testAClosedPanelMovesNothing() async throws {
        let fixture = try await makeFixture(["older", "newest"])
        let state = fixture.state
        let target = try XCTUnwrap(state.copyTarget)
        state.close()

        let deletion = await state.moveToRecentlyDeleted(target)?.value

        XCTAssertNil(deletion)
        let item = try await fixture.item("newest")
        XCTAssertTrue(item.historyEligible)
        XCTAssertEqual(fixture.maintenance.trash, [])
    }

    func testAnUndoForAnotherLibraryPutsNothingBack() async throws {
        let fixture = try await makeFixture(["older", "newest"])
        let state = fixture.state
        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        let moved = await moving?.value
        let deletion = try XCTUnwrap(moved)
        // The library was replaced: its maintenance is another one.
        let other = try await makeMaintenance(over: fixture.harness)
        fixture.services.lifecycle = other

        let undone = await state.undoMoveToRecentlyDeleted(deletion)

        XCTAssertFalse(undone)
        XCTAssertEqual(state.saveMessage, "The library changed. This item is still in Recently Deleted there.")
        let item = try await fixture.item("newest")
        XCTAssertFalse(item.historyEligible)
        XCTAssertEqual(state.selection.rows.map(\.title), ["older"])
    }

    func testARefusalAfterThePersonMovedOnPutsTheCardBackAndLeavesTheirSelection() async throws {
        let library = GatedLifecycle()
        library.grants = false
        let fixture = try await makeFixture(["a", "b", "c", "d"], lifecycle: library)
        let state = fixture.state
        var announced: [String] = []
        state.announce = { announced.append($0) }
        XCTAssertEqual(state.moveSelection(by: 1), .moved)
        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.selection.selectedRow?.title, "b")
        // While the library holds the move, the person steps on to another clip.
        XCTAssertEqual(state.moveSelection(by: 1), .moved)

        try await library.letGo()
        let moved = await moving?.value

        XCTAssertNil(moved)
        XCTAssertEqual(state.selection.rows.map(\.title), ["d", "c", "b", "a"])
        XCTAssertEqual(state.selection.selectedRow?.title, "a", "Return acts on the clip the person chose")
        XCTAssertEqual(state.saveMessage, "This item could not be moved to Recently Deleted.")
        XCTAssertEqual(announced, ["“c” could not be moved to Recently Deleted"])
    }

    func testAnUndoThatFinishesAfterThePersonMovedOnLeavesTheirSelection() async throws {
        let library = GatedLifecycle()
        let fixture = try await makeFixture(["a", "b", "c"], lifecycle: library)
        let state = fixture.state
        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        try await library.letGo()
        let moved = await moving?.value
        let deletion = try XCTUnwrap(moved)
        XCTAssertEqual(state.selection.selectedRow?.title, "b")

        let undoing = Task { await state.undoMoveToRecentlyDeleted(deletion) }
        try await SearchTestSupport.waitUntil { library.waiting == 1 }
        XCTAssertEqual(state.moveSelection(by: 1), .moved)
        try await library.letGo()
        let undone = await undoing.value

        XCTAssertTrue(undone)
        XCTAssertEqual(state.selection.rows.map(\.title), ["c", "b", "a"])
        XCTAssertEqual(state.selection.selectedRow?.title, "a")
    }

    func testAFrequentClipMovedToRecentlyDeletedStaysOutOfTheWingWhenTheListIsReadAgain() async throws {
        let fixture = try await makeFixture(["a", "b", "c", "d", "e"], frequent: ["a": 3], firstScreen: 2)
        let state = fixture.state
        XCTAssertEqual(state.selection.rows.map(\.title), ["a", "e", "d", "c", "b", "a"])
        let wingRow = try XCTUnwrap(state.selection.rows.first)
        XCTAssertTrue(wingRow.isFrequent)
        state.select(wingRow.id)

        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        let moved = await moving?.value
        XCTAssertNotNil(moved)
        XCTAssertEqual(state.selection.rows.map(\.title), ["e", "d", "c", "b"])
        // The wing was read as the panel opened, with the clip in it; a list read again leaves it out all the same.
        state.toggleKind(.text)
        try await SearchTestSupport.waitUntil { state.phase != .loading }
        state.toggleKind(.text)
        try await SearchTestSupport.waitUntil { state.phase == .results }

        XCTAssertEqual(state.selection.rows.map(\.title), ["e", "d", "c", "b"])
        XCTAssertEqual(state.selection.frequentCount, 0)
    }

    func testAListThatFindsOnlyWhatWasMovedSaysNothingMatches() async throws {
        let fixture = try await makeFixture(["alpha", "beta"])
        let state = fixture.state
        state.setQuery("beta")
        try await SearchTestSupport.waitUntil {
            state.phase == .results && state.selection.rows.map(\.title) == ["beta"] && state.copyTarget != nil
        }
        // The index stops following the store, as when it has not caught up with the move yet.
        await fixture.harness.consumer.stopAndDrain()
        let moving = state.moveToRecentlyDeleted(try XCTUnwrap(state.copyTarget))
        let moved = await moving?.value
        XCTAssertNotNil(moved)

        state.setQuery("bet")
        try await SearchTestSupport.waitUntil { state.phase != .loading }
        state.setQuery("beta")
        try await SearchTestSupport.waitUntil { state.phase != .loading }

        XCTAssertEqual(state.selection.rows, [])
        XCTAssertEqual(state.phase, .noResults)
    }

    func testMovesStillWaitingWhenTheLibraryStopsEndAndSayWhatHappened() async throws {
        let fixture = try await makeFixture(["a", "b", "c"])
        let maintenance = fixture.maintenance
        let refs = fixture.state.selection.rows.map(\.ref)
        let first = Task { await maintenance.moveToRecentlyDeleted(refs[0]) }
        let second = Task { await maintenance.moveToRecentlyDeleted(refs[1]) }
        await Task.yield()

        await maintenance.stopAndDrain()
        let results = [await first.value, await second.value]

        // Nothing waits for ever, and each answer is what the store holds.
        for (ref, result) in zip(refs, results) {
            let state = try await ContentRepository(controller: fixture.harness.controller).recordState(.item(ref.itemID))
            guard case .item(let item) = state.value else { return XCTFail("Missing history") }
            XCTAssertEqual(item.historyEligible, result == nil)
        }
    }

    // MARK: Remove from the listed collection

    func testRemoveFromTheListedCollectionTakesTheCardOffTheListAndKeepsTheSnippet() async throws {
        let fixture = try await makeFixture(["older", "newest"])
        let state = fixture.state
        let service = CollectionService(controller: fixture.harness.controller)
        let prompts = try await service.create(CollectionDraft(name: "Prompts", color: "blue"))
        let library = LibraryService(controller: fixture.harness.controller)
        for row in state.selection.rows {
            _ = try await library.saveAsMemo(row.ref.itemID, collectionIDs: [prompts.value.id])
        }
        try await fixture.harness.consumer.synchronize()
        state.collectionsDidChange()
        try await SearchTestSupport.waitUntil { state.collections.map(\.name) == ["Prompts"] }
        state.setList(.collection(prompts.value.id))
        try await SearchTestSupport.waitUntil { state.phase == .results && state.selection.rows.count == 2 }
        XCTAssertEqual(state.listedCollectionOfSelection?.name, "Prompts")
        let removed = try XCTUnwrap(state.selection.selectedRow)

        await state.removeFromListedCollection(try XCTUnwrap(state.copyTarget))

        XCTAssertEqual(state.saveMessage, "Removed from “Prompts”")
        XCTAssertFalse(state.selection.rows.contains { $0.ref == removed.ref })
        XCTAssertEqual(state.selection.rows.count, 1)
        XCTAssertNotNil(state.selection.selectedRow)
        let item = try await fixture.item(removed.title)
        XCTAssertEqual(item.collectionIDs, [])
        let memo = try await fixture.memo(of: item)
        XCTAssertNil(memo.deletedAt, "Leaving a collection deletes nothing")
        // Outside a collection there is no collection to leave.
        state.setList(.snippets)
        try await SearchTestSupport.waitUntil { state.phase == .results && state.copyTarget?.ref.facet == .memo }
        XCTAssertNil(state.listedCollectionOfSelection)
    }

    // MARK: Fixture

    @MainActor
    private final class Fixture {
        let harness: SearchHarness
        let state: QuickAccessState
        let maintenance: LibraryMaintenance
        var services: QuickAccessServices
        /// Each clip's item, by its title.
        let items: [String: ItemID]
        var refreshes = 0

        init(harness: SearchHarness, state: QuickAccessState, maintenance: LibraryMaintenance,
             services: QuickAccessServices, items: [String: ItemID]) {
            self.harness = harness
            self.state = state
            self.maintenance = maintenance
            self.services = services
            self.items = items
        }

        func item(_ title: String) async throws -> ItemValue {
            let id = try XCTUnwrap(items[title])
            let state = try await ContentRepository(controller: harness.controller).recordState(.item(id))
            guard case .item(let value) = state.value else { throw StoreError.notFound }
            return value
        }

        func memo(of item: ItemValue) async throws -> MemoValue {
            let memoID = try XCTUnwrap(item.memoID)
            let state = try await ContentRepository(controller: harness.controller).recordState(.memo(memoID))
            guard case .memo(let value) = state.value else { throw StoreError.notFound }
            return value
        }
    }

    /// A library that holds each move and recovery until the test lets it go, and then grants or refuses it.
    @MainActor
    private final class GatedLifecycle: QuickAccessLifecycle {
        var grants = true
        private var held: [CheckedContinuation<Void, Never>] = []
        var waiting: Int { held.count }

        func moveToRecentlyDeleted(_ ref: ContentRef) async -> DeletedFacetIdentity? {
            await withCheckedContinuation { held.append($0) }
            return grants ? DeletedFacetIdentity(itemID: ref.itemID, facet: ref.facet, generationID: ref.version.rawValue)
                : nil
        }

        func recover(_ target: DeletedFacetIdentity) async -> Bool {
            await withCheckedContinuation { held.append($0) }
            return grants
        }

        /// Lets the action held longest go on, once one is held.
        func letGo() async throws {
            try await SearchTestSupport.waitUntil { !self.held.isEmpty }
            held.removeFirst().resume()
        }
    }

    /// Reaches the fixture from what is made before it.
    @MainActor
    private final class Relay {
        weak var fixture: Fixture?
    }

    /// An open state over a real store holding one recent text clip per title, the last the newest, with the library's
    /// maintenance behind Move to Recently Deleted. The maintenance reports a change the way the app's does, by having
    /// the open panel read its recent clips again.
    private func makeFixture(_ titles: [String], lifecycle standIn: (any QuickAccessLifecycle)? = nil,
                             frequent uses: [String: Int] = [:], firstScreen: Int? = nil) async throws -> Fixture {
        let harness = try SearchHarness.make(in: self)
        var items: [String: ItemID] = [:]
        let now = Date()
        for (offset, title) in titles.enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(title.utf8))]])
            // Copied within the last few minutes: Recently Deleted recovers only clips the history would still keep.
            let item = ItemValue(title: title, captureID: capture.id, historyEligible: true,
                                 lastCopiedAt: now.addingTimeInterval(Double(offset - titles.count) * 60), copyCount: 1)
            try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
            items[title] = item.id
            for use in 0..<(uses[title] ?? 0) {
                try await LocalUsageStore(controller: harness.controller).record(UseReceipt(
                    ref: ContentStoreFixtures.ref(item, capture), occurredAt: now - Double(use), outcome: .success))
            }
        }
        try await harness.consumer.synchronize()
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) },
                                 recordUse: { _ in }, didWrite: { _ in })
        let collections = CollectionService(controller: harness.controller)
        let relay = Relay()
        let maintenance = try await makeMaintenance(over: harness) {
            relay.fixture?.refreshes += 1
            relay.fixture?.state.recentClipsChanged()
        }
        let services = QuickAccessServices(repository: repository, search: harness.service, paste: paste,
                                           usage: LocalUsageStore(controller: harness.controller),
                                           library: LibraryService(controller: harness.controller),
                                           collections: collections, collectionChanges: collections,
                                           lifecycle: standIn ?? maintenance)
        let made = Fixture(harness: harness, state: QuickAccessState(services: { relay.fixture?.services }),
                           maintenance: maintenance, services: services, items: items)
        relay.fixture = made
        addTeardownBlock { @MainActor in _ = made }
        if let firstScreen {
            made.state.open(frequentWingFirstScreen: { _ in firstScreen })
        } else {
            made.state.open()
        }
        try await SearchTestSupport.waitUntil { made.state.phase == .results && made.state.copyTarget != nil }
        return made
    }

    private func makeMaintenance(over harness: SearchHarness,
                                 didChange: @escaping @MainActor () async -> Void = {}) async throws
        -> LibraryMaintenance {
        let suite = "Keeptide-QuickAccessDelete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let maintenance = LibraryMaintenance(controller: harness.controller,
                                             identity: try await harness.controller.identity(),
                                             directory: harness.directory,
                                             preferences: LifecyclePreferences(defaults: defaults),
                                             didChange: didChange)
        addTeardownBlock {
            await maintenance.stopAndDrain()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return maintenance
    }
}
