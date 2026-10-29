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
        XCTAssertEqual(command(.right, in: .searchField), .move(1))
        XCTAssertEqual(command(.left, in: .searchField), .move(-1))
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
        XCTAssertEqual(command(.left, in: .searchField, queryIsEmpty: false), .passThrough)
        XCTAssertEqual(command(.right, in: .searchField, queryIsEmpty: false), .passThrough)
    }

    func testDownGoesFromTheToolbarToTheStrip() {
        // The filters sit beside the search field in the toolbar, so Down from either goes to the strip below.
        XCTAssertEqual(command(.down, in: .searchField), .focusResults)
        XCTAssertEqual(command(.down, in: .searchField, queryIsEmpty: false), .focusResults)
        XCTAssertEqual(command(.down, in: .filters), .focusResults)
        // A multi-line query keeps Down for the caret.
        XCTAssertEqual(command(.down, in: .searchField, isSingleLine: false), .passThrough)
        // Nothing lies below the strip.
        XCTAssertEqual(command(.down, in: .results), .passThrough)
    }

    func testUpGoesFromTheStripOrTheFiltersToTheSearchField() {
        for queryIsEmpty in [true, false] {
            XCTAssertEqual(command(.up, in: .results, queryIsEmpty: queryIsEmpty), .focusSearchField)
            XCTAssertEqual(command(.up, in: .filters, queryIsEmpty: queryIsEmpty), .focusSearchField)
        }
        // Nothing lies above the search field.
        XCTAssertEqual(command(.up, in: .searchField), .passThrough)
    }

    func testTheFiltersMoveAndToggle() {
        let routes: [(key: QuickAccessKey, expected: QuickAccessCommand)] = [
            (.left, .moveFilter(-1)), (.right, .moveFilter(1)), (.space, .toggleFilter),
        ]
        for queryIsEmpty in [true, false] {
            for route in routes {
                XCTAssertEqual(command(route.key, in: .filters, queryIsEmpty: queryIsEmpty), route.expected,
                               "\(route.key), queryIsEmpty \(queryIsEmpty)")
            }
        }
    }

    func testTabCyclesFocusFromEveryPosition() {
        for focus in [QuickAccessFocus.searchField, .filters, .results, .preview] {
            XCTAssertEqual(command(.tab, in: focus), .cycleFocus(forward: true), "Tab in \(focus)")
            XCTAssertEqual(command(.backTab, in: focus), .cycleFocus(forward: false), "Shift-Tab in \(focus)")
        }
    }

    func testTabGoesRoundTheSearchTheFiltersAndTheStrip() {
        // Forward: search field, filters, strip, and round again.
        XCTAssertEqual(next(after: .searchField), .filters)
        XCTAssertEqual(next(after: .filters), .results)
        XCTAssertEqual(next(after: .results), .searchField)
        // Backward the other way round.
        XCTAssertEqual(next(after: .searchField, forward: false), .results)
        XCTAssertEqual(next(after: .results, forward: false), .filters)
        XCTAssertEqual(next(after: .filters, forward: false), .searchField)
        // Without clips the strip is left out.
        XCTAssertEqual(next(after: .filters, hasClips: false), .searchField)
        XCTAssertEqual(next(after: .searchField, forward: false, hasClips: false), .filters)
        // From the preview's text, or with nothing focused, Tab starts at the search field and Shift-Tab at the end.
        XCTAssertEqual(next(after: .preview), .searchField)
        XCTAssertEqual(next(after: .preview, forward: false), .results)
        XCTAssertEqual(next(after: nil), .searchField)
        XCTAssertEqual(next(after: nil, forward: false, hasClips: false), .filters)
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
        XCTAssertEqual(command(.space, in: .searchField), .togglePreview)
        XCTAssertEqual(command(.space, in: .searchField, queryIsEmpty: false), .passThrough, "Space is text in a query")
        XCTAssertEqual(command(.space, in: .filters), .toggleFilter, "the filters toggle the one under the cursor")
        XCTAssertEqual(command(.space, in: .preview), .togglePreview, "Space closes the preview, as Escape does")
    }

    func testReturnCopiesFromEveryPosition() {
        for focus in [QuickAccessFocus.searchField, .filters, .results, .preview] {
            for queryIsEmpty in [true, false] {
                XCTAssertEqual(command(.returnKey, in: focus, queryIsEmpty: queryIsEmpty), .primary,
                               "Return in \(focus)")
                XCTAssertEqual(command(.returnKey, shift: true, in: focus, queryIsEmpty: queryIsEmpty), .plainText,
                               "Shift-Return in \(focus)")
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

    func testEscapeLayersPreviewBeforeQueryBeforeFoldBeforeClose() {
        let cases: [(marked: Bool, preview: Bool, query: Bool, filters: Bool, expanded: Bool,
                     expected: QuickAccessEscapeAction)] = [
            (true, true, true, true, true, .cancelComposition),
            (false, true, true, true, true, .collapsePreview),
            // A query or a filter is cleared, and the search folds with it, in one press.
            (false, false, true, false, true, .clearQuery),
            (false, false, false, true, true, .clearQuery),
            (false, false, false, true, false, .clearQuery),
            // An open search with nothing in it folds before the panel closes.
            (false, false, false, false, true, .foldSearch),
            (false, false, false, false, false, .closePanel),
        ]
        for item in cases {
            XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: item.marked, isPreviewExpanded: item.preview,
                                                          hasQuery: item.query, hasFilters: item.filters,
                                                          isSearchExpanded: item.expanded),
                           item.expected, "\(item)")
        }
    }

    private func command(_ key: QuickAccessKey, shift: Bool = false, in focus: QuickAccessFocus,
                         isSingleLine: Bool = true, queryIsEmpty: Bool = true) -> QuickAccessCommand {
        QuickAccessKeyRouter.command(for: QuickAccessKeyInput(key: key, shift: shift, focus: focus,
                                                              isSingleLine: isSingleLine, queryIsEmpty: queryIsEmpty))
    }

    private func next(after focus: QuickAccessFocus?, forward: Bool = true, hasClips: Bool = true) -> QuickAccessFocus {
        QuickAccessKeyRouter.focus(after: focus, forward: forward, hasClips: hasClips)
    }
}
