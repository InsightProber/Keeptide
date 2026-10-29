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
        editMenu.addItem(.separator())
        editMenu.addItem(item(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(item(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(item(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(item(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        mainMenu.addItem(menuItem(title: "Edit", submenu: editMenu))

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
