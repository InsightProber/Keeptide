import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import XCTest
@testable import Keeptide

@MainActor
final class AppLaunchTests: XCTestCase {
    /// A panel a test set up in a task of its own, for the test to look at once the task is done.
    private var panelUnderTest: PanelController?

    func testDefaultLibraryInitializerCreatesItsWindow() {
        XCTAssertNotNil(LibraryWindowController(session: CaptureSession()).window)
    }

    func testMakingCapturePreferencesWritesNothing() throws {
        let suiteName = "AppLaunchTests.capturePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        _ = CapturePreferences(defaults: defaults)

        // The app that hosts the unit tests shares the user's own defaults, and a new install still gets its welcome.
        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        XCTAssertTrue(OnboardingPreferences(defaults: defaults).snapshot().needsCurrentOnboarding)
    }

    func testALaunchKeepsNewCopiesWhateverSwitchAnEarlierVersionStored() async throws {
        // Earlier versions stored a recording switch, on or off; a new install has none.
        for stored in [false, true, nil] as [Bool?] {
            let suiteName = "AppLaunchTests.retiredSwitch.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
            if let stored { defaults.set(stored, forKey: "captureEnabled") }
            let launched = AppDelegate.launchPreferences(in: defaults)
            let configuration = CaptureTestConfiguration(id: UUID())
            addTeardownBlock {
                UserDefaults(suiteName: configuration.preferencesSuite)?
                    .removePersistentDomain(forName: configuration.preferencesSuite)
                try? FileManager.default.removeItem(at: configuration.directory)
                NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
            }
            let clipboard = SessionClipboard()
            let session = CaptureSession(preferences: launched.capture, clipboardReader: clipboard)
            await session.initialize(testSessionID: configuration.id)

            // The switch is gone, the next copy is kept, and there is nothing to say about it.
            XCTAssertNil(defaults.object(forKey: "captureEnabled"), "stored: \(String(describing: stored))")
            clipboard.changeCount += 1
            try await SearchTestSupport.waitUntil { session.recent.count == 1 }
            XCTAssertEqual(session.recent.count, 1, "stored: \(String(describing: stored))")
            XCTAssertNil(session.captureNotice, "stored: \(String(describing: stored))")
            await session.shutdown()
        }
    }

    func testALaunchLetsTheWelcomeLookForAnEarlierVersionBeforeRemovingItsSwitch() throws {
        func suite(_ stored: [String: Any]) throws -> UserDefaults {
            let suiteName = "AppLaunchTests.launchPreferences.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
            for (key, value) in stored { defaults.set(value, forKey: key) }
            return defaults
        }

        // A version from before the welcome stored only its recording switch, on or off: the welcome counts as seen,
        // and the switch is gone once it has looked. What else was stored stays.
        for stored in [false, true] {
            let earlier = try suite(["captureEnabled": stored, "captureExcludedApplications": ["com.example.ignored"]])
            let launched = AppDelegate.launchPreferences(in: earlier)
            XCTAssertFalse(launched.onboarding.snapshot().needsCurrentOnboarding, "stored: \(stored)")
            XCTAssertNil(earlier.object(forKey: "captureEnabled"), "stored: \(stored)")
            XCTAssertEqual(launched.capture.excludedApplications, ["com.example.ignored"], "stored: \(stored)")
            // The next launch takes the user for an earlier version's as well: the welcome is done.
            XCTAssertFalse(AppDelegate.launchPreferences(in: earlier).onboarding.snapshot().needsCurrentOnboarding)
        }
        // A version whose welcome was done, paused: the welcome stays done, and the pause is gone.
        let welcomed = try suite([OnboardingPreferences.completedVersionKey: 1, "captureEnabled": false])
        XCTAssertFalse(AppDelegate.launchPreferences(in: welcomed).onboarding.snapshot().needsCurrentOnboarding)
        XCTAssertNil(welcomed.object(forKey: "captureEnabled"))
        // A new install: the welcome shows, and nothing is stored for a switch. Quit before the welcome is done, the
        // next launch shows it again.
        let fresh = try suite([:])
        XCTAssertTrue(AppDelegate.launchPreferences(in: fresh).onboarding.snapshot().needsCurrentOnboarding)
        XCTAssertNil(fresh.object(forKey: "captureEnabled"))
        XCTAssertTrue(AppDelegate.launchPreferences(in: fresh).onboarding.snapshot().needsCurrentOnboarding)
    }

    func testTheAppThatHostsTheUnitTestsLaunchesOnPreferencesOfItsOwn() {
        // The launch removes the retired switch from the preferences it uses. In the app that hosts the unit tests,
        // which shares the user's, they are a throwaway suite.
        let underXCTest = ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        XCTAssertTrue(LaunchConfiguration(arguments: [], environment: underXCTest).shouldUseEphemeralApplicationState)
    }

    func testDefaultEnvironmentUsesEphemeralPreferencesAndNoSystemLoginController() {
        let environment = AppEnvironment()

        XCTAssertNotNil(environment.ephemeralPreferencesSuiteName)
        XCTAssertEqual(environment.settingsModel.launchAtLogin.state, .unavailable)
    }

    func testEnvironmentUsesOneSettingsModelForCaptureShortcutAndLoginState() throws {
        let suiteName = "AppLaunchTests.sharedSettingsModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(QuickAccessShortcut.disabled.rawValue, forKey: GlobalShortcutPreferences.selectionKey)
        let capture = CapturePreferences(defaults: defaults)
        let session = CaptureSession(preferences: capture)
        let shortcut = GlobalShortcutCoordinator(
            preferences: GlobalShortcutPreferences(defaults: defaults),
            shouldInstallHandler: false
        )
        let login = LaunchAtLoginModel(service: AppLaunchFakeLoginService())
        let environment = AppEnvironment(
            captureSession: session,
            quickAccessPreferences: QuickAccessPreferences(defaults: defaults),
            shortcutCoordinator: shortcut,
            launchAtLogin: login,
            onboardingPreferences: OnboardingPreferences(defaults: defaults)
        )

        XCTAssertTrue(environment.settingsModel.capture === capture)
        XCTAssertTrue(environment.settingsModel.shortcut === shortcut)
        XCTAssertTrue(environment.settingsModel.launchAtLogin === login)
    }

    func testDoneOnlyCompletesTheWelcomeAndTheIsolatedStoreOpensWithTheSamePreferences() async throws {
        let configuration = CaptureTestConfiguration(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        defaults.removePersistentDomain(forName: configuration.preferencesSuite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: configuration.preferencesSuite)
            try? FileManager.default.removeItem(at: configuration.directory)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }
        let capture = CapturePreferences(defaults: defaults)
        let session = CaptureSession(preferences: capture)
        let onboarding = OnboardingPreferences(defaults: defaults)
        var libraryShows = 0
        let environment = AppEnvironment(
            captureSession: session,
            quickAccessPreferences: QuickAccessPreferences(defaults: defaults),
            shortcutCoordinator: GlobalShortcutCoordinator(
                preferences: GlobalShortcutPreferences(defaults: defaults),
                shouldInstallHandler: false
            ),
            launchAtLogin: LaunchAtLoginModel(service: AppLaunchFakeLoginService()),
            onboardingPreferences: onboarding,
            showLibrary: { libraryShows += 1 }
        )
        XCTAssertNil(environment.settingsModel.lifecycle)
        XCTAssertFalse(environment.settingsModel.canExportLibrary)
        XCTAssertFalse(environment.canExportLibrary)

        // Done only completes the welcome.
        XCTAssertTrue(onboarding.snapshot().needsCurrentOnboarding)
        environment.onboardingActions.done()
        XCTAssertFalse(onboarding.snapshot().needsCurrentOnboarding)
        XCTAssertEqual(libraryShows, 0)

        await session.initialize(testSessionID: configuration.id)

        // The store opens with the same preferences, ready, with nothing to say about new copies.
        XCTAssertTrue(session.preferences === capture)
        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.captureNotice)
        XCTAssertNotNil(environment.settingsModel.lifecycle)
        XCTAssertTrue(environment.settingsModel.canExportLibrary)
        XCTAssertTrue(environment.canExportLibrary)
        await session.shutdown()
        XCTAssertNil(environment.settingsModel.lifecycle)
        XCTAssertFalse(environment.settingsModel.canExportLibrary)
    }

    func testDoneAndOpenLibraryCompleteTheWelcome() throws {
        for opensLibrary in [false, true] {
            let suiteName = "AppLaunchTests.welcome.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
            let onboarding = OnboardingPreferences(defaults: defaults)
            var libraryShows = 0
            let environment = AppEnvironment(
                captureSession: CaptureSession(preferences: CapturePreferences(defaults: defaults)),
                quickAccessPreferences: QuickAccessPreferences(defaults: defaults),
                shortcutCoordinator: GlobalShortcutCoordinator(
                    preferences: GlobalShortcutPreferences(defaults: defaults),
                    shouldInstallHandler: false
                ),
                launchAtLogin: LaunchAtLoginModel(service: AppLaunchFakeLoginService()),
                onboardingPreferences: onboarding,
                showLibrary: { libraryShows += 1 }
            )
            let name = "Open Library: \(opensLibrary)"
            XCTAssertTrue(onboarding.snapshot().needsCurrentOnboarding, name)

            if opensLibrary {
                environment.onboardingActions.openLibrary()
            } else {
                environment.onboardingActions.done()
            }

            XCTAssertFalse(onboarding.snapshot().needsCurrentOnboarding, name)
            // Only Open Library opens the Library. Done, like closing the window, only completes the welcome.
            XCTAssertEqual(libraryShows, opensLibrary ? 1 : 0, name)
        }
    }

    func testApplicationActivationRefreshesTheExternalLoginItemStateWithoutRegistering() throws {
        let suiteName = "AppLaunchTests.loginRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(QuickAccessShortcut.disabled.rawValue, forKey: GlobalShortcutPreferences.selectionKey)
        let service = AppLaunchFakeLoginService()
        let login = LaunchAtLoginModel(service: service)
        let environment = AppEnvironment(
            captureSession: CaptureSession(preferences: CapturePreferences(defaults: defaults)),
            quickAccessPreferences: QuickAccessPreferences(defaults: defaults),
            shortcutCoordinator: GlobalShortcutCoordinator(
                preferences: GlobalShortcutPreferences(defaults: defaults),
                shouldInstallHandler: false
            ),
            launchAtLogin: login,
            onboardingPreferences: OnboardingPreferences(defaults: defaults)
        )
        XCTAssertEqual(login.state, .disabled)
        XCTAssertEqual(service.registerCalls, 0)

        service.status = .enabled
        environment.applicationDidBecomeActive()

        XCTAssertEqual(login.state, .enabled)
        XCTAssertEqual(service.registerCalls, 0)
    }

    func testManagingIgnoredAppsFromSettingsDoesNotOpenTheLibrary() throws {
        let suiteName = "AppLaunchTests.ignoredApplications.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(QuickAccessShortcut.disabled.rawValue, forKey: GlobalShortcutPreferences.selectionKey)
        let environment = AppEnvironment(
            captureSession: CaptureSession(preferences: CapturePreferences(defaults: defaults)),
            quickAccessPreferences: QuickAccessPreferences(defaults: defaults),
            shortcutCoordinator: GlobalShortcutCoordinator(
                preferences: GlobalShortcutPreferences(defaults: defaults),
                shouldInstallHandler: false
            ),
            launchAtLogin: LaunchAtLoginModel(service: AppLaunchFakeLoginService()),
            onboardingPreferences: OnboardingPreferences(defaults: defaults),
            makeLibrary: { LibraryWindowController(session: CaptureSession(), autosaveName: nil) }
        )
        let library = environment.libraryWindowController
        addTeardownBlock { library.close() }
        XCTAssertFalse(environment.settingsModel.showsIgnoredApplications)

        environment.settingsModel.presentIgnoredApplications()

        XCTAssertTrue(environment.settingsModel.showsIgnoredApplications)
        XCTAssertNotEqual(library.window?.isVisible, true)
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
        let panel = PanelController(preferences: try makePreferences(.medium))
        let library = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        settleLayout()
        let window = try XCTUnwrap(panel.window)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        assertFrame(window.frame, places: panelFrame(on: screen, cardSize: .medium))
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

    func testDownAndUpMoveBetweenTheToolbarAndTheStrip() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let up = try key(kVK_UpArrow, "\u{F700}"), down = try key(kVK_DownArrow, "\u{F701}")

        // Down goes from the search field to the strip below it, and the newest clip stays selected.
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertTrue(window.firstResponder === strip)
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref,
                       "Down focuses the strip without skipping the first clip")
        strip.keyDown(with: up)
        XCTAssertTrue(isEditing(field, in: window))

        // The lists and the filter button share the toolbar's row with the search: Up from either goes back to the
        // search field, and Down to the strip. Tab reaches them after the strip.
        for (station, steps) in [(toolbar.lists as NSView, 2), (toolbar.filterButton as NSView, 3)] {
            for _ in 0..<steps { controller.perform(.cycleFocus(forward: true)) }
            XCTAssertTrue(window.firstResponder === station, "\(type(of: station))")
            station.keyDown(with: up)
            XCTAssertTrue(isEditing(field, in: window), "\(type(of: station))")
            for _ in 0..<steps { controller.perform(.cycleFocus(forward: true)) }
            station.keyDown(with: down)
            XCTAssertTrue(window.firstResponder === strip, "\(type(of: station))")
            strip.keyDown(with: up)
            XCTAssertTrue(isEditing(field, in: window), "\(type(of: station))")
        }
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

        strip.keyDown(with: up)

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
        let controller = PanelController(preferences: try makePreferences(.medium))
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        // No frame, no background and no window shadow: the band draws its own material, edge and shadow.
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

        // The panel is the band and the room around it for the band's shadow, and the band sits in the middle of the
        // screen's visible area.
        panel.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let visible = screen.visibleFrame
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: visible.width)
        let band = StripLayout.bandFrame(metrics, in: visible)
        XCTAssertEqual(band.midY, visible.midY, accuracy: 0.5)
        assertFrame(panel.frame, places: StripLayout.panelFrame(band: band, preview: nil, in: visible))
        XCTAssertEqual(panel.frame.width, metrics.bandWidth + 2 * StripLayout.sideMargin, accuracy: 1)
    }

    func testTheBandGivesTheEnlargedCardRoomAtMediumSize() async throws {
        // Settings as they come: the standard enlargement, and here the frequent clips turned off.
        let (controller, _) = try await makePanelWithClips(["older", "newer"])
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let metrics = try stripMetrics(in: window)
        XCTAssertEqual(StripLayout.bandHeight(metrics), 316)
        let band = try bandRect(in: window)
        XCTAssertEqual(band.height, 316)
        XCTAssertEqual(band.width, metrics.bandWidth)

        // From the top: 14 to the toolbar, its 30, 16 to the cards and 7 more, as far as the selected card reaches
        // past the others once it is enlarged, the cards' 224, and 18 and 7 below them. The search's 28 pt circle is
        // level with the toolbar's row, 1 pt inside it.
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let search = toolbar.search.convert(toolbar.search.bounds, to: nil)
        XCTAssertEqual(band.maxY - search.maxY, 15, accuracy: 0.5)
        XCTAssertEqual(search.height, 28, accuracy: 0.5)
        let card = strip.convert(try frame(of: "newer", in: strip), to: nil)
        XCTAssertEqual(band.maxY - card.maxY, 67, accuracy: 0.5)
        XCTAssertEqual(card.height, 224, accuracy: 0.5)
        XCTAssertEqual(card.minY - band.minY, 25, accuracy: 0.5)
        controller.state.close()
    }

    func testTheBandOpensWithTheSearchFolded() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let toolbar = try await laidOutToolbar(in: window)
        // The toolbar follows the clips a moment after they arrive: Return's hint shows once one is selected.
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return self.visibleKeycaps(in: window).map(\.symbol) == ["⏎"]
        }
        let field = toolbar.search.field

        // The search shows as its round icon, a button for the pointer. Its field is in it and has the keys, so the
        // first key typed goes straight in; the caret is hidden with the field.
        XCTAssertFalse(controller.state.isSearchExpanded)
        XCTAssertEqual(toolbar.search.frame.size, NSSize(width: 28, height: 28))
        XCTAssertTrue(isEditing(field, in: window), "The field has the keys from the start")
        XCTAssertEqual(field.alphaValue, 0, "The folded field and its caret are not drawn")
        XCTAssertTrue(toolbar.search.convert(toolbar.search.bounds, to: nil).contains(field.convert(field.bounds, to: nil)))
        XCTAssertFalse(toolbar.search.foldButton.isHidden)
        XCTAssertEqual(toolbar.search.foldButton.accessibilityLabel(), "Search Clips and Snippets")
        XCTAssertTrue(toolbar.search.clearButton.isHidden)

        // Below the toolbar there are the clips and nothing else: no caption row and no key hints. The one key cap
        // in the panel is Return's, in the toolbar.
        XCTAssertEqual(visibleKeycaps(in: window).map(\.symbol), ["⏎"])
        let keycap = try XCTUnwrap(visibleKeycaps(in: window).first)
        XCTAssertTrue(toolbar.convert(toolbar.bounds, to: nil).contains(keycap.convert(keycap.bounds, to: nil)))
        let strip = try await clipStrip(in: window)
        let card = strip.convert(try frame(of: "newer", in: strip), to: nil)
        XCTAssertEqual(card.minY - (try bandRect(in: window)).minY, 25, accuracy: 0.5)
    }

    func testTypingUnfoldsTheSearchAndSearches() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha", "beta"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        XCTAssertFalse(controller.state.isSearchExpanded)

        // An input method's first key opens the search, before anything is committed.
        editor.setMarkedText("b", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.didChangeText()
        XCTAssertTrue(controller.state.isSearchExpanded)
        XCTAssertEqual(controller.state.query, "")
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.search.frame.width, 300)
        XCTAssertEqual(field.alphaValue, 1)
        XCTAssertTrue(toolbar.search.foldButton.isHidden)
        XCTAssertTrue(isEditing(field, in: window), "The keys stay in the field")

        // The committed text searches, and only what matches stays in the strip.
        editor.insertText("beta", replacementRange: editor.markedRange())
        try await SearchTestSupport.waitUntil {
            controller.state.query == "beta" && controller.state.phase == .results
                && controller.state.selection.isComplete
        }
        XCTAssertTrue(controller.state.isSearchExpanded)
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["beta"])
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(toolbar.search.clearButton.isHidden, "A query can be cleared with the pointer")
        controller.state.close()
    }

    func testCommandFUnfoldsTheSearch() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        controller.perform(.focusResults)
        XCTAssertTrue(window.firstResponder is QuickAccessStripView)

        // ⌘F opens the search wherever the keys are, and puts them in its field.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
        XCTAssertTrue(controller.state.isSearchExpanded)
        XCTAssertTrue(isEditing(field, in: window))
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.search.frame.width, 300)
        XCTAssertEqual(field.alphaValue, 1)

        // Folded again, a click on the icon opens it the same way.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controller.state.isSearchExpanded)
        controller.perform(.focusResults)
        toolbar.layoutSubtreeIfNeeded()
        toolbar.search.foldButton.performClick(nil)
        XCTAssertTrue(controller.state.isSearchExpanded)
        XCTAssertTrue(isEditing(field, in: window))
    }

    func testAClickAnywhereOnTheOpenSearchGivesItsFieldTheKeys() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
        toolbar.layoutSubtreeIfNeeded()
        let search = toolbar.search
        XCTAssertEqual(search.frame.width, 300)

        // The keys are in the strip. A click on the open pill's magnifier, left of the field, or in its padding at the
        // right end, gives the field the keys, as a click on the field itself would; a second click leaves them there.
        let magnifier = NSPoint(x: search.magnifier.frame.midX, y: search.bounds.midY)
        let rightEnd = NSPoint(x: search.bounds.maxX - 4, y: search.bounds.midY)
        for point in [magnifier, rightEnd] {
            controller.perform(.focusResults)
            XCTAssertTrue(window.firstResponder is QuickAccessStripView)
            try click(at: search.convert(point, to: nil), in: window)
            XCTAssertTrue(isEditing(field, in: window), "\(point)")
            XCTAssertTrue(controller.state.isSearchExpanded)
        }

        // A click there while the field has the keys keeps its editing as it is: the caret stays where it was.
        editor.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil { controller.state.query == "beta" }
        let current = try XCTUnwrap(field.currentEditor() as? NSTextView)
        toolbar.layoutSubtreeIfNeeded()
        let fieldPoint = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let fieldHit = window.contentView?.hitTest(fieldPoint)
        XCTAssertTrue(fieldHit === field || fieldHit === current, "The field keeps its native hit")
        let clear = search.clearButton
        XCTAssertFalse(clear.isHidden)
        let clearPoint = clear.convert(NSPoint(x: clear.bounds.midX, y: clear.bounds.midY), to: nil)
        XCTAssertTrue(window.contentView?.hitTest(clearPoint) === clear, "The clear button keeps its native hit")
        current.setSelectedRange(NSRange(location: 1, length: 0))
        try click(at: search.convert(magnifier, to: nil), in: window)
        XCTAssertTrue(field.currentEditor() === current)
        XCTAssertEqual(current.selectedRange(), NSRange(location: 1, length: 0))
    }

    func testAClickBetweenTheListsLeavesTheKeysInTheSearch() async throws {
        let (controller, _, _) = try await showPanelWithLists(clips: ["older", "newer"], collections: ["Prompts", "Shell"])
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let lists = toolbar.lists
        controller.state.setList(.snippets)
        try await SearchTestSupport.waitUntil { controller.state.phase == .results }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(lists.chipsView.isHidden)

        // Between the two segments, between the switch and the first chip and between two chips there is no choice: a
        // click there leaves the keys in the search field and the list as it was.
        let segments = lists.segments.buttons.map { lists.segments.convert($0.frame, to: nil) }
        let chips = lists.chips.filter { !$0.isHidden }.map { lists.chipsView.convert($0.frame, to: nil) }
        let switchFrame = lists.convert(lists.segments.frame, to: nil)
        var gaps = [NSPoint(x: (segments[0].maxX + segments[1].minX) / 2, y: segments[0].midY),
                    NSPoint(x: (switchFrame.maxX + chips[0].minX) / 2, y: chips[0].midY)]
        for (left, right) in zip(chips, chips.dropFirst()) {
            gaps.append(NSPoint(x: (left.maxX + right.minX) / 2, y: left.midY))
        }
        for gap in gaps {
            try click(at: gap, in: window)
            XCTAssertTrue(isEditing(field, in: window), "\(gap)")
            XCTAssertFalse(window.firstResponder === lists, "\(gap)")
        }
        XCTAssertEqual(controller.state.list, .snippets)
        // The lists still take the keys by Tab, after the strip.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.insertTab(_:)))
        try XCTUnwrap(window.firstResponder as? QuickAccessStripView).keyDown(with: try key(kVK_Tab, "\t"))
        XCTAssertTrue(window.firstResponder === lists)
    }

    func testEscapeFoldsAnEmptySearchBeforeClosing() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
        XCTAssertTrue(controller.state.isSearchExpanded)

        // With nothing typed, the first Escape folds the search and leaves the panel open, the keys in the field.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controller.state.isSearchExpanded)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertTrue(isEditing(field, in: window))

        // The next one closes the panel.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertFalse(window.isVisible)
    }

    func testEscapeClearsAQueryAndFoldsTheSearch() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha note", "beta note"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        var menus: [NSMenu] = []
        controller.presentToolbarMenu = { menu, _, _ in menus.append(menu) }
        editor.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        toolbar.filterButton.face.performClick(nil)
        let menu = try XCTUnwrap(menus.last)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Text" }))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "beta" && controller.state.kinds == [.text] && controller.state.phase == .results
        }
        XCTAssertTrue(controller.state.isSearchExpanded)

        // One Escape clears the query and the filters and folds the search; the panel stays, with the recent clips.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(controller.state.query, "")
        XCTAssertEqual(controller.state.kinds, [])
        XCTAssertFalse(controller.state.isSearchExpanded)
        XCTAssertTrue(controller.isSessionOpen)
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 2 }

        // The next one closes the panel.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controller.isSessionOpen)
    }

    func testTheListsAndTheFilterButtonLiveInTheToolbar() async throws {
        let (controller, _, made) = try await showPanelWithLists(clips: ["older", "newer"],
                                                                 collections: ["Prompts", "Shell"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let lists = toolbar.lists
        let strip = try await clipStrip(in: window)
        let height = window.frame.height
        var menus: [NSMenu] = []
        controller.presentToolbarMenu = { menu, _, _ in menus.append(menu) }

        // From the start the switch is at the left and the filter button beside the search at the right; under All
        // there are no chips.
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(lists.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(lists.chipsView.isHidden)
        XCTAssertEqual(lists.segments.buttons.map(\.state), [.on, .off])
        XCTAssertFalse(toolbar.filterButton.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(toolbar.search.frame.minX - toolbar.filterButton.frame.maxX, 12, accuracy: 0.5)
        XCTAssertGreaterThan(toolbar.filterButton.frame.minX, lists.frame.maxX)

        // A click on Snippets lists the snippets and shows the collections, and the keys stay where they were.
        lists.segments.buttons[1].performClick(nil)
        try await SearchTestSupport.waitUntil { controller.state.list == .snippets && controller.state.phase == .results }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(lists.chipsView.isHidden)
        XCTAssertEqual(lists.chips.map(\.title), ["Prompts", "Shell"])
        XCTAssertEqual(lists.segments.buttons.map(\.state), [.off, .on])
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertEqual(window.frame.height, height)
        // A chip lists its collection; clicked again, it goes back to all the snippets.
        lists.chips[0].performClick(nil)
        try await SearchTestSupport.waitUntil { controller.state.list == .collection(made[0].value.id) }
        XCTAssertEqual(lists.chips.map(\.state), [.on, .off])
        lists.chips[0].performClick(nil)
        try await SearchTestSupport.waitUntil { controller.state.list == .snippets }

        // The filter button's menu: Favorites Only, then All Types and each type. A type turns on or off, several may
        // be on together, and All Types clears them.
        toolbar.filterButton.face.performClick(nil)
        var menu = try XCTUnwrap(menus.last)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
                       ["Favorites Only", "-", "All Types", "Text", "Links", "Images", "Files"])
        XCTAssertEqual(menu.items.first { $0.title == "All Types" }?.state, .on)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Text" }))
        XCTAssertEqual(controller.state.kinds, [.text])
        toolbar.filterButton.face.performClick(nil)
        menu = try XCTUnwrap(menus.last)
        XCTAssertEqual(menu.items.first { $0.title == "Text" }?.state, .on)
        XCTAssertEqual(menu.items.first { $0.title == "All Types" }?.state, .off)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Images" }))
        XCTAssertEqual(controller.state.kinds, [.text, .image])
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.filterButton.title, "2 Filters")
        toolbar.filterButton.face.performClick(nil)
        menu = try XCTUnwrap(menus.last)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "All Types" }))
        XCTAssertEqual(controller.state.kinds, [])
        XCTAssertTrue(isEditing(field, in: window))
        try await SearchTestSupport.waitUntil { controller.state.phase == .results }

        // Tab goes from the search to the strip, to the lists, to the filter button and round again; Shift-Tab goes
        // back. Space on the filter button opens its menu.
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === strip)
        strip.keyDown(with: try key(kVK_Tab, "\t"))
        XCTAssertTrue(window.firstResponder === lists)
        lists.keyDown(with: try key(kVK_Tab, "\t"))
        XCTAssertTrue(window.firstResponder === toolbar.filterButton)
        toolbar.filterButton.keyDown(with: try key(kVK_Tab, "\t"))
        XCTAssertTrue(isEditing(field, in: window))
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(window.firstResponder === toolbar.filterButton)
        let shown = menus.count
        toolbar.filterButton.keyDown(with: try key(kVK_Space, " "))
        XCTAssertEqual(menus.count, shown + 1)
        toolbar.filterButton.keyDown(with: try key(kVK_Tab, "\t", modifiers: .shift))
        XCTAssertTrue(window.firstResponder === lists)

        // Taking the keys, the lists put their cursor on the list shown. The arrows move it and Space chooses.
        XCTAssertEqual(lists.stopUnderCursor, .snippets)
        lists.keyDown(with: try key(kVK_LeftArrow, "\u{F702}"))
        lists.keyDown(with: try key(kVK_LeftArrow, "\u{F702}"))
        XCTAssertEqual(lists.stopUnderCursor, .all)
        lists.keyDown(with: try key(kVK_Space, " "))
        try await SearchTestSupport.waitUntil { controller.state.list == .all }
        XCTAssertTrue(window.firstResponder === lists)
    }

    func testStatusTakesThePlaceOfTheCopyHint() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips((0..<3).map { "ab \($0)" }, into: harness)
        try await insertImageClip(into: harness)
        try await harness.consumer.synchronize()
        // A two-letter query is scanned, here two clips at a time, and the scan holds after its first page until
        // the gate opens.
        let gate = ScanGate()
        addTeardownBlock { gate.open() }
        let search = SearchService(index: harness.index, status: harness.status, scanChunkSize: 2,
                                   onScanProgress: { _ in gate.pass() })
        let controller = try makePanel(over: harness, pasteboard: board, search: search)
        controller.state.open()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 4 }
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)

        // With a clip to copy, the toolbar's right end says what Return does, once the toolbar has followed the clips.
        try await SearchTestSupport.waitUntil { toolbar.note == .action(title: "Copy", enabled: true, hint: nil) }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.note, .action(title: "Copy", enabled: true, hint: nil))
        XCTAssertFalse(toolbar.copyHint.isHidden)
        XCTAssertTrue(toolbar.statusLabel.isHidden)
        XCTAssertEqual(toolbar.copyHint.frame.maxX, toolbar.moreButton.frame.minX - 12, accuracy: 0.5)

        // While the search scans, "Searching…" takes its place there.
        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "ab" && controller.state.phase == .results
        }
        XCTAssertFalse(controller.state.selection.isComplete)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.note, .status("Searching…"))
        XCTAssertTrue(toolbar.copyHint.isHidden)
        XCTAssertFalse(toolbar.statusLabel.isHidden)
        XCTAssertEqual(toolbar.statusLabel.stringValue, "Searching…")
        XCTAssertEqual(toolbar.statusLabel.accessibilityIdentifier(), "QuickAccessStatus")
        XCTAssertEqual(toolbar.statusLabel.frame.maxX, toolbar.moreButton.frame.minX - 12, accuracy: 0.5)
        XCTAssertGreaterThan(toolbar.statusLabel.frame.minX, toolbar.search.frame.maxX)

        // Once the scan is done, Return's hint comes back, as soon as the toolbar has followed the state.
        gate.open()
        try await SearchTestSupport.waitUntil {
            controller.state.selection.isComplete && toolbar.note == .action(title: "Copy", enabled: true, hint: nil)
        }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.note, .action(title: "Copy", enabled: true, hint: nil))
        XCTAssertFalse(toolbar.copyHint.isHidden)

        // A copy that fails says why in the same place: the picture has no plain text.
        try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
            .doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.count == 4 && controller.state.selection.rows.first?.kind == .image
        }
        controller.perform(.plainText)
        try await SearchTestSupport.waitUntil {
            controller.state.failure != nil && toolbar.note == .failure("This item has no plain text.")
        }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.note, .failure("This item has no plain text."))
        XCTAssertTrue(toolbar.copyHint.isHidden)
        XCTAssertEqual(toolbar.statusLabel.stringValue, "This item has no plain text.")
        XCTAssertEqual(toolbar.statusLabel.accessibilityIdentifier(), "QuickAccessFailure")
        XCTAssertEqual(toolbar.statusLabel.frame.maxX, toolbar.moreButton.frame.minX - 12, accuracy: 0.5)
        XCTAssertTrue(controller.state.selection.rows.count == 4, "The panel stays open with the clips")
        controller.state.close()
    }

    func testTheRebuildNoticeShowsAfterTheListsAndLeavesTheCopyHint() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["deploy one", "deploy two"], into: harness)
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board,
                                       visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
        controller.state.open()
        addTeardownBlock { controller.state.close() }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 2 }
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let notice = toolbar.indexNoticeLabel
        // The middle of the band's padding under the clips.
        let band = try bandRect(in: window)
        let underTheClips = NSRect(x: band.midX - 100, y: band.minY + 4, width: 200, height: 8)

        // While the index rebuilds, a search that finds clips says so after the filters in the toolbar's row.
        // The right end keeps Return's hint, word and all.
        harness.status.update(.rebuilding)
        editor.insertText("deploy", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            let state = controller.state
            return state.query == "deploy" && state.phase == .results && state.selection.isComplete
                && state.selection.rows.count == 2 && state.indexNotice == .rebuilding
        }
        try await SearchTestSupport.waitUntil {
            toolbar.layoutSubtreeIfNeeded()
            return toolbar.note == .action(title: "Copy", enabled: true, hint: nil) && !notice.isHidden
        }
        XCTAssertFalse(toolbar.copyHint.isHidden)
        XCTAssertTrue(toolbar.copyHint.showsTitle)
        XCTAssertTrue(toolbar.statusLabel.isHidden)
        XCTAssertFalse(notice.isHidden)
        XCTAssertEqual(notice.stringValue, QuickAccessStatus.rebuilding)
        XCTAssertEqual(notice.accessibilityIdentifier(), "QuickAccessIndexNotice")
        XCTAssertEqual(notice.frame.midY, toolbar.rowFrame.midY, accuracy: 0.5, "In the toolbar's row")
        XCTAssertGreaterThanOrEqual(notice.frame.minX, toolbar.lists.frame.maxX + 12 - 0.5)
        XCTAssertLessThanOrEqual(notice.frame.maxX, toolbar.filterButton.frame.minX - 12 + 0.5)
        // The clips have nothing under them; the band draws them in full first.
        _ = try await clipStrip(in: window)
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        settleLayout()
        XCTAssertLessThan(try contrast(in: window, at: underTheClips), 0.05, "Nothing is drawn under the clips")

        // With the index ready again, the same clips bring no notice.
        harness.status.update(.ready)
        controller.state.toggleKind(.text)
        try await SearchTestSupport.waitUntil {
            let state = controller.state
            return state.kinds == [.text] && state.phase == .results && state.selection.isComplete
                && state.selection.rows.count == 2 && state.indexNotice == nil
        }
        try await SearchTestSupport.waitUntil {
            toolbar.layoutSubtreeIfNeeded()
            return notice.isHidden
        }
        XCTAssertTrue(notice.isHidden)
        XCTAssertEqual(toolbar.note, .action(title: "Copy", enabled: true, hint: nil))
    }

    func testTheMoreMenuOffersLibraryAndSettings() async throws {
        let controller = PanelController(preferences: try makePreferences(.medium))
        let window = try XCTUnwrap(controller.window)
        let toolbar = try await laidOutToolbar(in: window)
        var opened: [String] = []
        controller.onOpenLibrary = { opened.append("library") }
        controller.onOpenSettings = { opened.append("settings") }
        var shown: [(menu: NSMenu, point: NSPoint, view: NSView)] = []
        controller.presentMoreMenu = { shown.append(($0, $1, $2)) }

        // The ⋯ at the toolbar's right end, 16 in from the band's edge, opens a menu below itself.
        let more = toolbar.moreButton
        XCTAssertEqual(more.accessibilityLabel(), "More")
        XCTAssertEqual(more.frame.size, NSSize(width: 26, height: 26))
        XCTAssertEqual(toolbar.bounds.width - more.frame.maxX, 16, accuracy: 0.5)
        more.performClick(nil)
        let menu = try XCTUnwrap(shown.first)
        XCTAssertTrue(menu.view === more)
        XCTAssertEqual(menu.menu.items.map(\.title), ["Open Library", "Settings…"])

        // Each item does what the app's own command does.
        menu.menu.performActionForItem(at: 0)
        menu.menu.performActionForItem(at: 1)
        XCTAssertEqual(opened, ["library", "settings"])
    }

    func testTheAppWiresTheMoreMenuToItsLibraryAndSettings() throws {
        let suiteName = "AppLaunchTests.moreMenu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = QuickAccessPreferences(defaults: defaults)
        var settingsMade = 0
        let environment = AppEnvironment(quickAccessPreferences: preferences, makeSettings: {
            settingsMade += 1
            return SettingsWindowController(preferences: preferences, setActivationPolicy: { _ in })
        })
        let panel = environment.panelController

        // Settings… from the panel's menu opens the one Settings window, as the app menu's Settings… does.
        try XCTUnwrap(panel.onOpenSettings)()
        XCTAssertEqual(settingsMade, 1)
        let settings = try XCTUnwrap(environment.settingsWindowController.window)
        addTeardownBlock { settings.close() }
        XCTAssertTrue(settings.isVisible)
        XCTAssertNotNil(panel.onOpenLibrary)
    }

    func testQuickAccessSaysWhyNewCopiesAreNotKeptAndOffersNothingToTurnOn() async throws {
        let clipboard = SessionClipboard()
        let environment = try await makeCapturingEnvironment(clipboard: clipboard)
        let controller = environment.panelController
        var menus: [NSMenu] = []
        controller.presentMoreMenu = { menu, _, _ in menus.append(menu) }
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        controller.show()
        addTeardownBlock { controller.close() }
        let toolbar = try await laidOutToolbar(in: try XCTUnwrap(controller.window))
        let notice = toolbar.captureNoticeLabel
        func moreMenu() throws -> [String] {
            toolbar.moreButton.performClick(nil)
            return try XCTUnwrap(menus.last).items.map { $0.isSeparatorItem ? "—" : $0.title }
        }

        // While new copies are kept, the toolbar says nothing about them, and ⋯ has nothing to turn on.
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertTrue(notice.isHidden)
        XCTAssertEqual(try moreMenu(), ["Open Library", "Settings…"])

        // With the panel open, a copy the system does not let Keeptide read: the panel follows on its own, the toolbar
        // says why, VoiceOver hears it, whole, and ⋯ still has nothing to turn on.
        clipboard.deniesAccess = true
        clipboard.changeCount += 1
        let reason = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
        try await SearchTestSupport.waitUntil {
            toolbar.layoutSubtreeIfNeeded()
            return !notice.isHidden && notice.stringValue == reason
        }
        XCTAssertEqual(notice.accessibilityValue(), reason)
        XCTAssertEqual(announced, [reason])
        XCTAssertEqual(try moreMenu(), ["Open Library", "Settings…"])

        // Allowed meanwhile, the next copy is kept, and the notice goes with nothing more to read. The notice can go
        // before the kept copy reaches the recent clips, which a store read after the save fills, so the wait is for
        // both.
        clipboard.deniesAccess = false
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil {
            toolbar.layoutSubtreeIfNeeded()
            return notice.isHidden && environment.captureSession.recent.count == 1
        }
        XCTAssertEqual(announced, [reason])
        XCTAssertEqual(try moreMenu(), ["Open Library", "Settings…"])
    }

    func testTheLibraryHasNoRecordingSwitchAndSaysOnlyWhatStopsNewCopies() async throws {
        let clipboard = SessionClipboard()
        let environment = try await makeCapturingEnvironment(clipboard: clipboard)
        let library = LibraryWindowController(session: environment.captureSession, autosaveName: nil,
                                              setActivationPolicy: { _ in })
        let content = try XCTUnwrap(library.window?.contentView)
        addTeardownBlock { library.window?.close() }
        func identified(_ identifier: String) -> (NSObject) -> Bool { { self.identifier(of: $0) == identifier } }

        // Over the recent clips, while new copies are kept: no switch, and no line about them. The Ignored Apps button
        // in the toolbar, outside this view, stays.
        let ready = try swiftUIAccessibilityElements(in: content) { $0.contains(where: identified("RecentClipsEmptyState")) }
        let described = ready.map { "\(self.identifier(of: $0) ?? "?") \(self.text(of: $0) ?? "")" }
        for identifier in ["CaptureRecordingToggle", "IgnoredApplications", "CaptureStatus"] {
            XCTAssertFalse(ready.contains(where: identified(identifier)), "\(identifier): \(described)")
        }
        XCTAssertFalse(ready.contains { self.text(of: $0)?.localizedCaseInsensitiveContains("record") == true },
                       "\(described)")

        // A copy the system does not let Keeptide read: one line says why.
        clipboard.deniesAccess = true
        clipboard.changeCount += 1
        let reason = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
        try await SearchTestSupport.waitUntil { environment.captureSession.captureNotice == reason }
        let denied = try swiftUIAccessibilityElements(in: content) { elements in
            elements.contains { identified("CaptureStatus")($0) && self.text(of: $0) == reason }
        }
        XCTAssertEqual(denied.filter(identified("CaptureStatus")).compactMap { text(of: $0) }, [reason])

        // Allowed meanwhile, the next copy is kept, and the line goes.
        clipboard.deniesAccess = false
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { environment.captureSession.recent.count == 1 }
        let kept = try swiftUIAccessibilityElements(in: content) { !$0.contains(where: identified("CaptureStatus")) }
        XCTAssertFalse(kept.contains(where: identified("CaptureStatus")))
    }

    func testTheLibrarySaysWhyOverEveryListButRecentlyDeleted() async throws {
        let clipboard = SessionClipboard()
        let environment = try await makeCapturingEnvironment(clipboard: clipboard)
        let library = LibraryWindowController(session: environment.captureSession, autosaveName: nil,
                                              setActivationPolicy: { _ in })
        let content = try XCTUnwrap(library.window?.contentView)
        addTeardownBlock { library.window?.close() }
        func identified(_ identifier: String) -> (NSObject) -> Bool { { self.identifier(of: $0) == identifier } }
        /// What the lines identified as the capture status say, once `shown` holds for the elements on screen.
        func notices(once shown: ([NSObject]) -> Bool) throws -> [String] {
            try swiftUIAccessibilityElements(in: content, until: shown).filter(identified("CaptureStatus"))
                .compactMap { text(of: $0) }
        }
        _ = try swiftUIAccessibilityElements(in: content) { $0.contains(where: identified("RecentClipsEmptyState")) }

        // A copy the system does not let Keeptide read.
        clipboard.deniesAccess = true
        clipboard.changeCount += 1
        let reason = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
        try await SearchTestSupport.waitUntil { environment.captureSession.captureNotice == reason }

        // Over All Snippets, as over the recent clips, one line says why.
        try selectLibraryList("All Snippets", in: content)
        XCTAssertEqual(try notices {
            $0.contains(where: identified("SnippetsEmptyState")) && $0.contains(where: identified("CaptureStatus"))
        }, [reason])
        // Recently Deleted, which new copies never reach, says nothing about them.
        try selectLibraryList("Recently Deleted", in: content)
        XCTAssertEqual(try notices { $0.contains(where: identified("RecentlyDeletedEmptyState")) }, [])
        // Back over the recent clips, the line is there again.
        try selectLibraryList("Recent Clips", in: content)
        XCTAssertEqual(try notices {
            $0.contains(where: identified("RecentClipsEmptyState")) && $0.contains(where: identified("CaptureStatus"))
        }, [reason])
    }

    func testTheMenuBarHasNoRecordingSwitchAndSaysOnlyWhatStopsNewCopies() async throws {
        let clipboard = SessionClipboard()
        let environment = try await makeCapturingEnvironment(clipboard: clipboard)
        let underXCTest = ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        let bar = AppDelegate.makeMenuBarController(
            environment: environment, launchConfiguration: LaunchConfiguration(arguments: [], environment: underXCTest),
            canRequestQuit: { true }
        )
        let menu = try XCTUnwrap(bar.menu)
        /// The menu as it opens: each item's title, with "hidden" for an item it does not show.
        func opened() -> [String] {
            bar.menuWillOpen(menu)
            return menu.items.map { $0.isSeparatorItem ? "—" : $0.isHidden ? "hidden" : $0.title }
        }
        let notice = { menu.items.first { $0.identifier?.rawValue == "CaptureStatusMenuItem" } }

        // While new copies are kept, the menu has no switch and says nothing about them.
        func items(saying line: String) -> [String] {
            ["Open Quick Access", "Open Library", "Settings…", "Show Welcome", "—", line,
             "iCloud: Not available in this build", "—",
             "Global shortcut disabled for this test run — open Quick Access here", "—", "Quit Keeptide"]
        }
        let kept = items(saying: "hidden")
        XCTAssertEqual(opened(), kept)

        // A copy the system does not let Keeptide read: one line says why, and cannot be chosen.
        clipboard.deniesAccess = true
        clipboard.changeCount += 1
        let reason = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
        try await SearchTestSupport.waitUntil { environment.captureSession.captureNotice == reason }
        XCTAssertEqual(opened(), items(saying: reason))
        XCTAssertEqual(notice()?.isEnabled, false)
        XCTAssertNil(notice()?.action)

        // Allowed meanwhile, the next copy is kept, and the line goes.
        clipboard.deniesAccess = false
        clipboard.changeCount += 1
        try await SearchTestSupport.waitUntil { environment.captureSession.recent.count == 1 }
        XCTAssertEqual(opened(), kept)
    }

    func testVoiceOverHearsTheCaptureNoticeAsItAppearsOrChangesWhileThePanelIsOpen() async throws {
        // A panel over clips, given its notice as the app gives it, once the panel is made: the panel follows the
        // notice from the next time it follows its state, as when the clips load.
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["older", "newer"], into: harness)
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board)
        let source = CaptureNoticeSource()
        controller.captureNotice = { source.notice }
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        let full = "Storage is full. Free some space to keep new copies."
        let denied = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."

        // A notice there as the panel opens is shown, not read: VoiceOver would hear it each time the panel opens.
        source.notice = full
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 2 }
        let toolbar = try await laidOutToolbar(in: try XCTUnwrap(controller.window))
        XCTAssertEqual(toolbar.captureNotice, full)
        // The panel follows what opening changed, with the notice as it was.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(announced, [])

        // Changed to another while the panel is open, it is read, once.
        source.notice = denied
        try await SearchTestSupport.waitUntil { toolbar.captureNotice == denied }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(announced, [denied])

        // Gone, there is nothing to read; back while the panel is open, it is read again.
        source.notice = nil
        try await SearchTestSupport.waitUntil { toolbar.captureNotice == nil }
        source.notice = full
        try await SearchTestSupport.waitUntil { toolbar.captureNotice == full }
        XCTAssertEqual(announced, [denied, full])

        // Changed while the panel is closed, it is not read, nor as the panel opens again.
        controller.close()
        source.notice = denied
        try await SearchTestSupport.waitUntil { toolbar.captureNotice == denied }
        controller.show()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(toolbar.captureNotice, denied)
        XCTAssertEqual(announced, [denied, full])
    }

    func testAClickBesideTheBandClosesThePanel() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let band = try bandRect(in: window)

        // The band itself takes clicks as ever.
        try click(at: NSPoint(x: band.minX + 40, y: band.maxY - 8), in: window)
        XCTAssertTrue(controller.isSessionOpen)

        // Below it the panel only holds the band's shadow: a click there is a click beside the panel, which closes.
        try click(at: NSPoint(x: band.midX, y: band.minY - 10), in: window)
        XCTAssertFalse(controller.isSessionOpen)
    }

    func testClickingTheExposedBandClosesOnlyThePreviewAndConsumesTheClick() async throws {
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        editor.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil { controller.state.query == "e" }
        controller.perform(.focusResults)
        controller.perform(.togglePreview)
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let band = try bandRect(in: window)
        let selection = controller.state.selection.selectedID
        board.declareTypes([.string], owner: nil)
        XCTAssertTrue(board.setString("untouched", forType: .string))
        let changeCount = board.changeCount

        // The preview leaves at least 24 pt of the band visible at either side. This click is only a dismissal gesture:
        // it does not reach the toolbar or strip underneath and does not close the Quick Access session.
        try click(at: NSPoint(x: band.minX + 12, y: band.midY), in: window)
        XCTAssertFalse(controller.state.isPreviewExpanded)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertEqual(controller.state.selection.selectedID, selection)
        XCTAssertEqual(controller.state.query, "e")
        XCTAssertEqual(field.stringValue, "e")
        XCTAssertEqual(board.changeCount, changeCount)
        XCTAssertEqual(board.string(forType: .string), "untouched")
    }

    func testCommandFKeepsTheEditingSession() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha note", "beta note"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        editor.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil { controller.state.query == "beta" }
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        // ⌘F in a search that is already being edited leaves the editing as it is: the caret stays where it was.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))

        // And a composition in progress goes on.
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), NSRange(location: 2, length: 2))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(isEditing(field, in: window))
    }

    func testLibraryShortcutsDoNotInterruptMarkedSearchText() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha note"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        var opens = 0
        var creates = 0
        controller.onOpenInLibrary = { _, _ in opens += 1 }
        controller.onNewSnippet = { _ in creates += 1 }
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let caret = editor.selectedRange()
        let query = controller.state.query
        for (code, character) in [(kVK_ANSI_S, "s"), (kVK_ANSI_E, "e"), (kVK_ANSI_N, "n"),
                                  (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_L, "l"),
                                  (kVK_ANSI_D, "d")] {
            // Consumed without acting, so AppKit cannot offer it to New/Save in
            // the main menu after this window returns. A list does not change under a composition either.
            XCTAssertTrue(window.performKeyEquivalent(with: try key(code, character, modifiers: .command)))
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.markedRange(), marked)
            XCTAssertEqual(editor.selectedRange(), caret)
            XCTAssertEqual(controller.state.query, query)
            XCTAssertTrue(isEditing(field, in: window))
        }
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(controller.state.list, .all)
        // From Snippets, where ⌘[ would go back to All, the composition keeps the list too.
        controller.state.setList(.snippets)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_LeftBracket, "[", modifiers: .command)))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(controller.state.list, .snippets)
    }

    func testTheLibrarysShortcutsStopAtThePanelWhereverItsKeysAre() async throws {
        try requireANSICommandLayer()
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        var handedOver = 0
        controller.onOpenInLibrary = { _, _ in handedOver += 1 }
        controller.onNewSnippet = { _ in handedOver += 1 }
        controller.onOpenLibrary = { handedOver += 1 }
        controller.onOpenSettings = { handedOver += 1 }
        let selected = controller.state.selection.selectedID
        let library = try libraryOnlyKeys()
        // Edit's Cut, Copy, Paste and Select All: nothing in the strip, the lists or the filter button takes them, and
        // the menu bar would send them on to the library's list or editor.
        let editing = [try key(kVK_ANSI_X, "x", modifiers: .command), try key(kVK_ANSI_C, "c", modifiers: .command),
                       try key(kVK_ANSI_V, "v", modifiers: .command), try key(kVK_ANSI_A, "a", modifiers: .command)]

        // The search field has the keys as the panel opens: the panel takes the library's keys, and nothing changes.
        for event in library {
            XCTAssertTrue(window.performKeyEquivalent(with: event), event.charactersIgnoringModifiers ?? "")
        }
        XCTAssertTrue(isEditing(field, in: window))
        // From the strip, the lists and the filter button, in Tab's order, it takes the editing keys too.
        for station in [strip, toolbar.lists, toolbar.filterButton] as [NSView] {
            controller.perform(.cycleFocus(forward: true))
            XCTAssertTrue(window.firstResponder === station, "\(type(of: station))")
            for event in library + editing {
                XCTAssertTrue(window.performKeyEquivalent(with: event),
                              "\(type(of: station)): \(event.charactersIgnoringModifiers ?? "")")
                XCTAssertTrue(window.firstResponder === station, "\(type(of: station))")
            }
        }
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertEqual(controller.state.query, "")
        XCTAssertEqual(controller.state.list, .all)
        XCTAssertEqual(controller.state.selection.selectedID, selected)
        XCTAssertEqual(handedOver, 0)
    }

    func testCutCopyPasteAndSelectAllStillReachTheTextInThePanel() async throws {
        try requireANSICommandLayer()
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isKeyWindow, "The panel has the keys")
        let edit = try XCTUnwrap(ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")
            .item(withTitle: "Edit")?.submenu)
        let editing = [(kVK_ANSI_X, "x", "Cut"), (kVK_ANSI_C, "c", "Copy"), (kVK_ANSI_V, "v", "Paste"),
                       (kVK_ANSI_A, "a", "Select All")]
        // The panel lets the keys go on to the menu bar, whose items send them to the text with the keys, as they would
        // with no panel in front. Cut, Copy and Paste are not sent here, as they would use the clipboard.
        func assertEditingReaches(_ text: NSTextView, _ name: String) throws {
            for (code, character, title) in editing {
                XCTAssertFalse(window.performKeyEquivalent(with: try key(code, character, modifiers: .command)),
                               "\(name): \(title)")
                let item = try XCTUnwrap(edit.item(withTitle: title))
                let target = NSApp.target(forAction: try XCTUnwrap(item.action), to: item.target, from: item)
                XCTAssertTrue(target as AnyObject? === text, "\(name): \(title)")
            }
        }

        // The preview's text, once it has the keys.
        _ = try searchEditor(in: controller)
        controller.perform(.focusResults)
        controller.perform(.togglePreview)
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        settleLayout()
        let preview = try XCTUnwrap(views(NSTextView.self, in: window.contentView).first { !$0.isFieldEditor })
        XCTAssertTrue(window.makeFirstResponder(preview))
        try assertEditingReaches(preview, "Preview")
        controller.perform(.togglePreview)

        // The search field's text.
        let (field, editor) = try searchEditor(in: controller)
        editor.insertText("synthetic query", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil { controller.state.query == "synthetic query" }
        editor.setSelectedRange(NSRange(location: 0, length: 9))
        try assertEditingReaches(editor, "Search field")
        XCTAssertTrue(editor.validateUserInterfaceItem(try XCTUnwrap(edit.item(withTitle: "Cut"))))
        XCTAssertTrue(editor.validateUserInterfaceItem(try XCTUnwrap(edit.item(withTitle: "Copy"))))
        // Select All leaves the clipboard alone, so it is sent: the menu selects the whole query.
        XCTAssertTrue(edit.performKeyEquivalent(with: try key(kVK_ANSI_A, "a", modifiers: .command)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 15))
        // ⌘← is no key the menu bar has, and goes on, to the text.
        XCTAssertFalse(window.performKeyEquivalent(with: try key(kVK_LeftArrow, "\u{F702}", modifiers: .command)))
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertEqual(field.stringValue, "synthetic query")
    }

    func testEveryLibraryKeyInTheMenuBarStopsAtThePanel() throws {
        try requireANSICommandLayer()
        // With no session open, as while the panel waits for Return to come up after an action, the panel runs none of
        // its commands, so each key can be pressed in turn. The search field has the keys.
        let controller = PanelController()
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        var taken: [String] = [], goneOn: [String] = []
        for item in keyedItems(in: ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")) {
            if window.performKeyEquivalent(with: try key(for: item)) {
                taken.append(item.title)
            } else {
                goneOn.append(item.title)
            }
        }
        // Every item that acts on the library window is kept from it, those the panel has commands of its own for too.
        XCTAssertEqual(taken, ["New Snippet", "New Collection…", "Save", "Find in Note…", "Search Library…",
                               "Copy Entire Item", "Show Sidebar", "Show Inspector", "Previous List", "Next List",
                               "Choose List…", "Add to Favorites", "Add to Collection…", "Move to Recently Deleted"])
        // The others act elsewhere: the app takes Settings… and Quit, the search field's text Cut, Copy, Paste and
        // Select All, and the panel's window Undo, Redo and Close.
        XCTAssertEqual(goneOn, ["Settings…", "Quit Keeptide", "Undo", "Redo", "Cut", "Copy", "Paste", "Select All",
                                "Close"])
        for action in ["undo:", "redo:", "performClose:"] {
            XCTAssertTrue(window.responds(to: NSSelectorFromString(action)), action)
        }
    }

    func testTheMenuBarsKeysAreKnownByWhatTheyTypeWithCommand() async throws {
        try requireANSICommandLayer()
        // On a layout such as Russian the keys type Cyrillic letters, and with ⌘ the Latin ones by which the menu bar
        // knows its items' keys. These events type Cyrillic letters; their key codes type Latin ones with ⌘ here.
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let paste = try key(kVK_ANSI_V, "м", modifiers: .command)

        // The search field's text takes Paste: it goes on to the menu bar.
        XCTAssertFalse(window.performKeyEquivalent(with: paste))
        XCTAssertTrue(isEditing(field, in: window))
        // From the strip, Paste, New Collection… and Show Sidebar stop at the panel.
        controller.perform(.focusResults)
        for event in [paste, try key(kVK_ANSI_N, "Т", modifiers: [.command, .shift]),
                      try key(kVK_ANSI_S, "ы", modifiers: [.control, .command])] {
            XCTAssertTrue(window.performKeyEquivalent(with: event), event.charactersIgnoringModifiers ?? "")
        }
        XCTAssertTrue(controller.isSessionOpen)
    }

    func testOptionCommandWClosesOnlyThePanel() async throws {
        try requireANSICommandLayer()
        // AppKit adds Close All to the app's Window menu, as Close's alternate with ⌥⌘W. From the panel it would close
        // the library window too.
        let windowMenu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Window")?.submenu)
        let closeAll = try XCTUnwrap(windowMenu.items.first { $0.action == NSSelectorFromString("closeAll:") })
        XCTAssertEqual(closeAll.keyEquivalent, "w")
        XCTAssertEqual(closeAll.keyEquivalentModifierMask, [.command, .option])
        let (controller, _) = try await makePanelWithClips(["older"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_W, "∑", modifiers: [.command, .option])))
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertFalse(window.isVisible)
    }

    func testACompositionStillHasTheLibrarysKeysAsKeys() async throws {
        try requireANSICommandLayer()
        let (controller, _) = try await makePanelWithClips(["older"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let composing = try composingText(in: controller)
        let library = try libraryOnlyKeys()

        // With a session open, the keys the panel has no command for go to the composition, for the input method. The
        // panel's own commands wait for the composition and take their keys (see
        // testLibraryShortcutsDoNotInterruptMarkedSearchText).
        for event in library {
            XCTAssertTrue(window.performKeyEquivalent(with: event), event.charactersIgnoringModifiers ?? "")
        }
        XCTAssertEqual(composing.keys, library)
        // Copy goes on to the menu bar, which sends it to the text.
        XCTAssertFalse(window.performKeyEquivalent(with: try key(kVK_ANSI_C, "c", modifiers: .command)))
        XCTAssertEqual(composing.keys, library)

        // With no session, as while the panel waits for Return to come up, every library key goes to the composition,
        // the panel's own ⌘S, ⌘[, ⇧⌘M and ⌘⌫ too.
        let idle = PanelController()
        let idleWindow = try XCTUnwrap(idle.window)
        let idleComposing = try composingText(in: idle)
        let all = library + [try key(kVK_ANSI_S, "s", modifiers: .command),
                             try key(kVK_ANSI_LeftBracket, "[", modifiers: .command),
                             try key(kVK_ANSI_M, "M", modifiers: [.command, .shift]),
                             try key(kVK_Delete, "\u{7F}", modifiers: .command)]
        for event in all {
            XCTAssertTrue(idleWindow.performKeyEquivalent(with: event), event.charactersIgnoringModifiers ?? "")
        }
        XCTAssertEqual(idleComposing.keys, all)
    }

    func testAnInputMethodsFirstKeyUnfoldsTheSearchAtTheRight() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["beta one", "beta two", "beta three"], into: harness)
        try await harness.consumer.synchronize()
        let gate = ScanGate()
        addTeardownBlock { gate.open() }
        let search = SearchService(index: harness.index, status: harness.status, scanChunkSize: 2,
                                   onScanProgress: { _ in gate.pass() })
        let controller = try makePanel(over: harness, pasteboard: board, search: search)
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 3 }
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        XCTAssertFalse(controller.state.isSearchExpanded)
        toolbar.layoutSubtreeIfNeeded()
        let folded = toolbar.search.convert(toolbar.search.bounds, to: nil)
        var moved: [NSTextView] = []
        controller.fieldCharactersMoved = { editor in
            moved.append(editor)
            editor.inputContext?.invalidateCharacterCoordinates()
        }

        // The first key of a composition, as an input method gives it: marked text, before any change is reported.
        editor.setMarkedText("b", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))

        // The search opens to the left of where its circle was, to show it, and the composition goes on in the field.
        XCTAssertTrue(controller.state.isSearchExpanded)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.search.frame.width, 300)
        let pill = toolbar.search.convert(toolbar.search.bounds, to: nil)
        let pillOnScreen = window.convertToScreen(pill)
        XCTAssertEqual(pill.maxX, folded.maxX, accuracy: 0.5)
        XCTAssertEqual(moved.count, 1)
        XCTAssertTrue(moved.first === editor)
        let marked = editor.firstRect(forCharacterRange: editor.markedRange(), actualRange: nil)
        XCTAssertGreaterThanOrEqual(marked.minX, pillOnScreen.minX + 34 - 1)
        XCTAssertLessThanOrEqual(marked.maxX, pillOnScreen.maxX)
        XCTAssertTrue(marked.intersects(pillOnScreen))
        XCTAssertEqual(field.alphaValue, 1)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), NSRange(location: 0, length: 1))
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertEqual(controller.state.query, "", "Nothing is searched for until the composition is committed")

        // Committing a short query starts a progressive scan; its status changes only the right end.
        editor.insertText("be", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil { toolbar.note == .status("Searching…") }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(moved.count, 1)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertEqual(toolbar.search.convert(toolbar.search.bounds, to: nil), pill, "Searching… moves nothing")
    }

    func testTheFocusRingsStayInsideTheBandsCorners() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let band = QuickAccessBandBackdrop.outline(in: try bandRect(in: window))
        func assertInside(_ ring: NSRect, radius: CGFloat, _ name: String) {
            let outline = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: ring)
            // Forty-eight points on the continuous outline, including its curved corners, not just its bounds.
            for sample in 1...48 {
                let point = outline.trimmedPath(from: 0, to: CGFloat(sample) / 48).cgPath.currentPoint
                XCTAssertTrue(band.contains(point), "\(name), sample \(sample): \(point)")
            }
        }
        // The search's ring, at the top right, folded and open.
        controller.perform(.focusResults)
        try XCTUnwrap(window.firstResponder as? QuickAccessStripView).keyDown(with: try key(kVK_Tab, "\t", modifiers: .shift))
        for expanded in [false, true] {
            if expanded {
                XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
            }
            toolbar.layoutSubtreeIfNeeded()
            XCTAssertTrue(isEditing(field, in: window))
            XCTAssertEqual(controller.state.isSearchExpanded, expanded)
            let halo = toolbar.focusHalo
            XCTAssertFalse(halo.isHidden)
            assertInside(halo.convert(halo.bounds, to: nil), radius: 19, "search, expanded \(expanded)")
        }
        // The lists' ring, around the All segment at the top left, as far out as a focus ring is drawn.
        XCTAssertTrue(window.makeFirstResponder(toolbar.lists))
        XCTAssertEqual(toolbar.lists.stopUnderCursor, .all)
        let segment = toolbar.lists.convert(toolbar.lists.focusRingMaskBounds, to: nil).insetBy(dx: -4, dy: -4)
        assertInside(segment, radius: segment.height / 2, "the All segment")
    }

    func testTheClearButtonEmptiesTheQueryAndUndoBringsItBack() async throws {
        let (controller, _) = try await makePanelWithClips(["alpha note", "beta note"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let undo = try XCTUnwrap(editor.undoManager)
        let groupsByEvent = undo.groupsByEvent
        defer { undo.groupsByEvent = groupsByEvent }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        editor.breakUndoCoalescing()
        try await SearchTestSupport.waitUntil { controller.state.query == "beta" }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(toolbar.search.clearButton.isHidden)

        // The clear button empties the query; the search stays open with the keys in its field.
        undo.beginUndoGrouping()
        toolbar.search.clearButton.performClick(nil)
        if undo.groupingLevel > 0 { undo.endUndoGrouping() }
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(controller.state.query, "")
        XCTAssertTrue(controller.state.isSearchExpanded)
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertTrue(field.currentEditor() === editor)

        // Undo brings the query back.
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(field.stringValue, "beta")
        try await SearchTestSupport.waitUntil { controller.state.query == "beta" }
        XCTAssertEqual(controller.state.query, "beta")
    }

    func testEachMoreMenuItemClosesThePanelAndRunsItsCommand() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let toolbar = try await laidOutToolbar(in: window)
        var ran: [String] = []
        controller.onOpenLibrary = { [unowned controller] in ran.append("library, panel open: \(controller.isSessionOpen)") }
        controller.onOpenSettings = { [unowned controller] in ran.append("settings, panel open: \(controller.isSessionOpen)") }
        var menus: [NSMenu] = []
        controller.presentMoreMenu = { menu, _, _ in menus.append(menu) }

        // Open Library closes the panel, then opens the Library.
        toolbar.moreButton.performClick(nil)
        try XCTUnwrap(menus.last).performActionForItem(at: 0)
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertEqual(ran, ["library, panel open: false"])

        // Settings… does the same for Settings.
        controller.show()
        toolbar.moreButton.performClick(nil)
        try XCTUnwrap(menus.last).performActionForItem(at: 1)
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertEqual(ran, ["library, panel open: false", "settings, panel open: false"])
    }

    func testTabIntoTheFoldedSearchRingsItsCircle() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        toolbar.layoutSubtreeIfNeeded()
        // As the panel opens, the keys are in the folded field and the circle has no ring.
        XCTAssertTrue(toolbar.focusHalo.isHidden)

        // Shift-Tab back from the strip to the search: the folded circle is ringed, and stays folded.
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)
        strip.keyDown(with: try key(kVK_Tab, "\t", modifiers: .shift))
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertFalse(controller.state.isSearchExpanded)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.search.frame.width, 28)
        XCTAssertFalse(toolbar.focusHalo.isHidden)
        XCTAssertEqual(toolbar.focusHalo.frame, toolbar.search.frame.insetBy(dx: -3, dy: -3))

        // The ring goes with the keys, and comes back with Shift-Tab from the strip.
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(window.firstResponder === strip)
        XCTAssertTrue(toolbar.focusHalo.isHidden)
        strip.keyDown(with: try key(kVK_Tab, "\t", modifiers: .shift))
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertFalse(toolbar.focusHalo.isHidden)
        XCTAssertFalse(controller.state.isSearchExpanded)

        // Closed and opened again, the panel gives the field the keys as it opens, and the circle has no ring.
        controller.close()
        controller.show()
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertTrue(toolbar.focusHalo.isHidden)

        // Brought back by the keyboard, the circle is ringed again. Opened with ⌘F, the search is ringed as the open
        // search always is while its field has the keys; folded again by Escape, it is as the panel opened it, with
        // no ring. Tab goes to the strip once its clips are back.
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 2 }
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.insertTab(_:)))
        try XCTUnwrap(window.firstResponder as? QuickAccessStripView)
            .keyDown(with: try key(kVK_Tab, "\t", modifiers: .shift))
        XCTAssertFalse(toolbar.focusHalo.isHidden)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
        XCTAssertTrue(controller.state.isSearchExpanded)
        XCTAssertFalse(toolbar.focusHalo.isHidden)
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(controller.state.isSearchExpanded)
        XCTAssertTrue(isEditing(field, in: window))
        XCTAssertTrue(toolbar.focusHalo.isHidden)
    }

    func testTheEmptyStateAndTheToolbarStatusHaveTheirOwnIdentifiers() throws {
        addTeardownBlock { self.panelUnderTest = nil }
        // The panel is set up and searched in a task, and the test waits for it. What follows asks accessibility for
        // SwiftUI's elements, which turns the run loop over; it must not run inside a test's own task.
        let searched = expectation(description: "A search that finds nothing")
        var setupError: (any Error)?
        Task { @MainActor in
            defer { searched.fulfill() }
            do {
                let (controller, _) = try await self.makePanelWithClips(["alpha", "beta"])
                let (_, editor) = try self.searchEditor(in: controller)
                editor.insertText("zzzz-no-match", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await SearchTestSupport.waitUntil { controller.state.phase == .noResults }
                self.panelUnderTest = controller
            } catch {
                setupError = error
            }
        }
        wait(for: [searched], timeout: 20)
        // A setup that failed says why, rather than leaving only a missing panel.
        if let setupError { throw setupError }
        let controller = try XCTUnwrap(panelUnderTest)
        defer { controller.state.close() }
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let content = try XCTUnwrap(window.contentView)

        // "No results" in the card area is the empty state's, not the toolbar status's: a test that looks for one can
        // never find the other.
        let elements = try swiftUIAccessibilityElements(in: content) { elements in
            elements.contains { self.text(of: $0)?.contains("No results") == true }
        }
        let noResults = try XCTUnwrap(elements.first { self.text(of: $0)?.contains("No results") == true })
        XCTAssertEqual(accessibility(noResults, "accessibilityIdentifier") as? String, "QuickAccessEmptyState")
        XCTAssertFalse(elements.contains { (accessibility($0, "accessibilityIdentifier") as? String) == "QuickAccessStatus" },
                       "Only the toolbar's status is QuickAccessStatus, and it shows nothing here")
    }

    func testOpenStripDocksTheNewestClipAtTheLeftEnd() async throws {
        let (controller, _) = try await makePanelWithClips((0..<40).reversed().map { "clip \($0)" })
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let metrics = try stripMetrics(in: window)
        let left = strip.bounds.midX - metrics.bandWidth / 2

        // The newest clip is selected and rests the dock inset in from the band's left end, with the older clips
        // running to its right.
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": clip 0") == true, selectedClipLabel(in: strip) ?? "")
        let newest = try drawnFrame(of: "clip 0", in: strip)
        XCTAssertEqual(newest.minX - left, metrics.dockInset, accuracy: 0.5)
        XCTAssertEqual(try frame(of: "clip 1", in: strip).minX - frame(of: "clip 0", in: strip).minX,
                       metrics.step + metrics.neighbourPush, accuracy: 1)
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

    func testStepsInTheDockKeepTheNewestCardsEdgeAtTheDock() async throws {
        let (controller, _) = try await makePanelWithClips((0..<40).reversed().map { "clip \($0)" })
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let docked = try drawnFrame(of: "clip 0", in: strip).minX

        // Near the newest end the selection walks along the film while the newest visible edge stays docked.
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows[1].ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": clip 1") == true, selectedClipLabel(in: strip) ?? "")
        XCTAssertEqual(try drawnFrame(of: "clip 0", in: strip).minX, docked, accuracy: 0.5)
        controller.state.close()
    }

    func testAVanishedSelectionLeavesTheDockEmptyAndRightPicksTheNewest() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let items = try await insertClips((0..<40).reversed().map { "clip \($0)" }, into: harness)
        let controller = try makePanel(over: harness, pasteboard: board)
        controller.state.open()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 40 }
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let metrics = try stripMetrics(in: window)
        let dock = NSRect(x: strip.bounds.midX - metrics.bandWidth / 2 + metrics.dockInset, y: strip.bounds.minY,
                          width: metrics.frameSize.width, height: strip.bounds.height)
        // The strip follows the state a moment after it changes, so each step waits for the strip itself.
        try await SearchTestSupport.waitUntil { self.selectedClipLabel(in: strip)?.hasSuffix(": clip 0") == true }

        // The newest clip, selected at the dock, leaves the list.
        var newest = try XCTUnwrap(items.last)
        newest.historyDeletedAt = Date()
        try await harness.update(.item(newest.id), to: .item(newest))
        controller.state.recentClipsChanged()
        try await SearchTestSupport.waitUntil {
            controller.state.selection.selectionLost && strip.accessibilitySelectedChildren()?.isEmpty != false
                && self.hasFrame(titled: "clip 1", in: strip) && !self.hasFrame(titled: "clip 0", in: strip)
        }

        // Its place at the dock stays empty, without a ring, and the clips left start one step to its right.
        let frames = framesOnScreen(in: strip)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertFalse(frames.contains { strip.convert($0.bounds, from: $0).intersects(dock) })
        XCTAssertFalse(frames.contains { $0.isAccessibilitySelected() })
        XCTAssertEqual(try frame(of: "clip 1", in: strip).minX - dock.minX, metrics.step, accuracy: 0.5)

        // Right selects the newest clip left, which comes to the dock.
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref)
        XCTAssertTrue(selectedClipLabel(in: strip)?.hasSuffix(": clip 1") == true, selectedClipLabel(in: strip) ?? "")
        XCTAssertEqual(try drawnFrame(of: "clip 1", in: strip).minX, dock.minX, accuracy: 0.5)
        controller.state.close()
    }

    func testCommandKBesideTheEmptyDock() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let items = try await insertClips((0..<40).reversed().map { "clip \($0)" }, into: harness)
        let controller = try makePanel(over: harness, pasteboard: board)
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 40 }
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        let metrics = try stripMetrics(in: window)
        var anchors: [NSPoint] = []
        controller.presentActionMenu = { _, point, _ in anchors.append(point) }

        // The newest clip, selected at the dock, leaves the list, and its place there stays empty.
        var newest = try XCTUnwrap(items.last)
        newest.historyDeletedAt = Date()
        try await harness.update(.item(newest.id), to: .item(newest))
        controller.state.recentClipsChanged()
        try await SearchTestSupport.waitUntil {
            controller.state.selection.selectionLost && strip.accessibilitySelectedChildren()?.isEmpty != false
        }
        let slot = try frame(of: "clip 1", in: strip).offsetBy(dx: -metrics.step, dy: 0)
        XCTAssertEqual(slot.minX - (strip.bounds.midX - metrics.bandWidth / 2), metrics.dockInset, accuracy: 0.5)

        // ⌘K opens beside that empty place, level with its top edge, as it would beside a clip selected there, and
        // not beside the middle of the strip.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_K, "k", modifiers: .command)))
        let anchor = try XCTUnwrap(anchors.first)
        XCTAssertEqual(anchor.x, slot.maxX, accuracy: metrics.gap)
        XCTAssertGreaterThanOrEqual(anchor.x, slot.maxX)
        XCTAssertEqual(anchor.y, slot.maxY, accuracy: 1)
    }

    func testTheOldestEndStopsTheFilmOnlyOncePagingIsDone() async throws {
        // On screen, so the film slides where it moves.
        let (controller, _) = try await makePanelWithClips((0..<61).map { "ab \($0)" }, shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        // Establish the first page and the long jump without an unrelated selection spring. Motion is enabled
        // below only for the page arrival this test measures, whatever the Mac's Reduce Motion setting is.
        strip.reducesMotion = { true }
        let metrics = try stripMetrics(in: window)
        let left = strip.bounds.midX - metrics.bandWidth / 2
        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "ab" && controller.state.phase == .results
                && controller.state.selection.isComplete
        }
        XCTAssertEqual(controller.state.selection.rows.count, 60)
        XCTAssertTrue(controller.state.hasMoreRows)

        // The last row of the first page is not the oldest match: the film keeps it in the middle while the next
        // page is on its way. The strip shows the first page before the step is taken, so the step starts from it.
        try await SearchTestSupport.waitUntil {
            self.framesOnScreen(in: strip).count > 1 && self.selectedClipLabel(in: strip) != nil
                && self.hasFrame(titled: controller.state.selection.rows[0].title, in: strip)
        }
        controller.perform(.move(59))
        let title = controller.state.selection.rows[59].title
        CATransaction.flush()
        // No await separates the step and the frozen clock: the next page cannot arrive during this setup.
        XCTAssertEqual(controller.state.selection.rows.count, 60)
        XCTAssertTrue(controller.state.hasMoreRows)
        XCTAssertEqual(try frame(of: title, in: strip).midX - left, metrics.bandWidth / 2, accuracy: 0.5)

        // Time stands still from here, so a slide that the next page starts stays at its beginning.
        strip.wantsLayer = true
        strip.layer?.speed = 0
        strip.reducesMotion = { false }
        defer { strip.layer?.speed = 1 }
        // The next page brings the last match. With no more to fetch, the film comes to rest with it at the right
        // dock, and slides there: the selected clip is still drawn in the middle, where it was.
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.count == 61 && !controller.state.hasMoreRows
                && self.hasFrame(titled: controller.state.selection.rows[60].title, in: strip)
        }
        let oldest = try drawnFrame(of: controller.state.selection.rows[60].title, in: strip)
        XCTAssertEqual(oldest.maxX - left, metrics.bandWidth - metrics.dockInset, accuracy: 0.5)
        CATransaction.flush()
        let drawn = try frame(of: title, in: strip).midX + (try filmOffset(in: strip))
        XCTAssertEqual(drawn - left, metrics.bandWidth / 2, accuracy: 1)
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
        try await insertClips((0..<3).map { "ab \($0)" }, into: harness)
        try await harness.consumer.synchronize()
        // A two-letter query is scanned, here two clips at a time, and the scan holds after its first page until
        // the gate opens.
        let gate = ScanGate()
        addTeardownBlock { gate.open() }
        let search = SearchService(index: harness.index, status: harness.status, scanChunkSize: 2,
                                   onScanProgress: { _ in gate.pass() })
        let controller = try makePanel(over: harness, pasteboard: board, search: search)
        controller.state.open()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 3 }
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        let metrics = try stripMetrics(in: window)
        let left = strip.bounds.midX - metrics.bandWidth / 2

        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "ab" && controller.state.phase == .results
                && self.framesOnScreen(in: strip).count == 2
        }
        XCTAssertFalse(controller.state.selection.isComplete)
        XCTAssertEqual(controller.state.selection.rows.count, 2)

        // The rest of the scan may bring more clips, so the two found so far are not centred as a group: they rest
        // at the left dock.
        let first = try drawnFrame(of: controller.state.selection.rows[0].title, in: strip)
        XCTAssertEqual(first.minX - left, metrics.dockInset, accuracy: 0.5)

        // The finished scan is all there is, and three clips fit: they are centred as a group.
        gate.open()
        try await SearchTestSupport.waitUntil {
            controller.state.selection.isComplete && self.framesOnScreen(in: strip).count == 3
        }
        let newest = try drawnFrame(of: controller.state.selection.rows[0].title, in: strip)
        let oldest = try drawnFrame(of: controller.state.selection.rows[2].title, in: strip)
        XCTAssertEqual((newest.minX + oldest.maxX) / 2 - left, metrics.bandWidth / 2, accuracy: 0.5)
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

    func testSpaceOpensThePreviewOverTheStationaryBandAndEscapeClosesIt() async throws {
        // Freeze the layout input: Dock/menu-bar changes can update NSScreen during the async preview load.
        let visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        let (controller, _) = try await makePanelWithClips(["older", "newer"], visibleFrame: visibleFrame)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let bandBefore = window.convertToScreen(try bandRect(in: window))
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)

        strip.keyDown(with: try key(kVK_Space, " "))
        XCTAssertTrue(controller.state.isPreviewExpanded)
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        settleLayout()

        // The preview floats over the band instead of laying out above it: opening it cannot move the strip the
        // pointer and keyboard are already using.
        let band = try bandRect(in: window)
        assertFrame(window.convertToScreen(band), places: bandBefore)
        let text = try XCTUnwrap(views(NSTextView.self, in: window.contentView).first { !$0.isFieldEditor })
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let previewBody = scroll.convert(scroll.bounds, to: nil)
        XCTAssertEqual(text.string, "newer")
        XCTAssertTrue(previewBody.intersects(band))
        XCTAssertEqual(previewBody.midX, band.midX, accuracy: 0.5)
        XCTAssertTrue(window.firstResponder === strip, "The strip keeps the keys")

        // Escape closes the card and leaves the band as it was.
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        settleLayout()
        XCTAssertFalse(controller.state.isPreviewExpanded)
        assertFrame(window.convertToScreen(try bandRect(in: window)), places: bandBefore)
        XCTAssertTrue(window.firstResponder === strip)
        controller.state.close()
    }

    func testEscapeFromANativeControlDismissesOnlyThePreviewWithoutInterruptingComposition() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        controller.togglePreview()
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }

        // Escape still belongs to an active input-method composition before it belongs to the preview.
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(controller.state.isPreviewExpanded)
        XCTAssertTrue(controller.isSessionOpen)

        // Escape also works while a non-text native control has focus. Its key repeat is consumed after the preview
        // disappears instead of immediately peeling the next layer and closing Quick Access too. The SwiftUI close
        // control's pointer and accessibility action are covered by the UI tests; this native button pins responder
        // routing.
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        XCTAssertTrue(window.makeFirstResponder(toolbar.moreButton))
        window.sendEvent(try key(kVK_Escape, "\u{1B}", windowNumber: window.windowNumber))
        XCTAssertFalse(controller.state.isPreviewExpanded)
        XCTAssertTrue(controller.isSessionOpen)
        window.sendEvent(try key(kVK_Escape, "\u{1B}", windowNumber: window.windowNumber, isARepeat: true))
        XCTAssertTrue(controller.isSessionOpen)
    }

    func testClicksOnThePreviewsEmptyPartsStayWithThePreview() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["older", "newer"], into: harness)
        // The newest clip, a small picture shown in the middle of the card, with nothing beside it.
        try await insertImageClip(into: harness)
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board,
                                       visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 3 }
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        controller.perform(.focusResults)
        controller.perform(.togglePreview)
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let band = try bandRect(in: window)
        let selection = controller.state.selection.selectedID
        board.declareTypes([.string], owner: nil)
        XCTAssertTrue(board.setString("untouched", forType: .string))
        let changeCount = board.changeCount

        // On the card, beside the picture, over the strip and its cards.
        let point = NSPoint(x: band.midX - 300, y: band.midY)
        let content = try XCTUnwrap(window.contentView)
        let hit = content.hitTest(content.convert(point, from: nil))
        XCTAssertFalse(hit === strip || hit?.isDescendant(of: strip) == true,
                       "The card takes the pointer, not the strip beneath it: \(String(describing: hit))")
        try click(at: point, in: window)
        try click(at: point, in: window, count: 2)

        XCTAssertTrue(controller.state.isPreviewExpanded, "The preview stays open")
        XCTAssertEqual(controller.state.selection.selectedID, selection, "No clip hidden under the card is selected")
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertEqual(board.changeCount, changeCount, "No clip hidden under the card is copied or pasted")
        XCTAssertEqual(board.string(forType: .string), "untouched")
    }

    func testThePreviewStandsOnATrayLikeTheBands() async throws {
        let (controller, _) = try await makePanelWithClips(
            ["older", "newer"], visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.focusResults)
        controller.perform(.togglePreview)
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        settleLayout()
        let text = try XCTUnwrap(views(NSTextView.self, in: window.contentView).first { !$0.isFieldEditor })
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        // Below the one short line of text, nothing but what the card stands on.
        let body = scroll.convert(scroll.bounds, to: nil)
        let empty = NSRect(x: body.midX - 20, y: body.minY + 40, width: 40, height: 20)
        // The band's own tray, below its top edge and above its toolbar, beside the card.
        let band = try bandRect(in: window)
        let bandTray = NSRect(x: band.minX + 40, y: band.maxY - 10, width: 20, height: 6)
        XCTAssertLessThan(bandTray.maxX, body.minX, "Left of the card, which is as wide as its text")
        XCTAssertFalse(empty.intersects(band), "Above the band, where nothing but the card can show")

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            settleLayout()
            let drawn = try XCTUnwrap(color(in: window, at: empty), "\(appearance.rawValue)")
            let tray = try XCTUnwrap(color(in: window, at: bandTray), "\(appearance.rawValue)")
            XCTAssertEqual(drawn.redComponent, tray.redComponent, accuracy: 1 / 255, "\(appearance.rawValue)")
            XCTAssertEqual(drawn.greenComponent, tray.greenComponent, accuracy: 1 / 255, "\(appearance.rawValue)")
            XCTAssertEqual(drawn.blueComponent, tray.blueComponent, accuracy: 1 / 255, "\(appearance.rawValue)")
        }
        controller.state.close()
    }

    func testAHeldCommandYTogglesThePreviewOnce() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)

        // ⌘Y opens the preview. Held down, its repeats are taken and do nothing, so the card stays open rather than
        // close and open again with each one.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_Y, "y", modifiers: .command)))
        XCTAssertTrue(controller.state.isPreviewExpanded)
        for _ in 0..<3 {
            XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_Y, "y", modifiers: .command,
                                                                    isARepeat: true)))
            XCTAssertTrue(controller.state.isPreviewExpanded)
        }

        // Pressed again, it closes the card, and a held one leaves it closed.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_Y, "y", modifiers: .command)))
        XCTAssertFalse(controller.state.isPreviewExpanded)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_Y, "y", modifiers: .command, isARepeat: true)))
        XCTAssertFalse(controller.state.isPreviewExpanded)
    }

    func testAHeldCommandSSavesOnceAndAHeldCommandEOrNHandsOverOnce() async throws {
        let (controller, _) = try await makeSavingPanel(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        var opened: [ContentRef] = []
        controller.onOpenInLibrary = { ref, _ in opened.append(ref) }
        var newSnippets = 0
        controller.onNewSnippet = { _ in newSnippets += 1 }
        let selected = try XCTUnwrap(controller.state.copyTarget?.ref)

        // ⌘S saves the selected clip and says so. Held down, its repeats are taken and do nothing: saved again, the
        // clip would be already in Snippets, and the save's undo would go.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_S, "s", modifiers: .command)))
        try await SearchTestSupport.waitUntil { announced == ["Saved to Snippets"] }
        for _ in 0..<3 {
            XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_S, "s", modifiers: .command,
                                                                    isARepeat: true)))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(announced, ["Saved to Snippets"])
        XCTAssertEqual(controller.state.saveMessage, "Saved to Snippets")
        XCTAssertTrue(controller.state.canUndoSave)

        // ⌘E and ⌘N hand the clip, or a new snippet, to the library once, however long they are held.
        for (code, character) in [(kVK_ANSI_E, "e"), (kVK_ANSI_N, "n")] {
            XCTAssertTrue(window.performKeyEquivalent(with: try key(code, character, modifiers: .command)))
            for _ in 0..<3 {
                XCTAssertTrue(window.performKeyEquivalent(with: try key(code, character, modifiers: .command,
                                                                        isARepeat: true)))
            }
        }
        XCTAssertEqual(opened, [selected])
        XCTAssertEqual(newSnippets, 1)
    }

    func testOnALowScreenThePreviewStaysCentredOverTheStationaryBand() async throws {
        // 1024 × 440 has no room for even the shortest card above the band.
        let low = NSRect(x: 0, y: 30, width: 1024, height: 440)
        let (controller, _) = try await makePanelWithClips(["older", "newer"], visibleFrame: low)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.focusResults)
        controller.perform(.togglePreview)
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        let expectedBand = StripLayout.bandFrame(
            StripLayout.metrics(for: .medium, visibleWidth: low.width), in: low
        )
        let band = try bandRect(in: window)
        assertFrame(window.convertToScreen(band), places: expectedBand)

        // The card is screen-safe and centred over the band. Its native text viewport is shorter than the card by
        // the bar above it.
        let viewportMidY = band.midY - StripLayout.previewBarHeight / 2
        var card = NSRect.zero
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            let text = self.views(NSTextView.self, in: window.contentView).first { !$0.isFieldEditor }
            card = text?.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? .zero
            return card.height > 0 && abs(card.midY - viewportMidY) <= 0.5
        }
        XCTAssertTrue(card.intersects(band), "Over the band")
        XCTAssertEqual(card.midX, band.midX, accuracy: 0.5)
        XCTAssertEqual(card.midY, viewportMidY, accuracy: 0.5)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertGreaterThanOrEqual(card.minY, content.bounds.minY - 0.5, "Inside the window")
        XCTAssertLessThanOrEqual(card.maxY, content.bounds.maxY + 0.5, "Inside the window")

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
        let selected = try drawnFrame(of: "newer", in: strip)
        XCTAssertTrue(commandK.view === strip)
        XCTAssertEqual(commandK.point.x, selected.maxX, accuracy: try stripMetrics(in: window).gap)
        XCTAssertGreaterThanOrEqual(commandK.point.x, selected.maxX)
        XCTAssertEqual(commandK.point.y, selected.maxY, accuracy: 1)
        XCTAssertEqual(commandK.menu.items.map(\.title), [
            "Copy", "Copy as Plain Text", "", "Show Preview", "",
            "Save as Snippet", "Save to Collection", "Add to Favorites", "", "Show in Library", "New Snippet",
            "", "Move to Recently Deleted",
        ])
        // Save to Collection has its submenu instead of a key: AppKit keeps none on such an item, and ⇧⌘M is the
        // panel's own.
        XCTAssertEqual(commandK.menu.items.map(\.keyEquivalent),
                       ["\r", "\r", "", " ", "", "s", "", "d", "", "e", "n", "", "\u{8}"])
        XCTAssertEqual(commandK.menu.items.filter { !$0.isSeparatorItem && !$0.hasSubmenu }
            .map(\.keyEquivalentModifierMask), [[], .shift, [], .command, .command, .command, .command, .command])
        // Everything is available but Save to Collection, which needs a collection first and says so, and Move to
        // Recently Deleted, which needs a library to move the clip in: this panel has none.
        let saveTo = try XCTUnwrap(commandK.menu.items.first { $0.title == "Save to Collection" })
        XCTAssertFalse(saveTo.isEnabled)
        XCTAssertEqual(saveTo.toolTip, "Create a collection first.")
        let delete = try XCTUnwrap(commandK.menu.items.last)
        XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(commandK.menu.items.allSatisfy {
            $0.isSeparatorItem || $0.isEnabled || $0 === saveTo || $0 === delete
        })
        // A right-click on the selected clip gives the same menu.
        let context = try XCTUnwrap(strip.menu(for: try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: strip.convert(NSPoint(x: selected.midX, y: selected.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))))
        XCTAssertEqual(context.items.map(\.title), commandK.menu.items.map(\.title))
        XCTAssertEqual(context.items.map(\.isEnabled), commandK.menu.items.map(\.isEnabled))
        XCTAssertEqual(context.items.map(\.keyEquivalent), commandK.menu.items.map(\.keyEquivalent))

        // The toolbar's "⏎ Copy" is a button that copies the selected clip, as Return does.
        let copy = try XCTUnwrap(views(QuickAccessCopyHint.self, in: window.contentView).first)
        XCTAssertFalse(copy.isHidden)
        XCTAssertTrue(copy.isEnabled)
        XCTAssertEqual(copy.accessibilityLabel(), "Copy")
        copy.performClick(nil)
        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "newer")
    }

    func testSaveAsSnippetSaysSoInTheToolbarAndTheActionsMenuUndoesIt() async throws {
        let (controller, harness) = try await makeSavingPanel(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        let saved = try XCTUnwrap(controller.state.copyTarget?.ref)
        // Nothing saved yet: the menu has no undo.
        XCTAssertFalse(try actionMenu(of: controller).items.contains { $0.title == "Undo Save as Snippet" })

        // ⌘S says what it did where Return's hint was, and VoiceOver hears it.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_S, "s", modifiers: .command)))
        let toolbar = try await toolbarSaying(.status("Saved to Snippets"), in: controller)
        XCTAssertFalse(toolbar.statusLabel.isHidden)
        XCTAssertEqual(toolbar.statusLabel.stringValue, "Saved to Snippets")
        XCTAssertEqual(toolbar.statusLabel.accessibilityIdentifier(), "QuickAccessStatus")
        XCTAssertTrue(toolbar.copyHint.isHidden)
        try await SearchTestSupport.waitUntil { announced == ["Saved to Snippets"] }

        // ⌘K offers the undo right after Save as Snippet, with no key of its own, and so does a right-click on the
        // clip saved; a right-click on another clip does not, since its menu acts on that clip.
        let menu = try actionMenu(of: controller)
        let undo = try XCTUnwrap(menu.items.firstIndex { $0.title == "Undo Save as Snippet" })
        XCTAssertEqual(menu.items[undo - 1].title, "Save to Collection")
        XCTAssertEqual(menu.items[undo].keyEquivalent, "")
        XCTAssertTrue(menu.items[undo].isEnabled)
        let newer = try drawnFrame(of: "newer", in: strip)
        let older = try frame(of: "older", in: strip)
        func rightClick(at frame: NSRect) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: strip.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ))
        }
        let context = try XCTUnwrap(strip.menu(for: try rightClick(at: newer)))
        XCTAssertEqual(context.items.map(\.title), menu.items.map(\.title))
        let otherClip = try XCTUnwrap(strip.menu(for: try rightClick(at: older)))
        XCTAssertFalse(otherClip.items.contains { $0.title == "Undo Save as Snippet" })

        menu.performActionForItem(at: undo)
        try await SearchTestSupport.waitUntil { controller.state.saveMessage == "Save undone" }
        _ = try await toolbarSaying(.status("Save undone"), in: controller)
        try await SearchTestSupport.waitUntil { announced == ["Saved to Snippets", "Save undone"] }
        XCTAssertEqual(announced, ["Saved to Snippets", "Save undone"])
        let item = try await ContentRepository(controller: harness.controller).recordState(.item(saved.itemID))
        guard case .item(let value) = item.value else { return XCTFail("Missing history") }
        XCTAssertNil(value.memoID, "The undo removed the snippet the panel saved")
        XCTAssertFalse(try actionMenu(of: controller).items.contains { $0.title == "Undo Save as Snippet" })
    }

    func testCommandDeleteMovesTheSelectedClipToRecentlyDeletedAndCommandZPutsItBack() async throws {
        let (controller, harness) = try await makeDeletingPanel(["oldest", "older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        XCTAssertEqual(field.stringValue, "")
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        let newer = try XCTUnwrap(controller.state.copyTarget?.ref)
        let delete = try key(kVK_Delete, "\u{7F}", modifiers: .command)

        // The empty search field holds the keys, as the panel opens: ⌘⌫ takes the selected clip off the strip at once,
        // and the older clip beside it is selected.
        XCTAssertTrue(window.performKeyEquivalent(with: delete))
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["older", "oldest"])
        XCTAssertEqual(controller.state.selection.selectedRow?.title, "older")
        _ = try await toolbarSaying(.status("Moved to Recently Deleted"), in: controller)
        try await SearchTestSupport.waitUntil { announced == ["Moved “newer” to Recently Deleted"] }
        let item = try await ContentRepository(controller: harness.controller).recordState(.item(newer.itemID))
        guard case .item(let moved) = item.value else { return XCTFail("Missing history") }
        XCTAssertFalse(moved.historyEligible)
        XCTAssertNotNil(moved.historyDeletedAt)
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "The keys stay in the search field")

        // Held down, ⌘⌫ has acted already: its repeats take nothing more.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_Delete, "\u{7F}", modifiers: .command,
                                                                isARepeat: true)))
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["older", "oldest"])

        // While the move is the panel's last change, ⌘K offers to undo it with ⌘Z, first in the last group.
        try await SearchTestSupport.waitUntil { window.undoManager?.canUndo == true }
        let menu = try actionMenu(of: controller)
        let undo = try XCTUnwrap(menu.items.firstIndex { $0.title == "Undo Move to Recently Deleted" })
        XCTAssertTrue(menu.items[undo - 1].isSeparatorItem)
        XCTAssertEqual(menu.items[undo].keyEquivalent, "z")
        XCTAssertEqual(menu.items[undo].keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items[undo + 1].title, "Move to Recently Deleted")
        XCTAssertTrue(menu.items[undo + 1].isEnabled)

        // ⌘Z puts it back where it was, selected again.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_Z, "z", modifiers: .command)))
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.map(\.title) == ["newer", "older", "oldest"]
        }
        XCTAssertEqual(controller.state.selection.selectedRow?.title, "newer")
        _ = try await toolbarSaying(.status("Recovered from Recently Deleted"), in: controller)
        try await SearchTestSupport.waitUntil { announced.last == "Recovered “newer”" }
        let recovered = try await ContentRepository(controller: harness.controller).recordState(.item(newer.itemID))
        guard case .item(let back) = recovered.value else { return XCTFail("Missing history") }
        XCTAssertTrue(back.historyEligible)
        XCTAssertFalse(try actionMenu(of: controller).items.contains { $0.title == "Undo Move to Recently Deleted" })
    }

    func testCommandDeleteWithTextInTheSearchFieldDeletesTheTextAndThenTheStripsClips() async throws {
        let (controller, harness) = try await makeDeletingPanel(["older", "newer", "newest"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let delete = try key(kVK_Delete, "\u{7F}", modifiers: .command)

        // With text in the search field, ⌘⌫ is the text's: it deletes to the start of the line, and goes nowhere else,
        // not to the menu bar's Item › Move to Recently Deleted, which acts on the library window.
        editor.insertText("ne", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.query == "ne" && controller.state.phase == .results
                && controller.state.selection.isComplete
        }
        XCTAssertTrue(window.performKeyEquivalent(with: delete))
        XCTAssertEqual(editor.string, "")
        try await SearchTestSupport.waitUntil {
            controller.state.query == "" && controller.state.selection.rows.count == 3
                && controller.state.copyTarget != nil
        }
        // Pressed again at once, in the field it emptied, it still means the text: no clip goes.
        XCTAssertTrue(window.performKeyEquivalent(with: delete))
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["newest", "newer", "older"])

        // From the strip, ⌘⌫ takes the selected clip.
        controller.perform(.focusResults)
        XCTAssertTrue(window.firstResponder is QuickAccessStripView)
        XCTAssertTrue(window.performKeyEquivalent(with: delete))
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["newer", "older"])

        // The menu's Move to Recently Deleted takes the next one, and the last clip gone leaves the keys to the field.
        let menu = try actionMenu(of: controller)
        let move = try XCTUnwrap(menu.items.lastIndex { $0.title == "Move to Recently Deleted" })
        XCTAssertEqual(menu.items[move].identifier?.rawValue, "QuickAccessMoveToRecentlyDeleted")
        XCTAssertEqual(menu.items[move].keyEquivalent, "\u{8}")
        menu.performActionForItem(at: move)
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["older"])
        XCTAssertTrue(window.performKeyEquivalent(with: delete))
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.isEmpty && controller.state.saveMessage == "Moved to Recently Deleted"
        }
        let editing = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editing.isFieldEditor)
        try await SearchTestSupport.waitUntil { (try? await self.trashTitles(in: harness)) == ["newer", "newest", "older"] }
    }

    func testCommandZUndoesMovesInTheOrderTheyWereAskedFor() async throws {
        let (controller, harness) = try await makeDeletingPanel(["older", "newer", "newest"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let delete = try key(kVK_Delete, "\u{7F}", modifiers: .command)
        let undo = try key(kVK_ANSI_Z, "z", modifiers: .command)

        // Two moves asked for one after the other, each a change of its own on the undo stack; the second may still be
        // under way when ⌘Z comes.
        XCTAssertTrue(window.performKeyEquivalent(with: delete))
        XCTAssertTrue(window.performKeyEquivalent(with: delete))
        XCTAssertEqual(window.undoManager?.groupingLevel, 0)
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["older"])
        XCTAssertEqual(window.undoManager?.undoActionName, "Move to Recently Deleted")

        // ⌘Z undoes the last asked for first.
        XCTAssertTrue(window.performKeyEquivalent(with: undo))
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.map(\.title) == ["newer", "older"]
        }
        XCTAssertTrue(window.performKeyEquivalent(with: undo))
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.map(\.title) == ["newest", "newer", "older"]
        }
        try await SearchTestSupport.waitUntil { (try? await self.trashTitles(in: harness)) == [] }
        // Nothing is left to undo, and ⌘Z still stays in the panel.
        XCTAssertTrue(window.performKeyEquivalent(with: undo))
        XCTAssertEqual(window.undoManager?.canUndo, false)
    }

    func testCommandZUndoesTheSearchFieldsTypingWhenNothingWasMoved() async throws {
        let (controller, harness) = try await makeDeletingPanel(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        editor.insertText("plain input", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil { controller.state.query == "plain input" }

        // The field keeps its typing on an undo stack of its own; ⌘Z reaches it, as Edit › Undo does.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_Z, "z", modifiers: .command)))

        XCTAssertEqual(editor.string, "")
        try await SearchTestSupport.waitUntil { controller.state.query == "" }
        XCTAssertEqual(window.undoManager?.canUndo, false)
        let trash = try await trashTitles(in: harness)
        XCTAssertEqual(trash, [])
    }

    func testCommandZUndoesTypingDoneAfterAMoveBeforeTheMove() async throws {
        let (controller, harness) = try await makeDeletingPanel(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let undo = try key(kVK_ANSI_Z, "z", modifiers: .command)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_Delete, "\u{7F}", modifiers: .command)))
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["older"])
        try await SearchTestSupport.waitUntil { (try? await self.trashTitles(in: harness)) == ["newer"] }

        // Typing after the move comes last: ⌘Z undoes it first, and the clip stays in Recently Deleted.
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil { controller.state.query == "x" }
        XCTAssertTrue(window.performKeyEquivalent(with: undo))
        XCTAssertEqual(editor.string, "")
        try await SearchTestSupport.waitUntil { controller.state.query == "" && controller.state.phase == .results }
        let stillMoved = try await trashTitles(in: harness)
        XCTAssertEqual(stillMoved, ["newer"])

        // With the field's edits undone, ⌘Z reaches the move.
        XCTAssertTrue(window.performKeyEquivalent(with: undo))
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.map(\.title) == ["newer", "older"]
        }
        try await SearchTestSupport.waitUntil { (try? await self.trashTitles(in: harness)) == [] }
    }

    func testTheSaveStatusIsTheToolbarsAndNothingLiesOverTheCards() throws {
        addTeardownBlock { self.panelUnderTest = nil }
        // The panel is set up and saves in a task, and the test waits for it. What follows asks accessibility for
        // SwiftUI's elements, which turns the run loop over; it must not run inside a test's own task.
        let saved = expectation(description: "A clip saved as a snippet")
        var setupError: (any Error)?
        Task { @MainActor in
            defer { saved.fulfill() }
            do {
                let (controller, _) = try await self.makeSavingPanel(["older", "newer"])
                await controller.state.saveSelection(try XCTUnwrap(controller.state.copyTarget))
                XCTAssertEqual(controller.state.saveMessage, "Saved to Snippets")
                self.panelUnderTest = controller
            } catch {
                setupError = error
            }
        }
        wait(for: [saved], timeout: 20)
        if let setupError { throw setupError }
        let controller = try XCTUnwrap(panelUnderTest)
        defer { controller.state.close() }
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        settleLayout()
        let content = try XCTUnwrap(window.contentView)

        // Only the toolbar's status says so: no capsule lies over the cards, nor takes their clicks.
        let says = { (element: NSObject) in self.text(of: element) == "Saved to Snippets" }
        _ = try swiftUIAccessibilityElements(in: content) { $0.contains(where: says) }
        settleLayout()
        let elements = accessibilityElements(below: content)
        // AppKit reads a text field out through its cell; the identifier is the field's.
        let identifier = { (element: NSObject) -> String? in
            let owner: NSObject = (element as? NSCell)?.controlView ?? element
            return self.accessibility(owner, "accessibilityIdentifier") as? String
        }
        XCTAssertEqual(elements.filter(says).map(identifier), ["QuickAccessStatus"])
        XCTAssertFalse(elements.contains { ["QuickAccessSaveStatus", "QuickAccessUndoSave"].contains(identifier($0)) })
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

    func testDoubleClickingTheOlderClipPastesItLikeReturn() async throws {
        let pasting = FakeDirectPasteSystem()
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true,
                                                               system: pasting.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        _ = try await toolbarSaying(.action(title: "Paste into TextEdit", enabled: true, hint: nil), in: controller)
        let strip = try await clipStrip(in: window)
        let older = try frame(of: "older", in: strip)
        let point = strip.convert(NSPoint(x: older.midX, y: older.midY), to: nil)
        let click = { (type: NSEvent.EventType, count: Int) in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
        }

        // The first click selects the older clip; the second, once released, pastes it into TextEdit.
        strip.mouseDown(with: try click(.leftMouseDown, 1))
        strip.mouseUp(with: try click(.leftMouseUp, 1))
        strip.mouseDown(with: try click(.leftMouseDown, 2))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pasting.sent, [], "Nothing is sent while the button is down")
        XCTAssertTrue(window.isVisible)
        strip.mouseUp(with: try click(.leftMouseUp, 2))

        try await SearchTestSupport.waitUntil { pasting.sent == [9] }
        XCTAssertEqual(board.string(forType: .string), "older")
        XCTAssertFalse(window.isVisible)
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
        // clip. Chosen with no event to tell how, it takes no Return for down either, since nothing acts.
        let stale = try XCTUnwrap(strip.menu(for: rightClick))
        editor.insertText("newer", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            controller.state.phase == .results && controller.state.selection.rows.map(\.title) == ["newer"]
        }
        controller.currentEvent = { nil }
        stale.performActionForItem(at: 0)
        XCTAssertEqual(controller.state.returnIsDown?(), false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(board.string(forType: .string))

        // Back among the recent clips, the menu selects the clip it was opened on and copies it.
        try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
            .doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await SearchTestSupport.waitUntil { self.framesOnScreen(in: strip).count == 2 }
        try XCTUnwrap(strip.menu(for: rightClick)).performActionForItem(at: 0)
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.last?.ref)
        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "older")
        controller.state.close()
    }

    func testEmptyLibraryShowsTheStripCopyWithoutKeycaps() async throws {
        let (controller, harness) = try await makeEmptyPanel()
        let window = try XCTUnwrap(controller.window)
        try await SearchTestSupport.waitUntil { controller.state.phase == .noContent }

        // Where the clips would be, the band says how they get there; there are no frames and no key hints.
        // SwiftUI's own accessibility is not built without an assistive app, so the copy is checked as drawn, which the
        // band does a moment after the library turns out to be empty.
        XCTAssertEqual(QuickAccessStatus.empty(phase: controller.state.phase, notice: controller.state.indexNotice).text,
                       "No clips yet. Copy something and it shows up here.")
        var copyArea: (strip: QuickAccessStripView, middle: NSRect)?
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let strip = self.views(QuickAccessStripView.self, in: window.contentView).first else { return false }
            let middle = strip.convert(NSRect(x: strip.bounds.midX - 40, y: strip.bounds.midY - 10, width: 80,
                                              height: 20), to: nil)
            copyArea = (strip, middle)
            return try self.contrast(in: window, at: middle) > 0.3
        }
        let (strip, middle) = try XCTUnwrap(copyArea)
        XCTAssertEqual(framesOnScreen(in: strip).count, 0)
        XCTAssertTrue(views(NSHostingView<StripFrameView>.self, in: strip).isEmpty)
        XCTAssertGreaterThan(try contrast(in: window, at: middle), 0.3, "The copy is drawn where the clips would be")
        XCTAssertLessThan(try contrast(in: window, at: middle.offsetBy(dx: -0.3 * strip.bounds.width, dy: 0)), 0.05,
                          "and nothing else is")
        // No key cap is shown anywhere: none beside the band, and Return's is not in the toolbar with nothing to copy.
        XCTAssertEqual(visibleKeycaps(in: window).count, 0, "No key hints")
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        XCTAssertEqual(toolbar.note, QuickAccessToolbar.Note.none)

        // The first clip brings its frame. Once it is selected, Return's hint is in the toolbar: one key cap, inside
        // the band.
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("first".utf8))]])
        let item = ItemValue(title: "first", captureID: capture.id, historyEligible: true,
                             lastCopiedAt: Date(timeIntervalSince1970: 1_000), copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        controller.state.recentClipsChanged()
        // The strip follows the state a moment after the clip arrives.
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return controller.state.selection.rows.count == 1 && self.framesOnScreen(in: strip).count == 1
        }
        XCTAssertEqual(framesOnScreen(in: strip).count, 1)
        controller.perform(.move(1))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.state.selection.selection, controller.state.selection.rows.first?.ref)
        XCTAssertEqual(visibleKeycaps(in: window).map(\.symbol), ["⏎"])
        let keycap = try XCTUnwrap(visibleKeycaps(in: window).first)
        XCTAssertTrue(try bandRect(in: window).contains(keycap.convert(keycap.bounds, to: nil)))
        controller.state.close()
    }

    // MARK: Lists

    func testCommandBracketsStepTheListsAndCommandLTakesTheKeysToThem() async throws {
        let (controller, _, made) = try await showPanelWithLists(clips: ["older", "newer"],
                                                                 collections: ["Prompts", "Shell"])
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        func press(_ code: Int, _ character: String, held: Bool = false) throws -> Bool {
            window.performKeyEquivalent(with: try key(code, character, modifiers: .command, isARepeat: held))
        }

        // ⌘] goes to the next list, from All to Snippets and then each collection, and stops at the last. The keys
        // stay in the search.
        let order: [QuickAccessList] = [.snippets, .collection(made[0].value.id), .collection(made[1].value.id)]
        for expected in order {
            XCTAssertTrue(try press(kVK_ANSI_RightBracket, "]"))
            XCTAssertEqual(controller.state.list, expected)
            XCTAssertTrue(isEditing(field, in: window))
        }
        XCTAssertTrue(try press(kVK_ANSI_RightBracket, "]"))
        XCTAssertEqual(controller.state.list, order.last)

        // Held, ⌘[ keeps stepping back, as an arrow does, and stops at All.
        XCTAssertTrue(try press(kVK_ANSI_LeftBracket, "["))
        XCTAssertTrue(try press(kVK_ANSI_LeftBracket, "[", held: true))
        XCTAssertEqual(controller.state.list, .snippets)
        XCTAssertTrue(try press(kVK_ANSI_LeftBracket, "[", held: true))
        XCTAssertTrue(try press(kVK_ANSI_LeftBracket, "[", held: true))
        XCTAssertEqual(controller.state.list, .all)
        XCTAssertTrue(isEditing(field, in: window))

        // ⌘L takes the keys to the lists, the cursor on the list shown; held, it does that once. Down goes on to the
        // clips.
        XCTAssertTrue(try press(kVK_ANSI_RightBracket, "]"))
        XCTAssertTrue(try press(kVK_ANSI_L, "l"))
        XCTAssertTrue(window.firstResponder === toolbar.lists)
        XCTAssertEqual(toolbar.lists.stopUnderCursor, .snippets)
        toolbar.lists.moveCursor(by: -1)
        XCTAssertTrue(try press(kVK_ANSI_L, "l", held: true))
        XCTAssertEqual(toolbar.lists.stopUnderCursor, .all, "a held ⌘L does nothing more")
        // With the keys on the lists, ⌘[ and ⌘] take the cursor along, so that Space does not undo the step.
        XCTAssertTrue(try press(kVK_ANSI_RightBracket, "]"))
        XCTAssertEqual(controller.state.list, .collection(made[0].value.id))
        XCTAssertEqual(toolbar.lists.stopUnderCursor, .collection(made[0].value.id))
        toolbar.lists.keyDown(with: try key(kVK_Space, " "))
        XCTAssertEqual(controller.state.list, .snippets, "Space on the chosen chip goes back to Snippets")
        XCTAssertTrue(try press(kVK_ANSI_LeftBracket, "["))
        XCTAssertEqual(controller.state.list, .all)
        XCTAssertEqual(toolbar.lists.stopUnderCursor, .all)
        try await SearchTestSupport.waitUntil { controller.state.phase == .results }
        toolbar.lists.keyDown(with: try key(kVK_DownArrow, "\u{F701}"))
        XCTAssertTrue(window.firstResponder is QuickAccessStripView)
    }

    // MARK: Saving into collections, favorites and the library

    func testShiftCommandMShowsTheCollectionsBesideTheCardAndSavesIntoTheOneChosen() async throws {
        let (controller, harness, made) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts", "Shell"])
        let window = try XCTUnwrap(controller.window)
        var shown: [(menu: NSMenu, point: NSPoint)] = []
        controller.presentActionMenu = { menu, point, _ in shown.append((menu, point)) }
        let shiftCommandM = try key(kVK_ANSI_M, "M", modifiers: [.command, .shift])
        XCTAssertTrue(window.performKeyEquivalent(with: shiftCommandM))
        let menu = try XCTUnwrap(shown.first?.menu)
        // Each collection in the sidebar's order; a clip's card does not know its snippet's collections, so nothing is
        // checked. Held down, ⇧⌘M opens nothing more.
        XCTAssertEqual(menu.title, "Save to Collection")
        XCTAssertEqual(menu.items.map(\.title), ["Prompts", "Shell"])
        XCTAssertTrue(menu.items.allSatisfy { $0.state == .off })
        XCTAssertNotNil(menu.items[0].image)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_M, "M", modifiers: [.command, .shift],
                                                                isARepeat: true)))
        XCTAssertEqual(shown.count, 1)

        menu.performActionForItem(at: 0)
        try await SearchTestSupport.waitUntil { controller.state.saveMessage == "Saved to “Prompts”" }
        let ref = try XCTUnwrap(controller.state.copyTarget?.ref)
        let state = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let item) = state.value else { return XCTFail("Missing the clip") }
        XCTAssertEqual(item.collectionIDs, [made[0].value.id])
        // The actions menu offers the same, under Save to Collection.
        let actions = try actionMenu(of: controller)
        let saveTo = try XCTUnwrap(actions.items.first { $0.title == "Save to Collection" })
        XCTAssertTrue(saveTo.isEnabled)
        XCTAssertEqual(saveTo.submenu?.items.map(\.title), ["Prompts", "Shell"])
    }

    func testCommandDAndShiftCommandMWaitForTheComposition() async throws {
        let (controller, harness, _) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        var shown = 0
        controller.presentActionMenu = { _, _, _ in shown += 1 }
        let ref = try XCTUnwrap(controller.state.copyTarget?.ref)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        // Taken without acting, so that neither saves nor opens a menu, and the composition goes on.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_D, "d", modifiers: .command)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_M, "M", modifiers: [.command, .shift])))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(isEditing(field, in: window))
        // Plain ⌘M is no shortcut here at all, and opens nothing either.
        _ = window.performKeyEquivalent(with: try key(kVK_ANSI_M, "m", modifiers: .command))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(controller.state.saveMessage)
        XCTAssertEqual(shown, 0)
        let state = try await ContentRepository(controller: harness.controller).recordState(.item(ref.itemID))
        guard case .item(let item) = state.value else { return XCTFail("Missing the clip") }
        XCTAssertNil(item.memoID)
    }

    func testShiftCommandMWithoutCollectionsSaysWhatItTakes() async throws {
        let (controller, _, _) = try await showPanelWithLists(clips: ["older"], collections: [])
        let window = try XCTUnwrap(controller.window)
        var shown = 0
        controller.presentActionMenu = { _, _, _ in shown += 1 }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_M, "M", modifiers: [.command, .shift])))
        XCTAssertEqual(shown, 0)
        XCTAssertEqual(controller.state.saveMessage, "Create a collection first.")
    }

    func testCommandDSavesTheClipAsAFavoriteAndTurnsASnippetsMarkOver() async throws {
        let (controller, _, _) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        let commandD = try key(kVK_ANSI_D, "d", modifiers: .command)
        XCTAssertTrue(window.performKeyEquivalent(with: commandD))
        try await SearchTestSupport.waitUntil {
            controller.state.saveMessage == "Saved as Snippet · Added to Favorites"
        }
        // On a snippet's card the mark turns over, and the actions menu names what ⌘D does next.
        controller.state.setList(.collection(try XCTUnwrap(controller.state.collections.first).id))
        try await SearchTestSupport.waitUntil {
            controller.state.phase == .results && controller.state.copyTarget?.ref.facet == .memo
        }
        XCTAssertEqual(try actionMenu(of: controller).items.first { $0.keyEquivalent == "d" }?.title, "Add to Favorites")
        XCTAssertTrue(window.performKeyEquivalent(with: commandD))
        try await SearchTestSupport.waitUntil { controller.state.saveMessage == "Added to Favorites" }
        XCTAssertEqual(try actionMenu(of: controller).items.first { $0.keyEquivalent == "d" }?.title,
                       "Remove from Favorites")
        XCTAssertTrue(window.performKeyEquivalent(with: commandD))
        try await SearchTestSupport.waitUntil { controller.state.saveMessage == "Removed from Favorites" }
        // Held down, ⌘D has acted already.
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_D, "d", modifiers: .command, isARepeat: true)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.state.saveMessage, "Removed from Favorites")
    }

    func testShowInLibraryAsksForTheSnippetOfASnippetOrASavedClip() async throws {
        let (controller, _, _) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        var opened: [(ref: ContentRef, showsSnippet: Bool)] = []
        controller.onOpenInLibrary = { opened.append(($0, $1)) }
        let commandE = try key(kVK_ANSI_E, "e", modifiers: .command)
        // A clip not saved shows as the clip.
        XCTAssertTrue(window.performKeyEquivalent(with: commandE))
        XCTAssertEqual(opened.last?.showsSnippet, false)
        // Once saved, as its snippet.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.copyTarget != nil }
        await controller.state.saveSelection(try XCTUnwrap(controller.state.copyTarget))
        XCTAssertTrue(window.performKeyEquivalent(with: commandE))
        XCTAssertEqual(opened.last?.showsSnippet, true)
        XCTAssertEqual(opened.last?.ref.facet, .history)
        // A snippet's card shows the snippet.
        controller.show()
        _ = try searchEditor(in: controller)
        controller.state.setList(.snippets)
        try await SearchTestSupport.waitUntil {
            controller.state.phase == .results && controller.state.copyTarget?.ref.facet == .memo
        }
        XCTAssertTrue(window.performKeyEquivalent(with: commandE))
        XCTAssertEqual(opened.last?.ref.facet, .memo)
        XCTAssertEqual(opened.last?.showsSnippet, true)
    }

    func testNewSnippetGoesIntoTheCollectionListed() async throws {
        let (controller, _, made) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        var asked: [CollectionID?] = []
        controller.onNewSnippet = { asked.append($0) }
        let commandN = try key(kVK_ANSI_N, "n", modifiers: .command)
        XCTAssertTrue(window.performKeyEquivalent(with: commandN))
        controller.show()
        _ = try searchEditor(in: controller)
        controller.state.setList(.snippets)
        XCTAssertTrue(window.performKeyEquivalent(with: commandN))
        controller.show()
        _ = try searchEditor(in: controller)
        controller.state.setList(.collection(made[0].value.id))
        XCTAssertTrue(window.performKeyEquivalent(with: commandN))
        // All and Snippets put it in Unfiled; a collection's list puts it there.
        XCTAssertEqual(asked, [nil, nil, made[0].value.id])
    }

    func testFavoritesOnlyUnderAllSwitchesTheSegment() async throws {
        let (controller, _, _) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"],
                                                              unfiled: ["Loose"], favorites: ["Loose"])
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        var menus: [NSMenu] = []
        controller.presentToolbarMenu = { menu, _, _ in menus.append(menu) }

        // Favorites are snippets, so Favorites Only under All goes to Snippets first, and the switch shows it.
        toolbar.filterButton.face.performClick(nil)
        let menu = try XCTUnwrap(menus.last)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Favorites Only" }))
        try await SearchTestSupport.waitUntil {
            controller.state.list == .snippets && controller.state.favoritesOnly && controller.state.phase == .results
        }
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["Loose"])
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.lists.segments.buttons.map(\.state), [.off, .on])
        XCTAssertEqual(toolbar.filterButton.title, "Favorites")
        toolbar.filterButton.face.performClick(nil)
        XCTAssertEqual(try XCTUnwrap(menus.last).items.first { $0.title == "Favorites Only" }?.state, .on)

        // Back to All, it is off again.
        toolbar.lists.segments.buttons[0].performClick(nil)
        try await SearchTestSupport.waitUntil { controller.state.list == .all && controller.state.phase == .results }
        XCTAssertFalse(controller.state.favoritesOnly)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertNil(toolbar.filterButton.title)
    }

    func testTheMoreChipOpensTheCollectionsThatDoNotFit() async throws {
        let names = ["Prompts", "Drafts", "Release notes", "Code review", "Meeting templates", "Customer replies",
                     "Shell", "Design", "Reading list", "Travel", "Interview questions", "Weekly report"]
        let (controller, _, made) = try await showPanelWithLists(
            clips: ["older"], collections: names, visibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 800)
        )
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        var menus: [NSMenu] = []
        controller.presentToolbarMenu = { menu, _, _ in menus.append(menu) }
        controller.state.setList(.snippets)
        try await SearchTestSupport.waitUntil { controller.state.phase == .results }
        toolbar.layoutSubtreeIfNeeded()
        let lists = toolbar.lists
        let shown = lists.visibleChipCount
        XCTAssertGreaterThan(shown, 0)
        XCTAssertLessThan(shown, names.count)
        XCTAssertFalse(lists.moreChip.isHidden)

        // More lists the collections that did not fit, in order; choosing one lists it, and More shows its name.
        lists.moreChip.performClick(nil)
        let menu = try XCTUnwrap(menus.last)
        XCTAssertEqual(menu.items.map(\.title), Array(names.dropFirst(shown)))
        menu.performActionForItem(at: menu.items.count - 1)
        try await SearchTestSupport.waitUntil { controller.state.list == .collection(made[names.count - 1].value.id) }
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(lists.moreChip.title, names[names.count - 1])
        XCTAssertEqual(lists.moreChip.state, .on)
        lists.moreChip.performClick(nil)
        XCTAssertEqual(try XCTUnwrap(menus.last).items.last?.state, .on)
    }

    func testTheSearchSaysWhichListItSearches() async throws {
        let (controller, _, made) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        let (field, _) = try searchEditor(in: controller)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        let cases: [(QuickAccessList, String)] = [
            (.all, "Search Clips and Snippets"), (.snippets, "Search Snippets"),
            (.collection(made[0].value.id), "Search “Prompts”"),
        ]
        for (list, placeholder) in cases {
            controller.state.setList(list)
            try await SearchTestSupport.waitUntil { controller.state.list == list && controller.state.phase != .loading }
            try await SearchTestSupport.waitUntil { field.placeholderAttributedString?.string == placeholder }
            XCTAssertEqual(toolbar.search.foldButton.accessibilityLabel(), placeholder)
        }
    }

    func testSwitchingListsSaysWhichListAndHowManyItems() async throws {
        let (controller, _, made) = try await showPanelWithLists(clips: ["older", "newer"],
                                                                 collections: ["Prompts"], unfiled: ["Loose"])
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        controller.state.setList(.snippets)
        try await SearchTestSupport.waitUntil { announced.last == "Snippets, 2 items" }
        controller.state.setList(.collection(made[0].value.id))
        try await SearchTestSupport.waitUntil { announced.last == "Prompts, 1 item" }
        controller.state.setList(.all)
        try await SearchTestSupport.waitUntil { announced.last == "All, 2 items" }
    }

    func testTheCardsFadeWhenTheListChanges() async throws {
        let (controller, _, _) = try await showPanelWithLists(clips: ["older", "newer"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        let strip = try await clipStrip(in: window)
        controller.reducesMotion = { false }
        // The fade lasts 0.15 s and goes when it ends; with the strip's clock stopped it stays to be read.
        let layer = try XCTUnwrap(strip.layer)
        layer.speed = 0
        defer { layer.speed = 1 }
        controller.state.setList(.snippets)
        try await SearchTestSupport.waitUntil { layer.animation(forKey: kCATransition) != nil }
        let fade = try XCTUnwrap(layer.animation(forKey: kCATransition) as? CATransition)
        XCTAssertEqual(fade.type, .fade)
        XCTAssertEqual(fade.duration, 0.15, accuracy: 0.001)

        // With Reduce Motion the cards change at once.
        layer.removeAllAnimations()
        controller.reducesMotion = { true }
        controller.state.setList(.all)
        // Once the strip shows All's cards, any fade added with them would still be there, the strip's clock stopped.
        try await SearchTestSupport.waitUntil {
            controller.state.phase == .results && self.framesOnScreen(in: strip).contains { Self.labels($0, "newer") }
        }
        XCTAssertNil(layer.animation(forKey: kCATransition))
    }

    func testTheFrequentWingShowsOnlyUnderAll() async throws {
        let (controller, _, _) = try await showPanelWithFrequentClips(Self.wingTitles, uses: Self.wingUses)
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let strip = try await clipStrip(in: window)
        try await waitForWingFrames(in: strip)
        let divider = try view(identifiedAs: "QuickAccessDivider", in: window)

        state.setList(.snippets)
        // The panel updates the strip a moment after the state, so the wait is for the divider itself.
        try await SearchTestSupport.waitUntil { state.phase != .loading && divider.isHidden }
        XCTAssertEqual(state.selection.frequentCount, 0)

        state.setList(.all)
        try await SearchTestSupport.waitUntil {
            state.phase == .results && state.selection.rows.filter { !$0.isFrequent }.count == Self.wingTitles.count
        }
        XCTAssertGreaterThan(state.selection.frequentCount, 0)
        try await waitForWingFrames(in: strip)
        XCTAssertFalse(divider.isHidden)
    }

    func testAClickOnTheFilterButtonOpensItsMenuAsTheMouseGoesDown() async throws {
        let (controller, _, _) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        toolbar.layoutSubtreeIfNeeded()
        var shown: [NSMenu] = []
        controller.presentToolbarMenu = { menu, _, _ in shown.append(menu) }
        // A click through the window lands on the button's face, and its mouse-down opens the menu, as a pop-up
        // button's does. A borderless button with no title or image would not track the click at all.
        let button = toolbar.filterButton
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        XCTAssertTrue(window.contentView?.hitTest(point) === button.face)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        window.sendEvent(down)
        XCTAssertEqual(shown.map(\.title), ["Filter"])
        XCTAssertFalse(button.face.isHighlighted)
    }

    func testToolbarMenusOpenWithoutActivatingTheApp() async throws {
        // The panel opens while another app is active, and neither it nor its menus make Keeptide the active app. AppKit
        // counts an app with a key panel as active, so what is checked is the system's view: the running application,
        // the frontmost application, and the notification activation posts. The test host often is the active app, so
        // it steps back before the panel opens, until it has stayed inactive for a second, and comes forward afterwards.
        let current = NSRunningApplication.current
        if current.isActive { addTeardownBlock { @MainActor in NSApp.activate() } }
        let deadline = ContinuousClock.now + .seconds(5)
        var inactiveSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if current.isActive {
                NSApp.deactivate()
                inactiveSince = nil
            } else if let since = inactiveSince {
                if ContinuousClock.now - since >= .seconds(1) { break }
            } else {
                inactiveSince = .now
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !current.isActive else { throw XCTSkip("The test host stayed the active app, so activation cannot be seen") }
        let watch = MenuWatch()
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                              object: NSApp, queue: nil) { _ in watch.activations += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let (controller, _, _) = try await showPanelWithLists(clips: ["older"], collections: ["Prompts"])
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(views(QuickAccessToolbar.self, in: window.contentView).first)
        XCTAssertTrue(window.isKeyWindow, "The panel has the keys")
        XCTAssertFalse(current.isActive, "The panel opened without activating the app")
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, current.processIdentifier)

        // The real menu, from the panel. A timer in the menu's own tracking mode reads whether the app became active
        // while the menu was open, and closes it, as Escape would.
        controller.presentToolbarMenu = { menu, point, view in
            watch.menu = menu
            let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                MainActor.assumeIsolated {
                    watch.wasActive = current.isActive
                    watch.frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    watch.menu?.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
            menu.popUp(positioning: nil, at: point, in: view)
        }
        toolbar.filterButton.face.performClick(nil)
        XCTAssertNotNil(watch.menu)
        XCTAssertEqual(watch.wasActive, false, "The menu opened without activating the app")
        XCTAssertNotNil(watch.frontmost)
        XCTAssertNotEqual(watch.frontmost, current.processIdentifier)
        XCTAssertEqual(watch.activations, 0)
        XCTAssertFalse(current.isActive)
        XCTAssertTrue(controller.isSessionOpen, "The panel stays open with its menu gone")
    }

    // MARK: The frequent wing

    /// clip 11, the oldest, to clip 0, the newest.
    private static let wingTitles = (0..<12).reversed().map { "clip \($0)" }
    /// How often four of them were used. clip 1 is used most, but it is among the three newest, which medium cards
    /// show whole on `wingScreen` beside a wing that puts the newest in the middle, so the wing leaves it out. The wing
    /// lists the other three from the least used, clip 9, to the most used, clip 11, beside the newest clip.
    private static let wingUses = ["clip 11": 4, "clip 10": 3, "clip 9": 2, "clip 1": 5]

    func testOpeningWithFrequentClipsCentresTheNewestClip() async throws {
        let (controller, _, _) = try await showPanelWithFrequentClips(Self.wingTitles, uses: Self.wingUses)
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let strip = try await clipStrip(in: window)
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: Self.wingScreen.width)

        // The wing lists the clips used most, without clip 1, which the band shows whole: from the least used to the
        // most used, beside the newest clip. The newest clip is selected, a recent row and not a frequent one.
        XCTAssertEqual(state.selection.rows.prefix { $0.isFrequent }.map(\.title), ["clip 9", "clip 10", "clip 11"])
        XCTAssertEqual(state.selection.rows.prefix { $0.isFrequent }.map(\.frequentUses), [2, 3, 4])
        XCTAssertEqual(state.selection.selectedRow?.title, "clip 0")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, false)

        // VoiceOver reads the two wings as two groups, left to right. The newest clip is in the middle of the band, the
        // divider's wider gap before it, and the two clips used most stand just left of it, the most used beside it.
        // The least used, clip 9, is cut off by the band's left end, and is read with the others.
        try await waitForWingFrames(in: strip)
        let wings = try groups(in: strip)
        XCTAssertEqual(wings.map(\.name), ["Frequent", "Recent"])
        let frequentFrames = try XCTUnwrap(wings.first).frames
        XCTAssertEqual(frequentFrames.map { $0.accessibilityLabel()?.components(separatedBy: ": ").last },
                       ["clip 9", "clip 10", "clip 11"])
        XCTAssertEqual(frequentFrames.map { $0.accessibilityLabel()?.contains("used 4 times") }, [false, false, true])
        let newest = try XCTUnwrap(wings.last?.frames.first)
        let mostUsed = try XCTUnwrap(wings.first?.frames.last)
        let secondMostUsed = try XCTUnwrap(wings.first?.frames.dropLast().last)
        XCTAssertTrue(newest.accessibilityLabel()?.hasSuffix(": clip 0") == true, newest.accessibilityLabel() ?? "")
        let newestFrame = strip.convert(newest.bounds, from: newest)
        let mostUsedFrame = strip.convert(mostUsed.bounds, from: mostUsed)
        let secondFrame = strip.convert(secondMostUsed.bounds, from: secondMostUsed)
        XCTAssertEqual(newestFrame.midX, strip.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(newestFrame.minX - mostUsedFrame.maxX, metrics.gap + metrics.dividerExtra + metrics.neighbourPush, accuracy: 1)
        XCTAssertEqual(mostUsedFrame.minX - secondFrame.maxX, metrics.gap, accuracy: 1)

        // The band has room below the cards for the section icons: 34 instead of 25, so it is 325 high. Both icons
        // show there, below the cards and inside the band, the flame left of the divider and the clock right of it.
        window.contentView?.layoutSubtreeIfNeeded()
        let band = try bandRect(in: window)
        let card = strip.convert(newestFrame, to: nil)
        XCTAssertEqual(band.height, 325)
        XCTAssertEqual(card.minY - band.minY, 34, accuracy: 0.5)
        let divider = try view(identifiedAs: "QuickAccessDivider", in: window)
        XCTAssertFalse(divider.isHidden)
        let line = divider.convert(divider.bounds, to: nil)
        for (identifier, isLeftOfTheLine) in [("QuickAccessFrequentLabel", true), ("QuickAccessRecentLabel", false)] {
            let icon = try view(identifiedAs: identifier, in: window)
            XCTAssertFalse(icon.isHidden, identifier)
            let drawn = icon.convert(icon.bounds, to: nil)
            XCTAssertLessThanOrEqual(drawn.maxY, card.minY + 0.5, "\(identifier) below the cards")
            XCTAssertGreaterThanOrEqual(drawn.minY, band.minY - 0.5, "\(identifier) inside the band")
            if isLeftOfTheLine {
                XCTAssertLessThan(drawn.maxX, line.minX, identifier)
            } else {
                XCTAssertGreaterThan(drawn.minX, line.maxX, identifier)
            }
        }
    }

    func testLeftFromTheNewestClipStepsIntoTheFrequentWing() async throws {
        let (controller, _, _) = try await showPanelWithFrequentClips(Self.wingTitles, uses: Self.wingUses)
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)

        // ← from the newest clip crosses the divider to the most used clip, which VoiceOver reads with how often it was
        // used, inside the "Frequent" group. The keys stay with the field.
        editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(state.selection.selectedRow?.title, "clip 11")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, true)
        let label = selectedClipLabel(in: strip)
        XCTAssertTrue(label?.contains("used 4 times") == true, label ?? "")
        let selected = try XCTUnwrap(strip.accessibilitySelectedChildren()?.first as? NSView)
        let frequent = try XCTUnwrap(groups(in: strip).first { $0.name == "Frequent" })
        XCTAssertTrue(frequent.frames.contains { $0 === selected })
        XCTAssertTrue(isEditing(field, in: window))

        // → comes back to the newest clip.
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(state.selection.selectedRow?.title, "clip 0")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, false)
    }

    func testASearchHidesTheFrequentWingUntilItIsCleared() async throws {
        let (controller, harness, _) = try await showPanelWithFrequentClips(Self.wingTitles, uses: Self.wingUses)
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let (field, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        try await waitForWingFrames(in: strip)
        let frequentIcon = try view(identifiedAs: "QuickAccessFrequentLabel", in: window)
        let recentIcon = try view(identifiedAs: "QuickAccessRecentLabel", in: window)
        let divider = try view(identifiedAs: "QuickAccessDivider", in: window)

        // A query lists its results alone: no frequent rows, no divider and no section icons, and the frames are the
        // list's own children again.
        editor.insertText("clip 1", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await SearchTestSupport.waitUntil {
            state.query == "clip 1" && state.phase == .results && state.selection.isComplete
                && (strip.accessibilityChildren() as? [NSView])?.isEmpty == false
        }
        XCTAssertFalse(state.selection.rows.isEmpty)
        XCTAssertFalse(state.selection.rows.contains { $0.isFrequent })
        XCTAssertTrue(frequentIcon.isHidden && recentIcon.isHidden && divider.isHidden)
        XCTAssertNotNil(strip.accessibilityChildren() as? [NSView])

        // clip 8, off the first screen, is used six times while the panel is open. Escape clears the query, and the
        // same wing comes back: uses recorded while the panel is open show the next time it opens.
        try await recordUses(of: "clip 8", times: 6, in: harness)
        try XCTUnwrap(field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await SearchTestSupport.waitUntil {
            state.query.isEmpty && state.phase == .results
                && state.selection.rows.filter { !$0.isFrequent }.count == Self.wingTitles.count
        }
        XCTAssertEqual(state.selection.rows.prefix { $0.isFrequent }.map(\.title), ["clip 9", "clip 10", "clip 11"])
        try await waitForWingFrames(in: strip)
        XCTAssertFalse(divider.isHidden)
    }

    func testTurningFrequentClipsOffLeavesTheStripAsItWas() async throws {
        let (controller, _, _) = try await showPanelWithFrequentClips(Self.wingTitles, uses: Self.wingUses,
                                                                      showsFrequent: false)
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let strip = try await clipStrip(in: window)
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: Self.wingScreen.width)
        let left = strip.bounds.midX - metrics.bandWidth / 2

        // The same uses, and no wing: the newest clip rests at the left dock, with no divider and no section icons,
        // and the frames are the list's own children.
        XCTAssertEqual(state.selection.frequentCount, 0)
        XCTAssertEqual(state.selection.rows.map(\.title), Array(Self.wingTitles.reversed()))
        XCTAssertEqual(try drawnFrame(of: "clip 0", in: strip).minX - left, metrics.dockInset, accuracy: 0.5)
        let frequentIcon = try view(identifiedAs: "QuickAccessFrequentLabel", in: window)
        let recentIcon = try view(identifiedAs: "QuickAccessRecentLabel", in: window)
        let divider = try view(identifiedAs: "QuickAccessDivider", in: window)
        XCTAssertTrue(frequentIcon.isHidden && recentIcon.isHidden && divider.isHidden)
        XCTAssertNotNil(strip.accessibilityChildren() as? [NSView])
        // The band is 316 high, with 25 below the cards: the room the enlarged selected card needs, and none for icons.
        window.contentView?.layoutSubtreeIfNeeded()
        let band = try bandRect(in: window)
        XCTAssertEqual(band.height, 316)
        XCTAssertEqual(strip.convert(try frame(of: "clip 0", in: strip), to: nil).minY - band.minY, 25, accuracy: 0.5)
    }

    func testWithFrequentClipsOnButNoneUsedTwiceTheStripListsOnlyRecentClips() async throws {
        // clip 9, off the first screen, was used once; a clip joins the wing once it was used twice.
        let (controller, _, _) = try await showPanelWithFrequentClips(Self.wingTitles, uses: ["clip 9": 1])
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let strip = try await clipStrip(in: window)
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: Self.wingScreen.width, showsFrequentClips: true)
        let left = strip.bounds.midX - metrics.bandWidth / 2

        // No wing: the recent clips alone, the newest at the left dock, with no divider and no section icons, and the
        // frames are the list's own children, in no groups.
        XCTAssertEqual(state.selection.frequentCount, 0)
        XCTAssertEqual(state.selection.rows.map(\.title), Array(Self.wingTitles.reversed()))
        XCTAssertEqual(try drawnFrame(of: "clip 0", in: strip).minX - left, metrics.dockInset, accuracy: 0.5)
        let frequentIcon = try view(identifiedAs: "QuickAccessFrequentLabel", in: window)
        let recentIcon = try view(identifiedAs: "QuickAccessRecentLabel", in: window)
        let divider = try view(identifiedAs: "QuickAccessDivider", in: window)
        XCTAssertTrue(frequentIcon.isHidden && recentIcon.isHidden && divider.isHidden)
        let frames = try XCTUnwrap(strip.accessibilityChildren() as? [NSView], "The list's own children, in no groups")
        XCTAssertFalse(frames.isEmpty)
        // The setting is on, so the band keeps the room below the cards that the icons would have: 325 high, with 34
        // below the cards.
        window.contentView?.layoutSubtreeIfNeeded()
        let band = try bandRect(in: window)
        XCTAssertEqual(band.height, 325)
        XCTAssertEqual(strip.convert(try frame(of: "clip 0", in: strip), to: nil).minY - band.minY, 34, accuracy: 0.5)
    }

    func testWithAFrequentWingSpaceOverlaysTheNewestClipsPreviewOnTheStationaryBand() async throws {
        let (controller, _, _) = try await showPanelWithFrequentClips(Self.wingTitles, uses: Self.wingUses)
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let strip = try await clipStrip(in: window)
        try await waitForWingFrames(in: strip)
        // The band is 325 high, with the room below the cards for the section icons.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: Self.wingScreen.width, showsFrequentClips: true)
        let band = StripLayout.bandFrame(metrics, in: Self.wingScreen)
        assertFrame(window.frame, places: StripLayout.panelFrame(band: band, preview: nil, in: Self.wingScreen))
        controller.perform(.focusResults)
        XCTAssertTrue(window.firstResponder === strip)

        // Space opens the preview of the selected clip, the newest, and not of the least used one, which leads the
        // rows. The band remains exactly where it opened while the preview floats over it.
        strip.keyDown(with: try key(kVK_Space, " "))
        XCTAssertTrue(state.isPreviewExpanded)
        try await SearchTestSupport.waitUntil { state.preview != nil }
        settleLayout()
        assertFrame(window.convertToScreen(try bandRect(in: window)), places: band)
        let text = try XCTUnwrap(views(NSTextView.self, in: window.contentView).first { !$0.isFieldEditor })
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let previewBody = scroll.convert(scroll.bounds, to: nil)
        let currentBand = try bandRect(in: window)
        XCTAssertEqual(state.selection.rows.first?.title, "clip 9")
        XCTAssertEqual(text.string, "clip 0")
        XCTAssertTrue(previewBody.intersects(currentBand))
        XCTAssertEqual(previewBody.midX, currentBand.midX, accuracy: 0.5)
        XCTAssertTrue(window.firstResponder === strip, "The strip keeps the keys")

        // Escape closes the card and leaves the band as it was, the wing still before the newest clip.
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        settleLayout()
        XCTAssertFalse(state.isPreviewExpanded)
        assertFrame(window.convertToScreen(try bandRect(in: window)), places: band)
        XCTAssertEqual(state.selection.frequentCount, 3)
        XCTAssertTrue(window.firstResponder === strip)
    }

    func testARightClickOnEitherCopyOfAClipActsOnTheCopyClicked() async throws {
        let (controller, _, board) = try await showPanelWithFrequentClips(Self.wingTitles, uses: Self.wingUses)
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let strip = try await clipStrip(in: window)
        // Disable springs; clicks still use the drawn face while AppKit commits the new model geometry.
        strip.reducesMotion = { true }
        try await waitForWingFrames(in: strip)
        // clip 11 is listed twice: last in the wing, beside the divider, and as the oldest of the recent clips, off the
        // band to the right.
        let wingCopy = try XCTUnwrap(state.selection.rows.first { $0.isFrequent && $0.title == "clip 11" })
        let recentCopy = try XCTUnwrap(state.selection.rows.first { !$0.isFrequent && $0.title == "clip 11" })
        XCTAssertEqual(wingCopy.ref, recentCopy.ref)
        func rightClick(on frame: NSView) throws -> NSEvent {
            let layer = try XCTUnwrap(frame.layer)
            let film = try XCTUnwrap(frame.superview)
            let shift = (film.layer?.presentation()?.position.x ?? film.layer?.position.x ?? 0)
                - (film.layer?.position.x ?? 0)
            let rect = strip.convert((layer.presentation() ?? layer).frame.offsetBy(dx: shift, dy: 0), from: film)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: .rightMouseDown, location: strip.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ))
        }

        // With the newest clip selected, Copy in the menu of the wing's copy selects that copy and copies the clip.
        let wingFrame = try XCTUnwrap(groups(in: strip).first { $0.name == "Frequent" }?.frames.last)
        XCTAssertTrue(wingFrame.accessibilityLabel()?.hasSuffix(": clip 11") == true,
                      wingFrame.accessibilityLabel() ?? "")
        let atWing = try rightClick(on: wingFrame)
        controller.currentEvent = { atWing }
        try XCTUnwrap(strip.menu(for: atWing)).performActionForItem(at: 0)
        XCTAssertEqual(state.selection.selectedID, wingCopy.id)
        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "clip 11")

        // Opened again with clip 10 selected among the recent clips, clip 11's recent copy is on the band beside it
        // and the wing's copy is not. Copy in the recent copy's menu selects that copy, not the wing's.
        board.clearContents()
        controller.show()
        try await SearchTestSupport.waitUntil {
            state.selection.rows.filter { !$0.isFrequent }.count == Self.wingTitles.count
        }
        controller.perform(.move(10))
        XCTAssertEqual(state.selection.selectedRow?.title, "clip 10")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, false)
        // The list reports frames where they are drawn. Wait for AppKit to show this copy and remove the frequent
        // wing from the visible group before asking VoiceOver for the recent copy.
        try await SearchTestSupport.waitUntil {
            self.framesOnScreen(in: strip).contains { $0.accessibilityLabel()?.hasSuffix(": clip 11") == true }
                && (try? self.groups(in: strip).map(\.name)) == ["Recent"]
        }
        let recentFrame = try XCTUnwrap(framesOnScreen(in: strip).first {
            $0.accessibilityLabel()?.hasSuffix(": clip 11") == true
        })
        XCTAssertEqual(try groups(in: strip).map(\.name), ["Recent"], "The wing is off the band")
        let recent = try XCTUnwrap(groups(in: strip).first { $0.name == "Recent" })
        XCTAssertTrue(recent.frames.contains { $0 === recentFrame })
        let atRecent = try rightClick(on: recentFrame)
        controller.currentEvent = { atRecent }
        try XCTUnwrap(strip.menu(for: atRecent)).performActionForItem(at: 0)
        XCTAssertEqual(state.selection.selectedID, recentCopy.id)
        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "clip 11")
    }

    func testTheFirstScreenIsCountedForTheCardSizeTheStripOpensWith() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(Self.wingTitles, into: harness)
        // clip 3, the fourth newest, is used twice. On `wingScreen` a wing of one card rests at the left end, and
        // beside it the band shows the three newest whole with large cards and the four newest with small ones.
        try await recordUses(of: "clip 3", times: 2, in: harness)
        let preferences = try makePreferences(.medium, showsFrequent: true)
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: Self.wingScreen,
                                       usage: LocalUsageStore(controller: harness.controller), preferences: preferences)
        addTeardownBlock { controller.close() }
        let state = controller.state

        // Settings changes the card size before the strip opens. It opens with large cards: clip 3 is not whole beside
        // the wing, so it is in it.
        preferences.cardSize = .large
        controller.show()
        try await SearchTestSupport.waitUntil {
            state.selection.rows.filter { !$0.isFrequent }.count == Self.wingTitles.count
        }
        XCTAssertEqual(state.selection.rows.prefix { $0.isFrequent }.map(\.title), ["clip 3"])

        // Opened again with small cards, clip 3 is whole beside a wing of one, and the wing leaves it out: there is
        // none.
        controller.close()
        preferences.cardSize = .small
        controller.show()
        try await SearchTestSupport.waitUntil {
            state.selection.rows.filter { !$0.isFrequent }.count == Self.wingTitles.count
        }
        XCTAssertEqual(state.selection.frequentCount, 0)
    }

    func testAPanelMadeWithFrequentClipsOnHasRoomForTheirIconsBeforeItOpens() throws {
        // The panel lays the band out for its settings as it is made, so a session opened on it at once, without the
        // shortcut, also has the room below the cards for the section icons: 325 high, not 316.
        let controller = PanelController(preferences: try makePreferences(.medium, showsFrequent: true),
                                         visibleFrame: Self.wingScreen)
        let window = try XCTUnwrap(controller.window)
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: Self.wingScreen.width, showsFrequentClips: true)
        XCTAssertEqual(try bandRect(in: window).height, 325)
        let band = StripLayout.bandFrame(metrics, in: Self.wingScreen)
        assertFrame(window.frame, places: StripLayout.panelFrame(band: band, preview: nil, in: Self.wingScreen))
    }

    func testTheFadeSettingTakesEffectWhenThePanelNextOpens() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips((0..<40).reversed().map { "clip \($0)" }, into: harness)
        try await harness.consumer.synchronize()
        let preferences = try makePreferences(.medium)
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: Self.wingScreen,
                                       preferences: preferences)
        addTeardownBlock { controller.close() }
        controller.show()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 40 }
        let window = try XCTUnwrap(controller.window)
        // The state receives the rows before PanelController's observation task
        // applies them to AppKit. Judge the fade only once a real frame is in the
        // strip, as the other panel-rendering tests do.
        let strip = try await clipStrip(in: window)
        XCTAssertEqual(strip.edgeFades, StripEdgeFades(leading: 0, trailing: 1))
        XCTAssertNotNil(strip.layer?.mask)
        preferences.fadesStripEnds = false
        controller.perform(.move(1))
        settleLayout()
        XCTAssertNotNil(strip.layer?.mask)
        controller.close()
        controller.show()
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.count == 40 && !self.framesOnScreen(in: strip).isEmpty
        }
        XCTAssertNil(strip.layer?.mask)
        XCTAssertFalse(strip.isFollowingMotion)
    }

    func testTheEnlargementTakesEffectWhenThePanelNextOpens() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["older", "newer"], into: harness)
        try await harness.consumer.synchronize()
        let preferences = try makePreferences(.medium, showsFrequent: true)
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: Self.wingScreen,
                                       preferences: preferences)
        addTeardownBlock { controller.close() }
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        // Where the panel puts the band and itself on `wingScreen` for an enlargement of `scale`.
        func expectedFrame(scale: CGFloat) -> NSRect {
            let metrics = StripLayout.metrics(for: .medium, visibleWidth: Self.wingScreen.width,
                                              showsFrequentClips: true, style: StripStyle(selectedScale: scale))
            return StripLayout.panelFrame(band: StripLayout.bandFrame(metrics, in: Self.wingScreen), preview: nil,
                                          in: Self.wingScreen)
        }

        // Settings enlarges the selected card the most before the panel opens. The band makes room for it as the panel
        // opens: 367 high, with the frequent clips' room below the cards.
        preferences.selectedCardScale = 1.25
        controller.show()
        try await SearchTestSupport.waitUntil { state.selection.rows.count == 2 }
        XCTAssertEqual(try bandRect(in: window).height, 367)
        assertFrame(window.frame, places: expectedFrame(scale: 1.25))

        // Turned off while the panel is open, it changes nothing there: as the panel follows a step to the older clip,
        // and after a turn of the run loop, the band keeps its height.
        preferences.selectedCardScale = 1
        controller.perform(.move(1))
        XCTAssertEqual(state.selection.selectedRow?.title, "older")
        settleLayout()
        XCTAssertEqual(try bandRect(in: window).height, 367)
        assertFrame(window.frame, places: expectedFrame(scale: 1.25))

        // The next time it opens, the band is as it was before the selected card was enlarged.
        controller.close()
        controller.show()
        try await SearchTestSupport.waitUntil { state.selection.rows.count == 2 }
        XCTAssertEqual(try bandRect(in: window).height, 311)
        assertFrame(window.frame, places: expectedFrame(scale: 1))
    }

    func testABandTooNarrowForACardLeavesNoRecentClipOutOfTheWing() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["clip 1", "clip 0"], into: harness)
        try await recordUses(of: "clip 0", times: 3, in: harness)
        try await recordUses(of: "clip 1", times: 2, in: harness)
        // A visible area 112 pt wide leaves a band 16 pt wide, which shows no card whole: the first screen holds none.
        let narrow = NSRect(x: 0, y: 0, width: 112, height: 900)
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: narrow.width, showsFrequentClips: true)
        XCTAssertEqual((0...2).map { StripLayout.recentShownWhole(metrics, frequentCount: $0) }, [0, 0, 0])
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: narrow,
                                       usage: LocalUsageStore(controller: harness.controller),
                                       preferences: try makePreferences(.medium, showsFrequent: true))
        addTeardownBlock { controller.close() }

        // So the wing leaves no recent clip out: both clips are in it, the more used beside the newest, and among the
        // recent clips after it.
        controller.show()
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 4 }
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["clip 1", "clip 0", "clip 0", "clip 1"])
        XCTAssertEqual(controller.state.selection.frequentCount, 2)
    }

    func testTheWingLeavesOutOnlyTheNewestClipsTheOpeningShowsWhole() async throws {
        // Twelve clips, clip 0 the newest, opened as the shortcut opens the strip with medium cards. Returns the wing.
        func wing(on width: CGFloat, uses: [String: Int]) async throws -> [String] {
            let harness = try SearchHarness.make(in: self)
            let board = NSPasteboard.withUniqueName()
            addTeardownBlock { board.releaseGlobally() }
            try await insertClips(Self.wingTitles, into: harness)
            for (title, times) in uses { try await recordUses(of: title, times: times, in: harness) }
            try await harness.consumer.synchronize()
            let controller = try makePanel(over: harness, pasteboard: board,
                                           visibleFrame: NSRect(x: 0, y: 0, width: width, height: 900),
                                           usage: LocalUsageStore(controller: harness.controller),
                                           preferences: try makePreferences(.medium, showsFrequent: true))
            controller.show()
            defer { controller.close() }
            try await SearchTestSupport.waitUntil {
                controller.state.selection.rows.filter { !$0.isFrequent }.count == Self.wingTitles.count
            }
            return controller.state.selection.rows.prefix { $0.isFrequent }.map(\.title)
        }

        // At 1440 a wing of two or more puts the newest clip in the middle, where the band shows the three newest
        // whole: clip 3 and clip 4, the fourth and fifth newest, are not, so the wing lists them.
        let wide = try await wing(on: 1440, uses: ["clip 11": 4, "clip 3": 3, "clip 4": 2])
        XCTAssertEqual(wide, ["clip 4", "clip 3", "clip 11"])
        // clip 3 alone would rest at the left end, where the band shows the four newest whole, clip 3 among them.
        let alone = try await wing(on: 1440, uses: ["clip 3": 2])
        XCTAssertEqual(alone, [])
        // At 1024 a single frequent clip rests at the left end too, where the band shows the three newest whole: clip
        // 3, the fourth newest, is listed, and clip 2, the third, is left out, as is clip 1.
        let narrow = try await wing(on: 1024, uses: ["clip 3": 2])
        XCTAssertEqual(narrow, ["clip 3"])
        let third = try await wing(on: 1024, uses: ["clip 2": 2])
        XCTAssertEqual(third, [])
        let left = try await wing(on: 1024, uses: ["clip 1": 2])
        XCTAssertEqual(left, [])
    }

    func testWithAFrequentWingAVanishedSelectionLeavesItsSlotBesideTheDivider() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let items = try await insertClips(Self.wingTitles, into: harness)
        for (title, times) in Self.wingUses { try await recordUses(of: title, times: times, in: harness) }
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: Self.wingScreen,
                                       usage: LocalUsageStore(controller: harness.controller),
                                       preferences: try makePreferences(.medium, showsFrequent: true))
        controller.show()
        addTeardownBlock { controller.close() }
        let state = controller.state
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        try await waitForWingFrames(in: strip)
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: Self.wingScreen.width, showsFrequentClips: true)
        let middle = strip.bounds.midX
        // Takes the clip with this title out of the history and waits until the strip shows it gone, with nothing
        // selected in its place.
        func remove(_ title: String) async throws {
            var gone = try XCTUnwrap(items.first { $0.title == title }, title)
            gone.historyDeletedAt = Date()
            try await harness.update(.item(gone.id), to: .item(gone))
            state.recentClipsChanged()
            try await SearchTestSupport.waitUntil {
                state.selection.selectionLost && strip.accessibilitySelectedChildren()?.isEmpty != false
                    && !self.hasFrame(titled: title, in: strip)
            }
        }

        // The newest clip, selected in the middle, leaves the list. Its place stays empty: the most used clip stands
        // left of it past the divider, and the newest clip left a step to its right.
        XCTAssertEqual(selectedClipLabel(in: strip)?.hasSuffix(": clip 0"), true)
        try await remove("clip 0")
        XCTAssertFalse(framesOnScreen(in: strip).contains {
            strip.convert($0.bounds, from: $0).contains(NSPoint(x: middle, y: strip.bounds.midY))
        })
        XCTAssertEqual(try frame(of: "clip 1", in: strip).midX - middle, metrics.step, accuracy: 0.5)
        XCTAssertEqual(middle - (try frame(of: "clip 11", in: strip)).midX, metrics.step + metrics.dividerExtra,
                       accuracy: 0.5)
        // ← selects the most used clip, across the divider.
        editor.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(state.selection.selectedRow?.title, "clip 11")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, true)

        // Two steps on, clip 2 is selected, and it leaves the list too. The empty slot is beside the divider again, and
        // → selects the newest clip left, which comes to the middle.
        controller.perform(.move(2))
        XCTAssertEqual(state.selection.selectedRow?.title, "clip 2")
        try await remove("clip 2")
        XCTAssertEqual(try frame(of: "clip 1", in: strip).midX - middle, metrics.step, accuracy: 0.5)
        editor.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(state.selection.selectedRow?.title, "clip 1")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, false)
        XCTAssertEqual(try frame(of: "clip 1", in: strip).midX, middle, accuracy: 0.5)
    }

    // MARK: Direct paste

    /// The quick-access seed's multi-line command, and the command the review card shows for it: its trailing line
    /// break gone, and the line break left in it made visible.
    private static let multiLineCommand = "set -e\necho synthetic-gamma\n"
    private static let reviewedCommand = "set -e↵\necho synthetic-gamma"

    func testShowRecordsTheTargetBeforeThePanelBecomesKey() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["older", "newer"], into: harness)
        let fake = FakeDirectPasteSystem()
        let controller = try makePanel(over: harness, pasteboard: board, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        var firstProbe: (isKey: Bool, isVisible: Bool)?
        fake.onProbe = { if firstProbe == nil { firstProbe = (window.isKeyWindow, window.isVisible) } }

        controller.show()
        addTeardownBlock { controller.close() }

        // The app in front is read while it is still in front: before the panel is on screen, let alone has the keys.
        let probe = try XCTUnwrap(firstProbe)
        XCTAssertFalse(probe.isKey)
        XCTAssertFalse(probe.isVisible)
        XCTAssertEqual(controller.state.pasteTarget, .textEdit)
        XCTAssertTrue(window.isVisible)
    }

    func testTheToolbarShowsThePrimaryActionAndTheReasonHint() async throws {
        // TextEdit in front, with every check passing: Return pastes into it, and there is nothing to explain.
        let pasting = FakeDirectPasteSystem()
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true, system: pasting.system)
        let toolbar = try await toolbarSaying(.action(title: "Paste into TextEdit", enabled: true, hint: nil),
                                              in: controller)
        let button = toolbar.copyHint
        XCTAssertEqual(button.accessibilityIdentifier(), "QuickAccessCopyButton")
        XCTAssertEqual(button.accessibilityLabel(), "Paste into TextEdit")
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.showsTitle)
        XCTAssertEqual(button.frame.width, button.fullWidth, "Read in full")
        XCTAssertNil(button.toolTip)
        XCTAssertEqual(button.keycap.symbol, "⏎")
        XCTAssertTrue(toolbar.directPasteHint.isHidden)
        // For the pointer, the button does what Return does: it pastes.
        button.performClick(nil)
        try await SearchTestSupport.waitUntil { pasting.sent == [9] }
        XCTAssertEqual(board.string(forType: .string), "newer")

        // Secure input is on: Return copies, and the toolbar says why, left of what Return does.
        let secure = FakeDirectPasteSystem()
        secure.secureInput = true
        let (copying, _) = try await makePanelWithClips(["older", "newer"], shown: true, system: secure.system)
        let copyingToolbar = try await toolbarSaying(.action(title: "Copy", enabled: true, hint: "Secure input is on"),
                                                     in: copying)
        let hint = copyingToolbar.directPasteHint
        XCTAssertEqual(copyingToolbar.copyHint.accessibilityLabel(), "Copy")
        XCTAssertFalse(hint.isHidden)
        XCTAssertEqual(hint.stringValue, "Secure input is on")
        XCTAssertEqual(hint.accessibilityIdentifier(), "QuickAccessDirectPasteHint")
        XCTAssertEqual(hint.textColor, ToolbarPalette.secondary)
        XCTAssertEqual(hint.frame.maxX, copyingToolbar.copyHint.frame.minX - 12, accuracy: 0.5)
        XCTAssertEqual(hint.frame.midY, copyingToolbar.rowFrame.midY, accuracy: 0.5)

        // Without direct paste the toolbar is as it was: "⏎ Copy", and nothing beside it.
        let (plain, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let plainToolbar = try await toolbarSaying(.action(title: "Copy", enabled: true, hint: nil), in: plain)
        XCTAssertEqual(plainToolbar.copyHint.accessibilityLabel(), "Copy")
        XCTAssertTrue(plainToolbar.directPasteHint.isHidden)
    }

    func testMenuOffersCopyAsIsAndEnableDirectPasteForATerminal() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        fake.permitted = false
        let (controller, board) = try await makePanelWithClips(
            ["echo synthetic-beta"], bodies: ["echo synthetic-beta": "echo synthetic-beta\n"], shown: true,
            system: fake.system)
        _ = try searchEditor(in: controller)

        // A terminal's text is a command, copied for want of access: no plain-text item, Copy As-Is to keep the clip as
        // captured, and the way to turn direct paste on, after a separator of its own.
        let menu = try actionMenu(of: controller)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Copy Command", "Copy As-Is (Keeps Trailing Newline)", "Show Preview",
                        "Save as Snippet", "Save to Collection", "Add to Favorites", "Show in Library", "New Snippet",
                        "Enable Direct Paste…", "Move to Recently Deleted"])
        XCTAssertEqual(menu.items.map(\.isSeparatorItem),
                       [false, false, true, false, true, false, false, false, true, false, false, true, false, true,
                        false])
        XCTAssertEqual(menu.items[0].keyEquivalent, "\r")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [])
        XCTAssertTrue(menu.items.allSatisfy {
            $0.isSeparatorItem || $0.isEnabled || ["Save to Collection", "Move to Recently Deleted"].contains($0.title)
        })

        // Copy As-Is copies the clip as captured, its trailing line break too, and sends nothing.
        menu.performActionForItem(at: 1)
        try await SearchTestSupport.waitUntil { board.string(forType: .string) != nil }
        XCTAssertEqual(board.string(forType: .string), "echo synthetic-beta\n")
        XCTAssertEqual(fake.sent, [])
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }

        // Where the panel pastes, the menu names the paste as the toolbar does, and keeps a Copy that never pastes.
        let pasting = FakeDirectPasteSystem()
        let (other, otherBoard) = try await makePanelWithClips(["older", "newer"], shown: true, system: pasting.system)
        _ = try searchEditor(in: other)
        let pasteMenu = try actionMenu(of: other)
        XCTAssertEqual(pasteMenu.items.map(\.title), [
            "Paste into TextEdit", "Paste as Plain Text", "Copy", "", "Show Preview", "",
            "Save as Snippet", "Save to Collection", "Add to Favorites", "", "Show in Library", "New Snippet",
            "", "Move to Recently Deleted",
        ])
        XCTAssertEqual(pasteMenu.items[1].keyEquivalentModifierMask, .shift)
        pasteMenu.performActionForItem(at: 2)
        try await SearchTestSupport.waitUntil { otherBoard.string(forType: .string) != nil && !other.isSessionOpen }
        XCTAssertEqual(otherBoard.string(forType: .string), "newer")
        XCTAssertEqual(pasting.sent, [], "Copy only copies")
        XCTAssertEqual(toastMessage(of: other), "Copied — press ⌘V to paste")
    }

    func testARightClickNamesTheActionsOfTheClipUnderThePointer() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["echo synthetic-beta"], into: harness)
        try await insertImageClip(into: harness)
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board, system: fake.system)
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 2 }
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let strip = try await clipStrip(in: window)
        controller.perform(.move(1))
        XCTAssertEqual(controller.state.selection.rows.first?.kind, .image)
        XCTAssertEqual(controller.state.actions.primaryTitle, "Paste Command", "The command is selected")

        // A right-click on the picture, which is not the selected clip, names the picture's actions, not the command's.
        let picture = try frame(of: "Picture", in: strip)
        let menu = try XCTUnwrap(strip.menu(for: try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: strip.convert(NSPoint(x: picture.midX, y: picture.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))))
        XCTAssertEqual(menu.items.map(\.title), [
            "Paste into Terminal", "Paste as Plain Text", "Copy As-Is", "", "Show Preview", "",
            "Save as Snippet", "Save to Collection", "Add to Favorites", "", "Show in Library", "New Snippet",
            "", "Move to Recently Deleted",
        ])
        XCTAssertEqual(fake.sent, [])
    }

    func testReturnShiftReturnAndTheMenuOpenTheSameReviewAndEscapeCancelsIt() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, board) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        let before = board.changeCount

        // Return in the search field: the card takes the preview's place with the command to review, and VoiceOver reads
        // its title.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await waitForReview(Self.reviewedCommand, in: window)
        XCTAssertEqual(announced, ["Review this 2-line command"])
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        assertFrame(window.frame, places: panelFrame(on: screen, cardSize: .medium, withPreview: true))
        // The command reads in the system's monospaced type, selectable and not editable, and the clips beside the
        // reviewed one step back as they do for the preview.
        let text = try XCTUnwrap(reviewTextView(in: window))
        XCTAssertTrue(text.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isEditable)
        let reviewStrip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        XCTAssertTrue(reviewStrip.dimsSideFrames)
        // Escape cancels it. The panel stays, its preview as it was.
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(controller.state.commandReview)
        try await waitForNoReview(in: window)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertFalse(controller.state.isPreviewExpanded)
        assertFrame(window.frame, places: panelFrame(on: screen, cardSize: .medium))
        XCTAssertFalse(reviewStrip.dimsSideFrames)

        // ⇧Return in the strip opens the same review, and Escape there cancels it too.
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)
        strip.keyDown(with: try key(kVK_Return, "\r", modifiers: .shift))
        try await waitForReview(Self.reviewedCommand, in: window)
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        XCTAssertNil(controller.state.commandReview)
        try await waitForNoReview(in: window)
        XCTAssertTrue(controller.isSessionOpen)

        // So does the menu's first item, which is Return's.
        let menu = try actionMenu(of: controller)
        XCTAssertEqual(menu.items.first?.title, "Paste Command")
        menu.performActionForItem(at: 0)
        try await waitForReview(Self.reviewedCommand, in: window)
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        try await waitForNoReview(in: window)

        // With the preview open the card takes its place, and Escape takes the card and leaves the preview open.
        strip.keyDown(with: try key(kVK_Space, " "))
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        strip.keyDown(with: try key(kVK_Return, "\r"))
        try await waitForReview(Self.reviewedCommand, in: window)
        XCTAssertTrue(controller.state.isPreviewExpanded)
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        XCTAssertNil(controller.state.commandReview)
        XCTAssertTrue(controller.state.isPreviewExpanded)
        XCTAssertTrue(controller.isSessionOpen)
        try await waitForNoReview(in: window)

        // Nothing was written or sent along the way.
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
    }

    func testOnlyCommandReturnConfirmsAndNotDuringComposition() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, board) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let commandReturn = try key(kVK_Return, "\r", modifiers: .command, windowNumber: window.windowNumber)
        let before = board.changeCount

        // A preview is not a confirmation: with the command only previewed, ⌘Return confirms nothing.
        editor.keyDown(with: try key(kVK_Space, " "))
        try await SearchTestSupport.waitUntil { controller.state.preview != nil }
        XCTAssertFalse(window.performKeyEquivalent(with: commandReturn))
        window.sendEvent(try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(board.changeCount, before)
        XCTAssertTrue(controller.isSessionOpen)
        controller.togglePreview()

        // Return opens the review, and pressed again it does not confirm it.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await waitForReview(Self.reviewedCommand, in: window)
        let review = try XCTUnwrap(controller.state.commandReview)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.state.commandReview, review)
        XCTAssertEqual(fake.sent, [])

        // While an input method composes in the field, ⌘Return is the composition's, not a confirmation.
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(window.performKeyEquivalent(with: commandReturn))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(controller.state.commandReview, review)
        // Escape ends the composition first, and leaves the card.
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(controller.state.commandReview, review)
        XCTAssertEqual(board.changeCount, before)

        // ⌘Return confirms: one ⌘V, of the command without its trailing line break, and the panel closes.
        try pressCommandReturn(in: window)
        try await SearchTestSupport.waitUntil { fake.sent == [9] && !controller.isSessionOpen }
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma")
        XCTAssertEqual(fake.sent, [9])
    }

    func testAClickOnTheReviewCardKeepsTheCardAndThePanel() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, _) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.primary)
        try await waitForReview(Self.reviewedCommand, in: window)
        settleLayout()
        let band = try bandRect(in: window)
        let text = try XCTUnwrap(reviewTextView(in: window))
        let card = text.convert(text.bounds, to: nil)
        XCTAssertGreaterThan(card.minY, band.maxY)

        // The card is the panel's own, as the preview card is: a click in it keeps the panel and the card.
        try click(at: NSPoint(x: card.midX, y: card.midY), in: window)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertNotNil(controller.state.commandReview)

        // The 16 pt between the card and the band hold only the band's shadow: a click there closes the panel, and the
        // review goes with it.
        try click(at: NSPoint(x: band.midX, y: band.maxY + StripLayout.previewGap / 2), in: window)
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertNil(controller.state.commandReview)
        XCTAssertEqual(fake.sent, [])
    }

    func testFilePermissionSheetKeepsThePreviewSessionUntilItEnds() async throws {
        let (controller, _) = try await makePanelWithClips(["synthetic file"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: { _ in })
        defer {
            if window.attachedSheet === sheet { window.endSheet(sheet) }
            sheet.orderOut(nil)
        }
        XCTAssertTrue(window.attachedSheet === sheet)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertTrue(controller.isSessionOpen)

        window.endSheet(sheet)
        try await SearchTestSupport.waitUntil { window.attachedSheet == nil }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertFalse(controller.isSessionOpen)
    }

    func testThePanelHidesBeforeTheKeystrokeWithoutEndingItsSession() async throws {
        let fake = FakeDirectPasteSystem()
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        var atSend: (isVisible: Bool, isSessionOpen: Bool)?
        fake.onSend = { [weak controller] in
            guard let controller else { return }
            // The panel gives up the keys as it hides, which does not close it.
            controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
            atSend = (window.isVisible, controller.isSessionOpen)
        }

        controller.perform(.primary)

        try await SearchTestSupport.waitUntil { fake.sent == [9] }
        let send = try XCTUnwrap(atSend)
        XCTAssertFalse(send.isVisible, "Hidden before ⌘V")
        XCTAssertTrue(send.isSessionOpen, "The session the last check needs is still open")
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(controller.isHiddenForPaste)
        XCTAssertEqual(board.string(forType: .string), "newer")
    }

    func testAFallbackShowsWhyAndADispatchShowsNoToast() async throws {
        let fake = FakeDirectPasteSystem()
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true, system: fake.system)
        _ = try searchEditor(in: controller)

        // A paste that goes says nothing: ⌘V does not prove that TextEdit pasted.
        controller.perform(.primary)
        try await SearchTestSupport.waitUntil { fake.sent == [9] && !controller.isSessionOpen }
        XCTAssertFalse(controller.toast.isVisible)

        // Another window comes to the front as the panel hides: the clip is copied instead, and the toast says why.
        controller.show()
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        fake.onProbe = { [weak controller, weak fake] in
            guard controller?.isHiddenForPaste == true else { return }
            fake?.front = .notes
        }
        controller.perform(.primary)
        try await SearchTestSupport.waitUntil { controller.toast.isVisible }
        XCTAssertEqual(toastMessage(of: controller), "The window changed — copied instead. Press ⌘V to paste.")
        XCTAssertEqual(fake.sent, [9])
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertEqual(board.string(forType: .string), "newer")
        // It stays longer than a copy's 1.2 s, to be read.
        try await Task.sleep(for: .milliseconds(1_700))
        XCTAssertTrue(controller.toast.isVisible)
        try await SearchTestSupport.waitUntil(timeout: .seconds(3)) { !controller.toast.isVisible }
    }

    func testEscapeClearsAChosenListBeforeFoldingTheSearch() {
        // A list other than All narrows the panel as a filter does: Escape takes it along with the query and filters,
        // after the preview and before folding the search.
        XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: false, hasQuery: false, hasFilters: false,
                                                      hasList: true, isSearchExpanded: true),
                       .clearQuery)
        XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: false, hasQuery: false, hasFilters: false,
                                                      hasList: false, isSearchExpanded: true),
                       .foldSearch)
        XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: false, isPreviewExpanded: true, hasQuery: false,
                                                      hasList: true),
                       .collapsePreview)
    }

    func testEscapeFromTheCardsClearsAChosenListBeforeClosing() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        _ = try searchEditor(in: controller)
        controller.state.setList(.snippets)
        try await SearchTestSupport.waitUntil { controller.state.phase != .loading }
        XCTAssertEqual(controller.state.list, .snippets)

        // From the cards, Escape peels the list as it peels a filter, and the panel stays open with the clips back.
        controller.perform(.escape)
        try await SearchTestSupport.waitUntil { controller.state.phase != .loading }

        XCTAssertEqual(controller.state.list, .all)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertEqual(controller.state.selection.rows.map(\.title), ["newer", "older"])
    }

    func testEscapeCancelsTheReviewBeforeThePreview() {
        // The card lies in the preview's place, over it: Escape takes the card first, whatever else is open.
        XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: false, hasCommandReview: true, isPreviewExpanded: true,
                                                      hasQuery: true, hasFilters: true, isSearchExpanded: true),
                       .cancelCommandReview)
        XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: false, hasCommandReview: true, hasQuery: false),
                       .cancelCommandReview)
        // An input method's composition still comes before it.
        XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: true, hasCommandReview: true, isPreviewExpanded: true,
                                                      hasQuery: true),
                       .cancelComposition)
        // Without a card, the preview is next, as before.
        XCTAssertEqual(QuickAccessEscapePolicy.action(hasMarkedText: false, hasCommandReview: false,
                                                      isPreviewExpanded: true, hasQuery: true),
                       .collapsePreview)
    }

    func testAPasteWaitsUntilReturnComesUpAndCopiesIfItStaysDown() async throws {
        let fake = FakeDirectPasteSystem()
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let down = try key(kVK_Return, "\r", windowNumber: window.windowNumber)
        let up = try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber)
        let before = board.changeCount

        // Return goes down in the search field. Hidden now, the panel would leave the key's repeats to TextEdit, to press
        // Return after the paste; so nothing is written or sent while it is down.
        window.sendEvent(down)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(board.changeCount, before)
        XCTAssertTrue(window.isVisible)
        // It comes up, and the paste goes.
        window.sendEvent(up)
        try await SearchTestSupport.waitUntil { fake.sent == [9] }
        XCTAssertEqual(board.string(forType: .string), "newer")

        // Held for over a second, Return copies instead. The session ends, but the panel stays on screen with the keys
        // until Return comes up, and only then closes and says why the clip was not pasted.
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let copiedFrom = board.changeCount
        window.sendEvent(down)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.isSessionOpen, "Still waiting for Return")
        XCTAssertEqual(board.changeCount, copiedFrom)
        try await SearchTestSupport.waitUntil(timeout: .seconds(3)) { !controller.isSessionOpen }
        XCTAssertEqual(fake.sent, [9])
        XCTAssertGreaterThan(board.changeCount, copiedFrom)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(window.isVisible, "Not closed while Return is down")
        XCTAssertFalse(controller.toast.isVisible)
        window.sendEvent(up)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.toast.isVisible)
        XCTAssertEqual(toastMessage(of: controller), "Return was held — copied instead. Press ⌘V to paste.")

        // Return came up where the panel saw it. Shown again, the panel does not take it for held: the toolbar's
        // button pastes at once.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let toolbar = try await laidOutToolbar(in: window)
        toolbar.copyHint.performClick(nil)
        // Taking Return for held, the button would wait a second and then copy, and ⌘V would never be sent.
        try await SearchTestSupport.waitUntil { fake.sent == [9, 9] }
        XCTAssertEqual(fake.sent, [9, 9])

        // A paste waiting for Return belongs to the session it was asked in: closed and shown again meanwhile, the panel
        // pastes and writes nothing when Return comes up.
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let unchanged = board.changeCount
        window.sendEvent(down)
        try await Task.sleep(for: .milliseconds(100))
        controller.close()
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        window.sendEvent(up)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sent, [9, 9])
        XCTAssertEqual(board.changeCount, unchanged)
        XCTAssertTrue(controller.isSessionOpen)

        // Keypad Enter is Return's twin in the strip: a paste waits for it to come up just the same.
        controller.perform(.focusResults)
        XCTAssertTrue(window.firstResponder is QuickAccessStripView)
        window.sendEvent(try key(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sent, [9, 9])
        XCTAssertEqual(board.changeCount, unchanged)
        window.sendEvent(try keyUp(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber))
        try await SearchTestSupport.waitUntil { fake.sent == [9, 9, 9] }
        XCTAssertEqual(fake.sent, [9, 9, 9])
    }

    func testAPasteChosenFromTheMenuWithReturnWaitsForItToComeUp() async throws {
        let fake = FakeDirectPasteSystem()
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let returnDown = try key(kVK_Return, "\r", windowNumber: window.windowNumber)
        let returnUp = try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber)
        let before = board.changeCount

        // A menu takes the key-down that chooses an item, so the panel never sees Return go down; the event the app is
        // handling as the item acts is that key-down. Nothing is written or sent while Return is down.
        controller.currentEvent = { returnDown }
        let menu = try actionMenu(of: controller)
        XCTAssertEqual(menu.items.first?.title, "Paste into TextEdit")
        menu.performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(board.changeCount, before)
        XCTAssertTrue(window.isVisible)
        // It comes up through the panel, which still has the keys, and the paste goes.
        window.sendEvent(returnUp)
        try await SearchTestSupport.waitUntil { fake.sent == [9] && !controller.isSessionOpen }
        XCTAssertEqual(board.string(forType: .string), "newer")

        // Chosen with keypad Enter, which stays down for more than a second: the clip is copied instead, and the panel
        // stays until the key comes up, then says why.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let enterDown = try key(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber)
        controller.currentEvent = { enterDown }
        let copiedFrom = board.changeCount
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.isSessionOpen, "Still waiting for keypad Enter")
        XCTAssertEqual(board.changeCount, copiedFrom)
        try await SearchTestSupport.waitUntil(timeout: .seconds(3)) { !controller.isSessionOpen }
        XCTAssertEqual(fake.sent, [9])
        XCTAssertGreaterThan(board.changeCount, copiedFrom)
        XCTAssertTrue(window.isVisible, "Not closed while keypad Enter is down")
        window.sendEvent(try keyUp(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(toastMessage(of: controller), "Return was held — copied instead. Press ⌘V to paste.")

        // Chosen with the pointer, the item acts at once.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 0))
        controller.currentEvent = { click }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await SearchTestSupport.waitUntil { fake.sent == [9, 9] && !controller.isSessionOpen }

        // Only a key going down counts. Return held in the panel keeps a paste waiting, even when the menu's event is
        // a key-up: it takes Return's own key-up for the paste to go.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        window.sendEvent(returnDown)
        controller.currentEvent = { returnUp }
        let previewItem = try XCTUnwrap(try actionMenu(of: controller).items.firstIndex { $0.title == "Show Preview" })
        try actionMenu(of: controller).performActionForItem(at: previewItem)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sent, [9, 9])
        window.sendEvent(returnUp)
        try await SearchTestSupport.waitUntil { fake.sent == [9, 9, 9] }
        XCTAssertEqual(fake.sent, [9, 9, 9])
    }

    func testAPasteItemChosenNeitherWithThePointerNorWithReturnTakesReturnForDown() async throws {
        let fake = FakeDirectPasteSystem()
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let before = board.changeCount

        // Nothing tells how the item was chosen, so Return may still be down from choosing it: nothing is written or
        // sent until Return or keypad Enter comes up.
        controller.currentEvent = { nil }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(board.changeCount, before)
        XCTAssertTrue(controller.isSessionOpen)
        window.sendEvent(try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber))
        try await SearchTestSupport.waitUntil { fake.sent == [9] && !controller.isSessionOpen }
        XCTAssertEqual(board.string(forType: .string), "newer")

        // Chosen with another key, and neither key comes up within a second: the clip is copied instead, and the panel
        // stays until one of them comes up.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let space = try key(kVK_Space, " ", windowNumber: window.windowNumber)
        controller.currentEvent = { space }
        let copiedFrom = board.changeCount
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(board.changeCount, copiedFrom)
        try await SearchTestSupport.waitUntil(timeout: .seconds(3)) { !controller.isSessionOpen }
        XCTAssertEqual(fake.sent, [9])
        XCTAssertGreaterThan(board.changeCount, copiedFrom)
        XCTAssertTrue(window.isVisible, "Not closed while Return may be down")
        window.sendEvent(try keyUp(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(toastMessage(of: controller), "Return was held — copied instead. Press ⌘V to paste.")

        // Chosen as Return came up, the item knows Return is up: it pastes at once.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let returnUp = try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber)
        controller.currentEvent = { returnUp }
        try actionMenu(of: controller).performActionForItem(at: 0)
        XCTAssertEqual(controller.state.returnIsDown?(), false)
        try await SearchTestSupport.waitUntil { fake.sent == [9, 9] }
        XCTAssertEqual(fake.sent, [9, 9])
    }

    func testAGuessedReturnGoesWithTheMenuChoiceItWasGuessedFor() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["older"], into: harness)
        try await insertDocumentClip(into: harness)
        try await harness.consumer.synchronize()
        let fake = FakeDirectPasteSystem()
        let controller = try makePanel(over: harness, pasteboard: board, system: fake.system)
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == 2 }
        _ = try searchEditor(in: controller)
        XCTAssertEqual(controller.state.selection.rows.first?.kind, .other)

        // Chosen with no event to tell how, a paste item takes Return for down, and waits for it; then the document,
        // which has no plain text, is refused. The guess was for that choice alone, and goes with it.
        controller.currentEvent = { nil }
        let menu = try actionMenu(of: controller)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Paste as Plain Text" }))
        try await SearchTestSupport.waitUntil(timeout: .seconds(3)) { controller.state.failure == .noPlainText }
        XCTAssertEqual(controller.state.returnIsDown?(), false)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertEqual(fake.sent, [])

        // The toolbar's button then pastes the text clip at once: nobody pressed Return.
        controller.perform(.move(1))
        let toolbar = try await toolbarSaying(.action(title: "Paste into TextEdit", enabled: true, hint: nil),
                                              in: controller)
        toolbar.copyHint.performClick(nil)
        XCTAssertEqual(controller.state.returnIsDown?(), false)
        try await SearchTestSupport.waitUntil { fake.sent == [9] }
        XCTAssertEqual(board.string(forType: .string), "older")

        // A click on the button is the pointer's, so it drops a guess made for a menu choice that is still waiting:
        // one paste goes at once.
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        controller.perform(.move(1))
        let shownToolbar = try await toolbarSaying(.action(title: "Paste into TextEdit", enabled: true, hint: nil),
                                                   in: controller)
        controller.currentEvent = { nil }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.sent, [9], "The menu's paste waits")
        shownToolbar.copyHint.performClick(nil)
        XCTAssertEqual(controller.state.returnIsDown?(), false)
        try await SearchTestSupport.waitUntil { fake.sent == [9, 9] }
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(fake.sent, [9, 9], "One paste")

        // So does a menu item chosen with the pointer, whatever it does: the waiting paste goes at once.
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        controller.show()
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        controller.perform(.move(1))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 0))
        let pointerMenu = try actionMenu(of: controller)
        let showPreview = try XCTUnwrap(pointerMenu.items.firstIndex { $0.title == "Show Preview" })
        controller.currentEvent = { nil }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.sent, [9, 9], "The menu's paste waits")
        controller.currentEvent = { click }
        pointerMenu.performActionForItem(at: showPreview)
        XCTAssertEqual(controller.state.returnIsDown?(), false)
        try await SearchTestSupport.waitUntil { fake.sent == [9, 9, 9] }
        XCTAssertEqual(fake.sent, [9, 9, 9])
    }

    func testAReviewFromAGuessedReturnConfirmsAtOnceWithTheCardsButton() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, board) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)

        // Chosen with no event to tell how, as VoiceOver may choose it, Paste Command waits for a Return it cannot see,
        // and then opens the review. The guess was for that choice, and goes as the card shows.
        controller.currentEvent = { nil }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await waitForReview(Self.reviewedCommand, in: window)
        XCTAssertEqual(controller.state.returnIsDown?(), false)

        // The card's Confirm button, pressed by VoiceOver or the pointer, confirms at once: one ⌘V.
        try XCTUnwrap(window.contentView as? NSHostingView<QuickAccessBandView>).rootView.actions.confirmCommand()
        XCTAssertEqual(controller.state.returnIsDown?(), false)
        try await SearchTestSupport.waitUntil { fake.sent == [9] }
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma")
    }

    func testAClickEndsAWaitOnlyAGuessedReturnHeldUp() async throws {
        // Without direct paste, Copy copies at once.
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let toolbar = try await toolbarSaying(.action(title: "Copy", enabled: true, hint: nil), in: controller)

        // Chosen with no event to tell how, Copy copies, and the panel waits for a Return that may be down. A click on
        // the toolbar's button is the pointer's, so Return is taken for up after all: the panel closes and says what it
        // did.
        controller.currentEvent = { nil }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        XCTAssertEqual(board.string(forType: .string), "newer")
        XCTAssertTrue(window.isVisible, "Return may be down")
        toolbar.copyHint.performClick(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.toast.isVisible)
        XCTAssertEqual(toastMessage(of: controller), "Copied — press ⌘V to paste")

        // With Return also down where the panel saw it go down, the click leaves the panel waiting for that key.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let shownToolbar = try await toolbarSaying(.action(title: "Copy", enabled: true, hint: nil), in: controller)
        let returnDown = try key(kVK_Return, "\r", windowNumber: window.windowNumber)
        controller.currentEvent = { returnDown }
        let previewMenu = try actionMenu(of: controller)
        previewMenu.performActionForItem(at: try XCTUnwrap(previewMenu.items.firstIndex { $0.title == "Show Preview" }))
        controller.currentEvent = { nil }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        shownToolbar.copyHint.performClick(nil)
        XCTAssertTrue(window.isVisible, "Return is still down")
        XCTAssertEqual(controller.state.returnIsDown?(), true)
        window.sendEvent(try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(toastMessage(of: controller), "Copied — press ⌘V to paste")
    }

    func testAnActionThatEndsWithReturnDownKeepsThePanelUntilReturnIsUp() async throws {
        // Without direct paste, Return copies at once, while it is still down.
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        let isKey = window.isKeyWindow

        // The clip is copied and the session ends, but the panel stays on screen with the keys while Return is down:
        // gone, it would leave the key's repeats to the app below, where a terminal would run the line typed there. The
        // panel takes the repeats, which do nothing.
        window.sendEvent(try key(kVK_Return, "\r", windowNumber: window.windowNumber))
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        XCTAssertEqual(board.string(forType: .string), "newer")
        window.sendEvent(try key(kVK_Return, "\r", windowNumber: window.windowNumber, isARepeat: true))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(window.isVisible, "Not closed before Return comes up")
        XCTAssertEqual(window.isKeyWindow, isKey)
        XCTAssertTrue(window.firstResponder === editor, "The keys stay in the panel")
        XCTAssertFalse(controller.toast.isVisible)
        // Return comes up: the panel closes, and says what it did.
        window.sendEvent(try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.toast.isVisible)
        XCTAssertEqual(toastMessage(of: controller), "Copied — press ⌘V to paste")

        // Keypad Enter in the strip keeps the panel the same way.
        controller.show()
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        controller.perform(.focusResults)
        let strip = try XCTUnwrap(window.firstResponder as? QuickAccessStripView)
        let copiedFrom = board.changeCount
        window.sendEvent(try key(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber))
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        XCTAssertGreaterThan(board.changeCount, copiedFrom)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(window.isVisible, "Not closed before keypad Enter comes up")
        XCTAssertTrue(window.firstResponder === strip)
        window.sendEvent(try keyUp(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber))
        XCTAssertFalse(window.isVisible)

        // With no key-up in sight, Escape closes the panel as it would any other time, at once: the session is over, so
        // there is nothing left to fold first.
        controller.show()
        let (_, shownEditor) = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_F, "f", modifiers: .command)))
        XCTAssertTrue(controller.state.isSearchExpanded)
        window.sendEvent(try key(kVK_Return, "\r", windowNumber: window.windowNumber))
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        XCTAssertTrue(window.isVisible)
        // Only while the field is still edited: a closed panel's editor has left it.
        if window.isVisible { shownEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(controller.toast.isVisible)
        XCTAssertEqual(toastMessage(of: controller), "Copied — press ⌘V to paste")

        // A copy chosen from the menu with no event to tell how waits for a Return that may be down. Shown again
        // meanwhile, the panel opens a session that does not take Return for down.
        controller.show()
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        controller.currentEvent = { nil }
        try actionMenu(of: controller).performActionForItem(at: 0)
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        XCTAssertTrue(window.isVisible, "Return may be down")
        controller.show()
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertEqual(controller.state.returnIsDown?(), false)
    }

    func testFinderInFrontIsNoTargetAndOnlyCopies() async throws {
        // The window check cannot tell Finder's desktop from a Finder window on top, and a paste there copies files:
        // Finder is no target, so the panel is as it was before direct paste and says nothing more.
        let fake = FakeDirectPasteSystem()
        fake.front = .finder
        let (controller, board) = try await makePanelWithClips(["older", "newer"], shown: true, system: fake.system)
        _ = try searchEditor(in: controller)
        XCTAssertNil(controller.state.pasteTarget)
        _ = try await toolbarSaying(.action(title: "Copy", enabled: true, hint: nil), in: controller)
        XCTAssertEqual(try actionMenu(of: controller).items.map(\.title),
                       ["Copy", "Copy as Plain Text", "", "Show Preview", "",
                        "Save as Snippet", "Save to Collection", "Add to Favorites", "", "Show in Library",
                        "New Snippet", "", "Move to Recently Deleted"])

        controller.perform(.primary)
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen }
        XCTAssertEqual(board.string(forType: .string), "newer")
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(toastMessage(of: controller), "Copied — press ⌘V to paste")
    }

    func testCommandWithKeypadEnterConfirmsAsCommandReturnDoes() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, board) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        let (_, editor) = try searchEditor(in: controller)
        // Keypad Enter comes with the keypad's flag, which is no modifier a shortcut asks for.
        let commandEnter = try key(kVK_ANSI_KeypadEnter, "\u{3}", modifiers: [.command, .numericPad],
                                   windowNumber: window.windowNumber)
        let enterUp = try keyUp(kVK_ANSI_KeypadEnter, "\u{3}", windowNumber: window.windowNumber)

        // Without a review there is nothing to confirm.
        XCTAssertFalse(window.performKeyEquivalent(with: commandEnter))

        // Return opens the review. While an input method composes in the field, ⌘ with keypad Enter is the
        // composition's, as ⌘Return is.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await waitForReview(Self.reviewedCommand, in: window)
        let review = try XCTUnwrap(controller.state.commandReview)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(window.performKeyEquivalent(with: commandEnter))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.state.commandReview, review)
        XCTAssertEqual(fake.sent, [])
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(editor.hasMarkedText())

        // With the card showing, it confirms once keypad Enter is up: one ⌘V, of the command without its trailing line
        // break.
        XCTAssertTrue(window.performKeyEquivalent(with: commandEnter))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.sent, [], "Not while keypad Enter is down")
        window.sendEvent(enterUp)
        try await SearchTestSupport.waitUntil { fake.sent == [9] && !controller.isSessionOpen }
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma")
    }

    func testAConfirmationWaitsForReturnToComeUpAndLapsesIfItStaysDown() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, board) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.primary)
        try await waitForReview(Self.reviewedCommand, in: window)
        let review = try XCTUnwrap(controller.state.commandReview)
        let before = board.changeCount
        let commandReturn = try key(kVK_Return, "\r", modifiers: .command, windowNumber: window.windowNumber)
        let up = try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber)

        // ⌘Return held for over a second confirms nothing: confirming it as a copy would need a review of its own, so the
        // card stays. Its repeats, the last of them less than a second before Return comes up, confirm nothing either.
        XCTAssertTrue(window.performKeyEquivalent(with: commandReturn))
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_Return, "\r", modifiers: .command,
                                                                windowNumber: window.windowNumber, isARepeat: true)))
        try await Task.sleep(for: .milliseconds(200))
        window.sendEvent(up)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.state.commandReview, review)
        XCTAssertTrue(controller.isSessionOpen)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(board.changeCount, before)

        // ⌘Return confirms the review on the card when it is pressed. Cancelled meanwhile, and another review made in
        // its place before Return comes up, the new one waits for a ⌘Return of its own.
        XCTAssertTrue(window.performKeyEquivalent(with: commandReturn))
        controller.perform(.escape)
        XCTAssertNil(controller.state.commandReview)
        let target = try XCTUnwrap(controller.state.copyTarget)
        await controller.state.act(on: target, mode: .original, delivery: .paste)
        let another = try XCTUnwrap(controller.state.commandReview)
        XCTAssertNotEqual(another, review)
        window.sendEvent(up)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.state.commandReview, another)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(board.changeCount, before)

        // Pressed and let go, it confirms, once Return is up.
        XCTAssertTrue(window.performKeyEquivalent(with: commandReturn))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.sent, [], "Not while Return is down")
        window.sendEvent(up)
        try await SearchTestSupport.waitUntil { fake.sent == [9] }
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma")
    }

    func testAReviewThatNoLongerAppliesComesBackSayingWhy() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, board) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        var announced: [String] = []
        controller.announce = { announced.append($0) }
        controller.perform(.primary)
        try await waitForReview(Self.reviewedCommand, in: window)
        XCTAssertEqual(controller.state.commandReview.map(QuickAccessActions.confirmTitle(for:)),
                       "Confirm Paste into Terminal")

        // Secure input comes on before the paste is confirmed: the review comes back for a copy, saying why, and
        // VoiceOver reads why before the title. Nothing was written or sent.
        let before = board.changeCount
        fake.secureInput = true
        try pressCommandReturn(in: window)
        try await SearchTestSupport.waitUntil { controller.state.commandReview?.isRenewal == true }
        XCTAssertEqual(controller.state.commandReview.map(QuickAccessActions.confirmTitle(for:)), "Confirm Copy Command")
        XCTAssertEqual(announced.last, "The content or target changed. Review it and confirm again. "
                                       + "Review this 2-line command")
        XCTAssertEqual(board.changeCount, before)
        XCTAssertEqual(fake.sent, [])

        // Confirmed again, the command is copied, and the toast says why it was not pasted.
        try pressCommandReturn(in: window)
        try await SearchTestSupport.waitUntil { !controller.isSessionOpen && controller.toast.isVisible }
        XCTAssertEqual(toastMessage(of: controller), "Secure input is on — copied instead. Press ⌘V to paste.")
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma")
        XCTAssertEqual(fake.sent, [])
    }

    func testWhileAReviewShowsOnlyTheCardConfirmsIt() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, _) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        let command = QuickAccessToolbar.Note.action(title: "Paste Command", enabled: true, hint: nil)
        _ = try await toolbarSaying(command, in: controller)
        XCTAssertTrue(try actionMenu(of: controller).items[0].isEnabled)

        // While the command waits on the card, only the card confirms it: the toolbar's "⏎ Paste Command" and the menu's
        // item for Return are disabled. Copy As-Is and the preview still work.
        controller.perform(.primary)
        try await waitForReview(Self.reviewedCommand, in: window)
        let toolbar = try await toolbarSaying(.action(title: "Paste Command", enabled: false, hint: nil), in: controller)
        XCTAssertFalse(toolbar.copyHint.isEnabled)
        let menu = try actionMenu(of: controller)
        XCTAssertEqual(menu.items.map(\.title), [
            "Paste Command", "Copy As-Is (Keeps Trailing Newline)", "", "Show Preview", "",
            "Save as Snippet", "Save to Collection", "Add to Favorites", "", "Show in Library", "New Snippet",
            "", "Move to Recently Deleted",
        ])
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isEnabled)
        XCTAssertTrue(menu.items[3].isEnabled)
        XCTAssertTrue(menu.items[5].isEnabled)
        XCTAssertTrue(menu.items[7].isEnabled)
        XCTAssertTrue(menu.items[9].isEnabled)
        XCTAssertTrue(menu.items[10].isEnabled)

        // Without the card, Return's actions are offered again.
        controller.perform(.escape)
        XCTAssertNil(controller.state.commandReview)
        _ = try await toolbarSaying(command, in: controller)
        XCTAssertTrue(try actionMenu(of: controller).items[0].isEnabled)
        XCTAssertEqual(fake.sent, [])
    }

    func testTheShortcutsWorkWithCapsLockOn() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let (controller, board) = try await makePanelWithClips(
            ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        controller.perform(.primary)
        try await waitForReview(Self.reviewedCommand, in: window)

        // Caps Lock is no modifier a shortcut asks for: ⌘K opens the menu and ⌘Return confirms with it on.
        var shown = 0
        controller.presentActionMenu = { _, _, _ in shown += 1 }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_K, "k", modifiers: [.command, .capsLock])))
        XCTAssertEqual(shown, 1)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_Return, "\r", modifiers: [.command, .capsLock],
                                                                windowNumber: window.windowNumber)))
        window.sendEvent(try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber))
        try await SearchTestSupport.waitUntil { fake.sent == [9] }
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma")
    }

    func testTheReviewCardSaysWhatItIsForAndItsButtonsConfirmOrCancel() throws {
        addTeardownBlock { self.panelUnderTest = nil }
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        var boardUnderTest: NSPasteboard?
        // The panel is set up in a task, and the test waits for it. Reading SwiftUI's elements turns the run loop over,
        // which must not happen inside a test's own task.
        try runInTask {
            let (controller, board) = try await self.makePanelWithClips(
                ["older", "gamma"], bodies: ["gamma": Self.multiLineCommand], shown: true, system: fake.system)
            _ = try self.searchEditor(in: controller)
            controller.perform(.primary)
            try await self.waitForReview(Self.reviewedCommand, in: try XCTUnwrap(controller.window))
            self.panelUnderTest = controller
            boardUnderTest = board
        }
        let controller = try XCTUnwrap(panelUnderTest)
        let board = try XCTUnwrap(boardUnderTest)
        let content = try XCTUnwrap(controller.window?.contentView)
        let before = board.changeCount

        // The card is one group, with its title, what to check, the command and its two buttons, each by the identifier
        // UI tests know it by. A first review has no notice.
        var elements = try swiftUIAccessibilityElements(in: content) { elements in
            elements.contains { self.identifier(of: $0) == "CommandReviewConfirm" }
        }
        XCTAssertTrue(elements.contains { identifier(of: $0) == "CommandReview" })
        XCTAssertTrue(elements.contains { text(of: $0) == "Review this 2-line command" })
        XCTAssertTrue(elements.contains {
            text(of: $0) == "A terminal can run each line as soon as it arrives. Check every line."
        })
        XCTAssertEqual(reviewTextView(in: try XCTUnwrap(controller.window))?.accessibilityLabel(), "Command")
        XCTAssertFalse(elements.contains { identifier(of: $0) == "CommandReviewNotice" })
        let confirm = try XCTUnwrap(elements.first { identifier(of: $0) == "CommandReviewConfirm" })
        XCTAssertEqual(text(of: confirm), "Confirm Paste into Terminal")
        let cancel = try XCTUnwrap(elements.first { identifier(of: $0) == "CommandReviewCancel" })
        XCTAssertEqual(text(of: cancel), "Cancel")

        // Cancel takes the card away, and nothing is written or sent.
        press(cancel)
        spin { controller.state.commandReview == nil }
        XCTAssertNil(controller.state.commandReview)
        XCTAssertTrue(controller.isSessionOpen)

        // Reviewed again, and secure input comes on before Confirm: the review comes back for a copy, with the notice
        // that says why.
        controller.perform(.primary)
        spin { controller.state.commandReview != nil }
        fake.secureInput = true
        elements = try swiftUIAccessibilityElements(in: content) { elements in
            elements.contains { self.identifier(of: $0) == "CommandReviewConfirm" }
        }
        press(try XCTUnwrap(elements.first { identifier(of: $0) == "CommandReviewConfirm" }))
        spin { controller.state.commandReview?.isRenewal == true }
        elements = try swiftUIAccessibilityElements(in: content) { elements in
            elements.contains { self.identifier(of: $0) == "CommandReviewNotice" }
        }
        let notice = try XCTUnwrap(elements.first { identifier(of: $0) == "CommandReviewNotice" })
        XCTAssertTrue(text(of: notice)?.contains("The content or target changed. Review it and confirm again.") == true,
                      text(of: notice) ?? "")
        let renewed = try XCTUnwrap(elements.first { identifier(of: $0) == "CommandReviewConfirm" })
        XCTAssertEqual(text(of: renewed), "Confirm Copy Command")
        XCTAssertEqual(board.changeCount, before)

        // Confirm copies the command, and sends nothing.
        press(renewed)
        spin { !controller.isSessionOpen }
        XCTAssertFalse(controller.isSessionOpen)
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma")
        XCTAssertEqual(fake.sent, [])
    }

    func testAToastThatSaysWhyAPasteBecameACopyStaysLonger() {
        XCTAssertEqual(PanelController.toastDuration(for: .copied, arguments: []), .milliseconds(1_200))
        for fallback in [DirectPasteFallback.targetChanged, .notPermitted, .secureInput, .cannotSendKeystroke,
                         .testSessionTarget, .returnHeld] {
            XCTAssertEqual(PanelController.toastDuration(for: .copiedInstead(fallback), arguments: []),
                           .milliseconds(2_500), "\(fallback)")
        }
        // Without a target a copy has only the copy to tell, for as long as a copy's toast.
        XCTAssertEqual(PanelController.toastDuration(for: .copiedInstead(.noTarget), arguments: []), .milliseconds(1_200))
        // UI tests poll about once a second, so there every toast stays four.
        for completion in [QuickAccessCompletion.copied, .copiedInstead(.targetChanged), .copiedInstead(.returnHeld)] {
            XCTAssertEqual(PanelController.toastDuration(for: completion, arguments: ["--ui-testing"]), .seconds(4))
        }
    }

    func testOpenInLibraryWaitsForTheChoosingReturnAndKeepsTheChosenClip() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let chosen = try XCTUnwrap(controller.state.copyTarget?.ref)
        var opened: [ContentRef] = []
        controller.onOpenInLibrary = { ref, _ in opened.append(ref) }
        let returnDown = try key(kVK_Return, "\r", windowNumber: window.windowNumber)
        controller.currentEvent = { returnDown }

        let menu = try actionMenu(of: controller)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Show in Library" }))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(opened, [], "The library must not receive Return repeats")
        XCTAssertEqual(controller.state.returnIsDown?(), true)

        controller.perform(.move(1))
        XCTAssertNotEqual(controller.state.copyTarget?.ref, chosen)
        window.sendEvent(try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber))
        try await SearchTestSupport.waitUntil { opened.count == 1 }
        XCTAssertEqual(opened, [chosen], "The menu action keeps the clip chosen before waiting")
    }

    func testNewSnippetChosenWithHeldReturnLapsesWithoutOpeningTheEditor() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        var newSnippets = 0
        controller.onNewSnippet = { _ in newSnippets += 1 }
        let returnDown = try key(kVK_Return, "\r", windowNumber: window.windowNumber)
        let returnUp = try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber)
        controller.currentEvent = { returnDown }

        let menu = try actionMenu(of: controller)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "New Snippet" }))
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertEqual(newSnippets, 0)
        XCTAssertTrue(controller.isSessionOpen)
        window.sendEvent(returnUp)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(newSnippets, 0, "A late key-up must not revive a lapsed handoff")
    }

    func testLibraryHandoffsFromThePointerAndCommandShortcutsAreImmediate() async throws {
        let (controller, _) = try await makePanelWithClips(["older", "newer"], shown: true)
        let window = try XCTUnwrap(controller.window)
        _ = try searchEditor(in: controller)
        try await SearchTestSupport.waitUntil { controller.state.selection.executableSelection != nil }
        let selected = try XCTUnwrap(controller.state.copyTarget?.ref)
        var opened: [ContentRef] = []
        var newSnippets = 0
        controller.onOpenInLibrary = { ref, _ in opened.append(ref) }
        controller.onNewSnippet = { _ in newSnippets += 1 }
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        controller.currentEvent = { click }

        let menu = try actionMenu(of: controller)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Show in Library" }))
        XCTAssertEqual(opened, [selected])
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "New Snippet" }))
        XCTAssertEqual(newSnippets, 1)
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_E, "e", modifiers: .command)))
        XCTAssertEqual(opened, [selected, selected])
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_N, "n", modifiers: .command)))
        XCTAssertEqual(newSnippets, 2)
    }

    func testSettingsSaysWhetherDirectPasteIsOnAndReadsItAgainWhenKeeptideIsActive() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["copy me"], into: harness)
        let fake = FakeDirectPasteSystem()
        fake.permitted = false
        let panel = try makePanel(over: harness, pasteboard: board, system: fake.system)
        let environment = AppEnvironment(makePanel: { panel })
        addTeardownBlock { panel.close() }
        var alerts = 0
        environment.runDirectPasteAlert = { _ in
            alerts += 1
            return .alertFirstButtonReturn
        }
        environment.activateApp = {}
        XCTAssertTrue(environment.panelController === panel)
        let directPaste = environment.settingsModel.directPaste

        // Coming to Keeptide reads the state: off, as nothing allowed it yet.
        environment.applicationDidBecomeActive()
        XCTAssertEqual(directPaste.state, .off)

        // Settings turns it on as the panel's Enable Direct Paste… does, and the grant waits for Keeptide to reopen.
        directPaste.turnOn()
        XCTAssertEqual(alerts, 1)
        XCTAssertEqual(fake.accessRequests, 1)
        XCTAssertEqual(directPaste.state, .awaitsReopen)

        // Reopened with access, Keeptide reads it again when it becomes active.
        fake.permitted = true
        environment.applicationDidBecomeActive()
        XCTAssertEqual(directPaste.state, .on)
    }

    func testEnableDirectPasteExplainsWhatItTakesBeforeAskingForAccess() async throws {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(["copy me"], into: harness)
        let fake = FakeDirectPasteSystem()
        fake.permitted = false
        let panel = try makePanel(over: harness, pasteboard: board, system: fake.system)
        let environment = AppEnvironment(makePanel: { panel })
        var alerts: [NSAlert] = []
        var choice = NSApplication.ModalResponse.alertSecondButtonReturn
        environment.runDirectPasteAlert = { alert in
            alerts.append(alert)
            return choice
        }
        // Keeptide comes forward for the alert; a unit test only counts it, and never brings the test host forward.
        var activations = 0
        environment.activateApp = { activations += 1 }
        XCTAssertTrue(environment.panelController === panel)
        addTeardownBlock { panel.close() }
        let window = try XCTUnwrap(panel.window)
        // Chosen with the pointer, until the test says otherwise.
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 0))
        panel.currentEvent = { click }
        func chooseEnableDirectPaste() async throws {
            panel.show()
            try await SearchTestSupport.waitUntil { panel.state.selection.executableSelection != nil }
            let menu = try actionMenu(of: panel)
            menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "Enable Direct Paste…" }))
        }

        // The panel closes first. Keeptide then says what turning direct paste on takes, and Cancel asks for nothing.
        try await chooseEnableDirectPaste()
        XCTAssertFalse(panel.isSessionOpen)
        let alert = try XCTUnwrap(alerts.last)
        XCTAssertEqual(alert.messageText, "Turn On Direct Paste")
        let settings = DirectPasteSettingsLocation.path()
        XCTAssertEqual(alert.informativeText, """
            Keeptide pastes by sending ⌘V to the app you were using. Allow Keeptide in \(settings), then quit and \
            reopen Keeptide. If Keeptide is already on there, remove it from the list with − and add it again with + \
            before reopening.
            """)
        XCTAssertEqual(alert.buttons.map(\.title), ["Open System Settings", "Cancel"])
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r", "Open System Settings is the default")
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(fake.accessRequests, 0)
        XCTAssertEqual(fake.settingsOpened, 0)

        // Open System Settings asks for access, and opens Accessibility settings when the system does not grant it.
        choice = .alertFirstButtonReturn
        try await chooseEnableDirectPaste()
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(activations, 2)
        XCTAssertFalse(panel.isSessionOpen)
        XCTAssertEqual(fake.accessRequests, 1)
        XCTAssertEqual(fake.settingsOpened, 1)
        // Keeptide sees the access only once it reopens, which the toolbar says until then.
        panel.show()
        _ = try await toolbarSaying(.action(title: "Copy", enabled: true,
                                            hint: "Reopen Keeptide to finish turning on direct paste"), in: panel)

        // Chosen with Return, the item waits for it to come up: held, its repeats would press the alert's default
        // button.
        let returnDown = try key(kVK_Return, "\r", windowNumber: window.windowNumber)
        let returnUp = try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber)
        panel.currentEvent = { returnDown }
        choice = .alertSecondButtonReturn
        try await chooseEnableDirectPaste()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(alerts.count, 2)
        XCTAssertTrue(panel.isSessionOpen)
        window.sendEvent(returnUp)
        try await SearchTestSupport.waitUntil { alerts.count == 3 }
        XCTAssertFalse(panel.isSessionOpen)
        XCTAssertEqual(activations, 3)

        // Still down after a second, it shows nothing, and the panel stays as it was.
        try await chooseEnableDirectPaste()
        try await Task.sleep(for: .milliseconds(1_400))
        XCTAssertEqual(alerts.count, 3)
        XCTAssertTrue(panel.isSessionOpen)
        window.sendEvent(returnUp)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(alerts.count, 3, "Return coming up late shows nothing either")
        XCTAssertEqual(activations, 3)
        XCTAssertEqual(fake.accessRequests, 1)

        // Chosen neither with the pointer nor with Return, as VoiceOver chooses it, the item waits for no key the panel
        // did not see go down: VoiceOver can turn direct paste on. At worst a held Return's repeats press the alert's
        // default button, which opens the settings asked for.
        panel.currentEvent = { nil }
        try await chooseEnableDirectPaste()
        XCTAssertEqual(alerts.count, 4)
        XCTAssertFalse(panel.isSessionOpen)
        XCTAssertEqual(activations, 4)
        XCTAssertEqual(fake.accessRequests, 1)
    }

    /// Runs `body` in a task of its own and waits for it. What a test does afterwards may turn the run loop over, as
    /// reading SwiftUI's elements does, which must not happen inside a test's own task.
    private func runInTask(_ body: @escaping @MainActor () async throws -> Void) throws {
        let done = expectation(description: "Set up in a task")
        var failure: (any Error)?
        Task { @MainActor in
            defer { done.fulfill() }
            do {
                try await body()
            } catch {
                failure = error
            }
        }
        wait(for: [done], timeout: 30)
        if let failure { throw failure }
    }

    private func identifier(of element: NSObject) -> String? {
        accessibility(element, "accessibilityIdentifier") as? String
    }

    /// Presses an accessibility element, as VoiceOver does. The press answers whether it was handled, which is not an
    /// object, so the answer is left unread.
    private func press(_ element: NSObject) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(element.responds(to: selector))
        _ = element.perform(selector)
    }

    /// Turns the run loop over until `condition` holds, for up to five seconds.
    private func spin(until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
    }

    /// The panel's toolbar once it says `note` at its right end and has laid it out. The toolbar follows the clips a
    /// moment after they arrive.
    private func toolbarSaying(_ note: QuickAccessToolbar.Note,
                               in controller: PanelController) async throws -> QuickAccessToolbar {
        let toolbar = try await laidOutToolbar(in: try XCTUnwrap(controller.window))
        try await SearchTestSupport.waitUntil {
            toolbar.layoutSubtreeIfNeeded()
            return toolbar.note == note
        }
        XCTAssertEqual(toolbar.note, note)
        toolbar.layoutSubtreeIfNeeded()
        return toolbar
    }

    /// The menu ⌘K opens for the selected clip.
    private func actionMenu(of controller: PanelController) throws -> NSMenu {
        let window = try XCTUnwrap(controller.window)
        var shown: NSMenu?
        controller.presentActionMenu = { menu, _, _ in shown = menu }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_ANSI_K, "k", modifiers: .command)))
        return try XCTUnwrap(shown)
    }

    /// The review card's command text, as its text view shows it.
    private func reviewTextView(in window: NSWindow) -> NSTextView? {
        views(NSTextView.self, in: window.contentView).first { $0.accessibilityIdentifier() == "CommandReviewText" }
    }

    /// Waits until the review card shows `command`. SwiftUI draws the card a moment after the review arrives.
    private func waitForReview(_ command: String, in window: NSWindow) async throws {
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return self.reviewTextView(in: window)?.string == command
        }
        XCTAssertEqual(reviewTextView(in: window)?.string, command)
    }

    private func waitForNoReview(in window: NSWindow) async throws {
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return self.reviewTextView(in: window) == nil
        }
    }

    /// ⌘Return pressed and let go, as the panel receives it: the key equivalent, then Return coming up.
    private func pressCommandReturn(in window: NSWindow) throws {
        XCTAssertTrue(window.performKeyEquivalent(with: try key(kVK_Return, "\r", modifiers: .command,
                                                                windowNumber: window.windowNumber)))
        window.sendEvent(try keyUp(kVK_Return, "\r", windowNumber: window.windowNumber))
    }

    /// What the panel's toast says.
    private func toastMessage(of controller: PanelController) -> String? {
        views(NSTextField.self, in: controller.toast.window?.contentView)
            .first { $0.accessibilityIdentifier() == "CopyToastMessage" }?.stringValue
    }

    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.lazy.compactMap { self.findSearchField(in: $0) }.first
    }

    /// A panel over a real temporary store holding one text clip per title, newest last; a clip's text is its title
    /// unless `bodies` gives it another. A shown panel opens the way the shortcut opens it; otherwise only its state
    /// does, and the window stays off screen. `visibleFrame` stands in for the screen's visible area when given, and
    /// `system` is what direct paste asks of the system: by default nothing is in front, and the panel only copies.
    private func makePanelWithClips(_ titles: [String], bodies: [String: String] = [:], shown: Bool = false,
                                    visibleFrame: NSRect? = nil, system: DirectPasteSystem = .unavailable) async throws
        -> (PanelController, NSPasteboard) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(titles, bodies: bodies, into: harness)
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: visibleFrame, system: system)
        if shown {
            controller.show()
            addTeardownBlock { controller.close() }
        } else {
            controller.state.open()
        }
        try await SearchTestSupport.waitUntil { controller.state.selection.rows.count == titles.count }
        return (controller, board)
    }

    /// A panel over a real temporary store holding one text clip per title, newest last, that saves clips as snippets
    /// through the library's own service. A shown panel opens the way the shortcut opens it; otherwise only its state
    /// does. It returns once the clips are listed and the newest can be acted on.
    private func makeSavingPanel(_ titles: [String], shown: Bool = false) async throws
        -> (PanelController, SearchHarness) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(titles, into: harness)
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board,
                                       library: LibraryService(controller: harness.controller))
        if shown {
            controller.show()
            addTeardownBlock { controller.close() }
        } else {
            controller.state.open()
        }
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.count == titles.count && controller.state.copyTarget != nil
        }
        return (controller, harness)
    }

    /// Stores a small PNG picture as the newest clip.
    private func insertImageClip(into harness: SearchHarness) async throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:]))
        let capture = try ContentStoreFixtures.capture([[("public.png", png)]])
        let item = ItemValue(title: "Picture", captureID: capture.id, historyEligible: true,
                             lastCopiedAt: Date(timeIntervalSince1970: 2_000), copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
    }

    /// Stores a synthetic PDF, a clip with no text, as the newest clip.
    private func insertDocumentClip(into harness: SearchHarness) async throws {
        let capture = try ContentStoreFixtures.capture([[("com.adobe.pdf", Data("%PDF-1.7 synthetic".utf8))]])
        let item = ItemValue(title: "Synthetic document", captureID: capture.id, historyEligible: true,
                             lastCopiedAt: Date(timeIntervalSince1970: 2_000), copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
    }

    /// Stores one text clip per title, each copied a second after the one before, so the last is the newest. A clip's
    /// text is its title unless `bodies` gives it another.
    @discardableResult
    private func insertClips(_ titles: [String], bodies: [String: String] = [:],
                             into harness: SearchHarness) async throws -> [ItemValue] {
        var items: [ItemValue] = []
        for (offset, title) in titles.enumerated() {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text",
                                                              Data((bodies[title] ?? title).utf8))]])
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

    /// `search` stands in for the harness's own search service when given, and `visibleFrame` for the screen's visible
    /// area. `system` is what direct paste asks of the system; never the live one, which could paste the general
    /// clipboard into the app in front. The panel reads how often clips were used from `usage`, and without it lists no
    /// frequent wing. `preferences` are medium cards with the frequent clips turned off unless given. The panel saves
    /// clips as snippets through `library`, and without it saves nothing.
    /// What Recently Deleted holds, by title, in alphabetical order.
    private func trashTitles(in harness: SearchHarness) async throws -> [String] {
        try await LifecycleService(controller: harness.controller)
            .trash(policy: .permanent, at: Date(), expecting: try await harness.controller.identity())
            .map(\.title).sorted()
    }

    /// Reaches a panel from what is made before it.
    @MainActor
    private final class PanelRelay {
        weak var controller: PanelController?
    }

    /// A shown panel over a real temporary store holding one text clip per title, newest last, that moves clips to
    /// Recently Deleted through the library's own maintenance. The maintenance reports a change as the app's does, by
    /// having the panel read its recent clips again. It returns once the clips are listed and the newest can be acted on.
    private func makeDeletingPanel(_ titles: [String], shown: Bool = false) async throws
        -> (PanelController, SearchHarness) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(titles, into: harness)
        try await harness.consumer.synchronize()
        let suite = "Keeptide-PanelDelete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // The clips are dated long ago; a history kept forever still recovers them from Recently Deleted.
        let preferences = LifecyclePreferences(defaults: defaults)
        try preferences.commit(try preferences.stageHistoryRetention(.permanent), confirmingShortening: true)
        let relay = PanelRelay()
        let maintenance = LibraryMaintenance(controller: harness.controller,
                                             identity: try await harness.controller.identity(),
                                             directory: harness.directory,
                                             preferences: preferences,
                                             didChange: { relay.controller?.state.recentClipsChanged() })
        addTeardownBlock {
            await maintenance.stopAndDrain()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let controller = try makePanel(over: harness, pasteboard: board,
                                       library: LibraryService(controller: harness.controller),
                                       lifecycle: maintenance)
        relay.controller = controller
        if shown {
            controller.show()
            addTeardownBlock { controller.close() }
        } else {
            controller.state.open()
        }
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.count == titles.count && controller.state.copyTarget != nil
        }
        return (controller, harness)
    }

    private func makePanel(over harness: SearchHarness, pasteboard: NSPasteboard, search: SearchService? = nil,
                           visibleFrame: NSRect? = nil, system: DirectPasteSystem = .unavailable,
                           usage: (any QuickAccessUsage)? = nil, library: LibraryService? = nil,
                           collections: (any QuickAccessCollections)? = nil,
                           preferences: QuickAccessPreferences? = nil,
                           lifecycle: (any QuickAccessLifecycle)? = nil) throws -> PanelController {
        let repository = ContentRepository(controller: harness.controller)
        let paste = PasteService(pasteboard: pasteboard, read: { try await repository.read($0) },
                                 recordUse: { _ in }, didWrite: { _ in }, system: system)
        // A paste the panel could not hide for stops a debug build; here it fails the test instead.
        paste.reportProgrammingError = { XCTFail("Programming error: \($0)") }
        let services = QuickAccessServices(repository: repository, search: search ?? harness.service, paste: paste,
                                           usage: usage, library: library, collections: collections,
                                           collectionChanges: collections as? any QuickAccessCollectionChanges,
                                           lifecycle: lifecycle)
        return PanelController(state: QuickAccessState(services: { services }),
                               preferences: try preferences ?? makePreferences(.medium), visibleFrame: visibleFrame)
    }

    /// A shown panel over a real temporary store holding one text clip per title, the last the newest, and a collection
    /// per name in `collections`, each with one snippet named "<collection> snippet", plus the snippets `unfiled` names
    /// in no collection. The snippets `favorites` names are favorites. It returns once the clips are listed and the
    /// collections read, with the collections in order.
    private func showPanelWithLists(clips: [String], collections: [String], unfiled: [String] = [],
                                    favorites: Set<String> = [], visibleFrame: NSRect? = nil)
        async throws -> (controller: PanelController, harness: SearchHarness, collections: [CollectionSnapshot]) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(clips, into: harness)
        let service = CollectionService(controller: harness.controller)
        let library = LibraryService(controller: harness.controller)
        var made: [CollectionSnapshot] = []
        var snippets: [(title: String, collectionID: CollectionID?)] = unfiled.map { ($0, nil) }
        for name in collections {
            let collection = try await service.create(CollectionDraft(name: name, color: "blue"))
            made.append(collection)
            snippets.append(("\(name) snippet", collection.value.id))
        }
        for snippet in snippets {
            let ref = try await library.create(MemoDraft(title: snippet.title, body: "\(snippet.title) body",
                                                         collectionIDs: snippet.collectionID.map { [$0] } ?? []))
            if favorites.contains(snippet.title) { _ = try await service.setFavorite([ref], isFavorite: true) }
        }
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: visibleFrame, library: library,
                                       collections: service)
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.count == clips.count
                && controller.state.collections.count == collections.count
        }
        return (controller, harness, made)
    }

    /// A screen whose visible area medium cards fill five whole cards wide.
    private static let wingScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    /// A shown panel over a real temporary store holding one text clip per title, the last the newest, in which the
    /// clips `uses` names were each used that many times, the last a minute ago. It opens as the shortcut opens it, on
    /// `wingScreen`, and reads the uses from the store, unless Settings turned the frequent clips off. It returns once
    /// the recent clips are listed; a frequent wing is listed with them, never after them.
    private func showPanelWithFrequentClips(_ titles: [String], uses: [String: Int], showsFrequent: Bool = true)
        async throws -> (controller: PanelController, harness: SearchHarness, board: NSPasteboard) {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        try await insertClips(titles, into: harness)
        for (title, times) in uses { try await recordUses(of: title, times: times, in: harness) }
        try await harness.consumer.synchronize()
        let controller = try makePanel(over: harness, pasteboard: board, visibleFrame: Self.wingScreen,
                                       usage: LocalUsageStore(controller: harness.controller),
                                       preferences: try makePreferences(.medium, showsFrequent: showsFrequent))
        controller.show()
        addTeardownBlock { controller.close() }
        try await SearchTestSupport.waitUntil {
            controller.state.selection.rows.filter { !$0.isFrequent }.count == titles.count
        }
        return (controller, harness, board)
    }

    /// Records `times` successful uses of the clip with this title in the harness's store, a second apart, the last a
    /// minute ago, as copies and pastes record them.
    private func recordUses(of title: String, times: Int, in harness: SearchHarness) async throws {
        let listed = try await ContentRepository(controller: harness.controller).recent(limit: 1000)
        let ref = try XCTUnwrap(listed.first { $0.title == title }?.history, "\(title) is not listed")
        let usage = LocalUsageStore(controller: harness.controller)
        let last = Date(timeIntervalSinceNow: -60)
        for secondsBefore in (0..<times).reversed() {
            try await usage.record(UseReceipt(ref: ref, occurredAt: last - TimeInterval(secondsBefore),
                                              outcome: .success))
        }
    }

    /// A left click at `point` in the window. Every press these tests send through a window goes through here, since a
    /// view may follow the button in a loop of its own until it comes up again, as a text view does on macOS 26: a press
    /// with no release would hold the test there for good. So the release is posted to the application's queue first,
    /// where such a loop finds it, and the press is sent after it. A release nothing took is dropped afterwards.
    /// A click at `point`, the `count`th of a series, as a second click of a double-click is.
    private func click(at point: NSPoint, in window: NSWindow, count: Int = 1) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: count, pressure: type == .leftMouseUp ? 0 : 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        window.sendEvent(try event(.leftMouseDown))
        NSApp.discardEvents(matching: .leftMouseUp, before: nil)
    }

    /// The app's environment over a fresh isolated test library, its monitor reading `clipboard` when given in place of
    /// the session's named pasteboard. It returns once the library is open and keeps new copies; the library goes when
    /// the test ends.
    private func makeCapturingEnvironment(clipboard: (any SnapshotReading)? = nil) async throws -> AppEnvironment {
        let configuration = CaptureTestConfiguration(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        defaults.removePersistentDomain(forName: configuration.preferencesSuite)
        let capture = CapturePreferences(defaults: defaults)
        let session = CaptureSession(preferences: capture, clipboardReader: clipboard)
        addTeardownBlock {
            await session.shutdown()
            UserDefaults(suiteName: configuration.preferencesSuite)?
                .removePersistentDomain(forName: configuration.preferencesSuite)
            try? FileManager.default.removeItem(at: configuration.directory)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }
        let environment = AppEnvironment(captureSession: session, quickAccessPreferences: try makePreferences(.medium))
        await session.initialize(testSessionID: configuration.id)
        XCTAssertTrue(session.isReady)
        XCTAssertNil(session.captureNotice)
        return environment
    }

    /// Settings of the panel's own, so its card size does not depend on this machine's. The frequent clips are off
    /// unless asked for, so that the band is as it was before they came, with no room below the cards for their icons.
    private func makePreferences(_ cardSize: CardSize, showsFrequent: Bool = false) throws -> QuickAccessPreferences {
        let suiteName = "AppLaunchTests.quickAccess.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = QuickAccessPreferences(defaults: defaults)
        preferences.cardSize = cardSize
        preferences.showsFrequentClips = showsFrequent
        return preferences
    }

    /// Where `StripLayout` puts the panel on `screen`: around the band alone, or around the band and the
    /// preview card above it.
    private func panelFrame(on screen: NSScreen, cardSize: CardSize, withPreview: Bool = false) -> NSRect {
        panelFrame(in: screen.visibleFrame, cardSize: cardSize, withPreview: withPreview)
    }

    private func panelFrame(in visible: NSRect, cardSize: CardSize, withPreview: Bool = false) -> NSRect {
        let metrics = StripLayout.metrics(for: cardSize, visibleWidth: visible.width)
        let band = StripLayout.bandFrame(metrics, in: visible)
        guard withPreview else { return StripLayout.panelFrame(band: band, preview: nil, in: visible) }
        let placed = StripLayout.previewLayout(band: band, in: visible)
        return StripLayout.panelFrame(band: placed.band, preview: placed.preview, in: visible)
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

    /// The frame sizes the panel takes for the screen it opens on: medium cards in a band as wide as the screen's
    /// visible area less its margins.
    private func stripMetrics(in window: NSWindow) throws -> StripMetrics {
        StripLayout.metrics(for: .medium,
                            visibleWidth: try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame.width)
    }

    /// The strip of the panel's window, once it shows the panel's clips: the panel follows the state a moment after
    /// the clips arrive.
    private func clipStrip(in window: NSWindow) async throws -> QuickAccessStripView {
        let strip = try XCTUnwrap(views(QuickAccessStripView.self, in: window.contentView).first)
        try await SearchTestSupport.waitUntil { !self.framesOnScreen(in: strip).isEmpty }
        return strip
    }

    /// The frames VoiceOver reads, left to right: the list's own children, or with a frequent wing the frames in its
    /// two groups, one after the other.
    private func framesOnScreen(in strip: QuickAccessStripView) -> [NSView] {
        (strip.accessibilityChildren() ?? []).flatMap { child -> [NSView] in
            if let frame = child as? NSView { return [frame] }
            return ((child as? NSAccessibilityElement)?.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        }
    }

    /// The groups VoiceOver reads a frequent wing's strip in, by name, each with its frames on screen left to right.
    /// Without a wing there are none, and the test fails.
    private func groups(in strip: QuickAccessStripView) throws -> [(name: String, frames: [NSView])] {
        try XCTUnwrap(strip.accessibilityChildren() as? [NSAccessibilityElement]).map {
            ($0.accessibilityLabel() ?? "", ($0.accessibilityChildren() ?? []).compactMap { $0 as? NSView })
        }
    }

    /// Waits until the strip shows the frequent wing beside the recent clips: both groups, with frames on screen.
    private func waitForWingFrames(in strip: QuickAccessStripView) async throws {
        try await SearchTestSupport.waitUntil {
            (strip.accessibilityChildren() as? [NSAccessibilityElement])?.map { $0.accessibilityLabel() }
                == ["Frequent", "Recent"]
        }
    }

    /// The view in the window with this accessibility identifier: the divider or a section icon.
    private func view(identifiedAs identifier: String, in window: NSWindow) throws -> NSView {
        try XCTUnwrap(views(NSView.self, in: window.contentView).first { $0.accessibilityIdentifier() == identifier },
                      identifier)
    }

    /// The band's toolbar, once the band has laid it out, with its ⋯ button in place at the right end.
    private func laidOutToolbar(in window: NSWindow) async throws -> QuickAccessToolbar {
        var toolbar: QuickAccessToolbar?
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            toolbar = self.views(QuickAccessToolbar.self, in: window.contentView).first
            return toolbar.map { $0.bounds.width > 0 && $0.moreButton.frame.width > 0 } ?? false
        }
        return try XCTUnwrap(toolbar)
    }

    /// Whether a frame with this title is on screen, without failing the test when there is none: for a wait.
    private func hasFrame(titled title: String, in strip: QuickAccessStripView) -> Bool {
        framesOnScreen(in: strip).contains { $0.accessibilityLabel()?.hasSuffix(": \(title)") == true }
    }

    /// Where the frame of the clip with this title is drawn, in the strip's coordinates. Only frames on screen,
    /// the ones VoiceOver reads, are looked at; of a clip shown in both wings, the leftmost.
    private func frame(of title: String, in strip: QuickAccessStripView) throws -> NSRect {
        let frames = framesOnScreen(in: strip)
        let frame = try XCTUnwrap(frames.first { Self.labels($0, title) }, title)
        return strip.convert(frame.bounds, from: frame)
    }

    /// Whether a frame's VoiceOver label names the clip `title`: the title ends the label, or its marks follow it, as
    /// "Saved as Snippet" does on a clip just saved.
    private static func labels(_ frame: NSView, _ title: String) -> Bool {
        guard let label = frame.accessibilityLabel() else { return false }
        return label.hasSuffix(": \(title)") || label.contains(": \(title), ")
    }

    /// The resting drawn face, including the host layer's centered scale but no running film spring.
    private func drawnFrame(of title: String, in strip: QuickAccessStripView) throws -> NSRect {
        let host = try XCTUnwrap(framesOnScreen(in: strip).first { Self.labels($0, title) })
        let scale = host.layer?.transform.m11 ?? 1
        return StripLayout.scaled(try frame(of: title, in: strip), by: scale)
    }

    /// Where the band is in the panel's window: as wide as the screen's visible area less the margins, and as tall
    /// as its card size makes it, with the room the panel gives its shadow below it.
    private func bandRect(in window: NSWindow) throws -> NSRect {
        let layout = try XCTUnwrap(window.contentView as? NSHostingView<QuickAccessBandView>).rootView.layout
        return NSRect(x: StripLayout.sideMargin, y: layout.roomBelow, width: layout.metrics.bandWidth,
                      height: StripLayout.bandHeight(layout.metrics))
    }

    /// Every element below `view` that VoiceOver could reach, SwiftUI's included, once `ready` finds what it needs.
    /// SwiftUI builds its elements only once an assistive client asks the app for anything, so the app's own
    /// accessibility element is asked for its role first. Where the test host may not use accessibility at all, the
    /// test is skipped.
    private func swiftUIAccessibilityElements(in view: NSView,
                                              until ready: ([NSObject]) -> Bool) throws -> [NSObject] {
        var role: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString,
                                                   &role)
        let deadline = Date(timeIntervalSinceNow: 5)
        var elements = accessibilityElements(below: view)
        while !ready(elements), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            elements = accessibilityElements(below: view)
        }
        if !ready(elements), status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        return elements
    }

    /// Chooses the list titled `title` in the Library's sidebar, as VoiceOver does: by selecting its row in the outline.
    private func selectLibraryList(_ title: String, in content: NSView) throws {
        let isSidebar = { (element: NSObject) in self.identifier(of: element) == "LibrarySidebar" }
        let sidebar = try XCTUnwrap(try swiftUIAccessibilityElements(in: content) { $0.contains(where: isSidebar) }
            .first(where: isSidebar))
        let rows = (accessibility(sidebar, "accessibilityRows") as? [Any] ?? []).compactMap { $0 as? NSObject }
        let row = try XCTUnwrap(rows.first { sidebarTexts(in: $0).contains(title) }, "No row titled \(title)")
        _ = sidebar.perform(NSSelectorFromString("setAccessibilitySelectedRows:"), with: [row])
    }

    /// What an element of the sidebar's outline says, and what its descendants say. A row and its cell give their
    /// children only through the older accessibility API, and the SwiftUI content of the cell only through the newer.
    private func sidebarTexts(in element: NSObject) -> [String] {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        let older = element.responds(to: selector)
            ? (element.perform(selector, with: "AXChildren")?.takeUnretainedValue() as? [Any] ?? []) : []
        let children = (older.isEmpty ? accessibility(element, "accessibilityChildren") as? [Any] ?? [] : older)
            .compactMap { $0 as? NSObject }
        return [text(of: element)].compactMap { $0 } + children.flatMap { sidebarTexts(in: $0) }
    }

    /// The elements below `element`, depth first.
    private func accessibilityElements(below element: NSObject) -> [NSObject] {
        let children = (accessibility(element, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
        return children.flatMap { [$0] + accessibilityElements(below: $0) }
    }

    /// An accessibility attribute of an element, asked for by its getter's name. SwiftUI's elements do not declare
    /// the accessibility protocol to Swift, and some of AppKit's answer only some of its getters.
    private func accessibility(_ element: NSObject, _ getter: String) -> Any? {
        let selector = NSSelectorFromString(getter)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    /// What an accessibility element says: its label, or its value where it has no label.
    private func text(of element: NSObject) -> String? {
        if let label = accessibility(element, "accessibilityLabel") as? String, !label.isEmpty { return label }
        return accessibility(element, "accessibilityValue") as? String
    }

    /// The key caps the panel shows, left to right.
    private func visibleKeycaps(in window: NSWindow) -> [QuickAccessKeycap] {
        views(QuickAccessKeycap.self, in: window.contentView)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
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

    /// ⇧⌘N New Collection…, ⇧⌘F Search Library…, ⇧⌘C Copy Entire Item, ⌃⌘S Show Sidebar and ⌃⌘I Show Inspector: the
    /// menu bar's library keys the panel has no command for.
    private func libraryOnlyKeys() throws -> [NSEvent] {
        [try key(kVK_ANSI_N, "N", modifiers: [.command, .shift]),
         try key(kVK_ANSI_F, "F", modifiers: [.command, .shift]),
         try key(kVK_ANSI_C, "C", modifiers: [.command, .shift]),
         try key(kVK_ANSI_S, "s", modifiers: [.control, .command]),
         try key(kVK_ANSI_I, "i", modifiers: [.control, .command])]
    }

    /// Skips a test whose keys must type, with ⌘, what their ANSI key codes name, as on the US and ABC layouts: the
    /// panel knows the menu bar's keys as the menu bar does, by what they type with ⌘ on this Mac's layout.
    private func requireANSICommandLayer() throws {
        let keys = [(kVK_ANSI_A, "a"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_F, "f"), (kVK_ANSI_I, "i"),
                    (kVK_ANSI_L, "l"), (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_Q, "q"), (kVK_ANSI_S, "s"),
                    (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"), (kVK_ANSI_Z, "z"), (kVK_ANSI_Comma, ","),
                    (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]")]
        for (code, character) in keys {
            let typed = try key(code, character, modifiers: .command).characters(byApplyingModifiers: .command)
            guard typed == character else {
                throw XCTSkip("This Mac's keyboard layout types “\(typed ?? "")” with ⌘ and the ANSI \(character) key")
            }
        }
    }

    /// Text in the panel that an input method composes in, standing in for the search field's editor, with the keys.
    private func composingText(in controller: PanelController) throws -> ComposingTextView {
        let window = try XCTUnwrap(controller.window)
        let text = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        try XCTUnwrap(window.contentView).addSubview(text)
        addTeardownBlock { text.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(text))
        return text
    }

    /// The items in `menu` and its submenus that have a key equivalent, in the menu's order.
    private func keyedItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            (item.keyEquivalent.isEmpty ? [] : [item]) + (item.submenu.map { keyedItems(in: $0) } ?? [])
        }
    }

    /// A menu item's key equivalent as the keyboard types it: Shift gives a letter in upper case, and the menu's
    /// backspace is the Delete key. A key missing here is a new one in the menu bar: decide what the panel does with
    /// it, in `PanelController`, before adding it.
    private func key(for item: NSMenuItem) throws -> NSEvent {
        let codes = [",": kVK_ANSI_Comma, "q": kVK_ANSI_Q, "n": kVK_ANSI_N, "s": kVK_ANSI_S, "z": kVK_ANSI_Z,
                     "x": kVK_ANSI_X, "c": kVK_ANSI_C, "v": kVK_ANSI_V, "a": kVK_ANSI_A, "f": kVK_ANSI_F,
                     "i": kVK_ANSI_I, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "l": kVK_ANSI_L,
                     "d": kVK_ANSI_D, "m": kVK_ANSI_M, "w": kVK_ANSI_W, "\u{8}": kVK_Delete]
        let code = try XCTUnwrap(codes[item.keyEquivalent], "No key for “\(item.title)”")
        let modifiers = item.keyEquivalentModifierMask
        let characters = item.keyEquivalent == "\u{8}" ? "\u{7F}"
            : modifiers.contains(.shift) ? item.keyEquivalent.uppercased() : item.keyEquivalent
        return try key(code, characters, modifiers: modifiers)
    }

    /// The key coming up.
    private func keyUp(_ code: Int, _ characters: String, windowNumber: Int = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
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

    /// The one colour the window draws all over `area` (window coordinates), in sRGB, or nil when the area holds more
    /// than one.
    private func color(in window: NSWindow, at area: NSRect, file: StaticString = #filePath,
                       line: UInt = #line) throws -> NSColor? {
        let spread = try contrast(in: window, at: area)
        guard spread < 2 / 255 else {
            XCTFail("\(area) holds more than one colour: they are \(spread) apart", file: file, line: line)
            return nil
        }
        let content = try XCTUnwrap(window.contentView)
        let rect = content.convert(area, from: nil)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: rect))
        content.cacheDisplay(in: rect, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
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
        // Snippets come only with the clips, in the same kind of session.
        func seedsSnippets(_ arguments: [String]) -> Bool {
            LaunchConfiguration(arguments: arguments, environment: [:]).shouldSeedSyntheticSnippets
        }
        XCTAssertTrue(seedsSnippets(["--ui-testing", "--capture-test-session", id, "--seed-synthetic-clips",
                                     "--seed-synthetic-snippets"]))
        XCTAssertFalse(seedsSnippets(["--ui-testing", "--capture-test-session", id, "--seed-synthetic-snippets"]))
        XCTAssertFalse(seedsSnippets(["--ui-testing", "--seed-synthetic-clips", "--seed-synthetic-snippets"]))
    }

    func testManualPasteQAStartsOnlyFromItsFlagOutsideTests() {
        func starts(_ arguments: [String], _ environment: [String: String] = [:]) -> Bool {
            LaunchConfiguration(arguments: arguments, environment: environment).shouldStartManualPasteQA
        }
        XCTAssertTrue(starts(["--manual-paste-qa"]))
        XCTAssertFalse(starts([]))
        XCTAssertFalse(starts(["--manual-paste-qa", "--ui-testing"]))
        let underXCTest = ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        XCTAssertFalse(starts(["--manual-paste-qa"], underXCTest))
    }

    func testWelcomeRoutingIsAutomaticOnlyForARealUserLaunch() {
        XCTAssertTrue(LaunchConfiguration(arguments: [], environment: [:]).shouldPresentOnboardingIfNeeded)
        XCTAssertFalse(LaunchConfiguration(arguments: ["--ui-testing"], environment: [:]).shouldPresentOnboardingIfNeeded)
        XCTAssertFalse(LaunchConfiguration(
            arguments: [],
            environment: ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        ).shouldPresentOnboardingIfNeeded)
        XCTAssertFalse(LaunchConfiguration(arguments: ["--manual-paste-qa"], environment: [:])
            .shouldPresentOnboardingIfNeeded)
    }

    func testOnlyARealLaunchOrAUITestSessionOpensALibraryThatRecords() {
        func initializes(_ arguments: [String], _ environment: [String: String] = [:]) -> Bool {
            LaunchConfiguration(arguments: arguments, environment: environment).shouldInitializeCaptureSession
        }
        let underXCTest = ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]

        // A real launch opens the user's library, which records the clipboard.
        XCTAssertTrue(initializes([]))
        // The app that hosts the unit tests never does, nor a UI test without a session of its own: the clipboard
        // there is the user's.
        XCTAssertFalse(initializes([], underXCTest))
        XCTAssertFalse(initializes(["--ui-testing"]))
        // A UI test session opens a library of its own, which records only the session's named clipboard.
        XCTAssertTrue(initializes(["--ui-testing", "--capture-test-session", UUID().uuidString]))
    }

    func testExplicitWelcomeRequiresAnIsolatedUITestSession() {
        let id = UUID().uuidString
        let isolatedArguments = ["--ui-testing", "--capture-test-session", id, "--show-onboarding"]

        XCTAssertTrue(LaunchConfiguration(arguments: isolatedArguments, environment: [:]).shouldForceOnboarding)
        XCTAssertFalse(LaunchConfiguration(
            arguments: ["--ui-testing", "--show-onboarding"],
            environment: [:]
        ).shouldForceOnboarding)
        XCTAssertFalse(LaunchConfiguration(
            arguments: ["--capture-test-session", id, "--show-onboarding"],
            environment: [:]
        ).shouldForceOnboarding)
    }

    func testSettingsLaunchFlagIsExplicit() {
        XCTAssertTrue(LaunchConfiguration(arguments: ["--show-settings"], environment: [:]).shouldShowSettings)
        XCTAssertFalse(LaunchConfiguration(arguments: [], environment: [:]).shouldShowSettings)
    }

    func testUITestWithoutCaptureSessionUsesEphemeralApplicationState() {
        XCTAssertTrue(LaunchConfiguration(arguments: ["--ui-testing"], environment: [:])
            .shouldUseEphemeralApplicationState)
        XCTAssertFalse(LaunchConfiguration(
            arguments: ["--ui-testing", "--capture-test-session", UUID().uuidString],
            environment: [:]
        ).shouldUseEphemeralApplicationState)
        XCTAssertFalse(LaunchConfiguration(arguments: [], environment: [:]).shouldUseEphemeralApplicationState)
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

    func testSyntheticShortcutPresetsUseDistinctNonUserChords() {
        let commandShift = UInt32(cmdKey | shiftKey)
        let commandOption = UInt32(cmdKey | optionKey)
        let commandControl = UInt32(cmdKey | controlKey)

        let syntheticShift = AppDelegate.syntheticModifiers(for: commandShift)
        let syntheticOption = AppDelegate.syntheticModifiers(for: commandOption)
        let syntheticControl = AppDelegate.syntheticModifiers(for: commandControl)

        XCTAssertEqual(syntheticShift, UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(Set([syntheticShift, syntheticOption, syntheticControl]).count, 3)
        XCTAssertNotEqual(syntheticOption, commandOption)
        XCTAssertNotEqual(syntheticControl, commandControl)
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
        // A layout that cannot resolve semantic V does not discard the last working registration.
        XCTAssertEqual(removed, 1)
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

/// A capture notice a test changes, which the panel follows as it follows the capture session's.
@MainActor @Observable
private final class CaptureNoticeSource {
    var notice: String?
}

@MainActor
private final class AppLaunchFakeLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus = .notRegistered
    private(set) var registerCalls = 0
    func register() async throws {
        registerCalls += 1
        status = .enabled
    }
    func unregister() async throws { status = .notRegistered }
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

/// Text an input method is composing in. It keeps the keys it is handed rather than acting on them.
@MainActor
private final class ComposingTextView: NSTextView {
    private(set) var keys: [NSEvent] = []

    override func hasMarkedText() -> Bool { true }

    override func keyDown(with event: NSEvent) { keys.append(event) }
}

// Exercise key-window notifications without taking focus from another application.
@MainActor
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// What a test sees of a menu it opened for real: the menu, and whether the app was active while it was open.
private final class MenuWatch: @unchecked Sendable {
    var menu: NSMenu?
    var wasActive: Bool?
    var frontmost: pid_t?
    var activations = 0
}
