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
        let collection = try command(#selector(LibraryWindowController.moveToCollection(_:)))
        XCTAssertEqual(collection.keyEquivalent, "m")
        XCTAssertEqual(collection.keyEquivalentModifierMask, [.shift, .command])
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
        let collection = item(#selector(LibraryWindowController.moveToCollection(_:)))
        let markdown = item(#selector(LibraryWindowController.setSnippetKind(_:)), tag: 3)
        let code = item(#selector(LibraryWindowController.setSnippetKind(_:)), tag: 2)
        let linked = item(#selector(LibraryWindowController.showLinkedItem(_:)))
        let inspector = item(#selector(LibraryWindowController.toggleInspector(_:)))

        // Nothing selected: nothing to act on.
        XCTAssertFalse(controller.validateMenuItem(favorite))
        XCTAssertFalse(controller.validateMenuItem(collection))
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
        XCTAssertEqual(collection.title, "Move to Collection…")
        XCTAssertTrue(controller.validateMenuItem(markdown))
        XCTAssertEqual(markdown.state, .on)
        XCTAssertTrue(controller.validateMenuItem(code))
        XCTAssertEqual(code.state, .off)
        XCTAssertTrue(controller.validateMenuItem(linked))
        XCTAssertEqual(linked.title, "Show in Recent Clips")
        XCTAssertTrue(controller.validateMenuItem(inspector))
        XCTAssertEqual(inspector.title, "Hide Inspector")
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

    func testItemCommandsAreForwardedAsRequests() throws {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let prompts = CollectionID()
        controller.commands.updateItemContext(LibraryItemContext(collectionEntries: [
            CollectionMenuEntry(id: "unfiled", role: .unfiled, title: "Unfiled", color: nil, isChecked: false),
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

        // ⇧⌘M's menu lists the same places as the toolbar's, the current one checked; choosing one files there.
        let menu = controller.makeCollectionMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Unfiled", "Prompts", "New Collection…"])
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
        XCTAssertTrue(state.canFile)
        XCTAssertNil(state.linked)
        XCTAssertNil(state.kind)

        // Saved already: its snippet's star and collection, and the way to it.
        let prompts = CollectionID()
        let snippet = Self.ref(.memo)
        details.savedSnippet = .init(ref: snippet, collectionID: prompts, isFavorite: true)
        state = .make(entries: [clip], open: open(details), hasCollections: true, canDelete: true)
        XCTAssertFalse(state.canSave)
        XCTAssertEqual(state.saveHelp, "Already in Snippets")
        XCTAssertEqual(state.favoriteTitle, "Remove from Favorites")
        XCTAssertEqual(state.collectionTitle, "Move to Collection")
        XCTAssertEqual(state.currentCollections, [prompts])
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
