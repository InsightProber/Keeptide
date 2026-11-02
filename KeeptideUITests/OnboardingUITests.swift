import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testWelcomeMakesRecordingAnExplicitChoiceWithoutPermissionPrompts() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        XCTAssertTrue(app.windows["KeeptideOnboardingWindow"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["OnboardingStartRecording"].exists)
        XCTAssertTrue(app.buttons["OnboardingNotNow"].exists)
        XCTAssertTrue(app.buttons["OnboardingOpenLibrary"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "starts only after"
        )).firstMatch.exists)
        XCTAssertFalse(app.buttons["Allow Accessibility"].exists)
        XCTAssertFalse(app.buttons["Enable iCloud"].exists)
    }

    func testNotNowClosesWelcomeWithoutStartingRecording() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.buttons["OnboardingNotNow"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
    }

    func testStartRecordingClosesWelcomeAndEnablesTheIsolatedMonitor() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.buttons["OnboardingStartRecording"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 8))
        let toggle = app.buttons["CaptureRecordingToggle"]
        expectation(for: NSPredicate(format: "label == %@", "Pause Recording"), evaluatedWith: toggle)
        waitForExpectations(timeout: 8)
    }

    func testOpenLibraryClosesWelcomeWithoutEnablingRecording() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.buttons["OnboardingOpenLibrary"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 8))
        let toggle = app.buttons["CaptureRecordingToggle"]
        expectation(for: NSPredicate(format: "label == %@", "Start Recording"), evaluatedWith: toggle)
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
