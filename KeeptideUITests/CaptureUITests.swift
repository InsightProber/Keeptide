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
        let app = launchKeeptide(sessionID: sessionID)

        app.activate()
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 8))
        let ignoredApps = app.buttons["IgnoredApplications"]
        XCTAssertTrue(ignoredApps.waitForExistence(timeout: 8))
        ignoredApps.click()

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

    func testRecordingLifecycleUsesOnlyTheIsolatedPasteboardAndPersistsRecentContent() {
        continueAfterFailure = false
        let sessionID = UUID()
        let app = launchKeeptide(sessionID: sessionID)
        let host = launchSystemTestHost(sessionID: sessionID)

        app.activate()
        let library = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(library.waitForExistence(timeout: 8), app.debugDescription)
        let recordingButton = app.buttons["CaptureRecordingToggle"]
        guard recordingButton.waitForExistence(timeout: 5) else {
            let status = app.descendants(matching: .any)["CaptureStatus"]
            XCTFail(
                """
                Capture recording control did not appear.
                CaptureStatus exists: \(status.exists)
                Application accessibility hierarchy:
                \(app.debugDescription)
                """
            )
            return
        }
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: recordingButton)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(recordingButton.label, "Start Recording")

        recordingButton.click()
        XCTAssertEqual(recordingButton.label, "Pause Recording")

        host.activate()
        let writeText = host.buttons["Write Text"]
        XCTAssertTrue(writeText.waitForExistence(timeout: 5), host.debugDescription)
        writeText.click()

        app.activate()
        let capturedRow = app.staticTexts["Synthetic Keeptide text"].firstMatch
        XCTAssertTrue(capturedRow.waitForExistence(timeout: 8), app.debugDescription)
        let recentRows = app.descendants(matching: .any).matching(identifier: "RecentClipRow")
        let capturedCount = recentRows.count
        XCTAssertGreaterThan(capturedCount, 0)
        capturedRow.click()
        let copyButton = app.buttons["CopyCapture"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))

        recordingButton.click()
        XCTAssertEqual(recordingButton.label, "Start Recording")
        host.activate()
        host.buttons["Write Alternate Text"].click()
        let hostStatus = host.staticTexts["Synthetic host status"]
        let alternateWritten = NSPredicate(format: "value == %@", "Synthetic alternate text written")
        expectation(for: alternateWritten, evaluatedWith: hostStatus)
        waitForExpectations(timeout: 5)

        app.activate()
        XCTAssertFalse(app.staticTexts["Synthetic paused text"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(recentRows.count, capturedCount)

        copyButton.click()
        host.activate()
        host.buttons["Inspect Synthetic Pasteboard"].click()
        let payloadReceived = NSPredicate(format: "value == %@", "Synthetic payload received")
        expectation(for: payloadReceived, evaluatedWith: hostStatus)
        waitForExpectations(timeout: 5)
        let receivedText = host.descendants(matching: .any)["ReceivedSyntheticText"]
        XCTAssertTrue(receivedText.waitForExistence(timeout: 5), host.debugDescription)
        XCTAssertEqual(receivedText.value as? String, "Synthetic Keeptide text")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Synthetic Keeptide text"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Synthetic paused text"].firstMatch.exists)
    }

    private func launchKeeptide(sessionID: UUID) -> XCUIApplication {
        let app = XCUIApplication()
        cleanupSessionID = sessionID
        cleanupApplication = app
        app.launchArguments = [
            "--ui-testing",
            "--disable-global-hotkey",
            "--show-library",
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

        let recordingButton = app.buttons["CaptureRecordingToggle"]
        XCTAssertTrue(recordingButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(recordingButton.isEnabled)
    }
}
