import XCTest

@MainActor
final class NativeShellUITests: XCTestCase {
    func testQuickPanelAcceptsTextWithoutPerformingAnAction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey"]
        app.launchArguments.append("--show-quick-access")
        app.launch()

        let queryField = app.textFields["Quick access query"]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))

        queryField.click()
        queryField.typeText("中文 input")

        XCTAssertEqual(queryField.value as? String, "中文 input")
        XCTAssertTrue(app.staticTexts["No content yet"].exists)
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

        XCTAssertNotEqual(app.state, .notRunning)
    }
}
