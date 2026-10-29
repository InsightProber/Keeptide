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

    /// Space, Return and Escape act once however long they are held: repeating, they would toggle the preview
    /// at the key repeat rate, copy again, or peel the panel's layers one after another. The arrows repeat.
    var actsOnceWhenHeld: Bool { self == .space || self == .returnKey || self == .escape }
}

/// A view that builds this from a key event follows these rules: Tab and ⇧Tab are `tab` and `backTab`;
/// Space, Return and Tab are never `character`, which is a key that types text with neither ⌘ nor ⌃
/// held; `queryIsEmpty` and `filtersVisible` are always passed, never left to their defaults; a repeat
/// of a key that acts once when held is dropped where it would act, and never typed in its place; and a
/// key routed to `passThrough` that the view has no native use for is dropped without an alert sound.
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
            return input.queryIsEmpty ? .move(-1) : .passThrough
        case (.right, .searchField):
            return input.queryIsEmpty ? .move(1) : .passThrough
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
        // Strip: newest at the left, so → is one clip older.
        case (.left, .results):
            return .move(-1)
        case (.right, .results):
            return .move(1)
        case (.up, .results):
            return input.filtersVisible ? .focusFilters : .focusSearchField
        case (.space, .results):
            return .togglePreview
        // The expanded preview closes on Space, as on Escape; it keeps the arrows for its own text.
        case (.space, .preview):
            return .togglePreview
        // Typing below the search field belongs in the search field, and so does typing in the preview's text,
        // which cannot be edited.
        case (.character, .filters), (.character, .results), (.character, .preview):
            return .typeIntoSearch
        // Return copies and Tab cycles from any focus, the expanded preview included.
        case (.returnKey, _):
            return input.shift ? .plainText : .primary
        case (.tab, _):
            return .cycleFocus(forward: true)
        case (.backTab, _):
            return .cycleFocus(forward: false)
        default:
            return .passThrough
        }
    }
}
