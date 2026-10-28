import Foundation

enum QuickAccessFocus: Equatable {
    case searchField, results, preview
}

enum QuickAccessKey: Equatable {
    case up, down, returnKey, space, escape, other
}

struct QuickAccessKeyInput: Equatable {
    var key: QuickAccessKey
    var shift = false
    var focus: QuickAccessFocus
    /// The key event began while an input method had marked text, so it belongs to the composition.
    var eventBeganWithMarkedText = false
    var isSingleLine = true
}

enum QuickAccessCommand: Equatable {
    case passThrough, focusResults, move(Int), primary, plainText, togglePreview, escape
}

/// Translates panel keys into commands. Keys with native meaning where focus is, and
/// keys an input method composition owns, pass through untouched.
enum QuickAccessKeyRouter {
    static func command(for input: QuickAccessKeyInput) -> QuickAccessCommand {
        // Escape peels layers itself, starting with any composition.
        if input.key == .escape { return .escape }
        guard !input.eventBeganWithMarkedText else { return .passThrough }
        switch (input.key, input.focus) {
        case (.returnKey, .searchField), (.returnKey, .results):
            return input.shift ? .plainText : .primary
        case (.down, .searchField):
            return input.isSingleLine ? .focusResults : .passThrough
        case (.up, .results):
            return .move(-1)
        case (.down, .results):
            return .move(1)
        case (.space, .results):
            return .togglePreview
        default:
            return .passThrough
        }
    }
}
