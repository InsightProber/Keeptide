import XCTest
@testable import Keeptide

final class QuickAccessKeyRouterTests: XCTestCase {
    func testKeysFromAnEventThatBeganWithMarkedTextPassThrough() {
        let keys: [QuickAccessKey] = [
            .up, .down, .left, .right, .tab, .backTab, .returnKey, .space, .character, .other,
        ]
        for focus in [QuickAccessFocus.searchField, .filters, .results, .preview] {
            for key in keys {
                for shift in [false, true] {
                    let input = QuickAccessKeyInput(key: key, shift: shift, focus: focus,
                                                    eventBeganWithMarkedText: true)
                    XCTAssertEqual(QuickAccessKeyRouter.command(for: input), .passThrough,
                                   "\(key) shift \(shift) in \(focus)")
                }
            }
        }
    }

    func testArrowsStepTheStripFromAnEmptySearchField() {
        // Right is older, left is newer: the strip puts the newest clip at the left.
        for filtersVisible in [false, true] {
            XCTAssertEqual(command(.right, in: .searchField, filtersVisible: filtersVisible), .move(1))
            XCTAssertEqual(command(.left, in: .searchField, filtersVisible: filtersVisible), .move(-1))
        }
        // An input that says nothing about the query counts as an empty one.
        XCTAssertEqual(QuickAccessKeyRouter.command(for: QuickAccessKeyInput(key: .right, focus: .searchField)),
                       .move(1))
        // From the strip itself the same steps apply, whatever the query holds.
        for queryIsEmpty in [true, false] {
            XCTAssertEqual(command(.right, in: .results, queryIsEmpty: queryIsEmpty), .move(1))
            XCTAssertEqual(command(.left, in: .results, queryIsEmpty: queryIsEmpty), .move(-1))
        }
        // The expanded preview keeps the arrows for its own text.
        for key in [QuickAccessKey.up, .down, .left, .right] {
            XCTAssertEqual(command(key, in: .preview), .passThrough, "\(key) in the preview")
        }
    }

    func testArrowsEditTextWhenTheQueryIsNotEmpty() {
        for filtersVisible in [false, true] {
            XCTAssertEqual(command(.left, in: .searchField, queryIsEmpty: false, filtersVisible: filtersVisible),
                           .passThrough)
            XCTAssertEqual(command(.right, in: .searchField, queryIsEmpty: false, filtersVisible: filtersVisible),
                           .passThrough)
        }
    }

    func testDownGoesToFiltersWhenVisibleElseTheStrip() {
        XCTAssertEqual(command(.down, in: .searchField, filtersVisible: true), .focusFilters)
        XCTAssertEqual(command(.down, in: .searchField, filtersVisible: false), .focusResults)
        // An input that says nothing about the filter row means there is none.
        XCTAssertEqual(QuickAccessKeyRouter.command(for: QuickAccessKeyInput(key: .down, focus: .searchField)),
                       .focusResults)
        // A multi-line query keeps Down for the caret.
        for filtersVisible in [false, true] {
            XCTAssertEqual(command(.down, in: .searchField, isSingleLine: false, filtersVisible: filtersVisible),
                           .passThrough)
        }
        // Nothing lies below the strip.
        XCTAssertEqual(command(.down, in: .results), .passThrough)
        XCTAssertEqual(command(.down, in: .results, filtersVisible: true), .passThrough)
    }

    func testUpFromTheStripReturnsToFiltersOrSearch() {
        for queryIsEmpty in [true, false] {
            XCTAssertEqual(command(.up, in: .results, queryIsEmpty: queryIsEmpty, filtersVisible: true),
                           .focusFilters)
            XCTAssertEqual(command(.up, in: .results, queryIsEmpty: queryIsEmpty, filtersVisible: false),
                           .focusSearchField)
        }
        // Nothing lies above the search field.
        XCTAssertEqual(command(.up, in: .searchField), .passThrough)
        XCTAssertEqual(command(.up, in: .searchField, filtersVisible: true), .passThrough)
    }

    func testFilterRowMovesTogglesAndLeaves() {
        let routes: [(key: QuickAccessKey, expected: QuickAccessCommand)] = [
            (.left, .moveFilter(-1)), (.right, .moveFilter(1)), (.space, .toggleFilter),
            (.up, .focusSearchField), (.down, .focusResults),
        ]
        for queryIsEmpty in [true, false] {
            for route in routes {
                XCTAssertEqual(command(route.key, in: .filters, queryIsEmpty: queryIsEmpty, filtersVisible: true),
                               route.expected, "\(route.key), queryIsEmpty \(queryIsEmpty)")
            }
        }
    }

    func testTabCyclesFocusFromEveryPosition() {
        for focus in [QuickAccessFocus.searchField, .filters, .results, .preview] {
            for filtersVisible in [false, true] {
                XCTAssertEqual(command(.tab, in: focus, filtersVisible: filtersVisible),
                               .cycleFocus(forward: true), "Tab in \(focus), filtersVisible \(filtersVisible)")
                XCTAssertEqual(command(.backTab, in: focus, filtersVisible: filtersVisible),
                               .cycleFocus(forward: false), "Shift-Tab in \(focus), filtersVisible \(filtersVisible)")
            }
        }
    }

    func testTypingInTheStripFiltersOrPreviewReturnsToTheSearchField() {
        // The preview's text cannot be edited, so a key typed there would only beep.
        for focus in [QuickAccessFocus.filters, .results, .preview] {
            for queryIsEmpty in [true, false] {
                for shift in [false, true] {
                    XCTAssertEqual(command(.character, shift: shift, in: focus, queryIsEmpty: queryIsEmpty),
                                   .typeIntoSearch, "\(focus), shift \(shift), queryIsEmpty \(queryIsEmpty)")
                }
                // Keys that type nothing do not move focus.
                XCTAssertEqual(command(.other, in: focus, queryIsEmpty: queryIsEmpty), .passThrough, "\(focus)")
            }
        }
        // The search field is where the text goes already.
        XCTAssertEqual(command(.character, in: .searchField), .passThrough)
        XCTAssertEqual(command(.character, shift: true, in: .searchField, queryIsEmpty: false), .passThrough)
    }

    func testSpacePreviewsOnlyFromTheStripOrAnEmptySearch() {
        for queryIsEmpty in [true, false] {
            XCTAssertEqual(command(.space, in: .results, queryIsEmpty: queryIsEmpty), .togglePreview)
        }
        for filtersVisible in [false, true] {
            XCTAssertEqual(command(.space, in: .searchField, filtersVisible: filtersVisible), .togglePreview)
            XCTAssertEqual(command(.space, in: .searchField, queryIsEmpty: false, filtersVisible: filtersVisible),
                           .passThrough, "Space is text in a query")
        }
        XCTAssertEqual(command(.space, in: .filters), .toggleFilter, "the filter row toggles its filter instead")
        XCTAssertEqual(command(.space, in: .preview), .togglePreview, "Space closes the preview, as Escape does")
    }

    func testReturnCopiesFromEveryPosition() {
        for focus in [QuickAccessFocus.searchField, .filters, .results, .preview] {
            for (queryIsEmpty, filtersVisible) in [(true, false), (false, true)] {
                XCTAssertEqual(command(.returnKey, in: focus, queryIsEmpty: queryIsEmpty,
                                       filtersVisible: filtersVisible), .primary, "Return in \(focus)")
                XCTAssertEqual(command(.returnKey, shift: true, in: focus, queryIsEmpty: queryIsEmpty,
                                       filtersVisible: filtersVisible), .plainText, "Shift-Return in \(focus)")
            }
        }
    }

    func testShiftReturnIsPlainTextCopy() {
        for focus in [QuickAccessFocus.searchField, .results] {
            XCTAssertEqual(command(.returnKey, in: focus), .primary)
            XCTAssertEqual(command(.returnKey, shift: true, in: focus), .plainText)
        }
    }

    func testEscapeIsAlwaysRouted() {
        for focus in [QuickAccessFocus.searchField, .filters, .results, .preview] {
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

    private func command(_ key: QuickAccessKey, shift: Bool = false, in focus: QuickAccessFocus,
                         isSingleLine: Bool = true, queryIsEmpty: Bool = true,
                         filtersVisible: Bool = false) -> QuickAccessCommand {
        QuickAccessKeyRouter.command(for: QuickAccessKeyInput(key: key, shift: shift, focus: focus,
                                                              isSingleLine: isSingleLine, queryIsEmpty: queryIsEmpty,
                                                              filtersVisible: filtersVisible))
    }
}
