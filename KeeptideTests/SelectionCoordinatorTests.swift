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
        progressive.select(b.ref)
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
        selection.select(b.ref)
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
}

private func row(_ title: String) -> QuickAccessRow {
    QuickAccessRow(
        ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 3, count: 32)),
        title: title, snippet: nil, kind: .text, sourceApp: nil, date: Date(timeIntervalSince1970: 1_000),
        savedAsMemo: false, isPartiallyIndexed: false, isTextUnavailable: false
    )
}
