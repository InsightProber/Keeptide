import XCTest

@MainActor
final class SettingsUITests: XCTestCase {
    func testSettingsExposeFourPagesAndTruthfulLocalOnlyCloudState() {
        let (app, sessionID) = launchSettings()
        defer { removeTestSession(sessionID, app: app) }
        XCTAssertTrue(app.windows["KeeptideSettingsWindow"].waitForExistence(timeout: 8))

        // The form can be taller than the bounded window on a small display.
        XCTAssertTrue(app.scrollViews["GeneralSettingsPage"].waitForExistence(timeout: 3))
        for title in ["General", "Shortcuts", "Recording & Privacy", "iCloud"] {
            XCTAssertTrue(app.tabs[title].exists, "Missing settings page \(title)")
        }
        app.tabs["iCloud"].click()
        let cloudPage = app.scrollViews["CloudSettingsPage"]
        let cloudDescription = cloudPage.staticTexts["CloudUnavailableTitle"]
        XCTAssertTrue(cloudDescription.waitForExistence(timeout: 3))
        // The native Form can expose separate or grouped static texts, with
        // their contents in AXValue instead of AXLabel.
        let cloudLabel = cloudDescription.label
        let cloudValue = cloudDescription.value as? String ?? ""
        XCTAssertTrue(cloudLabel.contains("iCloud is not available in this build")
                      || cloudValue.contains("iCloud is not available in this build"),
                      cloudDescription.debugDescription)
        let localExplanation = cloudPage.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Your library is stored locally on this Mac.", "Your library is stored locally on this Mac."
        )).firstMatch
        XCTAssertTrue(localExplanation.exists, cloudPage.debugDescription)
        XCTAssertFalse(app.buttons["Sign In"].exists)
        XCTAssertFalse(app.switches["iCloud"].exists)
    }

    func testRecordingPageUsesTheRealCapturePreferenceAndExplainsSnippetRetention() {
        let (app, sessionID) = launchSettings()
        defer { removeTestSession(sessionID, app: app) }
        XCTAssertTrue(app.windows["KeeptideSettingsWindow"].waitForExistence(timeout: 8))
        app.tabs["Recording & Privacy"].click()

        XCTAssertTrue(app.switches["CaptureEnabledToggle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["SavedSnippetRetentionExplanation"].exists)
        let manage = app.buttons["ManageIgnoredApplicationsButton"]
        XCTAssertTrue(manage.exists)
        manage.click()
        XCTAssertTrue(app.windows["KeeptideLibraryWindow"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Ignored Applications", "Ignored Applications"
        ))
            .firstMatch.waitForExistence(timeout: 3))
    }

    private func launchSettings() -> (XCUIApplication, UUID) {
        let sessionID = UUID()
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--disable-global-hotkey", "--show-settings",
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
