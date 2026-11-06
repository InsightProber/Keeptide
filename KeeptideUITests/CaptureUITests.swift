import AppKit
import XCTest

@MainActor
final class CaptureUITests: XCTestCase {
    private var cleanupSessionID: UUID?
    private var cleanupApplication: XCUIApplication?
    private var cleanupHost: XCUIApplication?

    override func tearDown() async throws {
        if let sessionID = cleanupSessionID, let app = cleanupApplication {
            cleanupCaptureTestSession(sessionID, app: app, host: cleanupHost)
        } else {
            cleanupHost?.terminate()
            cleanupApplication?.terminate()
        }
        cleanupSessionID = nil
        cleanupApplication = nil
        cleanupHost = nil
        try await super.tearDown()
    }

    func testIgnoredApplicationPickerCanBeCancelledAndOpenedAgain() {
        continueAfterFailure = false
        let sessionID = UUID()
        let app = launchKeeptide(sessionID: sessionID, showing: "--show-settings")

        app.activate()
        XCTAssertTrue(app.windows["KeeptideSettingsWindow"].waitForExistence(timeout: 8))
        app.tabs["Privacy"].click()
        let manage = app.buttons["ManageIgnoredApplicationsButton"]
        XCTAssertTrue(manage.waitForExistence(timeout: 8), app.debugDescription)
        manage.click()

        let choose = app.buttons["Choose Application…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<2 {
            choose.click()
            let openPanel = app.descendants(matching: .sheet)["open-panel"]
            XCTAssertTrue(openPanel.waitForExistence(timeout: 5), app.debugDescription)
            let cancel = openPanel.buttons["CancelButton"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
            cancel.click()
            XCTAssertTrue(openPanel.waitForNonExistence(timeout: 5))
            XCTAssertTrue(choose.waitForExistence(timeout: 5), app.debugDescription)
        }
    }

    func testNewCopiesAreKeptFromTheIsolatedPasteboardWithNothingToTurnOnAndPersist() {
        continueAfterFailure = false
        let sessionID = UUID()
        let app = launchKeeptide(sessionID: sessionID)
        let host = launchSystemTestHost(sessionID: sessionID)

        app.activate()
        let library = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(library.waitForExistence(timeout: 8), app.debugDescription)
        // Keeptide keeps new copies once the isolated library is open. There is no switch, and nothing is said while
        // copies are kept.
        let initialized = library.buttons["NewSnippet"]
        XCTAssertTrue(initialized.waitForExistence(timeout: 8), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: initialized)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["CaptureRecordingToggle"].exists, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["CaptureStatus"].exists, app.debugDescription)

        host.activate()
        let writeText = host.buttons["Write Text"]
        XCTAssertTrue(writeText.waitForExistence(timeout: 5), host.debugDescription)
        writeText.click()

        app.activate()
        let capturedRow = app.staticTexts["Synthetic Keeptide text"].firstMatch
        XCTAssertTrue(capturedRow.waitForExistence(timeout: 8), app.debugDescription)
        let recentRows = app.descendants(matching: .any).matching(identifier: "RecentClipRow")
        XCTAssertGreaterThan(recentRows.count, 0)

        // The next copy is kept too.
        host.activate()
        host.buttons["Write Alternate Text"].click()
        let hostStatus = host.staticTexts["Synthetic host status"]
        let alternateWritten = NSPredicate(format: "value == %@", "Synthetic alternate text written")
        expectation(for: alternateWritten, evaluatedWith: hostStatus)
        waitForExpectations(timeout: 5)
        app.activate()
        XCTAssertTrue(app.staticTexts["Synthetic alternate text"].firstMatch.waitForExistence(timeout: 8),
                      app.debugDescription)

        // The first copy goes back to the session's clipboard as it was copied.
        capturedRow.click()
        let copyButton = app.buttons["CopyLibraryItem"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: copyButton)
        waitForExpectations(timeout: 5)
        copyButton.click()
        host.activate()
        host.buttons["Inspect Synthetic Pasteboard"].click()
        let payloadReceived = NSPredicate(format: "value == %@", "Synthetic payload received")
        expectation(for: payloadReceived, evaluatedWith: hostStatus)
        waitForExpectations(timeout: 5)
        let receivedText = host.descendants(matching: .any)["ReceivedSyntheticText"]
        XCTAssertTrue(receivedText.waitForExistence(timeout: 5), host.debugDescription)
        XCTAssertEqual(receivedText.value as? String, "Synthetic Keeptide text")

        // Both copies are there once Keeptide reopens.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Synthetic Keeptide text"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Synthetic alternate text"].firstMatch.waitForExistence(timeout: 8))
    }

    private func launchKeeptide(sessionID: UUID, showing window: String = "--show-library") -> XCUIApplication {
        let app = XCUIApplication()
        cleanupSessionID = sessionID
        cleanupApplication = app
        app.launchArguments = [
            "--ui-testing",
            "--disable-global-hotkey",
            window,
            "--capture-test-session",
            sessionID.uuidString
        ]
        app.launch()
        return app
    }

    private func launchSystemTestHost(sessionID: UUID) -> XCUIApplication {
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("KeeptideSystemTestHost.app")
        let host = XCUIApplication(url: hostURL)
        cleanupHost = host
        host.launchArguments = ["--capture-test-session", sessionID.uuidString]
        host.launch()
        return host
    }

    private func cleanupCaptureTestSession(
        _ sessionID: UUID,
        app: XCUIApplication,
        host: XCUIApplication? = nil
    ) {
        host?.terminate()
        app.terminate()
        app.launchArguments = [
            "--ui-testing",
            "--disable-global-hotkey",
            "--show-library",
            "--capture-test-session",
            sessionID.uuidString,
            "--cleanup-capture-test-session",
        ]
        app.launch()
        defer { app.terminate() }

        let library = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(library.waitForExistence(timeout: 8), app.debugDescription)
        let status = app.descendants(matching: .any)["CaptureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        let removed = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Test session removed",
            "Test session removed"
        )
        expectation(for: removed, evaluatedWith: status)
        waitForExpectations(timeout: 8)
    }
}
