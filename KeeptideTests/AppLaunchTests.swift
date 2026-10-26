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

    func testClosingLibraryDoesNotRequestApplicationTermination() {
        let delegate = AppDelegate()
        let controller = LibraryWindowController()

        controller.show()
        controller.close()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
