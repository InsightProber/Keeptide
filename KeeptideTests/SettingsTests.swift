import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsAreNineAndTicksOn() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())

        XCTAssertEqual(preferences.density, .nine)
        XCTAssertTrue(preferences.trackpadTicks)
    }

    func testInvalidStoredDensityReadsAsNine() throws {
        let defaults = try makeDefaults()
        defaults.set(8, forKey: QuickAccessPreferences.densityKey)

        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).density, .nine)
    }

    func testChangesPersistImmediately() throws {
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)

        preferences.density = .eleven
        preferences.trackpadTicks = false

        // The stored names and types are what an update must keep reading.
        XCTAssertEqual(defaults.object(forKey: "quickAccessClipsPerRow") as? Int, 11)
        XCTAssertEqual(defaults.object(forKey: "quickAccessTrackpadTicks") as? Bool, false)
        let reopened = QuickAccessPreferences(defaults: defaults)
        XCTAssertEqual(reopened.density, .eleven)
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

    /// The real activation policy stays untouched: the controller reports it through `onPolicy`.
    private func makeController(onPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ in }) throws
        -> SettingsWindowController {
        SettingsWindowController(preferences: QuickAccessPreferences(defaults: try makeDefaults()),
                                 setActivationPolicy: onPolicy)
    }

    private func settleLayout() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    }

    /// Each test reads and writes its own suite, removed when the test ends.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
