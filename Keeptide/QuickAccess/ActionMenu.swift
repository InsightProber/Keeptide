import AppKit

enum ActionMenuCommand {
    case copy, copyPlainText, togglePreview
}

/// Cmd-K: the actions for the current selection only. Unavailable actions are
/// disabled rather than hidden, so the menu's shape stays predictable.
@MainActor
enum ActionMenu {
    static func make(row: QuickAccessRow?, canAct: Bool, isPreviewExpanded: Bool,
                     perform: @escaping (ActionMenuCommand) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Actions")
        menu.autoenablesItems = false
        let copy = ActionMenuItem("Copy", key: "\r", modifiers: []) { perform(.copy) }
        copy.isEnabled = canAct
        let plainText = ActionMenuItem("Copy as Plain Text", key: "\r", modifiers: .shift) { perform(.copyPlainText) }
        plainText.isEnabled = canAct && row.map { $0.kind != .image && $0.kind != .file } == true
        let preview = ActionMenuItem(isPreviewExpanded ? "Hide Preview" : "Show Preview", key: " ", modifiers: []) {
            perform(.togglePreview)
        }
        preview.isEnabled = row != nil
        menu.addItem(copy)
        menu.addItem(plainText)
        menu.addItem(.separator())
        menu.addItem(preview)
        return menu
    }

    /// Where the menu opens: beside the centred clip, level with its top edge, so that it covers neither the
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
