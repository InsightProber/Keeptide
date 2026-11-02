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

    // The state lists the wing the least used first, so the most used stands beside the newest recent clip.

    func testTheFirstPageSelectsTheNewestRecentRowAfterTheWing() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fb = frequent(b, uses: 3), fa = frequent(a, uses: 5)

        selection.apply([fb, fa, c, a], generation: 1, isComplete: true)

        XCTAssertEqual(selection.selectedID, c.id)
        XCTAssertEqual(selection.frequentCount, 2)
        // ← from the newest clip reaches the most used one, across the divider.
        XCTAssertEqual(selection.move(by: -1), .moved)
        XCTAssertEqual(selection.selectedID, fa.id)
        XCTAssertEqual(selection.selectedRow?.frequentUses, 5)
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

    func testAVanishedSelectionLeavesItsSlotAtTheDivider() {
        let fb = frequent(b, uses: 2), fa = frequent(a, uses: 3)
        // The same rows each time, with the chosen recent clip gone: rows [fb, fa, c] with the selection lost, fa the
        // most used.
        func lost() -> SelectionCoordinator {
            var selection = SelectionCoordinator()
            selection.beginGeneration(1)
            selection.apply([fb, fa, c, fresh], generation: 1, isComplete: true)
            XCTAssertEqual(selection.move(by: 1), .moved)
            XCTAssertEqual(selection.selectedID, fresh.id)
            // The chosen clip goes, and nothing is selected in its place.
            selection.apply([fb, fa, c], generation: 1, isComplete: true)
            XCTAssertNil(selection.selectedID)
            XCTAssertTrue(selection.selectionLost)
            return selection
        }

        // The empty slot lies at the divider, just before the newest recent clip: → selects that clip, and ← the most
        // used one, across the divider.
        var right = lost()
        XCTAssertEqual(right.move(by: 1), .moved)
        XCTAssertEqual(right.selectedID, c.id)
        XCTAssertFalse(right.selectionLost)
        var left = lost()
        XCTAssertEqual(left.move(by: -1), .moved)
        XCTAssertEqual(left.selectedID, fa.id)
        XCTAssertFalse(left.selectionLost)
        // A step of no length goes nowhere.
        var still = lost()
        XCTAssertEqual(still.move(by: 0), .unchanged)
        XCTAssertNil(still.selectedID)
    }

    func testAFrequentCopyThatLeavesTheWingHandsTheSelectionToItsRecentRow() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fa = frequent(a, uses: 2)
        selection.apply([fa, b, a], generation: 1, isComplete: true)
        selection.select(fa.id)

        // The clip is copied again and joins the first screen, so the wing no longer lists it. Its recent row holds the
        // same content, so the selection stays on the clip, in that row.
        selection.apply([a, b], generation: 1, isComplete: true)

        XCTAssertEqual(selection.selectedID, a.id)
        XCTAssertEqual(selection.selectedRow, a)
        XCTAssertFalse(selection.selectionLost)
        XCTAssertEqual(selection.executableSelection, a.ref)
        // From there the keys go on as from any recent row.
        XCTAssertEqual(selection.move(by: 1), .moved)
        XCTAssertEqual(selection.selectedID, b.id)
    }

    func testARecentRowThatGoesIsLostThoughTheWingStillListsItsClip() {
        var selection = SelectionCoordinator()
        selection.beginGeneration(1)
        let fa = frequent(a, uses: 2)
        selection.apply([fa, b, a], generation: 1, isComplete: true)
        selection.select(a.id)

        // The recent clips no longer list the clip, as when it left the history: the wing's row was read as the panel
        // opened and may be all that is left of it, so the selection does not go there.
        selection.apply([fa, b], generation: 1, isComplete: true)

        XCTAssertNil(selection.selectedID)
        XCTAssertTrue(selection.selectionLost)
    }

    func testAChosenRowKeptThroughReRankingStaysInItsOwnWing() {
        // A frequent row chosen at the wing's right end, beside the divider, while the next page lists a shorter wing:
        // it goes back no further right than the wing reaches, never among the recent rows.
        var frequentChosen = SelectionCoordinator()
        frequentChosen.beginGeneration(1)
        let fc = frequent(c, uses: 2), fb = frequent(b, uses: 3), fa = frequent(a, uses: 4)
        frequentChosen.apply([fc, fb, fa, fresh], generation: 1, isComplete: false, keepsChosenRow: true)
        frequentChosen.select(fa.id)
        frequentChosen.apply([fc, fresh, a, b], generation: 1, isComplete: true, keepsChosenRow: true)
        XCTAssertEqual(frequentChosen.rows.map(\.id), [fc.id, fa.id, fresh.id, a.id, b.id])
        XCTAssertEqual(frequentChosen.frequentCount, 2)
        XCTAssertEqual(frequentChosen.selectedID, fa.id)
        XCTAssertFalse(frequentChosen.selectionLost)

        // A recent row chosen just after a wing that the next page lists longer: it goes back no further left than the
        // wing reaches, never into it.
        var recentChosen = SelectionCoordinator()
        recentChosen.beginGeneration(1)
        recentChosen.apply([fa, fresh, b, c], generation: 1, isComplete: false, keepsChosenRow: true)
        recentChosen.select(fresh.id)
        recentChosen.apply([fc, fb, fa, b, c], generation: 1, isComplete: true, keepsChosenRow: true)
        XCTAssertEqual(recentChosen.rows.map(\.id), [fc.id, fb.id, fa.id, fresh.id, b.id, c.id])
        XCTAssertEqual(recentChosen.frequentCount, 3)
        XCTAssertEqual(recentChosen.selectedID, fresh.id)
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
