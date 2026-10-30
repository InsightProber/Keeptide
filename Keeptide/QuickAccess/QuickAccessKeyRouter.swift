import Foundation

/// Where keys are aimed. Along the band's toolbar the panel holds the search field and the filters, and below
/// them the strip of clips (`results`); `preview` is the expanded preview.
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
/// held; `queryIsEmpty` is always passed, never left to its default; a repeat of a key that acts once
/// when held is dropped where it would act, and never typed in its place; and a key routed to
/// `passThrough` that the view has no native use for is dropped without an alert sound.
struct QuickAccessKeyInput: Equatable {
    var key: QuickAccessKey
    var shift = false
    var focus: QuickAccessFocus
    /// The key event began while an input method had marked text, so it belongs to the composition.
    var eventBeganWithMarkedText = false
    var isSingleLine = true
    /// An empty search field has no caret to move, so ← and → are free to step the strip.
    var queryIsEmpty = true
}

enum QuickAccessCommand: Equatable {
    case passThrough, focusResults, move(Int), primary, plainText, togglePreview, escape
    case focusSearchField, cycleFocus(forward: Bool)
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
        // The filters sit beside it in the toolbar, so Down goes to the strip below.
        case (.left, .searchField):
            return input.queryIsEmpty ? .move(-1) : .passThrough
        case (.right, .searchField):
            return input.queryIsEmpty ? .move(1) : .passThrough
        case (.down, .searchField):
            return input.isSingleLine ? .focusResults : .passThrough
        case (.space, .searchField):
            return input.queryIsEmpty ? .togglePreview : .passThrough
        // Filters.
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
        // Strip: the rows run left to right, the most used frequent clip first and then the newest clip, so → is the
        // next row: a clip used less often, or one older.
        case (.left, .results):
            return .move(-1)
        case (.right, .results):
            return .move(1)
        case (.up, .results):
            return .focusSearchField
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

    /// Where Tab (`forward`) or ⇧Tab takes the keys from `current`: round the search field, the filters and the
    /// strip, in that order. The strip is left out while it has no clips. From the preview's text, or from nowhere
    /// in the panel, Tab starts at the search field and ⇧Tab at the end of the round.
    static func focus(after current: QuickAccessFocus?, forward: Bool, hasClips: Bool) -> QuickAccessFocus {
        var order: [QuickAccessFocus] = [.searchField, .filters]
        if hasClips { order.append(.results) }
        guard let index = current.flatMap(order.firstIndex(of:)) else {
            return forward ? order[0] : order[order.count - 1]
        }
        return order[(index + (forward ? 1 : order.count - 1)) % order.count]
    }
}
