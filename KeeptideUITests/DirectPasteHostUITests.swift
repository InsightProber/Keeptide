import AppKit
import XCTest

/// Direct paste end to end: the panel opens over the system test host's paste receiver, and Return pastes the newest
/// seeded clip, "Synthetic alpha note", into it. A test session pastes only into the host. The receiver takes ⌘V from
/// the session's named pasteboard and shows how many pastes arrived, the last one's text and the modifiers it came
/// with.
///
/// Whether Keeptide may send ⌘V depends on whether this build has Accessibility access, which no test can grant. The
/// two paste tests skip when it has not, and the copy test skips when it has.
///
/// Every key goes through the host, which stays in front, and no Keeptide element is clicked: that would activate
/// Keeptide. The panel takes the keys without activating Keeptide, so the host never sees them, and XCUITest waits
/// about ten seconds for each on CI. Each test types four such keys, well within the time `verify.sh` allows a test.
@MainActor
final class DirectPasteHostUITests: XCTestCase {
    private static let hostBundleIdentifier = "io.github.insightprober.Keeptide.SystemTestHost"
    private static let notAuthorized = "Direct paste is not authorized for this build. "
        + "Grant Keeptide in System Settings › Privacy & Security › Accessibility, then run again."
    private static let authorized = "Direct paste is authorized on this Mac; this test covers builds without it."

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

    func testReturnPastesOnceIntoTheHostWhenAuthorized() throws {
        let (app, host, primaryAction) = openPanelOverHost()
        guard primaryAction.hasPrefix("Paste into") else { throw XCTSkip(Self.notAuthorized) }

        typeThroughHost(.return)

        assertOneCommandVReachedTheReceiver(app: app, host: host)
    }

    func testShiftReturnStillSendsOnlyCommandV() throws {
        let (app, host, primaryAction) = openPanelOverHost()
        guard primaryAction.hasPrefix("Paste into") else { throw XCTSkip(Self.notAuthorized) }

        // ⇧Return pastes the plain text, and ⌘V still goes with ⌘ alone: ⇧⌘V is Keeptide's own hot key and, in many
        // apps, Paste and Match Style.
        typeThroughHost(.return, modifierFlags: .shift)

        assertOneCommandVReachedTheReceiver(app: app, host: host)
    }

    func testWithoutAuthorizationReturnCopiesAndSendsNothing() throws {
        let (app, host, primaryAction) = openPanelOverHost()
        guard primaryAction == "Copy" else { throw XCTSkip(Self.authorized) }

        typeThroughHost(.return)

        // The copy closes the panel. Its toast is gone by the time this test can look: XCUITest gives the host about
        // ten seconds to handle a key only the panel saw, and a UI test's toast stays four. QuickAccessUITests reads
        // the toast after a Return typed into Keeptide itself.
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].waitForNonExistence(timeout: 5), app.debugDescription)
        // Nothing is sent: two seconds on, no paste has reached the receiver.
        let count = host.staticTexts["ReceivedPasteCount"]
        let paste = expectation(for: NSPredicate(format: "value != %@", "0"), evaluatedWith: count)
        paste.isInverted = true
        waitForExpectations(timeout: 2)
        XCTAssertEqual(text(of: count), "0")
        XCTAssertEqual(copiedText(host: host), "Synthetic alpha note")
    }

    // MARK: - Helpers

    /// Launches Keeptide on a fresh test session, then the host on the same session so that it is in front, and opens
    /// the panel over the host's paste receiver with the synthetic hot key. Returns what Return does: the label of the
    /// toolbar's button for it, such as "Copy" or "Paste into Keeptide System Test Host".
    ///
    /// The panel opens twice. One that opens before the library is ready has no paste target and only copies, so the
    /// first showing waits for the seeded clips and closes. The second records the host's window as its target and
    /// selects the newest clip.
    private func openPanelOverHost() -> (app: XCUIApplication, host: XCUIApplication, primaryAction: String) {
        continueAfterFailure = false
        let sessionID = UUID()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--synthetic-hotkey", "--capture-test-session", sessionID.uuidString,
                               "--seed-synthetic-clips"]
        self.sessionID = sessionID
        application = app
        app.launch()
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("KeeptideSystemTestHost.app")
        let host = XCUIApplication(url: hostURL)
        host.launchArguments = ["--capture-test-session", sessionID.uuidString]
        self.host = host
        host.launch()

        let receiver = host.textViews["DirectPasteReceiver"]
        XCTAssertTrue(receiver.waitForExistence(timeout: 5), host.debugDescription)
        let panel = app.dialogs["KeeptideQuickAccessPanel"]
        let frames = app.descendants(matching: .any)["QuickAccessStrip"].descendants(matching: .any)
        let newest = frames.matching(NSPredicate(format: "label CONTAINS %@", ": Synthetic alpha note")).firstMatch

        receiver.click()
        pressSyntheticHotKey()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(newest.waitForExistence(timeout: 10), app.debugDescription)
        typeThroughHost(.escape)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), app.debugDescription)

        receiver.click()
        pressSyntheticHotKey()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(newest.waitForExistence(timeout: 10), app.debugDescription)
        // The button shows only while a clip is selected, and then says what Return does.
        let primaryAction = app.buttons["QuickAccessCopyButton"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5), app.debugDescription)
        return (app, host, primaryAction.label)
    }

    /// Types a key with the host in front, as the user would with the panel open over it.
    private func typeThroughHost(_ key: XCUIKeyboardKey, modifierFlags: XCUIElement.KeyModifierFlags = [],
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.hostBundleIdentifier,
                       file: file, line: line)
        host?.typeKey(key, modifierFlags: modifierFlags)
    }

    /// ⌃⌥⇧⌘9, the hot key a `--synthetic-hotkey` launch registers in place of the user's.
    private func pressSyntheticHotKey(file: StaticString = #filePath, line: UInt = #line) {
        typeThroughHost(XCUIKeyboardKey("9"), modifierFlags: [.command, .option, .control, .shift], file: file,
                        line: line)
    }

    /// One ⌘V, with ⌘ alone, reached the receiver and pasted the newest clip; two seconds on there is still only the
    /// one. The panel closed without a word, since sending ⌘V does not prove the target pasted, and the host is still
    /// in front.
    private func assertOneCommandVReachedTheReceiver(app: XCUIApplication, host: XCUIApplication,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        let count = host.staticTexts["ReceivedPasteCount"]
        let one = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: count)
        XCTAssertEqual(XCTWaiter().wait(for: [one], timeout: 5), .completed,
                       "Pastes received: \(text(of: count))\n\(host.debugDescription)", file: file, line: line)
        XCTAssertEqual(text(of: host.staticTexts["ReceivedPasteText"]), "Synthetic alpha note", file: file, line: line)
        XCTAssertEqual(text(of: host.staticTexts["ReceivedPasteModifiers"]), "⌘", file: file, line: line)
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].waitForNonExistence(timeout: 5), app.debugDescription,
                      file: file, line: line)
        // A toast would mean the clip was only copied. Such a toast may be gone by now, as after any key typed through
        // the host, but such a copy sends no ⌘V, and the count above would have stayed at zero.
        XCTAssertFalse(app.descendants(matching: .any)["CopyToastMessage"].waitForExistence(timeout: 2),
                       app.debugDescription, file: file, line: line)
        XCTAssertEqual(text(of: count), "1", file: file, line: line)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.hostBundleIdentifier,
                       file: file, line: line)
    }

    /// The text the session's pasteboard holds, as the host shows it when asked to inspect it.
    private func copiedText(host: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String? {
        host.buttons["Inspect Synthetic Pasteboard"].click()
        let received = host.descendants(matching: .any)["ReceivedSyntheticText"]
        XCTAssertTrue(received.waitForExistence(timeout: 5), host.debugDescription, file: file, line: line)
        return received.value as? String
    }

    private func text(of element: XCUIElement) -> String {
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
