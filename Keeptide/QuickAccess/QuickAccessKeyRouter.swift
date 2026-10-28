import Foundation

/// Where keys are aimed. Top to bottom the panel holds the search field, the filter row and the
/// strip of clips (`results`); `preview` is the expanded preview.
enum QuickAccessFocus: Equatable {
    case searchField, filters, results, preview
}

enum QuickAccessKey: Equatable {
    case up, down, left, right, tab, backTab, returnKey, space, escape, other
    /// A key that types text, with neither ⌘ nor ⌃ held.
    case character
}

struct QuickAccessKeyInput: Equatable {
    var key: QuickAccessKey
    var shift = false
    var focus: QuickAccessFocus
    /// The key event began while an input method had marked text, so it belongs to the composition.
    var eventBeganWithMarkedText = false
    var isSingleLine = true
    /// An empty search field has no caret to move, so ← and → are free to step the strip.
    var queryIsEmpty = true
    /// The filter row is shown between the search field and the strip.
    var filtersVisible = false
}

enum QuickAccessCommand: Equatable {
    case passThrough, focusResults, move(Int), primary, plainText, togglePreview, escape
    case focusFilters, focusSearchField, cycleFocus(forward: Bool)
    case moveFilter(Int), toggleFilter, typeIntoSearch
}

/// Translates panel keys into commands. Keys with native meaning where focus is, and
/// keys an input method composition owns, pass through untouched.
enum QuickAccessKeyRouter {
    static func command(for input: QuickAccessKeyInput) -> QuickAccessCommand {
        // Escape peels layers itself, starting with any composition.
        if input.key == .escape { return .escape }
        guard !input.eventBeganWithMarkedText else { return .passThrough }
        switch (input.key, input.focus) {
        // Search field. An empty one has no caret to move, so ← and → step the strip; with text they edit it.
        case (.left, .searchField):
            return input.queryIsEmpty ? .move(1) : .passThrough
        case (.right, .searchField):
            return input.queryIsEmpty ? .move(-1) : .passThrough
        case (.down, .searchField):
            guard input.isSingleLine else { return .passThrough }
            return input.filtersVisible ? .focusFilters : .focusResults
        case (.space, .searchField):
            return input.queryIsEmpty ? .togglePreview : .passThrough
        // Filter row.
        case (.left, .filters):
            return .moveFilter(-1)
        case (.right, .filters):
            return .moveFilter(1)
        case (.space, .filters):
            return .toggleFilter
        case (.up, .filters):
            return .focusSearchField
        case (.down, .filters):
            return .focusResults
        // Strip: newest at the right, so ← is one clip older.
        case (.left, .results):
            return .move(1)
        case (.right, .results):
            return .move(-1)
        case (.up, .results):
            return input.filtersVisible ? .focusFilters : .focusSearchField
        case (.space, .results):
            return .togglePreview
        // Typing below the search field belongs in the search field.
        case (.character, .filters), (.character, .results):
            return .typeIntoSearch
        // Return and Tab work from all three positions; the preview keeps its own keys.
        case (.returnKey, .searchField), (.returnKey, .filters), (.returnKey, .results):
            return input.shift ? .plainText : .primary
        case (.tab, .searchField), (.tab, .filters), (.tab, .results):
            return .cycleFocus(forward: true)
        case (.backTab, .searchField), (.backTab, .filters), (.backTab, .results):
            return .cycleFocus(forward: false)
        default:
            return .passThrough
        }
    }
}
