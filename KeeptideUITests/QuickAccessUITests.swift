import AppKit
import XCTest

/// Quick access against an isolated test session seeded with synthetic clips.
/// Every pasteboard involved is the session's named pasteboard.
///
/// The seeded clips, newest first: "Synthetic alpha note", "echo synthetic-beta" (stored with a trailing
/// newline), a shell snippet, a Chinese note, a link, rich text and, oldest, an image. The strip opens on
/// the newest, which is selected and leftmost, with the older clips on its right. Above the clips, the band's
/// toolbar holds the search, folded to its icon until it is wanted, and the filters.
@MainActor
final class QuickAccessUITests: XCTestCase {
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

    func testRecentClipsAppearNewestFirst() throws {
        let app = launchKeeptide()
        let frames = try openPanel(app)
        let newest = clip("Synthetic alpha note", in: frames)
        let older = clip("echo synthetic-beta", in: frames)

        XCTAssertTrue(newest.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(older.waitForExistence(timeout: 5), app.debugDescription)
        // The lists open on All at the left, with no collections shown; at the right the filter button and the search,
        // folded to its icon, all above the clips.
        let lists = app.descendants(matching: .any)["QuickAccessListNavigation"]
        XCTAssertTrue(lists.exists, app.debugDescription)
        XCTAssertTrue(app.radioButtons["All"].exists, app.debugDescription)
        XCTAssertTrue(app.radioButtons["Snippets"].exists, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["QuickAccessCollectionChips"].exists, app.debugDescription)
        let filter = app.descendants(matching: .any)["QuickAccessFilterButton"]
        XCTAssertTrue(filter.exists, app.debugDescription)
        let search = app.buttons["QuickAccessSearchButton"]
        XCTAssertTrue(search.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["Clear search"].exists)
        XCTAssertLessThan(lists.frame.maxX, filter.frame.minX, app.debugDescription)
        XCTAssertLessThan(filter.frame.maxX, search.frame.minX, app.debugDescription)
        XCTAssertLessThan(search.frame.maxY, newest.frame.minY, app.debugDescription)
        // The newest clip is the leftmost frame and the next older clip the frame on its right. That the newest is
        // the one selected shows in what Return copies.
        let lefts = frames.allElementsBoundByIndex.map(\.frame.minX)
        XCTAssertEqual(newest.frame.minX, lefts.min() ?? .infinity, accuracy: 1, app.debugDescription)
        XCTAssertTrue(isRightNeighbour(older, of: newest), app.debugDescription)
    }

    func testDownDoesNotSkipTheFirstRowAndUpReturnsToSearch() throws {
        let app = launchKeeptide()
        let frames = try openPanel(app)
        let query = app.searchFields["Quick access query"]
        let newest = clip("Synthetic alpha note", in: frames)
        XCTAssertTrue(newest.waitForExistence(timeout: 5), app.debugDescription)

        // ↓ goes into the strip and leaves the newest clip selected instead of stepping past it. Nothing else here
        // shows the selection, so the frames' own selected state is read where the system reports it.
        query.typeKey(.downArrow, modifierFlags: [])
        if let selected = selectedClip(in: frames) {
            XCTAssertEqual(selected.label, newest.label, app.debugDescription)
        } else {
            XCTContext.runActivity(named: "AXSelected not reported; selection check skipped") { _ in }
        }

        app.typeKey(.upArrow, modifierFlags: [])
        app.typeText("x")
        XCTAssertEqual(query.value as? String, "x")
    }

    func testDownThenReturnCopiesTheNewestClip() throws {
        let (app, host) = launchKeeptideWithHost()
        let frames = try openPanel(app)
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForExistence(timeout: 5), app.debugDescription)

        // ↓ never steps past the newest clip. Return copies the selected clip, so what it copies shows which clip ↓
        // left selected, whether or not the system reports the frames' selected state.
        app.searchFields["Quick access query"].typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let toast = app.descendants(matching: .any)["CopyToastMessage"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].waitForNonExistence(timeout: 5))

        XCTAssertEqual(copiedText(host: host), "Synthetic alpha note")
    }

    func testTypingSearchesAllContent() throws {
        let app = launchKeeptide()
        let frames = try openPanel(app)
        let unrelated = clip("Synthetic alpha note", in: frames)
        XCTAssertTrue(unrelated.waitForExistence(timeout: 5), app.debugDescription)

        app.searchFields["Quick access query"].typeText("beta")

        // Only what matches stays in the strip: the other recent clip leaves and the match remains. Typing opened the
        // search, which can now be cleared with the pointer.
        XCTAssertTrue(unrelated.waitForNonExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(clip("echo synthetic-beta", in: frames).exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Clear search"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["QuickAccessSearchButton"].exists, app.debugDescription)
    }

    func testSpaceOpensPreviewAndEscapeClosesOneLayerAtATime() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)
        let panel = app.dialogs["KeeptideQuickAccessPanel"]
        let query = app.searchFields["Quick access query"]
        let preview = app.descendants(matching: .any)["QuickAccessPreview"]

        query.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.exists)

        // The search is folded to its icon; a click on it opens the search with the keys in its field.
        app.buttons["Search Clips and Snippets"].click()
        XCTAssertTrue(app.buttons["Search Clips and Snippets"].waitForNonExistence(timeout: 5), app.debugDescription)
        query.typeText("x")
        query.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(query.value as? String, "")
        XCTAssertTrue(panel.exists)
        // Clearing the query folded the search again.
        XCTAssertTrue(app.buttons["Search Clips and Snippets"].exists, app.debugDescription)

        query.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }

    func testPreviewOverlaysTheStationaryStripAndItsCloseButtonDismissesOnlyThePreview() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)
        let panel = app.dialogs["KeeptideQuickAccessPanel"]
        let strip = stripElement(in: app)
        let stripBeforePreview = strip.frame
        let preview = app.descendants(matching: .any)["QuickAccessPreview"]
        let closePreview = app.buttons["CloseQuickAccessPreview"]

        app.searchFields["Quick access query"].typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])

        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(closePreview.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(waitUntilHittable(closePreview), app.debugDescription)
        XCTAssertEqual(strip.frame.minX, stripBeforePreview.minX, accuracy: 1, app.debugDescription)
        XCTAssertEqual(strip.frame.minY, stripBeforePreview.minY, accuracy: 1, app.debugDescription)
        XCTAssertEqual(strip.frame.width, stripBeforePreview.width, accuracy: 1, app.debugDescription)
        XCTAssertEqual(strip.frame.height, stripBeforePreview.height, accuracy: 1, app.debugDescription)
        XCTAssertEqual(preview.frame.midX, strip.frame.midX, accuracy: 2, app.debugDescription)
        XCTAssertTrue(preview.frame.intersects(strip.frame), app.debugDescription)

        closePreview.click()

        XCTAssertTrue(preview.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(panel.exists, app.debugDescription)
        XCTAssertEqual(strip.frame.minX, stripBeforePreview.minX, accuracy: 1, app.debugDescription)
        XCTAssertEqual(strip.frame.minY, stripBeforePreview.minY, accuracy: 1, app.debugDescription)
    }

    func testClickingTheBandDismissesPreviewWithoutActivatingTheControlBeneathIt() throws {
        let app = launchKeeptide()
        let frames = try openPanel(app)
        let panel = app.dialogs["KeeptideQuickAccessPanel"]
        let preview = app.descendants(matching: .any)["QuickAccessPreview"]
        let snippets = app.radioButtons["Snippets"]
        let query = app.searchFields["Quick access query"]
        let selectedBeforePreview = selectedClip(in: frames)?.label

        query.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)

        // The list switch at the band's top left is exposed beside the preview. The first click belongs to the preview
        // dismissal layer, so it must not also choose Snippets beneath it.
        let exposedMaxX = min(snippets.frame.maxX, preview.frame.minX)
        XCTAssertGreaterThan(exposedMaxX, snippets.frame.minX, app.debugDescription)
        let exposedX = (snippets.frame.minX + exposedMaxX) / 2
        snippets.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: exposedX - snippets.frame.minX, dy: snippets.frame.height / 2))
            .click()

        XCTAssertTrue(preview.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(panel.exists, app.debugDescription)
        XCTAssertEqual(snippets.value as? Int, 0, app.debugDescription)
        XCTAssertEqual(query.value as? String, "", app.debugDescription)
        if let selectedBeforePreview, let selectedAfterPreview = selectedClip(in: frames)?.label {
            XCTAssertEqual(selectedAfterPreview, selectedBeforePreview, app.debugDescription)
        }
    }

    func testEscapeFromInsidePreviewDismissesItBeforeClosingThePanel() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)
        let panel = app.dialogs["KeeptideQuickAccessPanel"]
        let preview = app.descendants(matching: .any)["QuickAccessPreview"]

        app.searchFields["Quick access query"].typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 5), app.debugDescription)

        XCTAssertTrue(waitUntilHittable(preview), app.debugDescription)
        preview.click()
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(preview.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(panel.exists, app.debugDescription)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    func testReturnWithNoResultsDoesNothing() throws {
        let app = launchKeeptide()
        _ = try openPanel(app)
        let query = app.searchFields["Quick access query"]

        query.typeText("zzzz-no-match")
        // In the card area, where the clips would be; the toolbar's status is another element.
        let status = app.descendants(matching: .any)["QuickAccessEmptyState"]
        let noResults = NSPredicate(format: "label == %@ OR value == %@", "No results", "No results")
        expectation(for: noResults, evaluatedWith: status)
        waitForExpectations(timeout: 8)

        query.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].exists)
    }

    func testReturnCopiesTheFirstRowClosesThePanelAndShowsTheToast() throws {
        let (app, host) = launchKeeptideWithHost()
        _ = try openPanel(app)

        app.searchFields["Quick access query"].typeKey(.return, modifierFlags: [])

        // UI-test builds keep the toast up for four seconds so a polling wait can see it.
        let toast = app.descendants(matching: .any)["CopyToastMessage"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(text(of: toast), "Copied — press ⌘V to paste")
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].waitForNonExistence(timeout: 5))

        XCTAssertEqual(copiedText(host: host), "Synthetic alpha note")
    }

    func testArrowKeysStepTheStripAndReturnCopiesTheSelectedClip() throws {
        let (app, host) = launchKeeptideWithHost()
        let frames = try openPanel(app)
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(clip("echo synthetic-beta", in: frames).waitForExistence(timeout: 5), app.debugDescription)

        // Nothing is newer than the newest clip, so ← leaves the selection on it; → steps one clip older. Return
        // copies the selected clip, wherever the keys are, so what it copies shows where the steps went.
        app.searchFields["Quick access query"].typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let toast = app.descendants(matching: .any)["CopyToastMessage"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].waitForNonExistence(timeout: 5))

        // The seeded clip ends with a newline.
        XCTAssertEqual(copiedText(host: host)?.trimmingCharacters(in: .whitespacesAndNewlines), "echo synthetic-beta")
    }

    func testShiftReturnOnTheImageRowShowsTheReason() throws {
        let (app, host) = launchKeeptideWithHost()
        let frames = try openPanel(app)
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForExistence(timeout: 5), app.debugDescription)

        // The image is the oldest of the seven seeded clips, at the right end. A screen too narrow for all seven makes
        // its card only as the strip comes near it. ↓ puts the keys in the strip, and each → selects the next older
        // clip; at the oldest one → does nothing more. The reason Shift-Return gives shows that the image is the clip
        // selected.
        app.searchFields["Quick access query"].typeKey(.downArrow, modifierFlags: [])
        for _ in 0..<7 { app.typeKey(.rightArrow, modifierFlags: []) }
        XCTAssertTrue(clip("Copied content", in: frames).waitForExistence(timeout: 5), app.debugDescription)

        app.typeKey(.return, modifierFlags: .shift)

        let failure = app.descendants(matching: .any)["QuickAccessFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(text(of: failure), "This item has no plain text.")
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].exists)
        host.activate()
        host.buttons["Inspect Synthetic Pasteboard"].click()
        XCTAssertEqual(text(of: host.staticTexts["Synthetic host status"]), "No synthetic payload received")
    }

    // MARK: - Lists

    func testClickingSnippetsShowsSnippetsAndCollections() throws {
        let app = launchKeeptide(seedsSnippets: true)
        let frames = try openPanel(app)
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.radioButtons["Prompts"].exists, "No collections under All\n\(app.debugDescription)")

        // Snippets lists the snippets, and the collections appear beside the switch.
        app.radioButtons["Snippets"].click()
        let meeting = clip("Summarize meeting notes", in: frames)
        XCTAssertTrue(meeting.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(clip("Release checklist", in: frames).exists, app.debugDescription)
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.radioButtons["Prompts"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.radioButtons["Shell"].exists, app.debugDescription)

        // A collection narrows them to its own.
        app.radioButtons["Prompts"].click()
        XCTAssertTrue(clip("Release checklist", in: frames).waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(meeting.exists, app.debugDescription)
    }

    func testCommandBracketSwitchesLists() throws {
        let app = launchKeeptide(seedsSnippets: true)
        let frames = try openPanel(app)
        let query = app.searchFields["Quick access query"]
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForExistence(timeout: 5), app.debugDescription)

        // ⌘] steps to Snippets and then to the first collection; ⌘[ steps back to All.
        query.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(clip("Release checklist", in: frames).waitForExistence(timeout: 5), app.debugDescription)
        query.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(clip("Release checklist", in: frames).waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(clip("Summarize meeting notes", in: frames).exists, app.debugDescription)
        query.typeKey("[", modifierFlags: .command)
        query.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForExistence(timeout: 5), app.debugDescription)
    }

    func testFavoritesOnlyLivesInTheFilterMenu() throws {
        let app = launchKeeptide(seedsSnippets: true)
        let frames = try openPanel(app)
        XCTAssertTrue(clip("Synthetic alpha note", in: frames).waitForExistence(timeout: 5), app.debugDescription)

        // Favorites Only, from the filter button's menu, lists the favorite snippets, and the switch moves to Snippets.
        let filter = app.descendants(matching: .any)["QuickAccessFilterButton"]
        filter.click()
        let favorites = app.menuItems["Favorites Only"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5), app.debugDescription)
        favorites.click()
        XCTAssertTrue(clip("List open ports", in: frames).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(clip("Release checklist", in: frames).waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(filter.value as? String, "Favorites", app.debugDescription)
    }

    // MARK: - Helpers

    /// Launches the test host first, so the panel opens last and keeps keyboard focus.
    private func launchKeeptideWithHost() -> (XCUIApplication, XCUIApplication) {
        let sessionID = UUID()
        let host = launchSystemTestHost(sessionID: sessionID)
        return (launchKeeptide(sessionID: sessionID), host)
    }

    private func launchKeeptide(sessionID: UUID = UUID(), seedsSnippets: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--disable-global-hotkey", "--show-quick-access",
                               "--capture-test-session", sessionID.uuidString, "--seed-synthetic-clips"]
            + (seedsSnippets ? ["--seed-synthetic-snippets"] : [])
        self.sessionID = sessionID
        application = app
        app.launch()
        return app
    }

    private func launchSystemTestHost(sessionID: UUID) -> XCUIApplication {
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("KeeptideSystemTestHost.app")
        let host = XCUIApplication(url: hostURL)
        host.launchArguments = ["--capture-test-session", sessionID.uuidString]
        self.host = host
        host.launch()
        return host
    }

    /// Waits for the panel `--show-quick-access` opened and for the frames of its seeded clips, which it
    /// returns. The status menu path is covered by NativeShellUITests.
    @discardableResult
    func openPanel(_ app: XCUIApplication) throws -> XCUIElementQuery {
        XCTAssertTrue(app.dialogs["KeeptideQuickAccessPanel"].waitForExistence(timeout: 8), app.debugDescription)
        let strip = stripElement(in: app)
        XCTAssertTrue(strip.waitForExistence(timeout: 10), app.debugDescription)
        let frames = strip.descendants(matching: .any)
        XCTAssertTrue(frames.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        return frames
    }

    private func stripElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["QuickAccessStrip"]
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }

    /// The frame of the clip with this title. A frame is labelled "<Kind>, <time>, from <App>, <footer>: <title>",
    /// with the clip's marks after the title when it has any, so the title is matched inside the label.
    private func clip(_ title: String, in frames: XCUIElementQuery) -> XCUIElement {
        frames.matching(NSPredicate(format: "label CONTAINS %@", ": \(title)")).firstMatch
    }

    /// The frame that reports itself selected, or nil where none does, as on a system that does not report the
    /// frames' selected state. The selected clip is not always in the middle, so where it is cannot tell.
    private func selectedClip(in frames: XCUIElementQuery) -> XCUIElement? {
        let selected = frames.matching(NSPredicate(format: "selected == true")).firstMatch
        return selected.waitForExistence(timeout: 2) ? selected : nil
    }

    /// Whether `clip` is the frame directly to the right of `other`: it starts after `other` ends, with less
    /// than a frame's width between them, since a gap that wide would hold another clip.
    private func isRightNeighbour(_ clip: XCUIElement, of other: XCUIElement) -> Bool {
        guard clip.exists, other.exists else { return false }
        let gap = clip.frame.minX - other.frame.maxX
        return gap >= 0 && gap < other.frame.width
    }

    /// The text the session's pasteboard received, as the test host shows it when asked to inspect it.
    private func copiedText(host: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String? {
        host.activate()
        host.buttons["Inspect Synthetic Pasteboard"].click()
        let received = host.descendants(matching: .any)["ReceivedSyntheticText"]
        XCTAssertTrue(received.waitForExistence(timeout: 5), host.debugDescription, file: file, line: line)
        return received.value as? String
    }

    func text(of element: XCUIElement) -> String {
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
