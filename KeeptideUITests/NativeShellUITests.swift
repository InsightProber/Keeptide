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
        XCTAssertTrue(app.staticTexts["No content yet"].exists)
        XCTAssertTrue(app.windows["Keeptide Quick Access"].exists)

        queryField.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(queryField.value as? String, "")
        XCTAssertTrue(app.windows["Keeptide Quick Access"].exists)

        queryField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.windows["Keeptide Quick Access"].waitForNonExistence(timeout: 5))
    }

    func testClosingLibraryLeavesMenuBarApplicationRunning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey"]
        app.launchArguments.append("--show-library")
        app.launch()

        let libraryWindow = app.windows["Keeptide Library"]
        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 5))

        libraryWindow.buttons["Close Library"].click()
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
