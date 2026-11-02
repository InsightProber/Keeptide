import AppKit

enum ActionMenuCommand {
    case primary, plainText, copyOnly, togglePreview, enableDirectPaste
}

/// ⌘K and a right-click: the actions for one clip. First what Return and ⇧Return do, named as the toolbar names them,
/// and the copy that never pastes, where the panel offers them; then the preview; then Enable Direct Paste… when the
/// panel only copies for want of access. Unavailable actions are disabled rather than hidden, so the menu's shape stays
/// predictable: Return's and ⇧Return's are disabled while a command waits on the review card, which alone confirms it.
@MainActor
enum ActionMenu {
    static func make(actions: QuickAccessActions, row: QuickAccessRow?, canAct: Bool, isReviewing: Bool = false,
                     isPreviewExpanded: Bool, perform: @escaping (ActionMenuCommand) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Actions")
        menu.autoenablesItems = false
        let primary = ActionMenuItem(actions.primaryTitle, key: "\r", modifiers: []) { perform(.primary) }
        primary.isEnabled = canAct && !isReviewing
        menu.addItem(primary)
        if let title = actions.plainTextTitle {
            let plainText = ActionMenuItem(title, key: "\r", modifiers: .shift) { perform(.plainText) }
            plainText.isEnabled = canAct && !isReviewing && row.map { $0.kind != .image && $0.kind != .file } == true
            menu.addItem(plainText)
        }
        if let title = actions.copyOnlyTitle {
            let copyOnly = ActionMenuItem(title, key: "", modifiers: []) { perform(.copyOnly) }
            copyOnly.isEnabled = canAct
            menu.addItem(copyOnly)
        }
        menu.addItem(.separator())
        let preview = ActionMenuItem(isPreviewExpanded ? "Hide Preview" : "Show Preview", key: " ", modifiers: []) {
            perform(.togglePreview)
        }
        preview.isEnabled = row != nil
        menu.addItem(preview)
        if actions.offersEnableDirectPaste {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Enable Direct Paste…", key: "", modifiers: []) { perform(.enableDirectPaste) })
        }
        return menu
    }

    /// Where the menu opens: beside the selected clip, level with its top edge, so that it covers neither the
    /// clip nor the search field. `frame` is the clip's frame in `view`.
    static func anchor(beside frame: NSRect, in view: NSView) -> NSPoint {
        NSPoint(x: frame.maxX + 8, y: view.isFlipped ? frame.minY : frame.maxY)
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}
