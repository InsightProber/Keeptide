import XCTest
@testable import Keeptide

final class QuickAccessKeyRouterTests: XCTestCase {
    func testKeysFromAnEventThatBeganWithMarkedTextPassThrough() {
        let keys: [QuickAccessKey] = [
            .up, .down, .left, .right, .tab, .backTab, .returnKey, .space, .character, .other,
        ]
        for focus in QuickAccessFocus.all {
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
        // Right is the next card and left the one before it: older clips stand right of the newest, and the frequent
        // clips left of it.
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
        // The lists, the filter button and the search share the toolbar's row, so Down from any of them goes to the strip
        // below.
        XCTAssertEqual(command(.down, in: .searchField), .focusResults)
        XCTAssertEqual(command(.down, in: .searchField, queryIsEmpty: false), .focusResults)
        XCTAssertEqual(command(.down, in: .lists), .focusResults)
        XCTAssertEqual(command(.down, in: .filterButton), .focusResults)
        // A multi-line query keeps Down for the caret.
        XCTAssertEqual(command(.down, in: .searchField, isSingleLine: false), .passThrough)
        // Nothing lies below the strip.
        XCTAssertEqual(command(.down, in: .results), .passThrough)
    }

    func testUpGoesFromTheStripTheListsOrTheFilterButtonToTheSearchField() {
        for queryIsEmpty in [true, false] {
            for focus in [QuickAccessFocus.results, .lists, .filterButton] {
                XCTAssertEqual(command(.up, in: focus, queryIsEmpty: queryIsEmpty), .focusSearchField, "\(focus)")
            }
        }
        // Nothing lies above the search field.
        XCTAssertEqual(command(.up, in: .searchField), .passThrough)
    }

    func testTheListsMoveTheirCursorAndChoose() {
        let routes: [(key: QuickAccessKey, expected: QuickAccessCommand)] = [
            (.left, .moveListCursor(-1)), (.right, .moveListCursor(1)), (.space, .chooseListAtCursor),
        ]
        for queryIsEmpty in [true, false] {
            for route in routes {
                XCTAssertEqual(command(route.key, in: .lists, queryIsEmpty: queryIsEmpty), route.expected,
                               "\(route.key), queryIsEmpty \(queryIsEmpty)")
            }
        }
    }

    func testSpaceOpensTheFilterMenuAndTheSideArrowsDoNothingThere() {
        for queryIsEmpty in [true, false] {
            XCTAssertEqual(command(.space, in: .filterButton, queryIsEmpty: queryIsEmpty), .openFilterMenu)
            XCTAssertEqual(command(.left, in: .filterButton, queryIsEmpty: queryIsEmpty), .passThrough)
            XCTAssertEqual(command(.right, in: .filterButton, queryIsEmpty: queryIsEmpty), .passThrough)
        }
    }

    func testTabCyclesFocusFromEveryPosition() {
        for focus in QuickAccessFocus.all {
            XCTAssertEqual(command(.tab, in: focus), .cycleFocus(forward: true), "Tab in \(focus)")
            XCTAssertEqual(command(.backTab, in: focus), .cycleFocus(forward: false), "Shift-Tab in \(focus)")
        }
    }

    func testTabGoesRoundTheSearchTheStripTheListsAndTheFilterButton() {
        // Forward from the search: the clips, the lists, the filter button, and round again.
        XCTAssertEqual(next(after: .searchField), .results)
        XCTAssertEqual(next(after: .results), .lists)
        XCTAssertEqual(next(after: .lists), .filterButton)
        XCTAssertEqual(next(after: .filterButton), .searchField)
        // Backward the other way round: Shift-Tab from the search goes to the filter button.
        XCTAssertEqual(next(after: .searchField, forward: false), .filterButton)
        XCTAssertEqual(next(after: .filterButton, forward: false), .lists)
        XCTAssertEqual(next(after: .lists, forward: false), .results)
        XCTAssertEqual(next(after: .results, forward: false), .searchField)
        // Without clips the strip is left out.
        XCTAssertEqual(next(after: .searchField, hasClips: false), .lists)
        XCTAssertEqual(next(after: .lists, forward: false, hasClips: false), .searchField)
        // From the preview's text, or with nothing focused, Tab starts at the search field and Shift-Tab at the end.
        XCTAssertEqual(next(after: .preview), .searchField)
        XCTAssertEqual(next(after: .preview, forward: false), .filterButton)
        XCTAssertEqual(next(after: nil), .searchField)
        XCTAssertEqual(next(after: nil, forward: false, hasClips: false), .filterButton)
    }

    func testTypingAnywhereButTheSearchReturnsToTheSearchField() {
        // The preview's text cannot be edited, so a key typed there would only beep.
        for focus in [QuickAccessFocus.lists, .filterButton, .results, .preview] {
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
        XCTAssertEqual(command(.space, in: .lists), .chooseListAtCursor, "the lists choose the one under the cursor")
        XCTAssertEqual(command(.space, in: .filterButton), .openFilterMenu, "the filter button opens its menu")
        XCTAssertEqual(command(.space, in: .preview), .togglePreview, "Space closes the preview, as Escape does")
    }

    func testReturnCopiesFromEveryPosition() {
        for focus in QuickAccessFocus.all {
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

    func testCommandDeleteTakesTheSelectionExceptFromTextInTheSearchField() {
        // Away from the search field ⌘⌫ has no text to delete, whatever the query holds.
        for focus in [QuickAccessFocus.lists, .filterButton, .results, .preview] {
            for queryIsEmpty in [true, false] {
                XCTAssertTrue(deletes(from: focus, queryIsEmpty: queryIsEmpty), "\(focus), empty query \(queryIsEmpty)")
            }
        }
        // An empty search field has nothing to delete either, as with ← and →; one with text keeps ⌘⌫ for it, deleting
        // to the start of the line.
        XCTAssertTrue(deletes(from: .searchField, queryIsEmpty: true))
        XCTAssertFalse(deletes(from: .searchField, queryIsEmpty: false))
        // Keys passing from one view to another leave none holding them: the strip's selection is still there.
        XCTAssertTrue(deletes(from: nil, queryIsEmpty: false))
        // A composition owns its keys wherever it is.
        for focus in QuickAccessFocus.all.map(Optional.some) + [nil] {
            XCTAssertFalse(QuickAccessKeyRouter.commandDeleteTakesSelection(focus: focus, queryIsEmpty: true,
                                                                            hasMarkedText: true),
                           String(describing: focus))
        }
    }

    func testEscapeIsAlwaysRouted() {
        for focus in QuickAccessFocus.all {
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

    private func deletes(from focus: QuickAccessFocus?, queryIsEmpty: Bool) -> Bool {
        QuickAccessKeyRouter.commandDeleteTakesSelection(focus: focus, queryIsEmpty: queryIsEmpty, hasMarkedText: false)
    }

    private func next(after focus: QuickAccessFocus?, forward: Bool = true, hasClips: Bool = true) -> QuickAccessFocus {
        QuickAccessKeyRouter.focus(after: focus, forward: forward, hasClips: hasClips)
    }
}

private extension QuickAccessFocus {
    static let all: [QuickAccessFocus] = [.searchField, .lists, .filterButton, .results, .preview]
}
