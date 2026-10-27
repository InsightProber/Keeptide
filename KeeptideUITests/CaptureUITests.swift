import AppKit
import XCTest

@MainActor
final class CaptureUITests: XCTestCase {
    func testRecordingLifecycleUsesOnlyTheIsolatedPasteboardAndPersistsRecentContent() {
        continueAfterFailure = false
        let sessionID = UUID()
        let app = launchKeeptide(sessionID: sessionID)
        let host = launchSystemTestHost(sessionID: sessionID)
        defer {
            host.terminate()
            app.terminate()
        }

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
        host.launchArguments = ["--capture-test-session", sessionID.uuidString]
        host.launch()
        return host
    }
}
