import AppKit
import Carbon
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

    func testWindowGeometrySurvivesHostingLayout() throws {
        let panel = PanelController()
        let library = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        settleLayout()
        XCTAssertEqual(panel.window?.contentView?.frame.size, NSSize(width: 680, height: 496))
        XCTAssertEqual(panel.window?.contentMinSize, NSSize(width: 520, height: 360))
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

    func testDownFocusesResultsAndUpOnTheFirstRowReturnsToTheSearchField() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        for (offset, title) in ["older", "newer"].enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(title.utf8))]])
            let item = ItemValue(title: title, captureID: capture.id, historyEligible: true,
                                 lastCopiedAt: Date(timeIntervalSince1970: 1_000 + Double(offset)), copyCount: 1)
            try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        }
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) },
                                 recordUse: { _ in }, didWrite: { _ in })
        let services = QuickAccessServices(repository: repository, search: harness.service, paste: paste)
        let controller = PanelController(state: QuickAccessState(services: { services }))
        controller.state.open()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 2 }
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)

        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let table = try XCTUnwrap(window.firstResponder as? QuickAccessResultsTableView)
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref,
                       "Down focuses the results without skipping the first row")

        table.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false,
            keyCode: UInt16(kVK_UpArrow)
        )))
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === controller.window?.contentView.flatMap {
            findSearchField(in: $0)
        })
        controller.state.close()
    }

    func testBecomingKeyAgainKeepsFocusThatAnotherControlHolds() throws {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                               styleMask: [.titled], backing: .buffered, defer: false)
        let field = QuickAccessSearchField()
        let results = QuickAccessResultsTableView()
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(results)
        XCTAssertTrue(window.makeFirstResponder(results))

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        XCTAssertTrue(window.firstResponder === results)
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

    func testOpeningThePreviewFromTheResultsKeepsThemFocused() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.focusResults)
        XCTAssertTrue(window.firstResponder is QuickAccessResultsTableView)

        controller.perform(.togglePreview)
        settleLayout()

        XCTAssertTrue(window.firstResponder is QuickAccessResultsTableView)
        controller.perform(.move(1))
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.last?.ref)
        controller.state.close()
    }

    func testThePreviewNeedsASelection() {
        let controller = PanelController()

        controller.togglePreview()

        XCTAssertFalse(controller.state.isPreviewExpanded)
    }

    func testUpFromTheFirstRowKeepsTheQueryText() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha note", "beta note"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        editor.insertText("note", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "note" && controller.state.phase == .results
        }

        controller.perform(.focusResults)
        controller.perform(.move(-1))

        let returned = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(returned.delegate === field)
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

    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { self.findSearchField(in: $0) }.first
    }

    /// A panel over a real temporary store holding one text clip per title, newest last.
    private func makePanelWithClips(_ titles: [String]) async throws -> (PanelController, NSPasteboard) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        for (offset, title) in titles.enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(title.utf8))]])
            let item = ItemValue(title: title, captureID: capture.id, historyEligible: true,
                                 lastCopiedAt: Date(timeIntervalSince1970: 1_000 + Double(offset)), copyCount: 1)
            try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        }
        try await harness.consumer.synchronize()
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) },
                                 recordUse: { _ in }, didWrite: { _ in })
        let services = QuickAccessServices(repository: repository, search: harness.service, paste: paste)
        let controller = PanelController(state: QuickAccessState(services: { services }))
        controller.state.open()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == titles.count }
        return (controller, board)
    }

    private func settleLayout() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    private func searchEditor(in controller: PanelController) throws -> (NSSearchField, NSTextView) {
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let field = try XCTUnwrap(window.contentView.flatMap(findSearchField))
        XCTAssertTrue(window.makeFirstResponder(field))
        return (field, try XCTUnwrap(field.currentEditor() as? NSTextView))
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

    func testPanelPlacementFitsNegativeAndSmallVisibleFrames() {
        for visible in [NSRect(x: -1800, y: 30, width: 1600, height: 1000),
                        NSRect(x: 0, y: 900, width: 400, height: 300)] {
            let frame = PanelController.frame(for: NSSize(width: 680, height: 496), in: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.midY, visible.midY)
        }
    }

    func testExpandedFrameKeepsTopEdgeAndFitsTheScreen() throws {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let compact = PanelController.frame(for: NSSize(width: 680, height: 496), in: visible)

        let expanded = try XCTUnwrap(PanelController.expandedFrame(from: compact, in: visible))

        XCTAssertEqual(expanded.size, NSSize(width: 960, height: 560))
        XCTAssertEqual(expanded.maxY, compact.maxY)
        XCTAssertEqual(expanded.midX, compact.midX)
        XCTAssertTrue(visible.contains(expanded))
    }

    func testExpandedFrameShiftsInsideAScreenEdge() throws {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let compact = NSRect(x: 1440 - 680, y: 300, width: 680, height: 496)

        let expanded = try XCTUnwrap(PanelController.expandedFrame(from: compact, in: visible))

        XCTAssertLessThanOrEqual(expanded.maxX, visible.maxX)
        XCTAssertTrue(visible.contains(expanded))
    }

    func testNarrowScreenUsesThePreviewPage() {
        let visible = NSRect(x: 0, y: 0, width: 900, height: 900)
        let compact = PanelController.frame(for: NSSize(width: 680, height: 496), in: visible)

        XCTAssertNil(PanelController.expandedFrame(from: compact, in: visible))
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

// Exercise key-window notifications without taking focus from another application.
@MainActor
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
