import AppKit
import ApplicationServices
import XCTest
@testable import Keeptide

@MainActor
final class OnboardingWindowTests: XCTestCase {
    func testDoneRunsOnlyItsInjectedActionOnce() throws {
        var dones = 0
        var libraries = 0
        let controller = makeController(done: { dones += 1 }, openLibrary: { libraries += 1 })
        let window = try XCTUnwrap(controller.window)
        controller.show()

        controller.finish(with: .done)
        _ = controller.windowShouldClose(window)

        XCTAssertEqual(dones, 1)
        XCTAssertEqual(libraries, 0)
    }

    func testClosingTheWindowMeansDoneExactlyOnce() throws {
        var dones = 0
        var libraries = 0
        let controller = makeController(done: { dones += 1 }, openLibrary: { libraries += 1 })
        let window = try XCTUnwrap(controller.window)
        controller.show()

        XCTAssertTrue(controller.windowShouldClose(window))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertTrue(controller.windowShouldClose(window))

        XCTAssertEqual(dones, 1)
        XCTAssertEqual(libraries, 0)
    }

    func testOpenLibraryIsAnIndependentExplicitChoice() throws {
        var dones = 0
        var libraries = 0
        let controller = makeController(done: { dones += 1 }, openLibrary: { libraries += 1 })
        let window = try XCTUnwrap(controller.window)
        controller.show()

        controller.finish(with: .openLibrary)
        _ = controller.windowShouldClose(window)

        XCTAssertEqual(libraries, 1)
        XCTAssertEqual(dones, 0)
    }

    func testTheWelcomeSaysKeeptideRecordsAndOffersOpenLibraryAndDone() throws {
        var dones = 0
        var libraries = 0
        let controller = makeController(done: { dones += 1 }, openLibrary: { libraries += 1 })
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { window.close() }
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let recording = "Keeptide saves what you copy. Pause or resume it anytime from the menu bar or Settings."
        let elements = try swiftUIAccessibilityElements(in: content) { elements in
            elements.contains { self.text(of: $0)?.contains(recording) == true }
        }
        let described = elements.map { "\(self.role(of: $0) ?? "?") \(self.text(of: $0) ?? "")" }

        // It says that Keeptide records already, and how to pause; nothing asks the user to start it.
        XCTAssertTrue(elements.contains { self.text(of: $0)?.contains(recording) == true }, "\(described)")
        XCTAssertFalse(elements.contains { self.text(of: $0)?.contains("Start Recording") == true }, "\(described)")
        // Its two buttons, in order: Open Library, then Done.
        let buttons = elements.filter { self.role(of: $0) == NSAccessibility.Role.button.rawValue }
        XCTAssertEqual(buttons.compactMap { self.text(of: $0) }, ["Open Library", "Done"], "\(described)")
        XCTAssertEqual(buttons.compactMap { self.accessibility($0, "accessibilityIdentifier") as? String },
                       ["OnboardingOpenLibrary", "OnboardingDone"])

        // Done is the default button: Return presses it.
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                                       isARepeat: false, keyCode: UInt16(36)))
        XCTAssertTrue(window.performKeyEquivalent(with: returnKey))
        XCTAssertEqual(dones, 1)
        XCTAssertEqual(libraries, 0)
    }

    func testEscapeIsDone() throws {
        var dones = 0
        var libraries = 0
        let controller = makeController(done: { dones += 1 }, openLibrary: { libraries += 1 })
        let window = try XCTUnwrap(controller.window)
        controller.show()
        addTeardownBlock { window.close() }

        // No button of the welcome takes Escape, so the key window sends cancelOperation up the responder chain from
        // whatever holds the keys, as it does for ⌘.: that is Done, and the welcome closes. The test host cannot make
        // the window key, so the test sends what the window would.
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                    isARepeat: false, keyCode: UInt16(53)))
        XCTAssertFalse(window.performKeyEquivalent(with: escape))
        let keys = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(keys.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))

        XCTAssertEqual(dones, 1)
        XCTAssertEqual(libraries, 0)
        XCTAssertFalse(window.isVisible)
    }

    func testClosingDoesNotHideTheDockWhenAnotherWindowStillNeedsIt() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = makeController(
            policies: { policies.append($0) },
            shouldRestoreAccessory: { false }
        )
        controller.show()
        controller.close()

        XCTAssertEqual(policies, [.regular])
    }

    func testLibraryParticipatesInTheRegularAccessoryWindowLifecycle() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = LibraryWindowController(
            session: CaptureSession(),
            autosaveName: nil,
            setActivationPolicy: { policies.append($0) }
        )
        let window = try XCTUnwrap(controller.window)

        controller.show()
        controller.show()
        window.close()

        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func testClosingThreeWindowsRestoresAccessoryOnlyAfterTheLastOne() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let policy: (NSApplication.ActivationPolicy) -> Void = { policies.append($0) }
        let settings = SettingsWindowController(
            preferences: QuickAccessPreferences(defaults: try makeDefaults()),
            setActivationPolicy: policy
        )
        let onboarding = makeController(policies: policy)
        let library = LibraryWindowController(
            session: CaptureSession(),
            autosaveName: nil,
            setActivationPolicy: policy
        )
        let settingsWindow = try XCTUnwrap(settings.window)
        let onboardingWindow = try XCTUnwrap(onboarding.window)
        let libraryWindow = try XCTUnwrap(library.window)
        settings.shouldRestoreAccessory = { !onboardingWindow.isVisible && !libraryWindow.isVisible }
        onboarding.shouldRestoreAccessory = { !settingsWindow.isVisible && !libraryWindow.isVisible }
        library.shouldRestoreAccessory = { !settingsWindow.isVisible && !onboardingWindow.isVisible }

        settings.show()
        onboarding.show()
        library.show()
        XCTAssertEqual(policies, [.regular, .regular, .regular])

        settingsWindow.close()
        XCTAssertEqual(policies, [.regular, .regular, .regular])
        onboardingWindow.close()
        XCTAssertEqual(policies, [.regular, .regular, .regular])
        libraryWindow.close()
        XCTAssertEqual(policies, [.regular, .regular, .regular, .accessory])
    }

    private func makeController(
        done: @escaping @MainActor () -> Void = {},
        openLibrary: @escaping @MainActor () -> Void = {},
        policies: @escaping (NSApplication.ActivationPolicy) -> Void = { _ in },
        shouldRestoreAccessory: @escaping () -> Bool = { true }
    ) -> OnboardingWindowController {
        OnboardingWindowController(
            actions: OnboardingActions(done: done, openLibrary: openLibrary),
            setActivationPolicy: policies,
            shouldRestoreAccessory: shouldRestoreAccessory
        )
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

    /// The elements below `element`, depth first.
    private func accessibilityElements(below element: NSObject) -> [NSObject] {
        let children = (accessibility(element, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
        return children.flatMap { [$0] + accessibilityElements(below: $0) }
    }

    /// An accessibility attribute of an element, asked for by its getter's name. SwiftUI's elements do not declare
    /// the accessibility protocol to Swift.
    private func accessibility(_ element: NSObject, _ getter: String) -> Any? {
        let selector = NSSelectorFromString(getter)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func role(of element: NSObject) -> String? {
        accessibility(element, "accessibilityRole") as? String
    }

    /// What an accessibility element says: its label, or its value where it has no label.
    private func text(of element: NSObject) -> String? {
        if let label = accessibility(element, "accessibilityLabel") as? String, !label.isEmpty { return label }
        return accessibility(element, "accessibilityValue") as? String
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "OnboardingWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
