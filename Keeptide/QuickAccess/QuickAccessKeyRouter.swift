import Foundation

/// Where keys are aimed. Along the band's toolbar the panel holds the lists (the All | Snippets switch and the
/// collection chips), the filter button and the search field, and below them the strip of clips (`results`);
/// `preview` is the expanded preview.
enum QuickAccessFocus: Equatable {
    case searchField, lists, filterButton, results, preview
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
    case moveListCursor(Int), chooseListAtCursor, openFilterMenu, typeIntoSearch
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
        // The lists: ← and → move the cursor along the segments and the chips, and Space chooses the one under it.
        case (.left, .lists):
            return .moveListCursor(-1)
        case (.right, .lists):
            return .moveListCursor(1)
        case (.space, .lists):
            return .chooseListAtCursor
        // The filter button: Space opens its menu.
        case (.space, .filterButton):
            return .openFilterMenu
        // The lists and the filter button share the toolbar's row with the search: Up goes to the search field, and
        // Down to the strip below.
        case (.up, .lists), (.up, .filterButton):
            return .focusSearchField
        case (.down, .lists), (.down, .filterButton):
            return .focusResults
        // Strip: the rows run left to right, the frequent clips from the least used to the most used, then the newest
        // clip and older ones, so → is the next row: a clip used more often, the newest after the most used, or one
        // older.
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
        case (.character, .lists), (.character, .filterButton), (.character, .results), (.character, .preview):
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

    /// Whether ⌘⌫ moves the selected clip to Recently Deleted from where the keys are. A search field with text keeps
    /// it for that text, deleting to the start of the line, as a composition keeps every key; an empty one has nothing
    /// to delete, as it has no caret for ← and → to move, so there ⌘⌫ takes the selection as it does from the strip,
    /// the lists, the filter button and the preview. Keys passing between views leave none holding them, and the
    /// selection is still there.
    static func commandDeleteTakesSelection(focus: QuickAccessFocus?, queryIsEmpty: Bool, hasMarkedText: Bool) -> Bool {
        guard !hasMarkedText else { return false }
        return focus != .searchField || queryIsEmpty
    }

    /// Where Tab (`forward`) or ⇧Tab takes the keys from `current`: round the search field, the strip, the lists and
    /// the filter button, in that order. The strip is left out while it has no clips. From the preview's text, or from
    /// nowhere in the panel, Tab starts at the search field and ⇧Tab at the end of the round.
    static func focus(after current: QuickAccessFocus?, forward: Bool, hasClips: Bool) -> QuickAccessFocus {
        var order: [QuickAccessFocus] = [.searchField]
        if hasClips { order.append(.results) }
        order += [.lists, .filterButton]
        guard let index = current.flatMap(order.firstIndex(of:)) else {
            return forward ? order[0] : order[order.count - 1]
        }
        return order[(index + (forward ? 1 : order.count - 1)) % order.count]
    }
}
