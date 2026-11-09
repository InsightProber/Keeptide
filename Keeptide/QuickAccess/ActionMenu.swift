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
    /// The text in an image: shown beside it, made again, copied, kept as a snippet, laid out, or stopped.
    case showTextInImage, extractText, copyText, saveTextAsSnippet, toggleKeepLineBreaks, stopTextRecognition
}

/// ⌘K and a right-click: the actions for one clip. First what Return and ⇧Return do, named as the toolbar names them,
/// and the copy that never pastes, where the panel offers them, or while the preview shows the text beside an image,
/// what can be done with that text; then the preview, and Extract Text; then what keeps the clip: Save as
/// Snippet, Save to Collection (Add to Collection on a snippet), Undo Save as Snippet while the save can still be
/// undone, and the favorite mark; then the library's actions; then Enable Direct Paste… when the panel only copies for
/// want of access; last what takes the clip away: Undo Move to Recently Deleted right after a move, Remove from the
/// collection a collection's list shows, and Move to Recently Deleted, named as the library names them. Other
/// unavailable actions are disabled rather than hidden, so the menu's shape stays predictable: Return's and ⇧Return's
/// are disabled while a command waits on the review card, which alone confirms it, the collections without any to
/// choose, and Move to Recently Deleted without a library to move it in.
///
/// Undo Save as Snippet has no key of its own: ⌘Z belongs to the search field's text while it has the keys. The menu is
/// how both the keyboard, with ⌘K, and the pointer reach it. Moves to Recently Deleted are on the panel's undo stack:
/// ⌘Z undoes the last one unless something was typed in the search field since, and the menu offers it while it is the
/// panel's last undoable change.
@MainActor
enum ActionMenu {
    /// What the menu offers for the text in an image. Every card has Extract Text, which only an image's makes use
    /// of. While the preview shows the text beside an image, the menu starts with what can be done with that text, in
    /// place of what Return and ⇧Return do with the clip: one item for each of the column's controls.
    struct TextInImage: Equatable {
        /// Whether the clip is an image whose text can be shown.
        var isOffered = false
        /// The column of text, while the preview shows it beside the clip.
        var column: Column?

        struct Column: Equatable {
            /// Return can take the text: it is whole and kept.
            var canTake = false
            /// There is text to copy and to keep as a snippet.
            var hasText = false
            var keepsLineBreaks = true
            var canStop = false
            /// No text was made yet, or making it failed: Extract Text, or Try Again, makes it.
            var canExtract = false
            var failed = false
        }
    }

    static let noCollectionsHelp = "Create a collection first."
    static let noTextToExtractHelp = "Only images have text to extract."
    /// The undo's action name, which Undo Move to Recently Deleted names.
    static let moveToRecentlyDeletedName = "Move to Recently Deleted"

    static func make(actions: QuickAccessActions, row: QuickAccessRow?, canAct: Bool, isReviewing: Bool = false,
                     isPreviewExpanded: Bool, canUndoSave: Bool = false, collections: [CollectionSummary] = [],
                     canMoveToRecentlyDeleted: Bool = false, listedCollection: CollectionSummary? = nil,
                     canUndoMoveToRecentlyDeleted: Bool = false, textInImage: TextInImage = TextInImage(),
                     perform: @escaping (ActionMenuCommand) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Actions")
        menu.autoenablesItems = false
        if let column = textInImage.column {
            addTextItems(column, actions: actions, isReviewing: isReviewing, to: menu, perform: perform)
        } else {
            let primary = ActionMenuItem(actions.primaryTitle, key: "\r", modifiers: []) { perform(.primary) }
            primary.isEnabled = canAct && !isReviewing
            menu.addItem(primary)
            if let title = actions.plainTextTitle {
                let plainText = ActionMenuItem(title, key: "\r", modifiers: .shift) { perform(.plainText) }
                plainText.isEnabled = canAct && !isReviewing
                    && row.map { $0.kind != .image && $0.kind != .file } == true
                menu.addItem(plainText)
            }
            if let title = actions.copyOnlyTitle {
                let copyOnly = ActionMenuItem(title, key: "", modifiers: []) { perform(.copyOnly) }
                copyOnly.isEnabled = canAct
                menu.addItem(copyOnly)
            }
        }
        menu.addItem(.separator())
        let preview = ActionMenuItem(isPreviewExpanded ? "Hide Preview" : "Show Preview", key: " ", modifiers: []) {
            perform(.togglePreview)
        }
        preview.isEnabled = row != nil
        menu.addItem(preview)
        if textInImage.column == nil {
            let extract = ActionMenuItem("Extract Text", key: "t", modifiers: [.command, .shift]) {
                perform(.showTextInImage)
            }
            extract.isEnabled = textInImage.isOffered && row != nil
            if let row, row.kind != .image { extract.toolTip = noTextToExtractHelp }
            menu.addItem(extract)
        }
        menu.addItem(.separator())
        // While the text shows, ⌘S keeps the text; this item still keeps the clip.
        let save = ActionMenuItem("Save as Snippet", key: textInImage.column == nil ? "s" : "", modifiers: .command) {
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

    /// What can be done with the text beside an image: take it as Return does, copy it beside a paste, keep it as a
    /// snippet, lay it out, stop making it, and make it, or make it again after a failure.
    private static func addTextItems(_ column: TextInImage.Column, actions: QuickAccessActions, isReviewing: Bool,
                                     to menu: NSMenu, perform: @escaping (ActionMenuCommand) -> Void) {
        let take = ActionMenuItem(actions.primaryTitle, key: "\r", modifiers: []) { perform(.primary) }
        take.isEnabled = column.canTake && !isReviewing
        menu.addItem(take)
        if let title = actions.copyOnlyTitle {
            let copy = ActionMenuItem(title, key: "c", modifiers: .command) { perform(.copyText) }
            copy.isEnabled = column.hasText
            menu.addItem(copy)
        }
        let save = ActionMenuItem("Save Text as Snippet", key: "s", modifiers: .command) {
            perform(.saveTextAsSnippet)
        }
        save.isEnabled = column.hasText
        menu.addItem(save)
        let lineBreaks = ActionMenuItem("Keep Line Breaks", key: "", modifiers: []) { perform(.toggleKeepLineBreaks) }
        lineBreaks.state = column.keepsLineBreaks ? .on : .off
        menu.addItem(lineBreaks)
        let stop = ActionMenuItem("Stop", key: ".", modifiers: .command) { perform(.stopTextRecognition) }
        stop.isEnabled = column.canStop
        menu.addItem(stop)
        let extract = ActionMenuItem(column.failed ? "Try Again" : "Extract Text", key: "t",
                                     modifiers: [.command, .shift]) { perform(.extractText) }
        extract.isEnabled = column.canExtract
        menu.addItem(extract)
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
