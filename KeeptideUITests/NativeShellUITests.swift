import XCTest

@MainActor
final class NativeShellUITests: XCTestCase {
    func testQuickPanelAcceptsTextWithoutPerformingAnAction() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey"]
        app.launch()

        let statusItem = app.menuBars.statusItems["Keeptide"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let openQuickAccess = app.menuItems["Open Quick Access"]
        XCTAssertTrue(openQuickAccess.waitForExistence(timeout: 5))
        openQuickAccess.click()

        let quickAccessPanel = app.dialogs["KeeptideQuickAccessPanel"]
        guard quickAccessPanel.waitForExistence(timeout: 5) else {
            let windowMatch = app.windows["KeeptideQuickAccessPanel"]
            let anyRoleMatch = app.descendants(matching: .any)
                .matching(identifier: "KeeptideQuickAccessPanel")
                .firstMatch
            XCTFail(
                """
                Quick access panel did not appear as a dialog.
                Matching dialog exists: \(quickAccessPanel.exists)
                Matching window exists: \(windowMatch.exists)
                Matching identifier with any accessibility role exists: \(anyRoleMatch.exists)
                Application accessibility hierarchy:
                \(app.debugDescription)
                """
            )
            return
        }

        let queryField = app.searchFields["Quick access query"]
        guard queryField.waitForExistence(timeout: 5) else {
            let anyRoleMatch = app.descendants(matching: .any)
                .matching(identifier: "Quick access query")
                .firstMatch
            XCTFail(
                """
                Quick access query field did not appear.
                Quick access panel exists: \(quickAccessPanel.exists)
                Matching identifier with any accessibility role exists: \(anyRoleMatch.exists)
                Application accessibility hierarchy:
                \(app.debugDescription)
                """
            )
            return
        }

        queryField.typeText("plain input")
        queryField.typeKey(.return, modifierFlags: [])

        XCTAssertEqual(queryField.value as? String, "plain input")
        let emptyState = app.descendants(matching: .any)["QuickAccessEmptyState"]
        XCTAssertTrue(emptyState.exists)
        XCTAssertTrue(quickAccessPanel.exists)

        queryField.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(queryField.value as? String, "")
        XCTAssertTrue(quickAccessPanel.exists)

        queryField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(quickAccessPanel.waitForNonExistence(timeout: 5))
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
