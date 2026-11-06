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
}
