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
        let bodyEditor = library.textViews["SnippetBodyTextView"]
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

        // The toolbar's items stay put; what the selection allows is enabled.
        let saveAsSnippet = library.buttons["SaveHistoryAsSnippet"]
        XCTAssertTrue(saveAsSnippet.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(library.buttons["CopyLibraryItem"].exists)
        waitUntil(saveAsSnippet, isEnabled: true)
        saveAsSnippet.click()

        // Saved: the clip's item is a snippet now, and the save is undone from the Edit menu.
        waitUntil(saveAsSnippet, isEnabled: false)
        XCTAssertTrue(app.staticTexts["Saved to Snippets"].firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
        app.menuBars.menuBarItems["Edit"].click()
        let undoSave = app.menuItems["Undo Save as Snippet"]
        XCTAssertTrue(undoSave.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(undoSave.isEnabled, app.debugDescription)
        undoSave.click()
        waitUntil(saveAsSnippet, isEnabled: true)

        saveAsSnippet.click()
        waitUntil(saveAsSnippet, isEnabled: false)
        let titleEditor = library.descendants(matching: .any)["SnippetTitleEditor"]
        let revisedTitle = "Saved synthetic alpha"
        replaceText(in: titleEditor, with: revisedTitle)
        app.typeKey("s", modifierFlags: .command)

        openAllSnippets(in: app)
        searchLibrary(for: revisedTitle, in: app)
        XCTAssertTrue(app.staticTexts[revisedTitle].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testFavoriteOnAClipSavesItFirst() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID(), seedSyntheticClips: true)
        _ = requireLibrary(in: app)
        let title = "Synthetic alpha note"
        let capture = app.staticTexts[title].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 8), app.debugDescription)
        capture.click()

        // ⌘D on a clip saves it as a snippet that is a favorite, and says both.
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Saved as Snippet · Added to Favorites"].firstMatch.waitForExistence(timeout: 8),
                      app.debugDescription)
        sidebarRow("Favorites", in: app).click()
        waitForList("Favorites", in: app)
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testCommandDeleteMovesTheSelectionToRecentlyDeleted() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID(), seedSyntheticClips: true)
        _ = requireLibrary(in: app)
        let title = "Synthetic alpha note"
        let capture = app.staticTexts[title].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 8), app.debugDescription)
        capture.click()

        // The list has the keyboard, so ⌘⌫ moves the clip, not text.
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(capture.waitForNonExistence(timeout: 8), app.debugDescription)
        sidebarRow("Recently Deleted", in: app).click()
        waitForList("Recently Deleted", in: app)
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testRecentClipCanMoveToRecentlyDeletedAndBeRestored() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID(), seedSyntheticClips: true)
        _ = requireLibrary(in: app)
        let title = "Synthetic alpha note"
        let capture = app.staticTexts[title].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 8), app.debugDescription)

        capture.rightClick()
        let remove = contextMenuItem("Move to Recently Deleted", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.click()

        let deletedScope = sidebarRow("Recently Deleted", in: app)
        XCTAssertTrue(deletedScope.waitForExistence(timeout: 8), app.debugDescription)
        deletedScope.click()
        let deleted = app.staticTexts[title].firstMatch
        XCTAssertTrue(deleted.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(deletedLine(endingWith: "Clip", in: app).exists, app.debugDescription)

        // Recover acts on the selected row, from the toolbar.
        deleted.click()
        let restore = app.buttons["RestoreDeletedItem"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5), app.debugDescription)
        waitUntil(restore, isEnabled: true)
        restore.click()
        XCTAssertTrue(deleted.waitForNonExistence(timeout: 8), app.debugDescription)
    }

    func testRecoverRestoresOnlyTheSelectedFacet() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID(), seedSyntheticClips: true)
        let library = requireLibrary(in: app)
        let title = "Synthetic alpha note"
        let clip = app.staticTexts[title].firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 8), app.debugDescription)
        clip.click()

        // One item, two deleted facets: its snippet and its clip.
        let save = library.buttons["SaveHistoryAsSnippet"]
        waitUntil(save, isEnabled: true)
        save.click()
        waitUntil(save, isEnabled: false)
        sidebarRow("All Snippets", in: app).click()
        waitForList("All Snippets", in: app)
        let snippet = app.staticTexts[title].firstMatch
        XCTAssertTrue(snippet.waitForExistence(timeout: 8), app.debugDescription)
        snippet.click()
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(snippet.waitForNonExistence(timeout: 8), app.debugDescription)
        sidebarRow("Recent Clips", in: app).click()
        waitForList("Recent Clips", in: app)
        XCTAssertTrue(clip.waitForExistence(timeout: 8), app.debugDescription)
        clip.click()
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(clip.waitForNonExistence(timeout: 8), app.debugDescription)

        // Each has its own row; Recover brings back only the one selected.
        sidebarRow("Recently Deleted", in: app).click()
        waitForList("Recently Deleted", in: app)
        let snippetRow = deletedLine(endingWith: "Snippet", in: app)
        let clipRow = deletedLine(endingWith: "Clip", in: app)
        XCTAssertTrue(snippetRow.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(clipRow.waitForExistence(timeout: 8), app.debugDescription)
        snippetRow.click()
        let recover = library.buttons["RestoreDeletedItem"]
        waitUntil(recover, isEnabled: true)
        recover.click()
        XCTAssertTrue(snippetRow.waitForNonExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(clipRow.exists, app.debugDescription)
        sidebarRow("All Snippets", in: app).click()
        waitForList("All Snippets", in: app)
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testFindInNoteAndLibrarySearchUseDistinctShortcuts() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID())
        let library = requireLibrary(in: app)
        app.typeKey("n", modifierFlags: .command)
        let bodyEditor = library.textViews["SnippetBodyTextView"]
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: bodyEditor, with: "alpha native-needle omega")

        bodyEditor.typeKey("f", modifierFlags: .command)
        let localFindField = app.searchFields["Find"].firstMatch
        XCTAssertTrue(localFindField.waitForExistence(timeout: 5), app.debugDescription)
        localFindField.typeText("native-needle")
        localFindField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(localFindField.waitForNonExistence(timeout: 5))

        app.typeKey("f", modifierFlags: [.command, .shift])
        let librarySearch = librarySearchField(in: library)
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 5), app.debugDescription)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: librarySearch)
        waitForExpectations(timeout: 5)
        librarySearch.typeText("a distinct library query")
        XCTAssertEqual(librarySearch.value as? String, "a distinct library query")
    }

    func testSearchWorksInRecentlyDeleted() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID(), seedSyntheticClips: true)
        let library = requireLibrary(in: app)
        let title = "Synthetic alpha note"
        let capture = app.staticTexts[title].firstMatch
        XCTAssertTrue(capture.waitForExistence(timeout: 8), app.debugDescription)
        capture.rightClick()
        let remove = contextMenuItem("Move to Recently Deleted", in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.click()
        let deletedScope = sidebarRow("Recently Deleted", in: app)
        XCTAssertTrue(deletedScope.waitForExistence(timeout: 8), app.debugDescription)
        deletedScope.click()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8), app.debugDescription)

        // The same search field looks through deleted titles, and says so.
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = librarySearchField(in: library)
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(search.placeholderValue, "Search Recently Deleted by Title")
        replaceText(in: search, with: "alpha")
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        // All Content never includes deleted items: no scope bar, and an empty result offers no wider search.
        XCTAssertFalse(app.descendants(matching: .any)["All Content"].exists, app.debugDescription)
        replaceText(in: search, with: "no deleted title like this")
        let empty = app.descendants(matching: .any)["RecentlyDeletedEmptyState"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Search All Content"].exists, app.debugDescription)
    }

    func testClosingLibraryFlushesTheCurrentSnippetBeforeReopening() {
        continueAfterFailure = false
        let app = launchKeeptide(sessionID: UUID())
        let library = requireLibrary(in: app)
        let title = "Close flush \(UUID().uuidString.prefix(8))"
        app.typeKey("n", modifierFlags: .command)
        let titleEditor = library.descendants(matching: .any)["SnippetTitleEditor"]
        let bodyEditor = library.textViews["SnippetBodyTextView"]
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
        let section = sidebarRow("All Snippets", in: app)
        XCTAssertTrue(section.waitForExistence(timeout: 5), app.debugDescription)
        section.click()
    }

    /// A Recently Deleted row's line under its title, "Deleted … · Clip" or "Deleted … · Snippet".
    private func deletedLine(endingWith facet: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@",
                                             "Deleted ", " · \(facet)")).firstMatch
    }

    /// A context menu's item. The Item menu in the menu bar repeats some of their titles; its items carry identifiers
    /// starting with "ItemMenu-".
    private func contextMenuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "title == %@ AND NOT (identifier BEGINSWITH %@)",
                                           title, "ItemMenu-")).firstMatch
    }

    /// The window's title ends with the list's name once the list shows.
    private func waitForList(_ name: String, in app: XCUIApplication) {
        expectation(for: NSPredicate(format: "title ENDSWITH %@", name),
                    evaluatedWith: app.windows["KeeptideLibraryWindow"])
        waitForExpectations(timeout: 8)
    }

    private func waitUntil(_ element: XCUIElement, isEnabled: Bool) {
        expectation(for: NSPredicate(format: "enabled == %@", NSNumber(value: isEnabled)), evaluatedWith: element)
        waitForExpectations(timeout: 8)
    }

    /// A list in the sidebar. The window's subtitle repeats the chosen list's name, so the sidebar is named.
    private func sidebarRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.windows["KeeptideLibraryWindow"].descendants(matching: .outline)["LibrarySidebar"].staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", name, name))
            .firstMatch
    }

    private func searchLibrary(for query: String, in app: XCUIApplication) {
        app.typeKey("f", modifierFlags: [.command, .shift])
        let field = librarySearchField(in: app.windows["KeeptideLibraryWindow"])
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: field, with: query)
    }

    /// The system search field in the toolbar. Its prompt names the list, unlike the editor's find bar ("Find").
    private func librarySearchField(in library: XCUIElement) -> XCUIElement {
        library.searchFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Search")).firstMatch
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        element.click()
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "The intended native editor must own keyboard input before replacing text.")
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
