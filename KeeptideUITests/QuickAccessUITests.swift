import AppKit
import XCTest

/// Quick access against an isolated test session seeded with synthetic clips.
/// Every pasteboard involved is the session's named pasteboard.
@MainActor
final class QuickAccessUITests: XCTestCase {
    private var sessionID: UUID?
    private var application: XCUIApplication?
    private var host: XCUIApplication?

    override func tearDown() async throws {
        host?.terminate()
        if let sessionID, let application { removeTestSession(sessionID, app: application) }
        sessionID = nil
        application = nil
        host = nil
        try await super.tearDown()
    }

    func testRecentClipsAppearNewestFirst() throws {
        let app = launchKeeptide()
        let rows = try openPanel(app)

        XCTAssertEqual(rows.element(boundBy: 0).label, "Synthetic alpha note")
        XCTAssertEqual(rows.element(boundBy: 1).label, "echo synthetic-beta")
        XCTAssertEqual(text(of: app.staticTexts["QuickAccessScope"]), "Recent Clips")
    }

    func testDownDoesNotSkipTheFirstRowAndUpReturnsToSearch() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)
        let query = app.searchFields["Quick access query"]

        query.typeKey(.downArrow, modifierFlags: [])
        let firstRow = app.tables["QuickAccessResults"].tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertTrue(firstRow.isSelected)

        app.typeKey(.upArrow, modifierFlags: [])
        app.typeText("x")
        XCTAssertEqual(query.value as? String, "x")
    }

    func testTypingSearchesAllContent() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)

        app.searchFields["Quick access query"].typeText("beta")

        let match = app.tables["QuickAccessResults"].cells
            .matching(NSPredicate(format: "label == %@", "echo synthetic-beta")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(text(of: app.staticTexts["QuickAccessScope"]).hasPrefix("All Content"))
    }

    func testSpaceOpensPreviewAndEscapeClosesOneLayerAtATime() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)
        let panel = app.dialogs["KeeptideQuickAccessPanel"]
        let query = app.searchFields["Quick access query"]
        let preview = app.descendants(matching: .any)["QuickAccessPreview"]

        query.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.exists)

        query.click()
        query.typeText("x")
        query.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(query.value as? String, "")
        XCTAssertTrue(panel.exists)

        query.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    func testReturnWithNoResultsDoesNothing() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)
        let query = app.searchFields["Quick access query"]

        query.typeText("zzzz-no-match")
        let status = app.descendants(matching: .any)["QuickAccessStatus"]
        let noResults = NSPredicate(format: "label == %@ OR value == %@", "No results", "No results")
        expectation(for: noResults, evaluatedWith: status)
        waitForExpectations(timeout: 8)

        query.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].exists)
    }

    // MARK: - Helpers

    private func launchKeeptide() -> XCUIApplication {
        continueAfterFailure = false
        let sessionID = UUID()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey", "--show-quick-access",
                               "--capture-test-session", sessionID.uuidString, "--seed-synthetic-clips"]
        self.sessionID = sessionID
        application = app
        app.launch()
        return app
    }

    func launchSystemTestHost() -> XCUIApplication {
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("KeeptideSystemTestHost.app")
        let host = XCUIApplication(url: hostURL)
        host.launchArguments = ["--capture-test-session", sessionID?.uuidString ?? ""]
        self.host = host
        host.launch()
        return host
    }

    /// Waits for the panel `--show-quick-access` opened and for its seeded rows. The
    /// status menu path is covered by NativeShellUITests.
    @discardableResult
    func openPanel(_ app: XCUIApplication) throws -> XCUIElementQuery {
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].waitForExistence(timeout: 8), app.debugDescription)
        let rows = app.tables["QuickAccessResults"].cells
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        return rows
    }

    func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func removeTestSession(_ sessionID: UUID, app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey", "--show-library", "--capture-test-session",
                               sessionID.uuidString, "--cleanup-capture-test-session"]
        app.launch()
        defer { app.terminate() }
        let status = app.descendants(matching: .any)["CaptureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8), app.debugDescription)
        let removed = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "Test session removed", "Test session removed")
        expectation(for: removed, evaluatedWith: status)
        waitForExpectations(timeout: 8)
    }
}
