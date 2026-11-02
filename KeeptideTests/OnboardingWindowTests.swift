import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class OnboardingWindowTests: XCTestCase {
    func testStartRecordingRunsOnlyItsInjectedActionOnce() throws {
        var starts = 0
        var skips = 0
        let controller = makeController(
            start: { starts += 1 },
            notNow: { skips += 1 }
        )
        let window = try XCTUnwrap(controller.window)
        controller.show()

        controller.finish(with: .startRecording)
        _ = controller.windowShouldClose(window)

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(skips, 0)
    }

    func testClosingTheWindowMeansNotNowExactlyOnce() throws {
        var skips = 0
        let controller = makeController(notNow: { skips += 1 })
        let window = try XCTUnwrap(controller.window)
        controller.show()

        XCTAssertTrue(controller.windowShouldClose(window))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertTrue(controller.windowShouldClose(window))

        XCTAssertEqual(skips, 1)
    }

    func testOpenLibraryIsAnIndependentExplicitChoice() throws {
        var libraries = 0
        let controller = makeController(openLibrary: { libraries += 1 })
        controller.show()

        controller.finish(with: .openLibrary)

        XCTAssertEqual(libraries, 1)
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
        start: @escaping @MainActor () -> Void = {},
        notNow: @escaping @MainActor () -> Void = {},
        openLibrary: @escaping @MainActor () -> Void = {},
        policies: @escaping (NSApplication.ActivationPolicy) -> Void = { _ in },
        shouldRestoreAccessory: @escaping () -> Bool = { true }
    ) -> OnboardingWindowController {
        OnboardingWindowController(
            actions: OnboardingActions(startRecording: start, notNow: notNow, openLibrary: openLibrary),
            setActivationPolicy: policies,
            shouldRestoreAccessory: shouldRestoreAccessory
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "OnboardingWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
