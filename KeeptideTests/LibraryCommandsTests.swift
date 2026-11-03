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
}
