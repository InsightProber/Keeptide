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
