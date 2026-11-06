import XCTest

@MainActor
final class CollectionUITests: XCTestCase {
    private var application: XCUIApplication?
    private var sessionID: UUID?

    override func tearDown() async throws {
        if let application, let sessionID {
            removeTestSession(sessionID, app: application)
        } else {
            application?.terminate()
        }
        application = nil
        sessionID = nil
        try await super.tearDown()
    }

    func testCollectionCanBeCreatedRenamedDeletedAndUndone() {
        let app = launchKeeptide()
        let library = requireLibrary(in: app)
        let name = "开发命令与超长中文提示词资料库"

        createCollection(named: name, in: app, withPlusButton: true)
        let row = collectionRow(named: name, in: library)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)

        row.rightClick()
        app.menuItems["Rename Collection"].click()
        let nameField = app.textFields["CollectionNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: nameField, with: "常用开发资料")
        app.buttons["CollectionSaveButton"].click()
        let renamed = collectionRow(named: "常用开发资料", in: library)
        XCTAssertTrue(renamed.waitForExistence(timeout: 5), app.debugDescription)

        renamed.rightClick()
        app.menuItems["Delete Collection"].click()
        let confirm = app.sheets.buttons["Delete Collection"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.click()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 5), app.debugDescription)

        let undo = app.buttons["UndoCollectionChange"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), app.debugDescription)
        undo.click()
        XCTAssertTrue(collectionRow(named: "常用开发资料", in: library).waitForExistence(timeout: 5),
                      app.debugDescription)
    }

    func testTwentyLongCollectionsRemainAvailableFromScopeMenu() {
        let app = launchKeeptide()
        let library = requireLibrary(in: app)
        let names = (1...20).map { "Group \($0) — 很长的中文名称用于验证完整筛选" }
        for name in names { createCollection(named: name, in: app) }
        XCTAssertTrue(collectionRow(named: names.last!, in: library).waitForExistence(timeout: 5),
                      app.debugDescription)

        // While the sidebar shows, lists are chosen there and the toolbar has no scope menu.
        let scopeMenu = app.descendants(matching: .menuButton)["LibraryScopeMenu"]
        XCTAssertFalse(scopeMenu.exists, app.debugDescription)

        attachScreenshot(of: library, named: "Sidebar with twenty collections")

        // With the sidebar hidden, the scope menu lists every collection, and its label names the one chosen in full.
        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(scopeMenu.waitForExistence(timeout: 5), app.debugDescription)
        scopeMenu.click()
        XCTAssertTrue(app.menuItems[names.last!].waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(of: app.windows.firstMatch, named: "Scope menu with the sidebar hidden")
        app.menuItems[names.last!].click()
        expectation(for: NSPredicate(format: "label == %@", "Library Scope: \(names.last!)"), evaluatedWith: scopeMenu)
        waitForExpectations(timeout: 8)
    }

    func testListsCanBeChosenFromTheKeyboard() {
        let app = launchKeeptide()
        let library = requireLibrary(in: app)

        // ⌘] and ⌘[ step through the sidebar's lists.
        app.typeKey("]", modifierFlags: .command)
        waitForScope("All Snippets", in: app)
        app.typeKey("[", modifierFlags: .command)
        waitForScope("Recent Clips", in: app)

        // ⌘L puts the keyboard on the sidebar, where the arrow keys choose.
        app.typeKey("l", modifierFlags: .command)
        let sidebar = library.descendants(matching: .outline)["LibrarySidebar"]
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: sidebar)
        waitForExpectations(timeout: 5)
        app.typeKey(.downArrow, modifierFlags: [])
        waitForScope("All Snippets", in: app)

        // With the sidebar hidden, ⌘L opens the scope menu instead.
        app.typeKey("s", modifierFlags: [.control, .command])
        let scopeMenu = app.descendants(matching: .menuButton)["LibraryScopeMenu"]
        XCTAssertTrue(scopeMenu.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("l", modifierFlags: .command)
        let recentlyDeleted = app.menuItems["Recently Deleted"]
        XCTAssertTrue(recentlyDeleted.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(of: library, named: "Choose List with the sidebar hidden")
        recentlyDeleted.click()
        waitForScope("Recently Deleted", in: app)
    }

    func testImmediateNewUsesTheCollectionSelectedFromTheSidebar() {
        let app = launchKeeptide()
        let library = requireLibrary(in: app)
        let collectionName = "Immediate Scope"
        let snippetTitle = "Scoped Immediately"
        createCollection(named: collectionName, in: app)

        collectionRow(named: collectionName, in: library).click()
        waitForScope(collectionName, in: app)
        app.typeKey("n", modifierFlags: .command)

        let titleField = app.textFields["SnippetTitleEditor"]
        let bodyEditor = app.textViews["SnippetBodyTextView"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        let initialFocus = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: bodyEditor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [initialFocus], timeout: 5), .completed,
                       "A new snippet must accept typing without an extra click.")
        bodyEditor.typeText("created before collection results finish loading")
        replaceText(in: titleField, with: snippetTitle)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Saved"].firstMatch.waitForExistence(timeout: 8),
                      app.debugDescription)
        XCTAssertTrue(snippetRow(containing: snippetTitle, in: app).waitForExistence(timeout: 8),
                      app.debugDescription)

        scopeRow(named: "Unfiled", in: library).click()
        waitForScope("Unfiled", in: app)
        XCTAssertTrue(snippetRow(containing: snippetTitle, in: app).waitForNonExistence(timeout: 8),
                      app.debugDescription)
    }

    func testMultiSelectionCanMoveAndFavoriteOnlySelectedRows() {
        let app = launchKeeptide()
        let library = requireLibrary(in: app)
        createCollection(named: "Prompts", in: app)
        createSnippet(title: "Selected Alpha", body: "alpha body", in: app)
        createSnippet(title: "Selected Beta", body: "beta body", in: app)
        createSnippet(title: "Unselected Gamma", body: "gamma body", in: app)

        scopeRow(named: "All Snippets", in: library).click()
        waitForScope("All Snippets", in: app)
        let alpha = snippetRow(containing: "Selected Alpha", in: app)
        let beta = snippetRow(containing: "Selected Beta", in: app)
        XCTAssertTrue(alpha.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(beta.waitForExistence(timeout: 5), app.debugDescription)
        alpha.click()
        XCUIElement.perform(withKeyModifiers: [.command]) { beta.click() }

        let actions = app.descendants(matching: .menuButton)["SelectionActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5), app.debugDescription)
        actions.click()
        app.menuItems["Add to Favorites"].click()

        openSelectionActions(actions, expecting: "Remove from Favorites", in: app)
        let moveTo = app.menuItems["Move To"]
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5), app.debugDescription)
        moveTo.click()
        let prompts = app.menuItems["Move to Prompts"]
        XCTAssertTrue(prompts.waitForExistence(timeout: 5), app.debugDescription)
        prompts.click()
        collectionRow(named: "Prompts", in: library).click()
        waitForScope("Prompts", in: app)
        XCTAssertTrue(snippetRow(containing: "Selected Alpha", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(snippetRow(containing: "Selected Beta", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(snippetRow(containing: "Unselected Gamma", in: app).waitForNonExistence(timeout: 8))

        scopeRow(named: "Favorites", in: library).click()
        waitForScope("Favorites", in: app)
        XCTAssertTrue(snippetRow(containing: "Selected Alpha", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(snippetRow(containing: "Selected Beta", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(snippetRow(containing: "Unselected Gamma", in: app).waitForNonExistence(timeout: 8))
    }

    private func launchKeeptide() -> XCUIApplication {
        let app = XCUIApplication()
        let sessionID = UUID()
        app.launchArguments = [
            "--ui-testing", "--disable-global-hotkey", "--show-library",
            "--capture-test-session", sessionID.uuidString,
        ]
        self.sessionID = sessionID
        application = app
        app.launch()
        return app
    }

    @discardableResult
    private func requireLibrary(in app: XCUIApplication) -> XCUIElement {
        app.activate()
        let library = app.windows["KeeptideLibraryWindow"]
        XCTAssertTrue(library.waitForExistence(timeout: 8), app.debugDescription)
        let newSnippet = library.buttons["NewSnippet"]
        XCTAssertTrue(newSnippet.waitForExistence(timeout: 8), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: newSnippet)
        waitForExpectations(timeout: 8)
        return library
    }

    /// File › New Collection… (⇧⌘N), or the plus on the Collections heading.
    private func createCollection(named name: String, in app: XCUIApplication, withPlusButton: Bool = false) {
        if withPlusButton {
            let add = app.buttons["AddCollection"]
            if add.waitForExistence(timeout: 2) {
                add.click()
            } else {
                // macOS 26 reads the heading as one text that holds the plus, drawn at its trailing end.
                let heading = app.staticTexts["AddCollection"]
                XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
                heading.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).click()
            }
        } else {
            app.typeKey("n", modifierFlags: [.shift, .command])
        }
        let field = app.textFields["CollectionNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: field, with: name)
        app.buttons["CollectionSaveButton"].click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    private func createSnippet(title: String, body: String, in app: XCUIApplication) {
        app.buttons["NewSnippet"].click()
        let titleField = app.textFields["SnippetTitleEditor"]
        let bodyEditor = app.textViews["SnippetBodyTextView"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: titleField, with: title)
        replaceText(in: bodyEditor, with: body)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Saved"].firstMatch.waitForExistence(timeout: 8),
                      app.debugDescription)
    }

    /// Keeps a picture of `element` with the test's results, whether or not it passes.
    private func attachScreenshot(of element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        element.click()
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "The intended native field must own keyboard input before replacing text.")
        element.typeKey("a", modifierFlags: .command)
        element.typeText(value)
    }

    private func collectionRow(named name: String, in library: XCUIElement) -> XCUIElement {
        // macOS exposes sidebar List entries as OutlineRows with an inner
        // StaticText; the row itself has no label on the supported OS.
        library.descendants(matching: .outline)["LibrarySidebar"].staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", name, name))
            .firstMatch
    }

    private func scopeRow(named name: String, in library: XCUIElement) -> XCUIElement {
        // macOS exposes sidebar List entries as OutlineRows with an inner
        // StaticText; the row itself has no label on the supported OS.
        library.descendants(matching: .outline)["LibrarySidebar"].staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", name, name))
            .firstMatch
    }

    private func snippetRow(containing title: String, in app: XCUIApplication) -> XCUIElement {
        let list = app.descendants(matching: .any)["SnippetList"]
        let exactTitle = NSPredicate(format: "label == %@ OR value == %@", title, title)
        return list.staticTexts
            .matching(identifier: "LibraryEntryRow")
            .matching(exactTitle)
            .firstMatch
    }

    /// The window's subtitle names the list, and the window's title reads "Keeptide Library – <list>". Names
    /// longer than 15 characters are shortened there, so a test waits on short names only.
    private func waitForScope(_ name: String, in app: XCUIApplication) {
        let library = app.windows["KeeptideLibraryWindow"]
        expectation(for: NSPredicate(format: "title ENDSWITH %@", name), evaluatedWith: library)
        waitForExpectations(timeout: 8)
    }

    private func openSelectionActions(
        _ actions: XCUIElement,
        expecting itemName: String,
        in app: XCUIApplication
    ) {
        let expectedItem = app.menuItems[itemName]
        let deadline = Date().addingTimeInterval(8)
        repeat {
            guard actions.waitForExistence(timeout: 1) else { continue }
            actions.click()
            if expectedItem.waitForExistence(timeout: 1) { return }
            app.typeKey(.escape, modifierFlags: [])
        } while Date() < deadline

        XCTFail("Selection actions never reflected \(itemName). \(app.debugDescription)")
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
