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

    func testMovingTheSelectionClearsTheSaveStatusAndItsUndo() async throws {
        let (state, harness, ref) = try await fixture(["older", "command"])
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")
        XCTAssertTrue(state.canUndoSave)

        XCTAssertEqual(state.moveSelection(by: 1), .moved)
        XCTAssertNotEqual(state.copyTarget?.ref, ref)
        XCTAssertNil(state.saveMessage)
        XCTAssertFalse(state.canUndoSave)
        // The other clip's save is no longer this selection's to undo.
        await state.undoSaveSelection()
        XCTAssertNil(state.saveMessage)
        let item = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let value) = item.value else { return XCTFail("Missing history") }
        XCTAssertNotNil(value.memoID)
    }

    func testARefreshThatLosesTheSelectedClipClearsTheSaveStatusAndItsUndo() async throws {
        let (state, harness, ref) = try await fixture(["older", "command"])
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")
        XCTAssertTrue(state.canUndoSave)

        // The clip leaves the history while the panel is open, and the list is read again without it.
        _ = try await LifecycleService(controller: harness.controller).remove(
            itemID: ref.itemID, facet: .history, at: Date(), expecting: try await harness.controller.identity(),
            permit: try await StoreSafetyGate(controller: harness.controller).permit(.maintenance))
        state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { state.selection.rows.map(\.title) == ["older"] }
        XCTAssertNil(state.selection.selectedID)
        XCTAssertNil(state.saveMessage)
        XCTAssertFalse(state.canUndoSave)
        // Its save is no longer this selection's to undo.
        await state.undoSaveSelection()
        let item = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let value) = item.value else { return XCTFail("Missing history") }
        XCTAssertNotNil(value.memoID)
    }

    func testSelectingTheSelectedClipAgainKeepsItsSaveStatus() async throws {
        let harness = try SearchHarness.make(in: self)
        let text = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("older".utf8))]])
        try await ContentStoreFixtures.insert(
            ItemValue(title: "older", captureID: text.id, historyEligible: true,
                      lastCopiedAt: Date(timeIntervalSince1970: 1_000), copyCount: 1), text, into: harness.controller)
        let picture = try ContentStoreFixtures.capture([[("public.png", Data([0x89, 0x50, 0x4E, 0x47]))]])
        try await ContentStoreFixtures.insert(
            ItemValue(title: "Picture", captureID: picture.id, historyEligible: true,
                      lastCopiedAt: Date(timeIntervalSince1970: 1_001), copyCount: 1), picture,
            into: harness.controller)
        let state = try await openState(over: harness)
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        await state.copySelection(.plainText)
        XCTAssertEqual(state.failure, .noPlainText)
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")

        // A second click on the selected card selects the same clip: its refusal goes, as any selection takes it, and
        // its save stays, with the undo.
        let selected = try XCTUnwrap(state.selection.selectedID)
        state.select(selected)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")
        XCTAssertTrue(state.canUndoSave)

        // Another clip's card takes the save's place.
        state.select(try XCTUnwrap(state.selection.rows.first { $0.id != selected }).id)
        XCTAssertNil(state.saveMessage)
        XCTAssertFalse(state.canUndoSave)
    }

    func testANewQueryOrFilterClearsTheSaveStatusAndItsUndo() async throws {
        let (state, _, _) = try await fixture()
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")
        state.setQuery("command")
        XCTAssertNil(state.saveMessage)
        XCTAssertFalse(state.canUndoSave)

        state.setQuery("")
        try await SearchTestSupport.waitUntil { state.phase == .results && state.copyTarget != nil }
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.saveMessage, "Already in Snippets")
        state.toggleKind(.text)
        XCTAssertNil(state.saveMessage)
        XCTAssertFalse(state.canUndoSave)
    }

    func testSavingAClipWhoseContentIsNotAvailableSaysWhyAndSavesNothing() async throws {
        let harness = try SearchHarness.make(in: self)
        let capture = try ContentStoreFixtures.localReferenceCapture()
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insertLocalReference(item, capture, into: harness.controller)
        // Without its local file access the reference has to be relocated before its content can be used.
        try await FileAccessStore(controller: harness.controller).remove(
            representationID: try XCTUnwrap(capture.representations.first).id,
            permit: StoreSafetyGate(controller: harness.controller).permit(.maintenance))
        let ref = ContentStoreFixtures.ref(item, capture)
        let content = try await ContentRepository(controller: harness.controller).read(ref)
        XCTAssertEqual(content.integrity, .requiresRelocation)
        let state = try await openState(over: harness)
        XCTAssertEqual(state.copyTarget?.ref, ref)

        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertEqual(state.saveMessage, "This clip can't be saved as a snippet until its content is available.")
        XCTAssertFalse(state.canUndoSave)
        let stored = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let value) = stored.value else { return XCTFail("Missing history") }
        XCTAssertNil(value.memoID)
    }

    func testASaveAfterARefusedCopySaysWhatTheSaveCameTo() async throws {
        let harness = try SearchHarness.make(in: self)
        let capture = try ContentStoreFixtures.capture([[("public.png", Data([0x89, 0x50, 0x4E, 0x47]))]])
        let item = ItemValue(title: "Picture", captureID: capture.id, historyEligible: true, copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        let state = try await openState(over: harness)
        await state.copySelection(.plainText)
        XCTAssertEqual(state.failure, .noPlainText)

        // The toolbar shows a refusal before a save's message, so the save, done last, takes the refusal's place.
        await state.saveSelection(try XCTUnwrap(state.copyTarget))
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.saveMessage, "Saved to Snippets")
    }

    /// A state over a temporary store holding one text clip per body, each copied a second after the one before, so
    /// the last is the newest and is selected; the clip returned is that one.
    private func fixture(_ bodies: [String] = ["command"]) async throws
        -> (QuickAccessState, SearchHarness, ContentRef) {
        let harness = try SearchHarness.make(in: self)
        var newest: ContentRef?
        for (offset, body) in bodies.enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(body.utf8))]])
            let item = ItemValue(title: body, captureID: capture.id, historyEligible: true,
                                 lastCopiedAt: Date(timeIntervalSince1970: 1_000 + Double(offset)), copyCount: 1)
            try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
            newest = ContentStoreFixtures.ref(item, capture)
        }
        let state = try await openState(over: harness)
        let ref = try XCTUnwrap(newest)
        XCTAssertEqual(state.copyTarget?.ref, ref)
        return (state, harness, ref)
    }

    /// An open state over the harness's store, once it lists the store's clips.
    private func openState(over harness: SearchHarness) async throws -> QuickAccessState {
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
        return state
    }
}
