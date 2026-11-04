import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    func testWelcomeSaysWhatKeeptideSavesWithoutPermissionPrompts() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        XCTAssertTrue(app.windows["KeeptideOnboardingWindow"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["OnboardingOpenLibrary"].exists)
        XCTAssertTrue(app.buttons["OnboardingDone"].exists)
        XCTAssertFalse(app.buttons["OnboardingStartRecording"].exists)
        XCTAssertFalse(app.buttons["OnboardingNotNow"].exists)
        for explanation in ["Keeptide saves what you copy so you can find and reuse it.",
                            "Apps you ignore and private content, such as passwords, are never saved."] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", explanation, explanation
            )).firstMatch.exists, app.debugDescription)
        }
        XCTAssertFalse(app.buttons["Allow Accessibility"].exists)
        XCTAssertFalse(app.buttons["Enable iCloud"].exists)
    }

    func testDoneClosesWelcomeWithoutOpeningTheLibrary() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.buttons["OnboardingDone"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 2), app.debugDescription)
    }

    func testEscapeClosesWelcomeAsDoneDoes() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        window.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 2), app.debugDescription)
    }

    func testOpenLibraryClosesWelcomeAndOpensTheLibraryWithNothingToTurnOn() {
        let (app, sessionID) = launchWelcome()
        defer { removeTestSession(sessionID, app: app) }
        let window = app.windows["KeeptideOnboardingWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        app.buttons["OnboardingOpenLibrary"].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 3))
        let library = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        // Once the isolated library is open, there is no switch for new copies.
        let initialized = library.buttons["NewSnippet"]
        XCTAssertTrue(initialized.waitForExistence(timeout: 8), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: initialized)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.buttons["CaptureRecordingToggle"].exists, app.debugDescription)
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
