import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class QuickAccessResultsTableTests: XCTestCase {
    func testLoadingMoreRowsDoesNotScrollBackToTheSelection() {
        let (table, scroll) = makeTable()
        let rows = makeRows(100)
        table.show(rows, selection: rows[0].ref)
        table.scrollRowToVisible(99)
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolled, 0)

        table.show(rows + makeRows(20), selection: rows[0].ref)

        XCTAssertEqual(scroll.contentView.bounds.origin.y, scrolled, accuracy: 1)
    }

    func testANewSelectionIsScrolledIntoView() {
        let (table, scroll) = makeTable()
        let rows = makeRows(100)
        table.show(rows, selection: rows[0].ref)

        table.show(rows, selection: rows[80].ref)

        XCTAssertTrue(scroll.contentView.bounds.intersects(table.rect(ofRow: 80)))
    }

    func testRejectedClickOrDeselectionShowsTheStateSelectionAgain() {
        let (table, _) = makeTable()
        let rows = makeRows(3)
        table.selectionProvider = { rows[0].ref }
        table.onSelect = { _ in }
        table.show(rows, selection: rows[0].ref)

        table.selectRowIndexes([1], byExtendingSelection: false)
        XCTAssertEqual(table.selectedRow, 0)
        table.deselectAll(nil)
        XCTAssertEqual(table.selectedRow, 0)
    }

    func testRejectedClickShowsNoRowWhenTheStateHoldsNone() {
        let (table, _) = makeTable()
        let rows = makeRows(3)
        table.show(rows, selection: rows[0].ref)
        // The state has dropped its selection before the view caught up.
        table.selectionProvider = { nil }
        table.onSelect = { _ in }

        table.selectRowIndexes([1], byExtendingSelection: false)

        XCTAssertEqual(table.selectedRow, -1)
    }

    func testAcceptedClickKeepsTheClickedRow() {
        let (table, _) = makeTable()
        let rows = makeRows(3)
        let chosen = Chosen(rows[0].ref)
        table.selectionProvider = { chosen.ref }
        table.onSelect = { chosen.ref = $0 }
        table.show(rows, selection: rows[0].ref)

        table.selectRowIndexes([2], byExtendingSelection: false)

        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertEqual(chosen.ref, rows[2].ref)
    }

    func testAcceptedClickMovesFocusToTheResults() {
        let (table, _) = makeTable()
        let rows = makeRows(3)
        let chosen = Chosen(rows[0].ref)
        table.selectionProvider = { chosen.ref }
        table.onSelect = { chosen.ref = $0 }
        table.show(rows, selection: rows[0].ref)

        table.selectRowIndexes([2], byExtendingSelection: false)

        // Space and Return after a click act on the results, not the search field.
        XCTAssertTrue(table.window?.firstResponder === table)
    }

    private func makeTable() -> (QuickAccessResultsTableView, NSScrollView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let table = QuickAccessResultsTableView()
        scroll.documentView = table
        window.contentView = scroll
        addTeardownBlock { window.close() }
        return (table, scroll)
    }

    private func makeRows(_ count: Int) -> [QuickAccessRow] {
        (0..<count).map { index in
            QuickAccessRow(
                ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                                digest: Data(repeating: 9, count: 32)),
                title: "Row \(index)", snippet: nil, kind: .text, sourceApp: nil,
                date: Date(timeIntervalSince1970: 1_000), savedAsMemo: false, isPartiallyIndexed: false,
                isTextUnavailable: false
            )
        }
    }
}

@MainActor
private final class Chosen {
    var ref: ContentRef
    init(_ ref: ContentRef) { self.ref = ref }
}
