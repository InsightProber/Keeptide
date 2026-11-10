import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class LibraryCommandsTests: XCTestCase {
    func testFileMenuExposesNewAndSaveWithoutReplacingNativeEditCommands() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let create = try XCTUnwrap(file.items.first { $0.action == #selector(LibraryWindowController.newDocument(_:)) })
        XCTAssertEqual(create.keyEquivalent, "n")
        XCTAssertEqual(create.keyEquivalentModifierMask, .command)
        let save = try XCTUnwrap(file.items.first { $0.action == #selector(LibraryWindowController.saveDocument(_:)) })
        XCTAssertEqual(save.keyEquivalent, "s")
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu)
        XCTAssertEqual(edit.items.first { $0.action == #selector(NSText.copy(_:)) }?.keyEquivalent, "c")
        XCTAssertEqual(edit.items.first { $0.action == Selector(("undo:")) }?.keyEquivalent, "z")
    }

    func testDocumentFindAndLibrarySearchHaveDistinctNativeCommands() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu)
        let find = try XCTUnwrap(edit.items.first { $0.action == #selector(NSTextView.performFindPanelAction(_:)) })
        XCTAssertEqual(find.keyEquivalent, "f")
        XCTAssertEqual(find.keyEquivalentModifierMask, .command)
        XCTAssertEqual(find.tag, Int(NSFindPanelAction.showFindPanel.rawValue))
        let search = try XCTUnwrap(edit.items.first { $0.action == #selector(LibraryWindowController.searchLibrary(_:)) })
        XCTAssertEqual(search.keyEquivalent, "f")
        XCTAssertEqual(search.keyEquivalentModifierMask, [.command, .shift])
        let copy = try XCTUnwrap(edit.items.first { $0.action == #selector(LibraryWindowController.copyEntireItem(_:)) })
        XCTAssertEqual(copy.keyEquivalent, "c")
        XCTAssertEqual(copy.keyEquivalentModifierMask, [.command, .shift])
    }

    func testEditMenuUndoesACollectionChangeWithoutTakingCommandZ() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu)
        let undo = try XCTUnwrap(edit.items.first {
            $0.action == #selector(LibraryWindowController.undoCollectionChange(_:))
        })
        XCTAssertEqual(undo.title, "Undo Collection Change")
        XCTAssertEqual(undo.keyEquivalent, "")

        // Nothing to undo yet.
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        XCTAssertFalse(controller.validateMenuItem(undo))
    }

    func testCommandFOutsideTheEditorSearchesTheLibrary() {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let find = NSMenuItem(title: "Find in Note…", action: #selector(NSTextView.performFindPanelAction(_:)),
                              keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)

        // The editor answers ⌘F itself; with the list or the sidebar in front, the window controller does.
        controller.performFindPanelAction(find)

        XCTAssertEqual(controller.commands.searchRequest, 1)
    }

    func testLibrarySearchWaitsWhileAFieldIsComposing() throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { window.close() }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        try XCTUnwrap(window.contentView).addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        fieldEditor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        // ⇧⌘F would commit the composition and move the keyboard away; it waits instead.
        controller.searchLibrary(nil)
        XCTAssertEqual(controller.commands.searchRequest, 0)
        XCTAssertTrue(fieldEditor.hasMarkedText())

        fieldEditor.unmarkText()
        controller.searchLibrary(nil)
        XCTAssertEqual(controller.commands.searchRequest, 1)
    }

    func testViewMenuShowsTheSidebarAndMovesBetweenLists() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let view = try XCTUnwrap(menu.items.first { $0.title == "View" }?.submenu)
        func item(_ action: Selector) throws -> NSMenuItem { try XCTUnwrap(view.items.first { $0.action == action }) }

        let sidebar = try item(#selector(LibraryWindowController.toggleLibrarySidebar(_:)))
        XCTAssertEqual(sidebar.keyEquivalent, "s")
        XCTAssertEqual(sidebar.keyEquivalentModifierMask, [.control, .command])
        let previous = try item(#selector(LibraryWindowController.selectPreviousList(_:)))
        XCTAssertEqual(previous.keyEquivalent, "[")
        XCTAssertEqual(previous.keyEquivalentModifierMask, .command)
        let next = try item(#selector(LibraryWindowController.selectNextList(_:)))
        XCTAssertEqual(next.keyEquivalent, "]")
        XCTAssertEqual(next.keyEquivalentModifierMask, .command)
        let choose = try item(#selector(LibraryWindowController.chooseList(_:)))
        XCTAssertEqual(choose.keyEquivalent, "l")
        XCTAssertEqual(choose.keyEquivalentModifierMask, .command)

        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let newCollection = try XCTUnwrap(file.items.first {
            $0.action == #selector(LibraryWindowController.newCollection(_:))
        })
        XCTAssertEqual(newCollection.title, "New Collection…")
        XCTAssertEqual(newCollection.keyEquivalent, "n")
        XCTAssertEqual(newCollection.keyEquivalentModifierMask, [.shift, .command])
    }

    func testToggleSidebarFlipsTheExplicitPreference() {
        XCTAssertEqual(LibraryLayoutPolicy.preference(toggling: .visible), .hidden)
        XCTAssertEqual(LibraryLayoutPolicy.preference(toggling: .hidden), .shown)

        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        controller.toggleLibrarySidebar(nil)
        controller.toggleLibrarySidebar(nil)

        XCTAssertEqual(controller.commands.sidebarToggleRequest, 2)
    }

    func testListCommandsWaitWhileTheEditorOrACompositionHasTheKeyboard() throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let next = NSMenuItem(
            title: "Next List", action: #selector(LibraryWindowController.selectNextList(_:)), keyEquivalent: "]"
        )
        let previous = NSMenuItem(
            title: "Previous List", action: #selector(LibraryWindowController.selectPreviousList(_:)), keyEquivalent: "["
        )

        // Nothing has the keyboard: the lists move, though not before the first one.
        XCTAssertTrue(controller.validateMenuItem(next))
        XCTAssertFalse(controller.validateMenuItem(previous), "Recent Clips is the first list")

        // The body editor indents with ⌘[ and ⌘], so the lists stay.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        content.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(controller.validateMenuItem(next))

        // A one-line field, like the search field, does not indent: the lists move.
        let field = NSTextField(frame: NSRect(x: 0, y: 50, width: 200, height: 22))
        content.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        XCTAssertTrue(controller.validateMenuItem(next))

        // Unless it is composing: the input method keeps the keys.
        fieldEditor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fieldEditor.hasMarkedText())
        XCTAssertFalse(controller.validateMenuItem(next))
    }

    func testItemMenuNamesTheCommandsForTheSelection() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let item = try XCTUnwrap(menu.items.first { $0.title == "Item" }?.submenu)
        func command(_ action: Selector) throws -> NSMenuItem { try XCTUnwrap(item.items.first { $0.action == action }) }

        let favorite = try command(#selector(LibraryWindowController.toggleFavorite(_:)))
        XCTAssertEqual(favorite.keyEquivalent, "d")
        XCTAssertEqual(favorite.keyEquivalentModifierMask, .command)
        // ⇧⌘M, not ⇧⌘S, which a Mac reserves for Save As or Duplicate.
        let collection = try command(#selector(LibraryWindowController.chooseCollection(_:)))
        XCTAssertEqual(collection.keyEquivalent, "m")
        XCTAssertEqual(collection.keyEquivalentModifierMask, [.shift, .command])
        let removeFromCollection = try command(#selector(LibraryWindowController.removeFromCollection(_:)))
        XCTAssertEqual(removeFromCollection.identifier?.rawValue, "ItemMenu-RemoveFromCollection")
        let types = try XCTUnwrap(item.items.first { $0.title == "Type" }?.submenu)
        XCTAssertEqual(types.items.map(\.title), ["Text", "Prompt", "Code", "Markdown"])
        XCTAssertEqual(types.items.map(\.tag), [0, 1, 2, 3])
        XCTAssertEqual(Set(types.items.compactMap(\.identifier)).count, 4)
        XCTAssertEqual(LibraryWindowController.snippetKinds, [.plainText, .prompt, .code, .markdown])
        _ = try command(#selector(LibraryWindowController.showLinkedItem(_:)))
        let delete = try command(#selector(LibraryWindowController.moveToRecentlyDeleted(_:)))
        XCTAssertEqual(delete.keyEquivalent, "\u{8}")
        XCTAssertEqual(delete.keyEquivalentModifierMask, .command)
        let recover = try command(#selector(LibraryWindowController.recoverDeletedItem(_:)))
        XCTAssertEqual(recover.title, "Recover")
        let deletePermanently = try command(#selector(LibraryWindowController.deleteDeletedItemPermanently(_:)))
        XCTAssertEqual(deletePermanently.title, "Delete Permanently…")
        // A row's context menu repeats these titles; the Item menu's own identifiers tell them apart.
        XCTAssertEqual([favorite, collection, delete, recover, deletePermanently].compactMap(\.identifier?.rawValue),
                       ["ItemMenu-Favorite", "ItemMenu-Collection", "ItemMenu-MoveToRecentlyDeleted",
                        "ItemMenu-Recover", "ItemMenu-DeletePermanently"])

        let view = try XCTUnwrap(menu.items.first { $0.title == "View" }?.submenu)
        let inspector = try XCTUnwrap(view.items.first {
            $0.action == #selector(LibraryWindowController.toggleInspector(_:))
        })
        XCTAssertEqual(inspector.keyEquivalent, "i")
        XCTAssertEqual(inspector.keyEquivalentModifierMask, [.control, .command])

        // A new save is undone from the Edit menu, apart from ⌘Z.
        let edit = try XCTUnwrap(menu.items.first { $0.title == "Edit" }?.submenu)
        let undoSave = try XCTUnwrap(edit.items.first {
            $0.action == #selector(LibraryWindowController.undoSaveAsSnippet(_:))
        })
        XCTAssertEqual(undoSave.title, "Undo Save as Snippet")
        XCTAssertEqual(undoSave.identifier?.rawValue, "LibraryUndoNewSave")
        XCTAssertEqual(undoSave.keyEquivalent, "")
        XCTAssertFalse(LibraryWindowController(session: CaptureSession(), autosaveName: nil).validateMenuItem(undoSave))
    }

    func testItemCommandsFollowTheSelection() {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = tag
            return item
        }
        let favorite = item(#selector(LibraryWindowController.toggleFavorite(_:)))
        let collection = item(#selector(LibraryWindowController.chooseCollection(_:)))
        let removeFromCollection = item(#selector(LibraryWindowController.removeFromCollection(_:)))
        let markdown = item(#selector(LibraryWindowController.setSnippetKind(_:)), tag: 3)
        let code = item(#selector(LibraryWindowController.setSnippetKind(_:)), tag: 2)
        let linked = item(#selector(LibraryWindowController.showLinkedItem(_:)))
        let inspector = item(#selector(LibraryWindowController.toggleInspector(_:)))

        // Nothing selected: nothing to act on.
        XCTAssertFalse(controller.validateMenuItem(favorite))
        XCTAssertFalse(controller.validateMenuItem(collection))
        XCTAssertFalse(controller.validateMenuItem(removeFromCollection))
        XCTAssertTrue(removeFromCollection.isHidden)
        XCTAssertFalse(controller.validateMenuItem(markdown))
        XCTAssertFalse(controller.validateMenuItem(linked))
        XCTAssertTrue(controller.validateMenuItem(inspector))
        XCTAssertEqual(inspector.title, "Show Inspector")

        // A favorite Markdown snippet, open, saved from a clip still in Recent Clips.
        let snippet = Self.entry(.memo, isFavorite: true)
        let clip = ContentRef(itemID: snippet.id, facet: .history, version: ContentVersion(),
                              digest: Data(repeating: 2, count: 32))
        var details = LibraryItemDetails(createdAt: Date(), lastCopiedAt: Date(), copyCount: 1)
        details.isFavorite = true
        details.originalClip = .available(clip)
        let open = LibrarySelectionState.OpenItem(ref: snippet.ref, details: details, kind: .markdown, isReadOnly: false)
        controller.commands.updateItemContext(LibraryItemContext(
            selection: .make(entries: [snippet], open: open, hasCollections: true, canDelete: true),
            inspectorIsPresented: true
        ))

        XCTAssertTrue(controller.validateMenuItem(favorite))
        XCTAssertEqual(favorite.title, "Remove from Favorites")
        XCTAssertTrue(controller.validateMenuItem(collection))
        XCTAssertEqual(collection.title, "Add to Collection…")
        // Outside a collection there is no collection to remove it from.
        XCTAssertFalse(controller.validateMenuItem(removeFromCollection))
        XCTAssertTrue(removeFromCollection.isHidden)
        XCTAssertTrue(controller.validateMenuItem(markdown))
        XCTAssertEqual(markdown.state, .on)
        XCTAssertTrue(controller.validateMenuItem(code))
        XCTAssertEqual(code.state, .off)
        XCTAssertTrue(controller.validateMenuItem(linked))
        XCTAssertEqual(linked.title, "Show in Recent Clips")
        XCTAssertTrue(controller.validateMenuItem(inspector))
        XCTAssertEqual(inspector.title, "Hide Inspector")

        // In a collection the snippet is in, the Item menu can take it out.
        let prompts = CollectionValue(name: "Prompts", color: "blue")
        controller.commands.updateItemContext(LibraryItemContext(
            selection: .make(entries: [snippet], open: open, hasCollections: true, canDelete: true),
            removableCollection: prompts
        ))
        XCTAssertTrue(controller.validateMenuItem(removeFromCollection))
        XCTAssertFalse(removeFromCollection.isHidden)
        XCTAssertEqual(removeFromCollection.title, "Remove from “Prompts”")
        controller.removeFromCollection(removeFromCollection)
        XCTAssertEqual(controller.commands.removeFromCollectionRequest, 1)
    }

    func testRecentlyDeletedCommandsActOnTheSelectedFacet() {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let recover = NSMenuItem(title: "Recover", action: #selector(LibraryWindowController.recoverDeletedItem(_:)),
                                 keyEquivalent: "")
        let delete = NSMenuItem(title: "Delete Permanently…",
                                action: #selector(LibraryWindowController.deleteDeletedItemPermanently(_:)),
                                keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(recover))
        XCTAssertFalse(controller.validateMenuItem(delete))

        // A snippet past its recovery window can only be deleted for good.
        let expired = TrashFacetSnapshot(identity: .memo(itemID: ItemID(), memoID: UUID()), title: "Synthetic",
                                         deletedAt: Date(), purgeAfter: Date(), canRestore: false)
        controller.commands.updateItemContext(LibraryItemContext(isRecentlyDeleted: true, deleted: expired))
        XCTAssertFalse(controller.validateMenuItem(recover))
        XCTAssertTrue(controller.validateMenuItem(delete))

        controller.recoverDeletedItem(recover)
        controller.deleteDeletedItemPermanently(delete)
        XCTAssertEqual(controller.commands.recoverRequest, 1)
        XCTAssertEqual(controller.commands.permanentDeleteRequest, 1)
    }

    func testCommandDeleteMovesItemsOnlyFromAList() throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let delete = NSMenuItem(title: "Move to Recently Deleted",
                                action: #selector(LibraryWindowController.moveToRecentlyDeleted(_:)),
                                keyEquivalent: "\u{8}")
        // The window's own view reports its selection as it lays out, so the test's goes in just before each check.
        let context = LibraryItemContext(
            selection: .make(entries: [Self.entry(.memo)], open: nil, hasCollections: false, canDelete: true)
        )

        // In the editor ⌘⌫ deletes to the start of the line.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        content.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        controller.commands.updateItemContext(context)
        XCTAssertFalse(controller.validateMenuItem(delete))

        // From the list it moves the selection to Recently Deleted.
        let list = KeyboardTable(frame: NSRect(x: 0, y: 50, width: 200, height: 100))
        content.addSubview(list)
        XCTAssertTrue(window.makeFirstResponder(list))
        XCTAssertTrue(window.firstResponder === list)
        controller.commands.updateItemContext(context)
        XCTAssertTrue(controller.validateMenuItem(delete))
        controller.moveToRecentlyDeleted(delete)
        XCTAssertEqual(controller.commands.deleteRequest, 1)
    }

    func testTheLibrarysCommandsStayOffWhileQuickAccessHasTheKeys() async throws {
        // A library over a session of its own, so that it can save and export too. The menu bar's library commands go
        // to its window controller while the window is open, and to the app, which opens it, while it is closed.
        let session = try await makeSession()
        let library = LibraryWindowController(session: session, autosaveName: nil, setActivationPolicy: { _ in })
        let window = try XCTUnwrap(library.window)
        addTeardownBlock { @MainActor in window.close() }
        let list = KeyboardTable(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        try XCTUnwrap(window.contentView).addSubview(list)
        let app = AppDelegate()
        app.environment = AppEnvironment(captureSession: session)
        let items = menuItems(in: ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide"))
        // A favorite snippet saved from a clip is selected and open, in the collection the library shows, and a list
        // has the keys.
        let snippet = Self.entry(.memo, isFavorite: true)
        var details = LibraryItemDetails(createdAt: Date(), lastCopiedAt: Date(), copyCount: 1)
        details.isFavorite = true
        details.originalClip = .available(Self.ref(.history, of: snippet.id))
        let open = LibrarySelectionState.OpenItem(ref: snippet.ref, details: details, kind: .markdown,
                                                  isReadOnly: false)
        let context = LibraryItemContext(
            selection: .make(entries: [snippet], open: open, hasCollections: true, canDelete: true),
            removableCollection: CollectionValue(name: "Prompts", color: "blue")
        )
        // The window's own view reports the library's state as it lays out, so the test's goes in before each check.
        func enabled() -> [String] {
            XCTAssertTrue(window.makeFirstResponder(list))
            library.commands.updateItemContext(context)
            library.commands.updateExportContext(refs: [snippet.ref], isRecentlyDeleted: false)
            return enabledCommands(in: items, library: library, app: app)
        }

        // Nothing in quick access has the keys: the commands follow the library.
        XCTAssertNotEqual(NSApp.keyWindow?.isQuickAccess, true, "Quick access is open from another test")
        let on = enabled()
        XCTAssertTrue(Set(on).isSuperset(of: [
            "newDocument:", "newCollection:", "saveDocument:", "exportLibrary:", "exportSelected:", "searchLibrary:",
            "copyEntireItem:", "toggleLibrarySidebar:", "chooseList:", "toggleFavorite:", "moveToRecentlyDeleted:",
            "App showSettings:", "App newDocument:", "App exportLibrary:", "App searchLibrary:",
        ]), "\(on)")

        // Quick access has the keys: none of them is on, wherever it would go. Settings… is the app's, which the
        // panel's own menu opens too. The items' titles still follow the library.
        let panel = PanelController()
        panel.show()
        addTeardownBlock { @MainActor in panel.close() }
        try await SearchTestSupport.waitUntil { NSApp.keyWindow?.isQuickAccess == true }
        let favorite = try XCTUnwrap(items.first { $0.action == #selector(LibraryWindowController.toggleFavorite(_:)) })
        favorite.title = "Add to Favorites"
        XCTAssertEqual(enabled(), ["App showSettings:"])
        XCTAssertEqual(favorite.title, "Remove from Favorites")

        // Closed, it leaves them as they were.
        panel.close()
        try await SearchTestSupport.waitUntil { NSApp.keyWindow?.isQuickAccess != true }
        XCTAssertEqual(enabled(), on)
    }

    func testTheLibrarysCommandsStayOffWhileASheetOverQuickAccessHasTheKeys() async throws {
        let library = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let libraryWindow = try XCTUnwrap(library.window)
        addTeardownBlock { @MainActor in libraryWindow.close() }
        let app = AppDelegate()
        let items = menuItems(in: ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide"))
        XCTAssertNotEqual(NSApp.keyWindow?.isQuickAccess, true, "Quick access is open from another test")
        let on = enabledCommands(in: items, library: library, app: app)
        XCTAssertTrue(Set(on).isSuperset(of: [
            "newDocument:", "searchLibrary:", "toggleLibrarySidebar:", "App newDocument:", "App searchLibrary:",
        ]), "\(on)")

        // A sheet over the panel takes the keys from it, as the file-access sheet does: the commands stay off.
        let panel = PanelController()
        let window = try XCTUnwrap(panel.window)
        panel.show()
        addTeardownBlock { @MainActor in panel.close() }
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120), styleMask: [.titled],
                            backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: { _ in })
        addTeardownBlock { @MainActor in
            if window.attachedSheet === sheet { window.endSheet(sheet) }
            sheet.orderOut(nil)
        }
        try await SearchTestSupport.waitUntil { NSApp.keyWindow === sheet }
        XCTAssertTrue(sheet.isQuickAccess)
        XCTAssertEqual(enabledCommands(in: items, library: library, app: app), ["App showSettings:"])

        // Gone, the sheet is no part of quick access, and the library's window never is. Closed, quick access leaves
        // the commands as they were.
        window.endSheet(sheet)
        try await SearchTestSupport.waitUntil { window.attachedSheet == nil }
        XCTAssertFalse(sheet.isQuickAccess)
        XCTAssertFalse(libraryWindow.isQuickAccess)
        panel.close()
        try await SearchTestSupport.waitUntil { NSApp.keyWindow?.isQuickAccess != true }
        XCTAssertEqual(enabledCommands(in: items, library: library, app: app), on)
    }

    func testItemCommandsAreForwardedAsRequests() throws {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let prompts = CollectionID()
        let shell = CollectionID()
        controller.commands.updateItemContext(LibraryItemContext(collectionEntries: [
            CollectionMenuEntry(id: "s", role: .collection(shell), title: "Shell", color: "green", isChecked: false),
            CollectionMenuEntry(id: "p", role: .collection(prompts), title: "Prompts", color: "blue", isChecked: true),
            CollectionMenuEntry(id: "new", role: .newCollection, title: "New Collection…", color: nil, isChecked: false),
        ]))

        controller.toggleFavorite(nil)
        controller.toggleInspector(nil)
        controller.showLinkedItem(nil)
        let code = NSMenuItem(title: "Code", action: #selector(LibraryWindowController.setSnippetKind(_:)),
                              keyEquivalent: "")
        code.tag = 2
        controller.setSnippetKind(code)
        XCTAssertEqual(controller.commands.favoriteRequest, 1)
        XCTAssertEqual(controller.commands.inspectorToggleRequest, 1)
        XCTAssertEqual(controller.commands.showLinkedRequest, 1)
        XCTAssertEqual(controller.commands.kindRequest?.kind, .code)

        // ⇧⌘M's menu lists the same collections as the toolbar's, those the selection is in checked; choosing one
        // adds the selection to it, or takes it out of a checked one.
        let menu = controller.makeCollectionMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Shell", "Prompts", "New Collection…"])
        XCTAssertEqual(menu.items.map(\.state), [.off, .on, .off])
        XCTAssertEqual(Set(menu.items.compactMap(\.identifier)).count, 3)
        menu.performActionForItem(at: 1)
        XCTAssertEqual(controller.commands.collectionRequest?.collectionID, prompts)
        XCTAssertEqual(controller.commands.collectionRequest?.createsCollection, false)
        menu.performActionForItem(at: 2)
        XCTAssertEqual(controller.commands.collectionRequest?.createsCollection, true)
        XCTAssertEqual(controller.commands.collectionRequest?.generation, 2)
    }

    func testTheSelectionDecidesWhatItsActionsDo() {
        let clip = Self.entry(.history)
        var details = LibraryItemDetails(createdAt: Date(), lastCopiedAt: Date(), copyCount: 1)
        details.formatCount = 2
        func open(_ details: LibraryItemDetails) -> LibrarySelectionState.OpenItem {
            .init(ref: clip.ref, details: details, kind: .plainText, isReadOnly: true)
        }

        // A clip not saved yet: copied, saved, starred or filed, each saving it first.
        var state = LibrarySelectionState.make(entries: [clip], open: open(details), hasCollections: true,
                                               canDelete: true)
        XCTAssertTrue(state.canCopy)
        XCTAssertTrue(state.canSave)
        XCTAssertEqual(state.favoriteTitle, "Add to Favorites")
        XCTAssertEqual(state.collectionTitle, "Save to Collection")
        XCTAssertEqual(state.memberships, [[]])
        XCTAssertTrue(state.canFile)
        XCTAssertNil(state.linked)
        XCTAssertNil(state.kind)

        // Saved already: its snippet's star and collection, and the way to it.
        let prompts = CollectionID()
        let snippet = Self.ref(.memo)
        details.savedSnippet = .init(ref: snippet, collectionIDs: [prompts], isFavorite: true)
        state = .make(entries: [clip], open: open(details), hasCollections: true, canDelete: true)
        XCTAssertFalse(state.canSave)
        XCTAssertEqual(state.saveHelp, "Already in Snippets")
        XCTAssertEqual(state.favoriteTitle, "Remove from Favorites")
        XCTAssertEqual(state.collectionTitle, "Add to Collection")
        XCTAssertEqual(state.memberships, [[prompts]])
        XCTAssertEqual(state.linked, snippet)
        XCTAssertEqual(state.linkedTitle, "Show Snippet")

        // Its formats cannot all be read: nothing that would use them.
        details = LibraryItemDetails(createdAt: Date(), lastCopiedAt: Date(), copyCount: 1)
        details.integrity = .requiresRelocation
        state = .make(entries: [clip], open: open(details), hasCollections: true, canDelete: true)
        XCTAssertFalse(state.canCopy)
        XCTAssertEqual(state.copyHelp, "This clip can't be copied until its content is available.")
        XCTAssertFalse(state.canSave)
        XCTAssertFalse(state.canFavorite)
        XCTAssertFalse(state.canFile)
        XCTAssertTrue(state.canDelete)

        // Several clips: one copy at a time, but saved together.
        let other = Self.entry(.history, isMemo: true)
        state = .make(entries: [clip, other], open: open(details), hasCollections: false, canDelete: true)
        XCTAssertFalse(state.canCopy)
        XCTAssertEqual(state.copyHelp, "Select one item to copy.")
        XCTAssertTrue(state.canSave)
        XCTAssertTrue(state.savesIntoCollection)
        // Without a collection the toolbar has none to offer.
        XCTAssertFalse(state.canFile)

        // Nothing selected: nothing to act on.
        state = .make(entries: [], open: open(details), hasCollections: true, canDelete: true)
        XCTAssertFalse(state.canCopy || state.canSave || state.canFavorite || state.canFile || state.canDelete)
    }

    /// A capture session over a temporary library of its own, shut down and removed as the test ends.
    private func makeSession() async throws -> CaptureSession {
        let configuration = CaptureTestConfiguration(id: UUID())
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)
        addTeardownBlock { @MainActor in
            await session.shutdown()
            try? FileManager.default.removeItem(at: configuration.directory)
            UserDefaults(suiteName: configuration.preferencesSuite)?
                .removePersistentDomain(forName: configuration.preferencesSuite)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }
        XCTAssertTrue(session.isReady)
        return session
    }

    /// The items in `menu` and its submenus that have an action, in the menu's order.
    private func menuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            (item.action == nil ? [] : [item]) + (item.submenu.map { menuItems(in: $0) } ?? [])
        }
    }

    /// The actions of `items` that `library` and `app` each turn on now, in the menu's order, the app's marked "App".
    /// Items with no target of their own go to the library window's controller while the window is open, and to the
    /// app while it is closed.
    private func enabledCommands(in items: [NSMenuItem], library: LibraryWindowController,
                                 app: AppDelegate) -> [String] {
        let commands = items.filter { $0.target == nil }
        let libraryOn = commands.filter { $0.action.map(library.responds(to:)) == true && library.validateMenuItem($0) }
        let appOn = commands.filter { $0.action.map(app.responds(to:)) == true && app.validateMenuItem($0) }
        return libraryOn.compactMap(\.action).map(NSStringFromSelector)
            + appOn.compactMap(\.action).map { "App " + NSStringFromSelector($0) }
    }

    private static func ref(_ facet: ContentFacet, of itemID: ItemID = ItemID()) -> ContentRef {
        ContentRef(itemID: itemID, facet: facet, version: ContentVersion(), digest: Data(repeating: 1, count: 32))
    }

    /// A row as the library lists it: a clip, or a snippet, of its own item.
    private static func entry(_ facet: ContentFacet, isMemo: Bool? = nil, isFavorite: Bool = false) -> LibraryEntry {
        let itemID = ItemID()
        return LibraryEntry(id: itemID, ref: ref(facet, of: itemID), title: "Synthetic", snippet: nil,
                            lastCopiedAt: Date(), kind: .text, isMemo: isMemo ?? (facet == .memo),
                            isFavorite: isFavorite)
    }
}

/// A list that takes the keyboard while empty, as the library's lists take it once they have rows.
private final class KeyboardTable: NSTableView {
    override var acceptsFirstResponder: Bool { true }
}
