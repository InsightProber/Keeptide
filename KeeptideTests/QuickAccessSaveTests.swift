import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class QuickAccessSaveTests: XCTestCase {
    func testSaveStaysInPanelAndUndoOnlyRemovesNewQualification() async throws {
        let (state, harness, ref) = try await fixture()
        let target = try XCTUnwrap(state.copyTarget)
        await state.saveSelection(target)
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")
        XCTAssertTrue(state.canUndoSave)
        XCTAssertEqual(state.copyTarget?.ref, ref)
        let saved = try await LibraryService(controller: harness.controller).saveAsMemo(ref.itemID)
        guard case .existing = saved else { return XCTFail("Panel did not save the selected history") }
        await state.undoSaveSelection()
        let item = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let value) = item.value else { return XCTFail("Missing history") }
        XCTAssertNil(value.memoID)
        _ = try await ContentRepository(controller: harness.controller).read(ref)
    }

    func testRepeatSaveCannotUndoPreviouslySavedSnippet() async throws {
        let (state, harness, ref) = try await fixture()
        _ = try await LibraryService(controller: harness.controller).saveAsMemo(ref.itemID)
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.saveMessage, "Already in Snippets")
        XCTAssertFalse(state.canUndoSave)
    }

    func testClosedPanelRefusesQueuedSave() async throws {
        let (state, harness, ref) = try await fixture()
        let target = try XCTUnwrap(state.copyTarget)
        state.close()
        await state.saveSelection(target)
        let item = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let value) = item.value else { return XCTFail("Missing history") }
        XCTAssertNil(value.memoID)
    }

    private func fixture() async throws -> (QuickAccessState, SearchHarness, ContentRef) {
        let harness = try SearchHarness.make(in: self)
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("command".utf8))]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) },
                                 recordUse: { _ in }, didWrite: { _ in })
        let services = QuickAccessServices(repository: repository, search: harness.service, paste: paste,
                                           library: LibraryService(controller: harness.controller))
        let state = QuickAccessState(services: { services })
        state.open()
        try await SearchTestSupport.waitUntil { state.phase == .results }
        return (state, harness, ContentStoreFixtures.ref(item, capture))
    }
}
