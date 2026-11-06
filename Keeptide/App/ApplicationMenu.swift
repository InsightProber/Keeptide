import AppKit

@MainActor
enum ApplicationMenuBuilder {
    static func makeMainMenu(applicationName: String) -> NSMenu {
        let mainMenu = NSMenu()

        let applicationMenu = NSMenu(title: applicationName)
        applicationMenu.addItem(
            item(
                title: "About \(applicationName)",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                target: NSApplication.shared
            )
        )
        applicationMenu.addItem(.separator())
        // No target: the responder chain ends at the application delegate, which opens the window.
        applicationMenu.addItem(
            item(
                title: "Settings…",
                action: #selector(AppDelegate.showSettings(_:)),
                keyEquivalent: ","
            )
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            item(
                title: "Quit \(applicationName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q",
                target: NSApplication.shared
            )
        )
        mainMenu.addItem(menuItem(title: applicationName, submenu: applicationMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item(title: "New Snippet", action: #selector(LibraryWindowController.newDocument(_:)), keyEquivalent: "n"))
        fileMenu.addItem(item(title: "New Collection…", action: #selector(LibraryWindowController.newCollection(_:)), keyEquivalent: "n", modifierMask: [.shift, .command]))
        fileMenu.addItem(item(title: "Save", action: #selector(LibraryWindowController.saveDocument(_:)), keyEquivalent: "s"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(title: "Export Library…", action: #selector(AppDelegate.exportLibrary(_:))))
        fileMenu.addItem(item(title: "Export Selected…", action: #selector(LibraryWindowController.exportSelected(_:))))
        mainMenu.addItem(menuItem(title: "File", submenu: fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(
            item(
                title: "Redo",
                action: Selector(("redo:")),
                keyEquivalent: "z",
                modifierMask: [.command, .shift]
            )
        )
        // Collection and favorite changes are undone here, apart from Undo: ⌘Z belongs to the text being edited.
        editMenu.addItem(item(title: "Undo Collection Change", action: #selector(LibraryWindowController.undoCollectionChange(_:))))
        let undoSave = item(title: "Undo Save as Snippet", action: #selector(LibraryWindowController.undoSaveAsSnippet(_:)))
        undoSave.identifier = NSUserInterfaceItemIdentifier("LibraryUndoNewSave")
        editMenu.addItem(undoSave)
        editMenu.addItem(.separator())
        editMenu.addItem(item(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(item(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(item(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(item(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let find = item(title: "Find in Note…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        editMenu.addItem(find)
        editMenu.addItem(item(title: "Search Library…", action: #selector(LibraryWindowController.searchLibrary(_:)), keyEquivalent: "f", modifierMask: [.command, .shift]))
        editMenu.addItem(item(title: "Copy Entire Item", action: #selector(LibraryWindowController.copyEntireItem(_:)), keyEquivalent: "c", modifierMask: [.command, .shift]))
        mainMenu.addItem(menuItem(title: "Edit", submenu: editMenu))

        // The library's own sidebar and list commands; validation names Show or Hide Sidebar.
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(item(title: "Show Sidebar", action: #selector(LibraryWindowController.toggleLibrarySidebar(_:)), keyEquivalent: "s", modifierMask: [.control, .command]))
        viewMenu.addItem(item(title: "Show Inspector", action: #selector(LibraryWindowController.toggleInspector(_:)), keyEquivalent: "i", modifierMask: [.control, .command]))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item(title: "Previous List", action: #selector(LibraryWindowController.selectPreviousList(_:)), keyEquivalent: "["))
        viewMenu.addItem(item(title: "Next List", action: #selector(LibraryWindowController.selectNextList(_:)), keyEquivalent: "]"))
        viewMenu.addItem(item(title: "Choose List…", action: #selector(LibraryWindowController.chooseList(_:)), keyEquivalent: "l"))
        mainMenu.addItem(menuItem(title: "View", submenu: viewMenu))

        // The selected items' commands; validation names them for the selection.
        let itemMenu = NSMenu(title: "Item")
        itemMenu.addItem(item(title: "Add to Favorites", action: #selector(LibraryWindowController.toggleFavorite(_:)), keyEquivalent: "d"))
        itemMenu.addItem(item(title: "Move to Collection…", action: #selector(LibraryWindowController.moveToCollection(_:)), keyEquivalent: "m", modifierMask: [.shift, .command]))
        let typeMenu = NSMenu(title: "Type")
        for (index, title) in ["Text", "Prompt", "Code", "Markdown"].enumerated() {
            let kind = item(title: title, action: #selector(LibraryWindowController.setSnippetKind(_:)))
            kind.tag = index
            kind.identifier = NSUserInterfaceItemIdentifier("SnippetKind-\(title)")
            typeMenu.addItem(kind)
        }
        itemMenu.addItem(menuItem(title: "Type", submenu: typeMenu))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item(title: "Show Snippet", action: #selector(LibraryWindowController.showLinkedItem(_:))))
        itemMenu.addItem(.separator())
        itemMenu.addItem(item(title: "Move to Recently Deleted", action: #selector(LibraryWindowController.moveToRecentlyDeleted(_:)), keyEquivalent: "\u{8}"))
        // Recently Deleted's own commands, for the deleted facet selected there.
        itemMenu.addItem(item(title: "Recover", action: #selector(LibraryWindowController.recoverDeletedItem(_:))))
        itemMenu.addItem(item(title: "Delete Permanently…", action: #selector(LibraryWindowController.deleteDeletedItemPermanently(_:))))
        mainMenu.addItem(menuItem(title: "Item", submenu: itemMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            item(
                title: "Close",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
        )
        mainMenu.addItem(menuItem(title: "Window", submenu: windowMenu))

        return mainMenu
    }

    private static func menuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }

    private static func item(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifierMask: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.keyEquivalentModifierMask = modifierMask
        menuItem.target = target
        return menuItem
    }
}
