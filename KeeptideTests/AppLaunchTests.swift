import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import Keeptide

@MainActor
final class AppLaunchTests: XCTestCase {
    func testCaptureMenuDoesNotEnableRecordingBeforeItsStoreIsReady() throws {
        var toggled = false
        let controller = MenuBarController(showQuickAccess: {}, toggleQuickAccess: {}, showLibrary: {},
            captureIsReady: { false }, toggleCapture: { toggled = true }, shouldRegisterHotKey: false)
        let menu = try XCTUnwrap(controller.menu)
        menu.update()
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "CaptureRecordingToggleMenuItem" })
        XCTAssertFalse(item.isEnabled)
        XCTAssertFalse(toggled)
    }
    func testDefaultLibraryInitializerCreatesItsWindow() {
        XCTAssertNotNil(LibraryWindowController(session: CaptureSession()).window)
    }

    func testCaptureStartsDisabled() {
        let suiteName = "AppLaunchTests.captureStartsDisabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.captureEnabled)
    }

    func testQuickAccessDoesNotActivateTheApplicationOrHideAnUnfinishedSession() throws {
        let controller = PanelController()
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    func testTheWindowMenuCloseIsEnabledForThePanel() throws {
        let panel = try XCTUnwrap(PanelController().window)
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let close = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu?.item(withTitle: "Close"))
        XCTAssertEqual(close.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(close.keyEquivalent, "w")

        // NSWindow disables Close for a window without a close button, and the borderless panel has none; ⌘W
        // would then only beep and leave the panel open.
        XCTAssertTrue(panel.validateMenuItem(close))
    }

    func testWindowGeometrySurvivesHostingLayout() throws {
        let panel = PanelController(preferences: try makePreferences(.nine))
        let library = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        settleLayout()
        let window = try XCTUnwrap(panel.window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        assertFrame(window.frame, places: panelFrame(on: screen, density: .nine))
        XCTAssertEqual(library.window?.contentView?.frame.size, NSSize(width: 1120, height: 740))
        XCTAssertEqual(library.window?.contentMinSize, NSSize(width: 840, height: 560))
        XCTAssertEqual(library.window?.title, "Keeptide Library")
    }

    func testEscapeCancelsOnlyTheMarkedSuffix() throws {
        let controller = PanelController()
        let (field, editor) = try searchEditor(in: controller)
        editor.insertText("committed ", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(editor.string, "committed ")
        XCTAssertEqual(field.stringValue, "committed ")
        XCTAssertFalse(editor.hasMarkedText())
    }

    func testEscapeClearNotifiesAndCanBeUndone() throws {
        let controller = PanelController()
        let (field, editor) = try searchEditor(in: controller)
        let undo = try XCTUnwrap(editor.undoManager)
        let groupsByEvent = undo.groupsByEvent
        defer { undo.groupsByEvent = groupsByEvent }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("restore me", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        editor.breakUndoCoalescing()
        undo.beginUndoGrouping()
        let changed = expectation(forNotification: NSControl.textDidChangeNotification, object: field)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(undo.groupingLevel, 1)
        if undo.groupingLevel > 0 { undo.endUndoGrouping() }
        wait(for: [changed], timeout: 1)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(field.stringValue, "restore me")
        undo.redo()
        XCTAssertEqual(field.stringValue, "")
    }

    func testTextChangesDuringCompositionDoNotSearch() throws {
        let controller = PanelController()
        let (field, editor) = try searchEditor(in: controller)
        let searchField = try XCTUnwrap(field as? QuickAccessSearchField)
        let reported = QueryLog()
        searchField.onQueryChange = { reported.queries.append($0) }

        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        // A real input method reports each composition change; a direct call does not.
        editor.didChangeText()
        settleLayout()
        XCTAssertEqual(reported.queries, [])

        editor.insertText("中", replacementRange: editor.markedRange())
        settleLayout()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(reported.queries, ["中"])
    }

    func testSearchFieldUsesTheMarkedTextAwareFieldEditor() throws {
        let controller = PanelController()
        let (_, editor) = try searchEditor(in: controller)
        XCTAssertTrue(editor is QuickAccessFieldEditor)
    }

    func testDownAndUpMoveBetweenSearchFiltersAndStrip() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let filters = try XCTUnwrap(views(QuickAccessFilterRow.self, in: window.contentView).first)
        let up = try key(kVK_UpArrow, "\u{F700}"), down = try key(kVK_DownArrow, "\u{F701}")

        // Without the filter row Down goes straight to the strip, and the newest clip stays selected.
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(window.firstResponder === strip)
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref,
                       "Down focuses the strip without skipping the first clip")
        strip.keyDown(with: up)
        XCTAssertTrue(isEditing(field, in: window))

        // Once the filter row shows, it lies between the two.
        controller.perform(.cycleFocus(forward: true))
        XCTAssertTrue(window.firstResponder === filters)
        filters.keyDown(with: up)
        XCTAssertTrue(isEditing(field, in: window))
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(window.firstResponder === filters)
        filters.keyDown(with: down)
        XCTAssertTrue(window.firstResponder === strip)
        strip.keyDown(with: up)
        XCTAssertTrue(window.firstResponder === filters)
        filters.keyDown(with: up)
        XCTAssertTrue(isEditing(field, in: window))
        controller.state.close()
    }

    func testBecomingKeyAgainKeepsFocusThatAnotherControlHolds() throws {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let field = QuickAccessSearchField()
        let strip = QuickAccessStripView()
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(strip)
        XCTAssertTrue(window.makeFirstResponder(strip))

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        XCTAssertTrue(window.firstResponder === strip)
    }

    func testTogglingThePreviewKeepsTypingInTheSearchField() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)

        controller.togglePreview()
        settleLayout()
        controller.togglePreview()
        settleLayout()

        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === field)
        controller.state.close()
    }

    func testOpeningThePreviewFromTheStripKeepsItFocused() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.focusResults)
        XCTAssertTrue(window.firstResponder is QuickAccessStripView)

        controller.perform(.togglePreview)
        settleLayout()

        XCTAssertTrue(window.firstResponder is QuickAccessStripView)
        controller.perform(.move(1))
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.last?.ref)
        controller.state.close()
    }

    func testThePreviewNeedsASelection() {
        let controller = PanelController()

        controller.togglePreview()

        XCTAssertFalse(controller.state.isPreviewExpanded)
    }

    func testUpFromTheStripKeepsTheQueryText() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha note", "beta note"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        editor.insertText("note", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "note" && controller.state.phase == .results
        }
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)
        let up = try key(kVK_UpArrow, "\u{F700}")

        // A query shows the filter row, so Up passes through it on the way back to the field.
        strip.keyDown(with: up)
        let filters = try XCTUnwrap(window.firstResponder as? QuickAccessFilterRow)
        filters.keyDown(with: up)

        let returned = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(returned.delegate === field)
        XCTAssertEqual(returned.string, "note")
        XCTAssertEqual(returned.selectedRange(), NSRange(location: 4, length: 0), "Typing continues the query")
        controller.state.close()
    }

    func testReturnCopiesTheRowSelectedWhenTheKeyWasPressed() async throws {
        let (controller, board) = try await makePanelWithClips(["older", "newer"])

        controller.perform(.primary)
        controller.state.moveSelection(by: 1)

        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "newer")
    }

    func testRepeatedKeyNotificationsPreserveTheExistingEditor() throws {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let field = QuickAccessSearchField()
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("prefix suffix", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let selection = editor.selectedRange()
        let marked = editor.markedRange()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(editor.string, "prefix suffix")
        XCTAssertFalse(editor.hasMarkedText())
    }

    func testPanelIsBorderlessTransparentAndFramesTheBand() throws {
        let controller = PanelController(preferences: try makePreferences(.nine))
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        // No frame, no background and no window shadow: the band draws its own shadow and fades out at its ends.
        XCTAssertEqual(panel.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        // Still a floating panel that takes the keys without activating Keeptide, and closes when it loses them.
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.identifier?.rawValue, "KeeptideQuickAccessPanel")
        XCTAssertEqual(panel.accessibilityIdentifier(), "KeeptideQuickAccessPanel")
        XCTAssertEqual(panel.title, "Keeptide Quick Access")
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.isSuperset(of: [.moveToActiveSpace, .fullScreenAuxiliary]))

        // The panel is the band and the room around it for the key hints and the shadow.
        panel.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let metrics = StripLayout.metrics(for: .nine, visibleWidth: screen.visibleFrame.width)
        let bandHeight = StripLayout.bandHeight(metrics, filtersVisible: false)
        XCTAssertEqual(panel.frame.width, metrics.bandWidth + 2 * StripLayout.sideMargin, accuracy: 1)
        XCTAssertEqual(panel.frame.height, bandHeight + 2 * StripLayout.shadowMargin, accuracy: 1)
        // The search row along its top, the strip across its whole width above the caption row.
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: panel.contentView).first)
        let stripFrame = strip.convert(strip.bounds, to: nil)
        XCTAssertEqual(stripFrame.width, metrics.bandWidth, accuracy: 1)
        XCTAssertEqual(stripFrame.midX, panel.frame.width / 2, accuracy: 1)
        XCTAssertEqual(stripFrame.midY, StripLayout.shadowMargin + StripLayout.captionHeight
                           + metrics.frameSize.height / 2, accuracy: 1)
        let field = try XCTUnwrap(views(QuickAccessSearchField.self, in: panel.contentView).first)
        XCTAssertEqual(field.convert(field.bounds, to: nil).midY,
                       StripLayout.shadowMargin + bandHeight - StripLayout.searchHeight / 2, accuracy: 1)
    }

    func testOpenStripDocksTheNewestClipAtTheLeftEnd() async throws {
        let (controller, _) = try await makePanelWithClips((0..<12).reversed().map { "clip \($0)" })
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let metrics = try stripMetrics(in: window)
        let left = strip.bounds.midX - metrics.bandWidth / 2

        // The newest clip is selected and rests the dock inset in from the band's left end, with the older clips
        // running to its right.
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": clip 0") == true, selectedClipLabel(in: strip) ?? "")
        let newest = try frame(of: "clip 0", in: strip)
        XCTAssertEqual(newest.minX - left, metrics.dockInset, accuracy: 0.5)
        XCTAssertEqual(try frame(of: "clip 1", in: strip).minX - newest.minX, metrics.step, accuracy: 1)
        controller.state.close()
    }

    func testRightStepsToTheOlderClipAndLeftComesBack() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let rows = controller.state.selection.rows

        // An empty field has no caret to move: Right steps the strip to the older clip, which is selected at
        // once, and the keys stay with the field.
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(controller.state.selection.selection, rows[1].ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": older") == true, selectedClipLabel(in: strip) ?? "")
        XCTAssertTrue(isEditing(field, in: window))

        // Left steps back to the newest clip, and at that end it does nothing.
        editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(controller.state.selection.selection, rows[0].ref)
        editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(controller.state.selection.selection, rows[0].ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": newer") == true, selectedClipLabel(in: strip) ?? "")
        XCTAssertTrue(isEditing(field, in: window))
        controller.state.close()
    }

    func testStepsInTheDockMoveTheSelectionNotTheFrames() async throws {
        let (controller, _) = try await makePanelWithClips((0..<12).reversed().map { "clip \($0)" })
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let docked = try frame(of: "clip 0", in: strip)

        // Near the newest end the selection walks along the film, which stays where it is.
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows[1].ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": clip 1") == true, selectedClipLabel(in: strip) ?? "")
        XCTAssertEqual(try frame(of: "clip 0", in: strip), docked)
        controller.state.close()
    }

    func testFadesFollowTheFilmEnds() async throws {
        let (controller, _) = try await makePanelWithClips((0..<12).reversed().map { "clip \($0)" })
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)

        // At the newest clip the band's left end is a hard edge; older clips go on beyond its right end, which fades.
        XCTAssertTrue(strip.fades == (false, true), "\(strip.fades)")
        var band = try bandFades(in: window)
        XCTAssertTrue(band == (false, true), "\(band)")

        // Six clips older the film has left both docks, and both ends fade.
        for _ in 0..<6 { editor.doCommand(by: #selector(NSResponder.moveRight(_:))) }
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows[6].ref)
        XCTAssertTrue(strip.fades == (true, true), "\(strip.fades)")
        band = try bandFades(in: window)
        XCTAssertTrue(band == (true, true), "\(band)")
        controller.state.close()

        // Two clips fit between the docks with room to spare, so neither end fades.
        let (pair, _) = try await makePanelWithClips(["older", "newer"])
        let pairWindow = try XCTUnwrap(pair.window)
        _ = try searchEditor(in: pair)
        let pairStrip = try await clipStrip(in: pairWindow)
        XCTAssertTrue(pairStrip.fades == (false, false), "\(pairStrip.fades)")
        band = try bandFades(in: pairWindow)
        XCTAssertTrue(band == (false, false), "\(band)")
        pair.state.close()
    }

    func testFadesSwitchAtOnceWhenTheFilmAppearsOrGoes() async throws {
        let (controller, _) = try await makePanelWithClips((0..<12).reversed().map { "clip \($0)" }, shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)

        // The film comes with the panel, so its fades are there at once instead of easing in.
        var layout = try bandLayout(in: window)
        XCTAssertTrue((layout.fadesLeading, layout.fadesTrailing) == (false, true))
        XCTAssertFalse(layout.animatesFades)

        // Along the film a fade eases in.
        for _ in 0..<6 { editor.doCommand(by: #selector(NSResponder.moveRight(_:))) }
        layout = try bandLayout(in: window)
        XCTAssertTrue((layout.fadesLeading, layout.fadesTrailing) == (true, true))
        XCTAssertTrue(layout.animatesFades)

        // Opened again, the panel starts without clips and the film goes, then comes back at the newest clip. Both
        // times the fades switch at once, and the clips come back with the fades of the open picture.
        controller.close()
        controller.show()
        layout = try bandLayout(in: window)
        XCTAssertTrue((layout.fadesLeading, layout.fadesTrailing) == (false, false))
        XCTAssertFalse(layout.animatesFades)
        try await SearchTestSupport.waitUntil { strip.accessibilityChildren()?.isEmpty == false }
        layout = try bandLayout(in: window)
        XCTAssertTrue((layout.fadesLeading, layout.fadesTrailing) == (false, true))
        XCTAssertFalse(layout.animatesFades)
    }

    func testAVanishedSelectionLeavesTheDockEmptyAndRightPicksTheNewest() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let items = try await insertClips((0..<12).reversed().map { "clip \($0)" }, into: harness)
        let controller = try makePanel(over: harness, pasteboard: board)
        controller.state.open()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 12 }
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let metrics = try stripMetrics(in: window)
        let dock = NSRect(x: strip.bounds.midX - metrics.bandWidth / 2 + metrics.dockInset, y: strip.bounds.minY,
                          width: metrics.frameSize.width, height: strip.bounds.height)

        // The newest clip, selected at the dock, leaves the list.
        var newest = try XCTUnwrap(items.last)
        newest.historyDeletedAt = Date()
        try await harness.update(.item(newest.id), to: .item(newest))
        controller.state.recentClipsChanged()
        try await SearchTestSupport.waitUntil {
            controller.state.selection.selectionLost && strip.accessibilitySelectedChildren()?.isEmpty != false
        }

        // Its place at the dock stays empty, without a ring, and the clips left start one step to its right.
        let frames = try XCTUnwrap(strip.accessibilityChildren() as? [NSView])
        XCTAssertFalse(frames.isEmpty)
        XCTAssertFalse(frames.contains { strip.convert($0.bounds, from: $0).intersects(dock) })
        XCTAssertFalse(frames.contains { $0.isAccessibilitySelected() })
        XCTAssertEqual(try frame(of: "clip 1", in: strip).minX - dock.minX, metrics.step, accuracy: 0.5)

        // Right selects the newest clip left, which comes to the dock.
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": clip 1") == true, selectedClipLabel(in: strip) ?? "")
        XCTAssertEqual(try frame(of: "clip 1", in: strip).minX, dock.minX, accuracy: 0.5)
        controller.state.close()
    }

    func testTheOldestEndStopsTheFilmOnlyOncePagingIsDone() async throws {
        // On screen, so the film slides where it moves.
        let (controller, _) = try await makePanelWithClips((0..<61).map { "ab \($0)" }, shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let metrics = try stripMetrics(in: window)
        let left = strip.bounds.midX - metrics.bandWidth / 2
        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "ab" && controller.state.phase == .results
                && controller.state.selection.isComplete
        }
        XCTAssertEqual(controller.state.selection.rows.count, 60)

        // The last row of the first page is not the oldest match: the film keeps it in the middle, and the right
        // end fades while the next page is on its way.
        controller.perform(.move(59))
        let title = controller.state.selection.rows[59].title
        XCTAssertEqual(try frame(of: title, in: strip).midX - left, metrics.bandWidth / 2, accuracy: 0.5)
        XCTAssertTrue(strip.fades.trailing)

        // Time stands still from here, so a slide that the next page starts stays at its beginning.
        strip.wantsLayer = true
        strip.layer?.speed = 0
        defer { strip.layer?.speed = 1 }
        // The next page brings the last match. With no more to fetch, the film comes to rest with it at the right
        // dock, and slides there: the selected clip is still drawn in the middle, where it was.
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.count == 61 && !strip.fades.trailing
        }
        let oldest = try frame(of: controller.state.selection.rows[60].title, in: strip)
        XCTAssertEqual(oldest.maxX - left, metrics.bandWidth - metrics.dockInset, accuracy: 0.5)
        CATransaction.flush()
        let resting = try frame(of: title, in: strip).midX
        let drawn = resting + (try filmOffset(in: strip))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(drawn, resting, accuracy: 0.5, "With Reduce Motion the film goes straight to its place")
        } else {
            XCTAssertEqual(drawn - left, metrics.bandWidth / 2, accuracy: 1)
        }
    }

    func testANewQueryLeavesTheClipsInPlaceUntilItsResultsCome() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha note", "beta note", "gamma note"])
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let before = try frame(of: "gamma note", in: strip)

        // A key typed into the field starts a new search. Until it brings rows, the three clips on screen are still
        // all there is and stay centred as a group, instead of docking left and coming back with the results.
        editor.insertText("n", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(controller.state.phase, .loading)
        XCTAssertEqual(try frame(of: "gamma note", in: strip), before)
        controller.state.close()
    }

    func testAPageStillBeingScannedIsNotTheLastOne() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips((0..<5).map { "ab \($0)" }, into: harness)
        try await harness.consumer.synchronize()
        // A two-letter query is scanned, here three clips at a time, and the scan holds after its first page until
        // the gate opens.
        let gate = ScanGate()
        addTeardownBlock { gate.open() }
        let search = SearchService(index: harness.index, status: harness.status, scanChunkSize: 3,
                                   onScanProgress: { _ in gate.pass() })
        let controller = try makePanel(over: harness, pasteboard: board, search: search)
        controller.state.open()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 5 }
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let metrics = try stripMetrics(in: window)
        let left = strip.bounds.midX - metrics.bandWidth / 2

        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "ab" && controller.state.phase == .results
                && strip.accessibilityChildren()?.count == 3
        }
        XCTAssertFalse(controller.state.selection.isComplete)
        XCTAssertEqual(controller.state.selection.rows.count, 3)

        // The rest of the scan may bring more clips, so the three found so far are not centred as a group: they
        // rest at the left dock, and the right end fades.
        let first = try frame(of: controller.state.selection.rows[0].title, in: strip)
        XCTAssertEqual(first.minX - left, metrics.dockInset, accuracy: 0.5)
        XCTAssertTrue(strip.fades == (false, true), "\(strip.fades)")

        // The finished scan is all there is, and five clips fit: they are centred as a group.
        gate.open()
        try await SearchTestSupport.waitUntil {
            controller.state.selection.isComplete && strip.accessibilityChildren()?.count == 5
        }
        let film = 5 * metrics.step - metrics.gap
        let newest = try frame(of: controller.state.selection.rows[0].title, in: strip)
        XCTAssertEqual(newest.minX - left, (metrics.bandWidth - film) / 2, accuracy: 0.5)
        XCTAssertTrue(strip.fades == (false, false), "\(strip.fades)")
        controller.state.close()
    }

    func testTypingInTheStripReturnsToTheFieldWithoutLosingTheKey() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)

        // The key arrives the way a real one does: as the application's current event.
        NSApp.postEvent(try key(kVK_ANSI_A, "a", windowNumber: window.windowNumber), atStart: true)
        let typed = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true))
        strip.keyDown(with: typed)
        XCTAssertTrue(isEditing(field, in: window), "Typing goes back to the search field")

        // The key is posted again for the field, so that it arrives after the change of focus, when an input
        // method can start a composition with it. The event loop hands it to the field's editor.
        try deliverQueuedKeys(in: window) { field.stringValue == "a" }

        XCTAssertEqual(field.stringValue, "a", "The key that moved focus is typed there, not lost")
        XCTAssertEqual(controller.state.query, "a")
        controller.state.close()
    }

    func testAKeyPostedAgainForTheFieldIsNeverPostedTwice() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)
        NSApp.postEvent(try key(kVK_ANSI_A, "a", windowNumber: window.windowNumber), atStart: true)
        strip.keyDown(with: try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default,
                                                          dequeue: true)))

        // Should the key come back to the strip instead of reaching the field, it is dropped, not posted again.
        let reposted = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 1),
                                                     inMode: .default, dequeue: true))
        strip.keyDown(with: reposted)

        XCTAssertNil(NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true))
        controller.state.close()
    }

    func testHeldReturnEscapeAndSpaceActOnceInTheSearchField() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let (field, editor) = try searchEditor(in: controller)
        let search = try XCTUnwrap(field as? QuickAccessSearchField)
        var commands: [QuickAccessCommand] = []
        search.onCommand = { commands.append($0) }
        var escapes: [QuickAccessEscapeAction] = []
        search.onEscape = { escapes.append($0) }

        // In the empty field Space opens the preview and Return copies. A key held down acts on its first press
        // alone: a repeat does nothing, and Space is not typed instead.
        for (code, characters, command) in [(kVK_Space, " ", QuickAccessCommand.togglePreview),
                                            (kVK_Return, "\r", .primary)] {
            editor.keyDown(with: try key(code, characters, isARepeat: true))
            XCTAssertEqual(commands, [], "A repeat of \(command)")
            editor.keyDown(with: try key(code, characters))
            XCTAssertEqual(commands, [command])
            commands = []
        }
        XCTAssertEqual(field.stringValue, "")

        // In a query Space is text, and a held one keeps typing.
        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try key(kVK_Space, " "))
        editor.keyDown(with: try key(kVK_Space, " ", isARepeat: true))
        XCTAssertEqual(field.stringValue, "ab  ")

        // A repeated Escape leaves the query alone; pressed, Escape clears it.
        editor.keyDown(with: try key(kVK_Escape, "\u{1B}", isARepeat: true))
        XCTAssertEqual(escapes, [])
        XCTAssertEqual(field.stringValue, "ab  ")
        editor.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        XCTAssertEqual(escapes, [.clearQuery])
        controller.state.close()
    }

    func testSpaceOpensThePreviewAboveTheBandAndEscapeClosesIt() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        assertFrame(window.frame, places: panelFrame(on: screen, density: .nine))
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)

        strip.keyDown(with: try key(kVK_Space, " "))
        XCTAssertTrue(controller.state.isPreviewExpanded)
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        settleLayout()

        // The panel grows to hold the card above the band, and the band moves down if the card has no room there.
        assertFrame(window.frame, places: panelFrame(on: screen, density: .nine, withPreview: true))
        let text = try XCTUnwrap(views(NSTextView.self, in: window.contentView).first { !$0.isFieldEditor })
        XCTAssertEqual(text.string, "newer")
        XCTAssertGreaterThan(text.convert(text.bounds, to: nil).minY, strip.convert(strip.bounds, to: nil).maxY)
        XCTAssertTrue(window.firstResponder === strip, "The strip keeps the keys")

        // Escape closes the card and leaves the band as it was.
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        settleLayout()
        XCTAssertFalse(controller.state.isPreviewExpanded)
        assertFrame(window.frame, places: panelFrame(on: screen, density: .nine))
        XCTAssertTrue(window.firstResponder === strip)
        controller.state.close()
    }

    func testCopyButtonCopiesAndContextMenuMatchesCommandK() async throws {
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        var shown: [(menu: NSMenu, point: NSPoint, view: NSView)] = []
        controller.presentActionMenu = { shown.append(($0, $1, $2)) }

        // ⌘K opens the selected clip's actions beside it, level with its top edge.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_K, "k", modifiers: .command)))
        let commandK = try XCTUnwrap(shown.first)
        let selected = try frame(of: "newer", in: strip)
        XCTAssertTrue(commandK.view === strip)
        XCTAssertEqual(commandK.point.x, selected.maxX, accuracy: try stripMetrics(in: window).gap)
        XCTAssertGreaterThanOrEqual(commandK.point.x, selected.maxX)
        XCTAssertEqual(commandK.point.y, selected.maxY, accuracy: 1)
        XCTAssertEqual(commandK.menu.items.map(\.title), ["Copy", "Copy as Plain Text", "", "Show Preview"])
        // A right-click on the selected clip gives the same menu.
        let context = try XCTUnwrap(strip.menu(for: try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: strip.convert(NSPoint(x: selected.midX, y: selected.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))))
        XCTAssertEqual(context.items.map(\.title), commandK.menu.items.map(\.title))
        XCTAssertEqual(context.items.map(\.isEnabled), commandK.menu.items.map(\.isEnabled))
        XCTAssertEqual(context.items.map(\.keyEquivalent), commandK.menu.items.map(\.keyEquivalent))

        // The caption's Copy button copies the selected clip, as Return does. SwiftUI draws it with an AppKit
        // button, the only one in the caption row.
        let caption = NSRect(x: 0, y: StripLayout.shadowMargin, width: window.frame.width,
                             height: StripLayout.captionHeight)
        let copy = try XCTUnwrap(views(NSButton.self, in: window.contentView).first {
            caption.contains($0.convert($0.bounds, to: nil))
        })
        XCTAssertTrue(copy.isEnabled)
        copy.performClick(nil)
        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "newer")
    }

    func testClickingTheOlderClipSelectsIt() async throws {
        let (controller, board) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let older = try frame(of: "older", in: strip)
        let point = strip.convert(NSPoint(x: older.midX, y: older.midY), to: nil)
        let click = { (type: NSEvent.EventType) in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }

        // A click where the older clip is drawn, right of the newer one, selects it and puts the keys in the strip.
        strip.mouseDown(with: try click(.leftMouseDown))
        strip.mouseUp(with: try click(.leftMouseUp))
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.last?.ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": older") == true, selectedClipLabel(in: strip) ?? "")
        XCTAssertTrue(window.firstResponder === strip)
        // It only selects: nothing is copied.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(board.string(forType: .string))
        controller.state.close()
    }

    func testRightClickingTheOlderClipCopiesItOrNothing() async throws {
        let (controller, board) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        // The older clip lies to the right of the newer one, which is selected; the click goes where it is drawn.
        let older = try frame(of: "older", in: strip)
        XCTAssertGreaterThan(older.minX, try frame(of: "newer", in: strip).maxX)
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: strip.convert(NSPoint(x: older.midX, y: older.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))

        // The clip leaves the results while its menu is open: Copy then copies nothing, least of all the selected
        // clip.
        let stale = try XCTUnwrap(strip.menu(for: rightClick))
        editor.insertText("newer", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.phase == .results && controller.state.selection.rows.map(\.title) == ["newer"]
        }
        stale.performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(board.string(forType: .string))

        // Back among the recent clips, the menu selects the clip it was opened on and copies it.
        try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
            .doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await SearchTestSupport.waitUntil { strip.accessibilityChildren()?.count == 2 }
        try XCTUnwrap(strip.menu(for: rightClick)).performActionForItem(at: 0)
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.last?.ref)
        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "older")
        controller.state.close()
    }

    func testTabRevealsTheFiltersAndEscapeHidesThem() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let filters = try XCTUnwrap(views(QuickAccessFilterRow.self, in: window.contentView).first)
        let height = window.frame.height
        let top = window.frame.maxY
        XCTAssertFalse(controller.state.filtersVisible)
        XCTAssertTrue(filters.isHidden)

        // Tab shows the hidden filter row and puts the keys in it; the band grows down to hold it, and the search
        // row stays where it was.
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === filters)
        XCTAssertTrue(controller.state.filtersVisible)
        XCTAssertFalse(filters.isHidden)
        XCTAssertEqual(window.frame.height, height + StripLayout.filterHeight, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)

        // With no query and no filter chosen, the row is a layer of its own: Escape hides it and keeps the panel.
        filters.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        XCTAssertFalse(controller.state.filtersVisible)
        XCTAssertTrue(filters.isHidden)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertTrue(isEditing(field, in: window), "The keys go back to the search field")
        XCTAssertEqual(window.frame.height, height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 1)

        // The next Escape closes the panel.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertFalse(window.isVisible)
    }

    func testEmptyLibraryShowsTheStripCopyWithoutKeycaps() async throws {
        let (controller, harness) = try await makeEmptyPanel()
        let window = try XCTUnwrap(controller.window)
        try await SearchTestSupport.waitUntil { controller.state.phase == .noContent }
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()

        // Where the clips would be, the band says how they get there; there are no frames and no key hints.
        // SwiftUI's own accessibility is not built without an assistive app, so the copy is checked as drawn.
        XCTAssertEqual(QuickAccessStatus.empty(phase: controller.state.phase, notice: controller.state.indexNotice).text,
                       "No clips yet. Copy something and it shows up here.")
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        XCTAssertEqual(strip.accessibilityChildren()?.count ?? 0, 0)
        XCTAssertTrue(views(NSHostingView<StripFrameView>.self, in: strip).isEmpty)
        let middle = strip.convert(NSRect(x: strip.bounds.midX - 40, y: strip.bounds.midY - 10, width: 80, height: 20),
                                   to: nil)
        XCTAssertGreaterThan(try contrast(in: window, at: middle), 0.3, "The copy is drawn where the clips would be")
        XCTAssertLessThan(try contrast(in: window, at: middle.offsetBy(dx: -0.3 * strip.bounds.width, dy: 0)), 0.05,
                          "and nothing else is")
        XCTAssertLessThan(try contrast(in: window, at: keyHintArea(in: window)), 0.05, "No key hints")

        // The first clip brings its frame, and the hints with it.
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("first".utf8))]])
        let item = ItemValue(title: "first", captureID: capture.id, historyEligible: true,
                             lastCopiedAt: Date(timeIntervalSince1970: 1_000), copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        controller.state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 1 }
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        XCTAssertEqual(strip.accessibilityChildren()?.count, 1)
        XCTAssertGreaterThan(try contrast(in: window, at: keyHintArea(in: window)), 0.1, "Key hints")
        controller.state.close()
    }

    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { self.findSearchField(in: $0) }.first
    }

    /// A panel over a real temporary store holding one text clip per title, newest last. A shown panel opens the
    /// way the shortcut opens it; otherwise only its state does, and the window stays off screen.
    private func makePanelWithClips(_ titles: [String], shown: Bool = false) async throws
        -> (PanelController, NSPasteboard) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(titles, into: harness)
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board)
        if shown {
            controller.show()
            addTeardownBlock { controller.close() }
        } else {
            controller.state.open()
        }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == titles.count }
        return (controller, board)
    }

    /// Stores one text clip per title, each copied a second after the one before, so the last is the newest.
    @discardableResult
    private func insertClips(_ titles: [String], into harness: SearchHarness) async throws -> [ItemValue] {
        var items: [ItemValue] = []
        for (offset, title) in titles.enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(title.utf8))]])
            let item = ItemValue(title: title, captureID: capture.id, historyEligible: true,
                                 lastCopiedAt: Date(timeIntervalSince1970: 1_000 + Double(offset)), copyCount: 1)
            try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
            items.append(item)
        }
        return items
    }

    /// A panel over a real temporary store with nothing in it yet.
    private func makeEmptyPanel() async throws -> (PanelController, SearchHarness) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let controller = try makePanel(over: harness, pasteboard: board)
        controller.state.open()
        return (controller, harness)
    }

    /// `search` stands in for the harness's own search service when given.
    private func makePanel(over harness: SearchHarness, pasteboard: NSPasteboard,
                           search: SearchService? = nil) throws -> PanelController {
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: pasteboard, read: { try await repository.read($0) },
                                 recordUse: { _ in }, didWrite: { _ in })
        let services = QuickAccessServices(repository: repository, search: search ?? harness.service, paste: paste)
        return PanelController(state: QuickAccessState(services: { services }), preferences: try makePreferences(.nine))
    }

    /// Settings of the panel's own, so its density does not depend on this machine's.
    private func makePreferences(_ density: StripDensity) throws -> QuickAccessPreferences {
        let suiteName = "AppLaunchTests.quickAccess.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = QuickAccessPreferences(defaults: defaults)
        preferences.density = density
        return preferences
    }

    /// Where `StripLayout` puts the panel on `screen`: around the band alone, or around the band and the
    /// preview card above it.
    private func panelFrame(on screen: NSScreen, density: StripDensity, withPreview: Bool = false) -> NSRect {
        let visible = screen.visibleFrame
        let metrics = StripLayout.metrics(for: density, visibleWidth: visible.width)
        let band = StripLayout.bandFrame(metrics, filtersVisible: false, in: visible)
        guard withPreview else { return StripLayout.panelFrame(band: band, preview: nil) }
        let placed = StripLayout.previewLayout(band: band, filtersVisible: false, in: visible)
        return StripLayout.panelFrame(band: placed.band, preview: placed.preview)
    }

    /// The window sits where `expected` is, moved at most half a point so that it starts on whole pixels.
    private func assertFrame(_ frame: NSRect, places expected: NSRect, file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(frame.size, expected.size, file: file, line: line)
        XCTAssertEqual(frame.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frame.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frame.minX, frame.minX.rounded(), "\(frame) is on whole points", file: file, line: line)
        XCTAssertEqual(frame.minY, frame.minY.rounded(), "\(frame) is on whole points", file: file, line: line)
    }

    private func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func isEditing(_ field: NSSearchField, in window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.delegate === field
    }

    /// What VoiceOver reads for the selected clip.
    private func selectedClipLabel(in strip: QuickAccessStripView) -> String? {
        (strip.accessibilitySelectedChildren()?.first as? NSView)?.accessibilityLabel()
    }

    /// The frame sizes the panel takes for the screen it opens on: nine in a row, or fewer on a narrow screen.
    private func stripMetrics(in window: NSWindow) throws -> StripMetrics {
        StripLayout.metrics(for: .nine, visibleWidth: try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame.width)
    }

    /// The strip of the panel's window, once it shows the panel's clips: the panel follows the state a moment after
    /// the clips arrive.
    private func clipStrip(in window: NSWindow) async throws -> QuickAccessStripView {
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        try await SearchTestSupport.waitUntil { strip.accessibilityChildren()?.isEmpty == false }
        return strip
    }

    /// Where the frame of the clip with this title is drawn, in the strip's coordinates. Only frames on screen,
    /// the ones VoiceOver reads, are looked at.
    private func frame(of title: String, in strip: QuickAccessStripView) throws -> NSRect {
        let frames = try XCTUnwrap(strip.accessibilityChildren() as? [NSView])
        let frame = try XCTUnwrap(frames.first { $0.accessibilityLabel()?.hasSuffix(": \(title)") == true }, title)
        return strip.convert(frame.bounds, from: frame)
    }

    /// What the panel lays the band out by.
    private func bandLayout(in window: NSWindow) throws -> QuickAccessBandView.Layout {
        try XCTUnwrap(window.contentView as? NSHostingView<QuickAccessBandView>).rootView.layout
    }

    /// Which ends of the band the panel has it fade.
    private func bandFades(in window: NSWindow) throws -> (leading: Bool, trailing: Bool) {
        let layout = try bandLayout(in: window)
        return (layout.fadesLeading, layout.fadesTrailing)
    }

    /// How far the strip's film is drawn from its place while a slide runs: the frames move as one inside it.
    private func filmOffset(in strip: QuickAccessStripView) throws -> CGFloat {
        let layer = try XCTUnwrap(strip.subviews.first?.layer)
        return (layer.presentation()?.position.x ?? layer.position.x) - layer.position.x
    }

    private func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [],
                     windowNumber: Int = 0, isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: isARepeat,
            keyCode: UInt16(code)
        ))
    }

    private func settleLayout() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    /// Hands the key events waiting in the application's queue to the window's first responder, as the event loop
    /// would, until `condition` holds or two seconds have passed. A test runs inside the event loop, which does
    /// not take another event until the test returns.
    private func deliverQueuedKeys(in window: NSWindow, until condition: () -> Bool) throws {
        let deadline = Date(timeIntervalSinceNow: 2)
        while !condition(), Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.05),
                                              inMode: .default, dequeue: true) else { continue }
            try XCTUnwrap(window.firstResponder).keyDown(with: event)
        }
    }

    private func searchEditor(in controller: PanelController) throws -> (NSSearchField, NSTextView) {
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let field = try XCTUnwrap(window.contentView.flatMap(findSearchField))
        XCTAssertTrue(window.makeFirstResponder(field))
        return (field, try XCTUnwrap(field.currentEditor() as? NSTextView))
    }

    /// Where the ← hint goes, in window coordinates: in the room left of the band, level with the clips.
    private func keyHintArea(in window: NSWindow) throws -> NSRect {
        let metrics = StripLayout.metrics(for: .nine, visibleWidth: try XCTUnwrap(window.screen ?? NSScreen.main)
            .visibleFrame.width)
        let middle = StripLayout.shadowMargin + StripLayout.captionHeight + metrics.frameSize.height / 2
        return NSRect(x: 0, y: middle - 16, width: StripLayout.sideMargin, height: 32)
    }

    /// How far apart the colours the window draws in `area` (window coordinates) are: 0 where nothing or one
    /// even colour is drawn, more where there are strokes such as text.
    private func contrast(in window: NSWindow, at area: NSRect) throws -> CGFloat {
        let content = try XCTUnwrap(window.contentView)
        let rect = content.convert(area, from: nil)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: rect))
        content.cacheDisplay(in: rect, to: bitmap)
        var low: [CGFloat] = [1, 1, 1, 1], high: [CGFloat] = [0, 0, 0, 0]
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let alpha = color.alphaComponent
                let channels = [color.redComponent * alpha, color.greenComponent * alpha, color.blueComponent * alpha,
                                alpha]
                for index in channels.indices {
                    low[index] = min(low[index], channels[index])
                    high[index] = max(high[index], channels[index])
                }
            }
        }
        return zip(high, low).map { $0 - $1 }.max() ?? 0
    }

    func testSeedingRequiresAnExplicitUITestSession() {
        let id = UUID().uuidString
        func seeds(_ arguments: [String]) -> Bool {
            LaunchConfiguration(arguments: arguments, environment: [:]).shouldSeedSyntheticClips
        }
        XCTAssertTrue(seeds(["--ui-testing", "--capture-test-session", id, "--seed-synthetic-clips"]))
        XCTAssertFalse(seeds(["--ui-testing", "--seed-synthetic-clips"]))
        XCTAssertFalse(seeds(["--capture-test-session", id, "--seed-synthetic-clips"]))
        XCTAssertFalse(seeds(["--ui-testing", "--capture-test-session", id]))
    }

    func testXCTestLaunchDoesNotRegisterTheGlobalShortcut() {
        let configuration = LaunchConfiguration(
            arguments: [],
            environment: ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        )

        XCTAssertFalse(configuration.shouldRegisterGlobalHotKey)
    }

    func testExplicitSyntheticHotKeyIsAvailableInsideTheUITestEnvironment() {
        let arguments = ["--ui-testing", "--synthetic-hotkey"]
        let environment = ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        XCTAssertTrue(LaunchConfiguration(arguments: arguments, environment: environment).shouldRegisterGlobalHotKey)
        XCTAssertFalse(LaunchConfiguration(arguments: arguments + ["--disable-global-hotkey"],
                                          environment: environment).shouldRegisterGlobalHotKey)
    }

    func testEscapeCancelsMarkedTextBeforeClearingTheQuery() {
        XCTAssertEqual(
            QuickAccessEscapePolicy.action(hasMarkedText: true, hasQuery: true),
            .cancelComposition
        )
    }

    func testEscapeClearsACommittedQueryBeforeClosingThePanel() {
        XCTAssertEqual(
            QuickAccessEscapePolicy.action(hasMarkedText: false, hasQuery: true),
            .clearQuery
        )
    }

    func testEscapeClosesThePanelWhenThereIsNoCompositionOrQuery() {
        XCTAssertEqual(
            QuickAccessEscapePolicy.action(hasMarkedText: false, hasQuery: false),
            .closePanel
        )
    }

    func testMenuConstructionDoesNotCreateWindowsAndEnvironmentReusesThem() {
        var panels = 0
        var libraries = 0
        let environment = AppEnvironment(makePanel: { panels += 1; return PanelController() },
                                         makeLibrary: { libraries += 1; return LibraryWindowController(session: CaptureSession(), autosaveName: nil) })
        let menu = MenuBarController(showQuickAccess: { _ = environment.panelController },
                                     toggleQuickAccess: { _ = environment.panelController },
                                     showLibrary: { _ = environment.libraryWindowController },
                                     shouldRegisterHotKey: false)
        XCTAssertEqual(panels, 0)
        XCTAssertEqual(libraries, 0)
        XCTAssertTrue(environment.panelController === environment.panelController)
        XCTAssertEqual(panels, 1)
        XCTAssertEqual(libraries, 0)
        XCTAssertTrue(environment.libraryWindowController === environment.libraryWindowController)
        XCTAssertEqual(libraries, 1)
        withExtendedLifetime(menu) {}
    }

    func testFallbackMenuActuallyInvokesQuickAccessWhenRegistrationFails() throws {
        var opens = 0
        let menu = MenuBarController(showQuickAccess: { opens += 1 }, toggleQuickAccess: {}, showLibrary: {},
                                     shouldRegisterHotKey: true,
                                     registration: .init(keyCode: { 9 }, register: { _, _, _ in OSStatus(eventHotKeyExistsErr) },
                                                         unregister: { _ in XCTFail("No registration to remove") }))
        XCTAssertEqual(menu.shortcutStatus, .unavailable)
        let item = try XCTUnwrap(menu.menu?.items.first { $0.identifier?.rawValue == "ShortcutFallback" })
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(opens, 1)
    }

    func testLayoutChangeUnregistersOldKeyAndKeepsNonexclusiveRegistration() {
        var key: UInt32? = 9
        var registered: [UInt32] = []
        var removed = 0
        let handle = EventHotKeyRef(bitPattern: 1)!
        var menu: MenuBarController? = MenuBarController(
            showQuickAccess: {}, toggleQuickAccess: {}, showLibrary: {}, shouldRegisterHotKey: true,
            registration: .init(keyCode: { key }, register: { code, options, reference in
                XCTAssertEqual(options, 0)
                registered.append(code)
                reference = handle
                return noErr
            }, unregister: { reference in XCTAssertEqual(reference, handle); removed += 1 })
        )
        XCTAssertEqual(registered, [9])
        key = 47
        menu?.inputSourceChanged()
        settleLayout()
        XCTAssertEqual(registered, [9, 47])
        XCTAssertEqual(removed, 1)
        key = nil
        menu?.inputSourceChanged()
        settleLayout()
        XCTAssertEqual(registered, [9, 47])
        XCTAssertEqual(removed, 2)
        XCTAssertNotEqual(menu?.shortcutStatus, .registered)
        menu = nil
        XCTAssertEqual(removed, 2)
    }

    func testReleasingTheMenuUnregistersItsActiveShortcutExactlyOnce() {
        var removed = 0
        let handle = EventHotKeyRef(bitPattern: 1)!
        var menu: MenuBarController? = MenuBarController(
            showQuickAccess: {}, toggleQuickAccess: {}, showLibrary: {}, shouldRegisterHotKey: true,
            registration: .init(keyCode: { 9 }, register: { _, _, reference in
                reference = handle
                return noErr
            }, unregister: { _ in removed += 1 })
        )
        XCTAssertEqual(menu?.shortcutStatus, .registered)
        XCTAssertEqual(removed, 0)
        menu = nil
        XCTAssertEqual(removed, 1)
    }

    func testCommandVResolvesSystemKeyboardLayoutsWithoutSelectingThem() throws {
        let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
        for (id, expected) in [("com.apple.keylayout.US", UInt32(9)),
                               ("com.apple.keylayout.Dvorak", UInt32(47)),
                               ("com.apple.keylayout.DVORAK-QWERTYCMD", UInt32(9)),
                               ("com.apple.keylayout.Turkish-Standard", UInt32(8))] {
            let source = try XCTUnwrap(sources.first {
                guard let raw = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
                return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String == id
            }, id)
            let raw = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
            XCTAssertEqual(ShortcutKeyResolver.commandV(in: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()), expected, id)
        }
        XCTAssertNil(ShortcutKeyResolver.commandV(in: Data() as CFData))
    }

    func testLibraryRestoresAnIsolatedSavedFrameAfterHostingLayout() throws {
        let name = "KeeptideTests.frame." + UUID().uuidString
        defer { NSWindow.removeFrame(usingName: name) }
        let original = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let window = try XCTUnwrap(original.window)
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let saved = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 1000, height: 700)
        window.setFrame(saved, display: false)
        window.saveFrame(usingName: name)
        let restored = LibraryWindowController(session: CaptureSession(), autosaveName: name)
        settleLayout()
        XCTAssertEqual(restored.window?.frame, saved)
        XCTAssertEqual(restored.window?.title, "Keeptide Library")
    }

    func testApplicationMenuBindsStandardResponderActions() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let appMenu = try XCTUnwrap(menu.item(withTitle: "Keeptide")?.submenu)
        let editMenu = try XCTUnwrap(menu.item(withTitle: "Edit")?.submenu)
        let windowMenu = try XCTUnwrap(menu.item(withTitle: "Window")?.submenu)

        XCTAssertEqual(appMenu.item(withTitle: "Quit Keeptide")?.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(appMenu.item(withTitle: "Quit Keeptide")?.keyEquivalent, "q")
        XCTAssertEqual(windowMenu.item(withTitle: "Close")?.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(windowMenu.item(withTitle: "Close")?.keyEquivalent, "w")

        let expectedEditActions: [(String, Selector, String)] = [
            ("Undo", Selector(("undo:")), "z"),
            ("Redo", Selector(("redo:")), "z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (title, action, keyEquivalent) in expectedEditActions {
            XCTAssertEqual(editMenu.item(withTitle: title)?.action, action)
            XCTAssertEqual(editMenu.item(withTitle: title)?.keyEquivalent, keyEquivalent)
        }
        XCTAssertEqual(
            editMenu.item(withTitle: "Redo")?.keyEquivalentModifierMask,
            [.command, .shift]
        )
    }

    func testApplicationMenuHasSettingsWithCommandComma() throws {
        let menu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
        let appMenu = try XCTUnwrap(menu.item(withTitle: "Keeptide")?.submenu)
        let settings = try XCTUnwrap(appMenu.item(withTitle: "Settings…"))

        let action = try XCTUnwrap(settings.action)

        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertEqual(action, #selector(AppDelegate.showSettings(_:)))
        // Nothing is sent: the delegate would open a real Settings window in the test host.
        XCTAssertTrue(NSApplication.shared.target(forAction: action, to: settings.target, from: settings) is AppDelegate)
    }

}

@MainActor
private final class QueryLog {
    var queries: [String] = []
}

/// Lets a search's first scanned range through and holds every later one, on the search queue, until it opens.
private final class ScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var ranges = 0
    private var isOpen = false

    func pass() {
        condition.lock()
        defer { condition.unlock() }
        ranges += 1
        while ranges > 1, !isOpen { condition.wait() }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

// Exercise key-window notifications without taking focus from another application.
@MainActor
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
