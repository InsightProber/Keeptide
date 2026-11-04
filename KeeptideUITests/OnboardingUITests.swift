import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testWelcomeSaysKeeptideRecordsWithoutPermissionPrompts() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        XCTAssertTrue(app.windows["KeeptideOnboardingWindow"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["OnboardingOpenLibrary"].exists)
        XCTAssertTrue(app.buttons["OnboardingDone"].exists)
        XCTAssertFalse(app.buttons["OnboardingStartRecording"].exists)
        XCTAssertFalse(app.buttons["OnboardingNotNow"].exists)
        let recordingExplanation = "Keeptide saves what you copy. "
            + "Pause or resume it anytime from the menu bar or Settings."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", recordingExplanation, recordingExplanation
        )).firstMatch.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["Allow Accessibility"].exists)
        XCTAssertFalse(app.buttons["Enable iCloud"].exists)
    }

    func testDoneClosesWelcomeWithoutOpeningTheLibraryAndLeavesRecordingOn() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.buttons["OnboardingDone"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 2), app.debugDescription)

        // The same session opened again still records: Done changed nothing.
        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--disable-global-hotkey", "--show-library",
            "--capture-test-session", sessionID.uuidString,
        ]
        app.launch()
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 8), app.debugDescription)
        let toggle = app.buttons["CaptureRecordingToggle"]
        expectation(for: NSPredicate(format: "label == %@", "Pause Recording"), evaluatedWith: toggle)
        waitForExpectations(timeout: 8)
    }

    func testOpenLibraryClosesWelcomeAndTheIsolatedMonitorRecords() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.buttons["OnboardingOpenLibrary"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 8))
        // Recording was on from launch; opening the Library left it so.
        let toggle = app.buttons["CaptureRecordingToggle"]
        expectation(for: NSPredicate(format: "label == %@", "Pause Recording"), evaluatedWith: toggle)
        waitForExpectations(timeout: 8)
    }

    private func launchWelcome() -> (XCUIApplication, UUID) {
        let sessionID = UUID()
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--disable-global-hotkey", "--show-onboarding",
            "--capture-test-session", sessionID.uuidString,
        ]
        app.launch()
        return (app, sessionID)
    }

    private func removeTestSession(_ sessionID: UUID, app: XCUIApplication) {
        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--disable-global-hotkey", "--show-library",
            "--capture-test-session", sessionID.uuidString,
            "--cleanup-capture-test-session",
        ]
        app.launch()
        defer { app.terminate() }
        let status = app.descendants(matching: .any)["CaptureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8), app.debugDescription)
        expectation(
            for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                             "Test session removed", "Test session removed"),
            evaluatedWith: status
        )
        waitForExpectations(timeout: 8)
    }
}
