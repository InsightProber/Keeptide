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

        createCollection(named: name, in: app)
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
        let confirm = app.buttons["Delete Collection"].firstMatch
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
        let names = (1...20).map { "分类 \($0) — 很长的中文分类名称用于验证完整筛选" }
        for name in names { createCollection(named: name, in: app) }

        let filter = app.textFields["CollectionFilterField"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: filter, with: "分类 20")
        XCTAssertTrue(collectionRow(named: names.last!, in: library).waitForExistence(timeout: 5),
                      app.debugDescription)
        XCTAssertFalse(collectionRow(named: names.first!, in: library).exists)

        let scopeMenu = app.descendants(matching: .menuButton)["LibraryScopeMenu"]
        XCTAssertTrue(scopeMenu.waitForExistence(timeout: 5), app.debugDescription)
        scopeMenu.click()
        XCTAssertTrue(app.menuItems[names.last!].waitForExistence(timeout: 5), app.debugDescription)
        app.menuItems[names.last!].click()
        XCTAssertTrue(collectionRow(named: names.last!, in: library).waitForExistence(timeout: 5),
                      app.debugDescription)
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
        replaceText(in: bodyEditor, with: "created before collection results finish loading")
        replaceText(in: titleField, with: snippetTitle)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Saved"].firstMatch.waitForExistence(timeout: 8),
                      app.debugDescription)
        XCTAssertTrue(snippetRow(containing: snippetTitle, in: app).waitForExistence(timeout: 8),
                      app.debugDescription)

        scopeRow(named: "Uncategorized", in: library).click()
        waitForScope("Uncategorized", in: app)
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

        let actions = app.buttons["SelectionActions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5), app.debugDescription)
        actions.click()
        app.menuItems["Add to Favorites"].click()

        actions.click()
        app.menuItems["Move To"].click()
        app.menuItems["Move to Prompts"].click()
        app.descendants(matching: .menuButton)["LibraryScopeMenu"].click()
        app.menuItems["Prompts"].click()
        waitForScope("Prompts", in: app)
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

    private func createCollection(named name: String, in app: XCUIApplication) {
        let add = app.buttons["AddCollection"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.click()
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

    private func waitForScope(_ name: String, in app: XCUIApplication) {
        let menu = app.descendants(matching: .menuButton)["LibraryScopeMenu"]
        let selected = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", name, name
        )
        expectation(for: selected, evaluatedWith: menu)
        waitForExpectations(timeout: 8)
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
