import XCTest

/// Markdown reading workflows backed only by an isolated synthetic store.
@MainActor
final class PreviewUITests: XCTestCase {
    private var sessionID: UUID?
    private var application: XCUIApplication?

    override func tearDown() async throws {
        if let sessionID, let application {
            removeTestSession(sessionID, app: application)
        } else {
            application?.terminate()
        }
        self.sessionID = nil
        application = nil
        try await super.tearDown()
    }

    func testMarkdownSourcePreviewRoundTripPreservesExactBodyAndRefreshesEdits() {
        continueAfterFailure = false
        let app = launchKeeptide()
        let library = requireLibrary(in: app)
        app.typeKey("n", modifierFlags: .command)

        chooseKind("Markdown", in: library)
        let source = "# Preview heading\n- [ ] review before running\n[safe link](https://example.com)\n![remote image](https://example.com/image.png)"
        let bodyEditor = library.textViews["SnippetBodyTextView"]
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        replaceText(in: bodyEditor, with: source)

        modeControl("MarkdownModePreview", in: library).click()
        let preview = library.descendants(matching: .any)["MarkdownPreviewReadingView"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Preview heading"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["review before running"].waitForExistence(timeout: 5), app.debugDescription)
        // Both lines belong to one Markdown paragraph and one native Text.
        // Assert its actual accessible text rather than requiring separate nodes.
        let paragraph = "safe link\n![remote image](https://example.com/image.png)"
        XCTAssertTrue(app.staticTexts[paragraph].firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        modeControl("MarkdownModeSource", in: library).click()
        XCTAssertTrue(bodyEditor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(bodyEditor.value as? String, source)

        let updated = "## Updated preview\n- [x] kept exact source"
        replaceText(in: bodyEditor, with: updated)
        modeControl("MarkdownModePreview", in: library).click()
        XCTAssertTrue(app.staticTexts["Updated preview"].waitForExistence(timeout: 8), app.debugDescription)
        modeControl("MarkdownModeSource", in: library).click()
        XCTAssertEqual(bodyEditor.value as? String, updated)
    }

    func testPromptAndPlainTextNeverExposeMarkdownPreviewMode() {
        continueAfterFailure = false
        let app = launchKeeptide()
        let library = requireLibrary(in: app)
        app.typeKey("n", modifierFlags: .command)

        XCTAssertFalse(library.descendants(matching: .any)["MarkdownModePicker"].exists)
        chooseKind("Prompt", in: library)
        XCTAssertFalse(library.descendants(matching: .any)["MarkdownModePicker"].exists)
        chooseKind("Code", in: library)
        XCTAssertFalse(library.descendants(matching: .any)["MarkdownModePicker"].exists)
        chooseKind("Markdown", in: library)
        XCTAssertTrue(
            library.descendants(matching: .any)["MarkdownModePicker"].waitForExistence(timeout: 5),
            app.debugDescription
        )
    }

    func testRecentURLAndImageUseSharedTypedPreview() {
        continueAfterFailure = false
        let app = launchKeeptide(seedSyntheticClips: true)
        let library = requireLibrary(in: app)

        let urlClip = app.staticTexts["https://example.com/synthetic"].firstMatch
        XCTAssertTrue(urlClip.waitForExistence(timeout: 8), app.debugDescription)
        urlClip.click()
        XCTAssertTrue(library.buttons["Open Link"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(
            library.descendants(matching: .any)["LibraryContentPreview"].waitForExistence(timeout: 5),
            app.debugDescription
        )

        let imageClip = app.staticTexts["Copied content"].firstMatch
        XCTAssertTrue(imageClip.waitForExistence(timeout: 8), app.debugDescription)
        imageClip.click()
        XCTAssertTrue(library.descendants(matching: .any)["Image scale"].waitForExistence(timeout: 8),
                      app.debugDescription)
        XCTAssertTrue(
            library.descendants(matching: .any)["LibraryContentPreview"].waitForExistence(timeout: 5),
            app.debugDescription
        )
    }

    func testSavedURLLeavesTypedPreviewAndBecomesExactEditableSource() {
        continueAfterFailure = false
        let app = launchKeeptide(seedSyntheticClips: true)
        let library = requireLibrary(in: app)

        let address = "https://example.com/synthetic"
        let urlClip = app.staticTexts[address].firstMatch
        XCTAssertTrue(urlClip.waitForExistence(timeout: 8), app.debugDescription)
        urlClip.click()
        XCTAssertTrue(library.buttons["Open Link"].waitForExistence(timeout: 8), app.debugDescription)

        let save = library.buttons["SaveHistoryAsSnippet"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        save.click()

        let editor = library.textViews["SnippetBodyTextView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(editor.value as? String, address)
        XCTAssertFalse(library.buttons["Open Link"].exists)
    }

    private func launchKeeptide(seedSyntheticClips: Bool = false) -> XCUIApplication {
        let sessionID = UUID()
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--disable-global-hotkey",
            "--show-library",
            "--capture-test-session",
            sessionID.uuidString,
        ]
        if seedSyntheticClips { app.launchArguments.append("--seed-synthetic-clips") }
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
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: newSnippet)
        waitForExpectations(timeout: 8)
        return library
    }

    private func chooseKind(_ kind: String, in library: XCUIElement) {
        let picker = library.popUpButtons["SnippetKindPicker"]
        // The type is chosen in the inspector, closed until View › Show Inspector opens it.
        if !picker.exists { library.typeKey("i", modifierFlags: [.control, .command]) }
        XCTAssertTrue(picker.waitForExistence(timeout: 5), library.debugDescription)
        picker.click()
        let item = picker.menuItems[kind]
        XCTAssertTrue(item.waitForExistence(timeout: 5), library.debugDescription)
        item.click()
    }

    private func modeControl(_ identifier: String, in library: XCUIElement) -> XCUIElement {
        let control = library.descendants(matching: .any)[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 5), library.debugDescription)
        return control
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        element.click()
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
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
