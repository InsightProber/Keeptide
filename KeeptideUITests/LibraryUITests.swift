import AppKit
import XCTest

/// Native library workflows backed only by a per-test store and named pasteboard.
/// These tests deliberately do not read or write the user's general pasteboard.
@MainActor
final class LibraryUITests: XCTestCase {
    private var sessionID: UUID?
    private var application: XCUIApplication?
    private var host: XCUIApplication?

    override func tearDown() async throws {
        host?.terminate()
        if let sessionID, let application {
            removeTestSession(sessionID, app: application)
        } else {
            application?.terminate()
        }
        self.sessionID = nil
        application = nil
        host = nil
        try await super.tearDown()
    }

    func testNewSnippetCanBeSavedSearchedCopiedAndReopened() {
        continueAfterFailure = false
        let sessionID = UUID()
        let host = launchSystemTestHost(sessionID: sessionID)
        let app = launchKeeptide(sessionID: sessionID, seedSyntheticClips: true)
        let title = "PR08 deployment command \(sessionID.uuidString.prefix(8))"
        let body = "printf 'keeptide-pr08-copy'"

        let library = requireLibrary(in: app)
        app.typeKey("n", modifierFlags: .command)
        let titleEditor = library.descendants(matching: .any)["SnippetTitleEditor"]
        let bodyEditor = library.descendants(matching: .any)["SnippetBodyEditor"]
        XCTAssertTrue(titleEditor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: titleEditor, with: title)
        replaceText(in: bodyEditor, with: body)
        bodyEditor.typeKey("s", modifierFlags: .command)

        openAllSnippets(in: app)
        searchLibrary(for: title, in: app)
        let result = app.staticTexts[title].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8), app.debugDescription)
        result.click()

        app.typeKey("c", modifierFlags: [.command, .shift])
        host.activate()
        let inspect = host.buttons["Inspect Synthetic Pasteboard"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 5), host.debugDescription)
        inspect.click()
        let received = host.descendants(matching: .any)["ReceivedSyntheticText"]
        XCTAssertTrue(received.waitForExistence(timeout: 5), host.debugDescription)
        XCTAssertEqual(received.value as? String, body)

        app.terminate()
        app.launch()
        _ = requireLibrary(in: app)
        openAllSnippets(in: app)
        searchLibrary(for: title, in: app)
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testRecentHistoryCanBeSavedAsAnEditableSnippet() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID(), seedSyntheticClips: true)
        let library = requireLibrary(in: app)
        let capture = app.staticTexts["Synthetic alpha note"].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 8), app.debugDescription)
        capture.click()

        let saveAsSnippet = library.buttons["SaveHistoryAsSnippet"]
        XCTAssertTrue(saveAsSnippet.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(library.buttons["CopyLibraryItem"].exists)
        saveAsSnippet.click()

        let editableCopy = library.buttons["CopyLibraryItem"]
        XCTAssertTrue(editableCopy.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(saveAsSnippet.waitForNonExistence(timeout: 5))
        let undoSave = library.buttons["LibraryUndoNewSave"]
        XCTAssertTrue(undoSave.waitForExistence(timeout: 5), app.debugDescription)
        undoSave.click()
        XCTAssertTrue(saveAsSnippet.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(editableCopy.waitForNonExistence(timeout: 5))

        saveAsSnippet.click()
        XCTAssertTrue(editableCopy.waitForExistence(timeout: 8), app.debugDescription)
        let titleEditor = library.descendants(matching: .any)["SnippetTitleEditor"]
        let revisedTitle = "Saved synthetic alpha"
        replaceText(in: titleEditor, with: revisedTitle)
        app.typeKey("s", modifierFlags: .command)

        openAllSnippets(in: app)
        searchLibrary(for: revisedTitle, in: app)
        XCTAssertTrue(app.staticTexts[revisedTitle].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testFindInNoteAndLibrarySearchUseDistinctShortcuts() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID())
        let library = requireLibrary(in: app)
        app.typeKey("n", modifierFlags: .command)
        let bodyEditor = library.descendants(matching: .any)["SnippetBodyEditor"]
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: bodyEditor, with: "alpha native-needle omega")

        bodyEditor.typeKey("f", modifierFlags: .command)
        let localFindField = app.searchFields["Find"].firstMatch
        XCTAssertTrue(localFindField.waitForExistence(timeout: 5), app.debugDescription)
        localFindField.typeText("native-needle")
        localFindField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(localFindField.waitForNonExistence(timeout: 5))

        app.typeKey("f", modifierFlags: [.command, .shift])
        let librarySearch = library.descendants(matching: .any)["LibrarySearchField"]
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 5), app.debugDescription)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: librarySearch)
        waitForExpectations(timeout: 5)
        librarySearch.typeText("a distinct library query")
        XCTAssertEqual(librarySearch.value as? String, "a distinct library query")
    }

    func testClosingLibraryFlushesTheCurrentSnippetBeforeReopening() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID())
        let library = requireLibrary(in: app)
        let title = "Close flush \(UUID().uuidString.prefix(8))"
        app.typeKey("n", modifierFlags: .command)
        let titleEditor = library.descendants(matching: .any)["SnippetTitleEditor"]
        let bodyEditor = library.descendants(matching: .any)["SnippetBodyEditor"]
        XCTAssertTrue(titleEditor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: titleEditor, with: title)
        replaceText(in: bodyEditor, with: "content flushed by prepareToClose")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(library.waitForNonExistence(timeout: 8), app.debugDescription)
        let statusItem = app.menuBars.statusItems["Keeptide"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), app.debugDescription)
        statusItem.click()
        let openLibrary = app.menuItems["Open Library"]
        XCTAssertTrue(openLibrary.waitForExistence(timeout: 5), app.debugDescription)
        openLibrary.click()

        _ = requireLibrary(in: app)
        openAllSnippets(in: app)
        searchLibrary(for: title, in: app)
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    // MARK: - Isolated launch and interaction helpers

    private func launchKeeptide(sessionID: UUID, seedSyntheticClips: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = [
            "--ui-testing",
            "--disable-global-hotkey",
            "--show-library",
            "--capture-test-session",
            sessionID.uuidString,
        ]
        if seedSyntheticClips { arguments.append("--seed-synthetic-clips") }
        app.launchArguments = arguments
        self.sessionID = sessionID
        application = app
        app.launch()
        return app
    }

    private func launchSystemTestHost(sessionID: UUID) -> XCUIApplication {
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("KeeptideSystemTestHost.app")
        let host = XCUIApplication(url: hostURL)
        host.launchArguments = ["--capture-test-session", sessionID.uuidString]
        self.host = host
        host.launch()
        return host
    }

    @discardableResult
    private func requireLibrary(in app: XCUIApplication) -> XCUIElement {
        app.activate()
        let library = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(library.waitForExistence(timeout: 8), app.debugDescription)
        let initialized = library.buttons["NewSnippet"]
        XCTAssertTrue(initialized.waitForExistence(timeout: 8), app.debugDescription)
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: initialized)
        waitForExpectations(timeout: 8)
        return library
    }

    private func openAllSnippets(in app: XCUIApplication) {
        let section = app.staticTexts["All Snippets"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 5), app.debugDescription)
        section.click()
    }

    private func searchLibrary(for query: String, in app: XCUIApplication) {
        app.typeKey("f", modifierFlags: [.command, .shift])
        let field = app.descendants(matching: .any)["LibrarySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: field, with: query)
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
    }

    private func removeTestSession(_ sessionID: UUID, app: XCUIApplication) {
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
        let status = app.descendants(matching: .any)["CaptureStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 8), app.debugDescription)
        let removed = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Test session removed",
            "Test session removed"
        )
        expectation(for: removed, evaluatedWith: status)
        waitForExpectations(timeout: 8)
    }
}
