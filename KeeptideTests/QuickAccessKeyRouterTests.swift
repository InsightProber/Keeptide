import XCTest
@testable import Keeptide

final class QuickAccessKeyRouterTests: XCTestCase {
    func testKeysFromAnEventThatBeganWithMarkedTextPassThrough() {
        for focus in [QuickAccessFocus.searchField, .results] {
            for (key, shift) in [(QuickAccessKey.returnKey, false), (.returnKey, true), (.space, false), (.down, false)] {
                let input = QuickAccessKeyInput(key: key, shift: shift, focus: focus, eventBeganWithMarkedText: true)
                XCTAssertEqual(QuickAccessKeyRouter.command(for: input), .passThrough, "\(key) in \(focus)")
            }
        }
    }

    func testDownFromSingleLineSearchFieldFocusesResults() {
        XCTAssertEqual(command(.down, in: .searchField), .focusResults)
        XCTAssertEqual(QuickAccessKeyRouter.command(for: QuickAccessKeyInput(key: .down, focus: .searchField,
                                                                             isSingleLine: false)), .passThrough)
        XCTAssertEqual(command(.up, in: .searchField), .passThrough)
    }

    func testArrowsMoveTheSelectionInResults() {
        XCTAssertEqual(command(.up, in: .results), .move(-1))
        XCTAssertEqual(command(.down, in: .results), .move(1))
    }

    func testSpaceIsTextInSearchFieldAndPreviewInResults() {
        XCTAssertEqual(command(.space, in: .searchField), .passThrough)
        XCTAssertEqual(command(.space, in: .results), .togglePreview)
        XCTAssertEqual(command(.space, in: .preview), .passThrough, "Space scrolls the preview text")
    }

    func testShiftReturnIsPlainTextCopy() {
        for focus in [QuickAccessFocus.searchField, .results] {
            XCTAssertEqual(command(.returnKey, in: focus), .primary)
            XCTAssertEqual(command(.returnKey, shift: true, in: focus), .plainText)
        }
    }

    func testEscapeIsAlwaysRouted() {
        for focus in [QuickAccessFocus.searchField, .results, .preview] {
            XCTAssertEqual(command(.escape, in: focus), .escape)
        }
    }

    func testEscapeLayersPreviewBeforeQueryBeforeClose() {
        let cases: [(marked: Bool, preview: Bool, query: Bool, filters: Bool, expected: QuickAccessEscapeAction)] = [
            (true, true, true, true, .cancelComposition),
            (false, true, true, true, .collapsePreview),
            (false, false, true, false, .clearQuery),
            (false, false, false, true, .clearQuery),
            (false, false, false, false, .closePanel),
        ]
        for item in cases {
            XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: item.marked, isPreviewExpanded: item.preview,
                                                          hasQuery: item.query, hasFilters: item.filters),
                           item.expected, "\(item)")
        }
    }

    private func command(_ key: QuickAccessKey, shift: Bool = false, in focus: QuickAccessFocus) -> QuickAccessCommand {
        QuickAccessKeyRouter.command(for: QuickAccessKeyInput(key: key, shift: shift, focus: focus))
    }
}
