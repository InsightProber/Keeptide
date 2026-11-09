import AppKit

enum ActionMenuCommand: Equatable {
    case primary, plainText, copyOnly, togglePreview
    case saveSnippet, undoSave, toggleFavorite, showInLibrary, newSnippet, enableDirectPaste
    /// Save to Collection or Add to Collection: the collection chosen. On a snippet's card, choosing one it is in takes
    /// it out.
    case saveToCollection(CollectionID)
    case undoMoveToRecentlyDeleted, moveToRecentlyDeleted
    /// Remove from “Prompts”: out of the collection the list shows.
    case removeFromCollection(CollectionID)
}

/// ⌘K and a right-click: the actions for one clip. First what Return and ⇧Return do, named as the toolbar names them,
/// and the copy that never pastes, where the panel offers them; then the preview; then what keeps the clip: Save as
/// Snippet, Save to Collection (Add to Collection on a snippet), Undo Save as Snippet while the save can still be
/// undone, and the favorite mark; then the library's actions; then Enable Direct Paste… when the panel only copies for
/// want of access; last what takes the clip away: Undo Move to Recently Deleted right after a move, Remove from the
/// collection a collection's list shows, and Move to Recently Deleted, named as the library names them. Other
/// unavailable actions are disabled rather than hidden, so the menu's shape stays predictable: Return's and ⇧Return's
/// are disabled while a command waits on the review card, which alone confirms it, the collections without any to
/// choose, and Move to Recently Deleted without a library to move it in.
///
/// Undo Save as Snippet has no key of its own: ⌘Z belongs to the search field's text while it has the keys. The menu is
/// how both the keyboard, with ⌘K, and the pointer reach it. A move to Recently Deleted joins the panel's undo, the
/// field's typing included, so ⌘Z undoes the last of either, and the menu offers it while it is the last.
@MainActor
enum ActionMenu {
    static let noCollectionsHelp = "Create a collection first."
    /// The undo's action name, which Undo Move to Recently Deleted names.
    static let moveToRecentlyDeletedName = "Move to Recently Deleted"

    static func make(actions: QuickAccessActions, row: QuickAccessRow?, canAct: Bool, isReviewing: Bool = false,
                     isPreviewExpanded: Bool, canUndoSave: Bool = false, collections: [CollectionSummary] = [],
                     canMoveToRecentlyDeleted: Bool = false, listedCollection: CollectionSummary? = nil,
                     canUndoMoveToRecentlyDeleted: Bool = false,
                     perform: @escaping (ActionMenuCommand) -> Void) -> NSMenu {
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
        menu.addItem(.separator())
        let save = ActionMenuItem("Save as Snippet", key: "s", modifiers: .command) {
            perform(.saveSnippet)
        }
        let isSnippet = row?.facet == .memo
        // A snippet is in Snippets already: the item stays, disabled.
        save.isEnabled = canAct && !isSnippet
        menu.addItem(save)
        let place = NSMenuItem(title: isSnippet ? "Add to Collection" : "Save to Collection", action: nil,
                               keyEquivalent: "")
        let choices = NSMenu(title: place.title)
        choices.autoenablesItems = false
        for item in collectionItems(collections: collections, row: row, perform: { perform(.saveToCollection($0)) }) {
            choices.addItem(item)
        }
        // AppKit shows no key on an item with a submenu, and keeps none; the panel handles ⇧⌘M itself.
        place.submenu = choices
        place.isEnabled = canAct && !collections.isEmpty
        if collections.isEmpty { place.toolTip = noCollectionsHelp }
        menu.addItem(place)
        if canUndoSave {
            menu.addItem(ActionMenuItem("Undo Save as Snippet", key: "", modifiers: []) { perform(.undoSave) })
        }
        // A snippet's card knows its mark; a clip's card adds it to the snippet it is or becomes.
        let removes = isSnippet && row?.isFavorite == true
        let favorite = ActionMenuItem(removes ? "Remove from Favorites" : "Add to Favorites", key: "d",
                                      modifiers: .command) { perform(.toggleFavorite) }
        favorite.isEnabled = canAct
        menu.addItem(favorite)
        menu.addItem(.separator())
        let show = ActionMenuItem("Show in Library", key: "e", modifiers: .command) {
            perform(.showInLibrary)
        }
        show.isEnabled = canAct
        menu.addItem(show)
        menu.addItem(ActionMenuItem("New Snippet", key: "n", modifiers: .command) {
            perform(.newSnippet)
        })
        if actions.offersEnableDirectPaste {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Enable Direct Paste…", key: "", modifiers: []) { perform(.enableDirectPaste) })
        }
        menu.addItem(.separator())
        // Each has an identifier of its own: the menu bar's Item menu has a Move to Recently Deleted too.
        if canUndoMoveToRecentlyDeleted {
            let undo = ActionMenuItem("Undo \(moveToRecentlyDeletedName)", key: "z", modifiers: .command) {
                perform(.undoMoveToRecentlyDeleted)
            }
            undo.identifier = NSUserInterfaceItemIdentifier("QuickAccessUndoMoveToRecentlyDeleted")
            menu.addItem(undo)
        }
        if let listedCollection {
            let remove = ActionMenuItem("Remove from “\(listedCollection.name)”", key: "", modifiers: []) {
                perform(.removeFromCollection(listedCollection.id))
            }
            remove.identifier = NSUserInterfaceItemIdentifier("QuickAccessRemoveFromCollection")
            remove.isEnabled = canAct
            menu.addItem(remove)
        }
        let delete = ActionMenuItem(moveToRecentlyDeletedName, key: "\u{8}", modifiers: .command) {
            perform(.moveToRecentlyDeleted)
        }
        delete.identifier = NSUserInterfaceItemIdentifier("QuickAccessMoveToRecentlyDeleted")
        delete.isEnabled = canMoveToRecentlyDeleted && row != nil
        menu.addItem(delete)
        return menu
    }

    /// The collections a clip or snippet can go in, in the sidebar's order, each with a dot in its colour. A
    /// snippet's own collections are checked, and choosing one takes it out; a clip's card does not know its
    /// snippet's, so nothing is checked there.
    static func collectionItems(collections: [CollectionSummary], row: QuickAccessRow?,
                                perform: @escaping (CollectionID) -> Void) -> [NSMenuItem] {
        let values = collections.map {
            CollectionValue(id: $0.id, name: $0.name, color: $0.color, sortOrder: $0.sortOrder)
        }
        let memberships: [Set<CollectionID>] = row.map { [$0.facet == .memo ? Set($0.collectionIDs) : []] } ?? []
        return CollectionMenu.make(collections: values, memberships: memberships, includesNewCollection: false)
            .compactMap { entry in
                guard let id = entry.collectionID else { return nil }
                let item = ActionMenuItem(entry.title, key: "", modifiers: []) { perform(id) }
                item.state = entry.isChecked ? .on : .off
                if let color = entry.color { item.image = dot(color) }
                return item
            }
    }

    /// A collection's dot, for a menu item.
    static func dot(_ color: String) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.collection(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
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
