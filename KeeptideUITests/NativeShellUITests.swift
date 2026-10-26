import XCTest

@MainActor
final class NativeShellUITests: XCTestCase {
    func testQuickPanelAcceptsTextWithoutPerformingAnAction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey"]
        app.launchArguments.append("--show-quick-access")
        app.launch()

        let queryField = app.searchFields["Quick access query"]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))

        queryField.typeText("plain input")
        queryField.typeKey(.return, modifierFlags: [])

        XCTAssertEqual(queryField.value as? String, "plain input")
        let emptyState = app.descendants(matching: .any)["QuickAccessEmptyState"]
        let quickAccessWindow = app.windows["KeeptideQuickAccessPanel"]
        XCTAssertTrue(emptyState.exists)
        XCTAssertTrue(quickAccessWindow.exists)

        queryField.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(queryField.value as? String, "")
        XCTAssertTrue(quickAccessWindow.exists)

        queryField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(quickAccessWindow.waitForNonExistence(timeout: 5))
    }

    func testClosingLibraryLeavesMenuBarApplicationRunning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey"]
        app.launchArguments.append("--show-library")
        app.launch()

        let libraryWindow = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(libraryWindow.waitForNonExistence(timeout: 5))

        let statusItem = app.menuBars.statusItems["Keeptide"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let openLibrary = app.menuItems["Open Library"]
        XCTAssertTrue(openLibrary.waitForExistence(timeout: 5))
        openLibrary.click()

        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 5))
    }
}
