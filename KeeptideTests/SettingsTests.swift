import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Keeptide

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsAreMediumAndTicksOn() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())

        XCTAssertEqual(preferences.cardSize, .medium)
        XCTAssertTrue(preferences.trackpadTicks)
    }

    func testStoredClipsInARowBecomeACardSize() throws {
        // Where no card size is stored, the old clips-in-a-row choice stands in for it: 7 gave the largest
        // previews and 11 the smallest; any other value, and none, give the default.
        let cases: [(stored: Int?, size: CardSize)] = [
            (7, .large), (9, .medium), (11, .small), (5, .medium), (nil, .medium),
        ]
        for (stored, size) in cases {
            let defaults = try makeDefaults()
            if let stored { defaults.set(stored, forKey: "quickAccessClipsPerRow") }

            XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, size, "\(String(describing: stored))")
            // The old key stays where it is; reading it changes nothing.
            XCTAssertEqual(defaults.object(forKey: "quickAccessClipsPerRow") as? Int, stored)
            XCTAssertNil(defaults.object(forKey: "quickAccess.cardSize"))
        }

        // A stored card size wins over the old key, and is taken as it is: one that is not a card size reads as
        // the default instead of looking at the old key.
        let defaults = try makeDefaults()
        defaults.set(7, forKey: "quickAccessClipsPerRow")
        defaults.set("small", forKey: "quickAccess.cardSize")
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .small)
        defaults.set("huge", forKey: "quickAccess.cardSize")
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .medium)
    }

    func testSettingsOffersThreeCardSizes() throws {
        // The radio group lists the sizes in this order, by these names; Medium is the one chosen to begin with.
        XCTAssertEqual(CardSize.allCases.map(\.title), ["Small", "Medium", "Large"])
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)
        XCTAssertEqual(preferences.cardSize, .medium)

        // Choosing Large stores it as "large", and the next launch reads it back.
        preferences.cardSize = .large

        XCTAssertEqual(defaults.object(forKey: "quickAccess.cardSize") as? String, "large")
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .large)
    }

    func testAStoredCardSizeThatIsNotTextReadsAsMedium() throws {
        // A number, a flag, data or a list under the card size key is not a card size. It reads as the default, and
        // the old clips-in-a-row key is not consulted in its place, even where it would give another size.
        let stored: [Any] = [11, true, 2.5, Data("large".utf8), ["large"]]
        for value in stored {
            let defaults = try makeDefaults()
            defaults.set(7, forKey: "quickAccessClipsPerRow")
            defaults.set(value, forKey: "quickAccess.cardSize")

            XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .medium, "\(value)")
        }
    }

    func testTheCardSizeChoiceReadsAsThreeRadioButtons() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let hosting = NSHostingView(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI builds what VoiceOver reads only once an assistive client asks the app for anything; asking the
        // app's own accessibility element for its role is enough. A host that may not use accessibility at all
        // cannot run this test.
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        func radioButtons() -> [NSObject] {
            accessibilityElements(in: hosting).first { role(of: $0) == .radioGroup }
                .map { accessibilityElements(in: $0).filter { role(of: $0) == .radioButton } } ?? []
        }
        func chosen() -> [Int?] {
            radioButtons().map { ($0.value(forKey: "accessibilityValue") as? NSNumber)?.intValue }
        }
        let built = waitUntil { radioButtons().count == 3 }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }

        XCTAssertEqual(radioButtons().map { label(of: $0) }, ["Small", "Medium", "Large"])
        XCTAssertEqual(chosen(), [0, 1, 0], "Medium is the one chosen")

        // The group follows the preference: once Large is chosen, Large reads as the chosen one.
        preferences.cardSize = .large
        XCTAssertTrue(waitUntil { chosen() == [0, 0, 1] }, "\(chosen())")
    }

    func testChangesPersistImmediately() throws {
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)

        preferences.cardSize = .small
        preferences.trackpadTicks = false

        // The stored names and types are what an update must keep reading.
        XCTAssertEqual(defaults.object(forKey: "quickAccess.cardSize") as? String, "small")
        XCTAssertEqual(defaults.object(forKey: "quickAccessTrackpadTicks") as? Bool, false)
        let reopened = QuickAccessPreferences(defaults: defaults)
        XCTAssertEqual(reopened.cardSize, .small)
        XCTAssertFalse(reopened.trackpadTicks)
    }

    func testSettingsWindowIsReusedAndRestoresTheAccessoryPolicy() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = try makeController(onPolicy: { policies.append($0) })
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        controller.show()

        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(window.title, "Keeptide Settings")
        let shown = NSApplication.shared.windows.filter { $0.identifier == window.identifier && $0.isVisible }
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(policies, [.regular])

        window.close()

        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func testSettingsWindowCanBeOpenedAgainAfterItIsClosed() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = try makeController(onPolicy: { policies.append($0) })
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        window.close()
        controller.show()

        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
    }

    func testSettingsWindowIs520PointsWideAndFitsItsForm() throws {
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        settleLayout()

        let content = window.contentRect(forFrameRect: window.frame)
        let form = try XCTUnwrap(window.contentView).fittingSize
        XCTAssertEqual(content.width, 520)
        // A form that took no height of its own would leave a bare title bar.
        XCTAssertGreaterThan(form.height, 150)
        XCTAssertEqual(content.height, form.height, accuracy: 1)
    }

    func testSettingsWindowOpensWithoutFocusingAControl() throws {
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        settleLayout()

        // SwiftUI makes its hosting view the initial first responder, which hands the first
        // control the focus under full keyboard access.
        XCTAssertNil(window.initialFirstResponder)
        XCTAssertTrue(window.firstResponder === window)
    }

    func testEnvironmentCreatesTheSettingsWindowOnFirstUseAndReusesIt() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        var created = 0
        let environment = AppEnvironment(quickAccessPreferences: preferences, makeSettings: {
            created += 1
            return SettingsWindowController(preferences: preferences, setActivationPolicy: { _ in })
        })
        XCTAssertEqual(created, 0)

        XCTAssertTrue(environment.settingsWindowController === environment.settingsWindowController)

        XCTAssertEqual(created, 1)
    }

    func testDockClickWhileSettingsIsOpenLeavesTheLibraryClosed() throws {
        var libraries = 0
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let environment = AppEnvironment(quickAccessPreferences: preferences, makeLibrary: {
            libraries += 1
            return LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        })
        let delegate = AppDelegate()
        delegate.environment = environment

        // With a window on screen, such as Settings, Keeptide comes forward as it is; the Library is not made.
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(libraries, 0)
    }

    /// The real activation policy stays untouched: the controller reports it through `onPolicy`.
    private func makeController(onPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ in }) throws
        -> SettingsWindowController {
        SettingsWindowController(preferences: QuickAccessPreferences(defaults: try makeDefaults()),
                                 setActivationPolicy: onPolicy)
    }

    private func settleLayout() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    }

    /// Runs the main run loop in short turns until `condition` holds or five seconds have passed, and says which.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return true
    }

    /// Every element below `element` that VoiceOver could reach, depth first. SwiftUI's elements do not declare the
    /// accessibility protocol to Swift, so their children are asked for by name.
    private func accessibilityElements(in element: NSObject) -> [NSObject] {
        let children = (element.value(forKey: "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
        return children.flatMap { [$0] + accessibilityElements(in: $0) }
    }

    private func role(of element: NSObject) -> NSAccessibility.Role? {
        (element.value(forKey: "accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
    }

    private func label(of element: NSObject) -> String? {
        element.value(forKey: "accessibilityLabel") as? String
    }

    /// Each test reads and writes its own suite, removed when the test ends.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
