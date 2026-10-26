import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class AppLaunchTests: XCTestCase {
    func testCaptureStartsDisabled() {
        let suiteName = "AppLaunchTests.captureStartsDisabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.captureEnabled)
    }

    func testXCTestLaunchDoesNotRegisterTheGlobalShortcut() {
        let configuration = LaunchConfiguration(
            arguments: [],
            environment: ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        )

        XCTAssertFalse(configuration.shouldRegisterGlobalHotKey)
    }

    func testEscapeLeavesMarkedTextWithTheInputMethod() {
        XCTAssertEqual(
            QuickAccessEscapePolicy.action(hasMarkedText: true, hasQuery: true),
            .passToInputMethod
        )
    }

    func testEscapeClearsACommittedQueryBeforeClosingThePanel() {
        XCTAssertEqual(
            QuickAccessEscapePolicy.action(hasMarkedText: false, hasQuery: true),
            .clearQuery
        )
    }

    func testEscapeClosesThePanelWhenThereIsNoCompositionOrQuery() {
        XCTAssertEqual(
            QuickAccessEscapePolicy.action(hasMarkedText: false, hasQuery: false),
            .closePanel
        )
    }

    func testShortcutStatusMessagesCoverEveryState() {
        XCTAssertNil(MenuBarController.ShortcutStatus.available.menuTitle)
        XCTAssertEqual(
            MenuBarController.ShortcutStatus.disabledForTesting.menuTitle,
            "Global shortcut disabled for this test run — open Quick Access here"
        )
        XCTAssertEqual(
            MenuBarController.ShortcutStatus.unavailable.menuTitle,
            "Shift-Command-V is already in use — open Quick Access here"
        )
        XCTAssertEqual(
            MenuBarController.ShortcutStatus.failed(-50).menuTitle,
            "Shift-Command-V is unavailable (error -50) — open Quick Access here"
        )
    }

    func testApplicationMenuBindsStandardResponderActions() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let appMenu = try XCTUnwrap(menu.item(withTitle: "Keeptide")?.submenu)
        let editMenu = try XCTUnwrap(menu.item(withTitle: "Edit")?.submenu)
        let windowMenu = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)

        XCTAssertEqual(appMenu.item(withTitle: "Quit Keeptide")?.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(appMenu.item(withTitle: "Quit Keeptide")?.keyEquivalent, "q")
        XCTAssertEqual(windowMenu.item(withTitle: "Close")?.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(windowMenu.item(withTitle: "Close")?.keyEquivalent, "w")

        let expectedEditActions: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, keyEquivalent) in expectedEditActions {
            XCTAssertEqual(editMenu.item(withTitle: title)?.action, action)
            XCTAssertEqual(editMenu.item(withTitle: title)?.keyEquivalent, keyEquivalent)
        }
        XCTAssertEqual(
            editMenu.item(withTitle: "Redo")?.keyEquivalentModifierMask,
            [.command, .shift]
        )
    }

    func testClosingLibraryDoesNotRequestApplicationTermination() {
        let delegate = AppDelegate()
        let controller = LibraryWindowController()

        controller.show()
        controller.close()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
