import XCTest
@testable import Keeptide

final class SelectionCoordinatorTests: XCTestCase {
    private let a = row("a"), b = row("b"), c = row("c"), fresh = row("fresh")

    func testOldRowsAreNotExecutableBeforeTheFirstPage() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b], generation: 1, isComplete: true)
        XCTAssertEqual(selection.executableSelection, a.ref)

        selection.beginGeneration(2)

        XCTAssertEqual(selection.rows, [a, b], "Old rows stay visible to avoid flicker")
        XCTAssertNil(selection.executableSelection)
    }

    func testFirstPageSelectsTheFirstRow() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)

        selection.apply([a, b], generation: 1, isComplete: true)

        XCTAssertEqual(selection.selection, a.ref)
        XCTAssertEqual(selection.executableSelection, a.ref)
    }

    func testLatePagesForOtherGenerationsAreIgnored() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(2)

        selection.apply([a, b], generation: 1, isComplete: true)

        XCTAssertEqual(selection.rows, [])
        XCTAssertNil(selection.selection)
    }

    func testProgressivePagesFollowTheTopUntilTheUserMoves() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([b, c], generation: 1, isComplete: false)
        XCTAssertEqual(selection.selection, b.ref)

        selection.apply([a, b, c], generation: 1, isComplete: false)
        XCTAssertEqual(selection.selection, a.ref)

        XCTAssertEqual(selection.move(by: 1), .moved)
        selection.apply([fresh, a, b, c], generation: 1, isComplete: true)
        XCTAssertEqual(selection.selection, b.ref)
    }

    func testIncompletePageIsNotExecutableUntilCompleteOrChosen() {
        var progressive = SelectionCoordinator()
        progressive.beginGeneration(1)
        progressive.apply([a, b], generation: 1, isComplete: false)
        XCTAssertNil(progressive.executableSelection)
        progressive.select(b.id)
        XCTAssertEqual(progressive.executableSelection, b.ref)

        var completed = SelectionCoordinator()
        completed.beginGeneration(1)
        completed.apply([a, b], generation: 1, isComplete: false)
        completed.apply([a, b], generation: 1, isComplete: true)
        XCTAssertEqual(completed.executableSelection, a.ref)
    }

    func testRefreshKeepsTheSelectedIdentityWhenRowsShift() {
        var chosen = SelectionCoordinator()
        chosen.beginGeneration(1)
        chosen.apply([a, b, c], generation: 1, isComplete: true)
        _ = chosen.move(by: 1)
        chosen.apply([fresh, a, b, c], generation: 1, isComplete: true)
        XCTAssertEqual(chosen.selection, b.ref)

        var automatic = SelectionCoordinator()
        automatic.beginGeneration(1)
        automatic.apply([a, b], generation: 1, isComplete: true)
        automatic.apply([fresh, a, b], generation: 1, isComplete: true)
        XCTAssertEqual(automatic.selection, a.ref, "A new clip must not take over the selected row")
    }

    func testVanishedSelectionClearsAndDoesNotAdvance() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b, c], generation: 1, isComplete: true)
        _ = selection.move(by: 1)

        selection.apply([a, c], generation: 1, isComplete: true)

        XCTAssertNil(selection.selection)
        XCTAssertTrue(selection.selectionLost)
        XCTAssertNil(selection.executableSelection)
    }

    func testEmptyResultsClearSelection() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a], generation: 1, isComplete: true)
        selection.beginGeneration(2)

        selection.apply([], generation: 2, isComplete: true)

        XCTAssertNil(selection.selection)
        XCTAssertNil(selection.executableSelection)
        XCTAssertFalse(selection.selectionLost)
    }

    func testMoveUpFromFirstRowReportsAtTopWithoutWrapping() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b], generation: 1, isComplete: true)

        XCTAssertEqual(selection.move(by: -1), .atTop)
        XCTAssertEqual(selection.selection, a.ref)
    }

    func testMoveDownFromLastRowStops() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b], generation: 1, isComplete: true)

        XCTAssertEqual(selection.move(by: 1), .moved)
        XCTAssertEqual(selection.move(by: 1), .atBottom)
        XCTAssertEqual(selection.selection, b.ref)
    }

    func testDownWithoutSelectionSelectsTheFirstRow() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b], generation: 1, isComplete: true)
        _ = selection.move(by: 1)
        selection.apply([a], generation: 1, isComplete: true)
        XCTAssertNil(selection.selection)

        XCTAssertEqual(selection.move(by: 1), .moved)

        XCTAssertEqual(selection.selection, a.ref)
        XCTAssertFalse(selection.selectionLost)
    }

    func testInertRowsCannotBeChosenBeforeTheFirstPage() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b], generation: 1, isComplete: true)
        selection.beginGeneration(2)

        XCTAssertEqual(selection.move(by: 1), .unchanged)
        selection.select(b.id)
        selection.apply([fresh, c], generation: 2, isComplete: false)

        XCTAssertEqual(selection.selection, fresh.ref)
        XCTAssertNil(selection.executableSelection, "An incomplete page stays inert until the user chooses on it")
    }

    func testChosenRowSurvivesReRankingWithinOneStream() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b, c], generation: 1, isComplete: false, keepsChosenRow: true)
        XCTAssertEqual(selection.move(by: 1), .moved)

        selection.apply([fresh, a, c], generation: 1, isComplete: true, keepsChosenRow: true)

        XCTAssertEqual(selection.selection, b.ref)
        XCTAssertEqual(selection.rows.map(\.title), ["fresh", "b", "a", "c"], "The chosen row keeps its place")
        XCTAssertFalse(selection.selectionLost)
        XCTAssertEqual(selection.executableSelection, b.ref)
    }

    func testAppendKeepsSelectionAndSkipsDuplicates() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        selection.apply([a, b], generation: 1, isComplete: true)
        _ = selection.move(by: 1)

        selection.append([b, c], generation: 1)

        XCTAssertEqual(selection.rows, [a, b, c])
        XCTAssertEqual(selection.selection, b.ref)
    }

    // MARK: The frequent wing

    func testTheFirstPageSelectsTheNewestRecentRowAfterTheWing() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fa = frequent(a, uses: 5), fb = frequent(b, uses: 3)

        selection.apply([fa, fb, c, a], generation: 1, isComplete: true)

        XCTAssertEqual(selection.selectedID, c.id)
        XCTAssertEqual(selection.frequentCount, 2)
        XCTAssertEqual(selection.move(by: -1), .moved)
        XCTAssertEqual(selection.selectedID, fb.id)
    }

    func testTheSameClipInBothWingsIsTwoRows() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fa = frequent(a, uses: 2)
        selection.apply([fa, c, a], generation: 1, isComplete: true)

        selection.select(a.id)

        XCTAssertEqual(selection.selection, a.ref)
        XCTAssertEqual(selection.move(by: -1), .moved)
        XCTAssertEqual(selection.selectedID, c.id)
        XCTAssertEqual(selection.move(by: 1), .moved)
        XCTAssertEqual(selection.selectedID, a.id, "The recent copy, not the frequent one")
        XCTAssertEqual(selection.move(by: 1), .atBottom)
    }

    func testAPageAppendedAfterTheWingKeepsClipsAlsoInIt() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fa = frequent(a, uses: 2)
        selection.apply([fa, b], generation: 1, isComplete: true)

        selection.append([a, c], generation: 1)

        XCTAssertEqual(selection.rows.map(\.id), [fa.id, b.id, a.id, c.id])
    }

    func testAVanishedSelectionLeavesItsSlotBeforeTheWing() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fa = frequent(a, uses: 3), fb = frequent(b, uses: 2)
        selection.apply([fa, fb, c, fresh], generation: 1, isComplete: true)
        XCTAssertEqual(selection.move(by: 1), .moved)
        XCTAssertEqual(selection.selectedID, fresh.id)

        // The chosen clip goes, and nothing is selected in its place.
        selection.apply([fa, fb, c], generation: 1, isComplete: true)
        XCTAssertNil(selection.selectedID)
        XCTAssertTrue(selection.selectionLost)

        // The empty slot lies before the whole film, the wing included: nothing is newer, and the next row is the first
        // frequent one, not the first recent one.
        XCTAssertEqual(selection.move(by: -1), .atTop)
        XCTAssertNil(selection.selectedID)
        XCTAssertEqual(selection.move(by: 1), .moved)
        XCTAssertEqual(selection.selectedID, fa.id)
    }

    func testAFrequentCopyThatLeavesTheWingIsLostThoughItsClipStays() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fa = frequent(a, uses: 2)
        selection.apply([fa, b, a], generation: 1, isComplete: true)
        selection.select(fa.id)

        // The clip is copied again and joins the first screen, so the wing no longer lists it.
        selection.apply([a, b], generation: 1, isComplete: true)

        XCTAssertNil(selection.selectedID)
        XCTAssertNil(selection.selectedRow)
        XCTAssertTrue(selection.selectionLost)
    }
}

/// A copy of `row` listed in the frequent wing, used `uses` times.
private func frequent(_ row: QuickAccessRow, uses: Int64) -> QuickAccessRow {
    var copy = row
    copy.frequentUses = uses
    return copy
}

private func row(_ title: String) -> QuickAccessRow {
    QuickAccessRow(
        ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 3, count: 32)),
        title: title, snippet: nil, kind: .text, sourceApp: nil, date: Date(timeIntervalSince1970: 1_000),
        savedAsMemo: false, isPartiallyIndexed: false, isTextUnavailable: false
    )
}
