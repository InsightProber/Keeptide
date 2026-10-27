import AppKit
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

        let openQuickAccess = app.menuItems["ShortcutFallback"]
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

        queryField.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(queryField.value as? String, "plain input")
        queryField.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(queryField.value as? String, "")
        queryField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(quickAccessPanel.waitForNonExistence(timeout: 5))
    }

    func testGlobalHotKeySessionsReturnFocusAndDoNotResurrect() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--synthetic-hotkey"]
        app.launch()
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("KeeptideSystemTestHost.app")
        let host = XCUIApplication(url: hostURL)
        host.launch()
        defer { host.terminate() }
        let input = host.textFields["Synthetic input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("before")
        let panel = app.dialogs["KeeptideQuickAccessPanel"]
        let query = app.searchFields["Quick access query"]

        // Use a reserved synthetic chord through the real Carbon registration path.
        pressSyntheticHotKey()
        guard panel.waitForExistence(timeout: 5) else {
            let beforeMenu = app.debugDescription
            app.menuBars.statusItems["Keeptide"].click()
            XCTFail("Hotkey did not present panel. Before menu: \(beforeMenu) After menu: \(app.debugDescription)")
            return
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       "io.github.insightprober.Keeptide.SystemTestHost")
        query.typeText("first session")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       "io.github.insightprober.Keeptide.SystemTestHost")
        query.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       "io.github.insightprober.Keeptide.SystemTestHost")
        host.typeText(" after")
        XCTAssertEqual(input.value as? String, "before after")

        pressSyntheticHotKey()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(query.value as? String, "")
        query.typeText("toggle session")
        pressSyntheticHotKey()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        pressSyntheticHotKey()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(query.value as? String, "")
        query.typeText("click away session")
        input.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        // One key press must open a fresh session after click-away.
        pressSyntheticHotKey()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(query.value as? String, "")
        query.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       "io.github.insightprober.Keeptide.SystemTestHost")

        pressSyntheticHotKey()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        query.typeText("must not return with library")
        input.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        let statusItem = app.menuBars.statusItems["Keeptide"]
        statusItem.click()
        app.menuItems["Open Library"].click()
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 5))
        XCTAssertFalse(panel.exists)
    }

    private func pressSyntheticHotKey() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let allowedTargets = ["io.github.insightprober.Keeptide", "io.github.insightprober.Keeptide.SystemTestHost"]
        XCTAssertTrue(allowedTargets.contains(frontmost))
        XCUIApplication(bundleIdentifier: frontmost).typeKey("9", modifierFlags: [.command, .option, .control, .shift])
    }

    func testLaunchServicesReopenShowsLibrary() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey"]
        app.launch()
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Keeptide.app")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 5))
    }

    func testClosingLibraryLeavesMenuBarApplicationRunning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey"]
        app.launchArguments.append("--show-library")
        app.launch()

        let libraryWindow = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 5), app.debugDescription)

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(libraryWindow.waitForNonExistence(timeout: 5))

        let statusItem = app.menuBars.statusItems["Keeptide"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let openLibrary = app.menuItems["Open Library"]
        XCTAssertTrue(openLibrary.waitForExistence(timeout: 5))
        openLibrary.click()

        XCTAssertTrue(libraryWindow.waitForExistence(timeout: 5), app.debugDescription)
    }
}
