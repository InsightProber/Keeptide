import AppKit
import Carbon
import XCTest
@testable import Keeptide

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testLegacySyntheticRegistrationInitializerRemainsSourceCompatible() {
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: {},
            shouldRegisterHotKey: true,
            registration: .init(
                keyCode: { nil },
                register: { _, _, _ in OSStatus(eventHotKeyExistsErr) },
                unregister: { _ in }
            )
        )

        XCTAssertEqual(controller.shortcutStatus, .unavailable)
    }

    func testRegisteredShortcutDoesNotAddFallbackMenuItem() {
        let preferences = GlobalShortcutPreferences(defaults: isolatedDefaults())
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)
        let controller = makeController(shortcutCoordinator: coordinator)

        XCTAssertEqual(coordinator.status, .registered(.commandShiftV))
        XCTAssertNil(controller.menu?.items.first { $0.identifier?.rawValue == "ShortcutFallback" })
    }

    func testShortcutConflictAddsActionableFallbackAndAlternateSuccessRemovesIt() throws {
        var opens = 0
        let preferences = GlobalShortcutPreferences(defaults: isolatedDefaults())
        let platform = ShortcutPlatformFake()
        platform.nextRegistrationStatus = OSStatus(eventHotKeyExistsErr)
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)
        let controller = MenuBarController(
            showQuickAccess: { opens += 1 },
            toggleQuickAccess: {},
            showLibrary: {},
            shouldRegisterHotKey: true,
            shortcutCoordinator: coordinator
        )

        let fallback = try XCTUnwrap(
            controller.menu?.items.first { $0.identifier?.rawValue == "ShortcutFallback" }
        )
        XCTAssertTrue(fallback.title.contains("⇧⌘V"))
        XCTAssertTrue(fallback.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(fallback.action), to: fallback.target, from: fallback))
        XCTAssertEqual(opens, 1)

        XCTAssertTrue(coordinator.apply(.commandOptionV))
        XCTAssertNil(controller.menu?.items.first { $0.identifier?.rawValue == "ShortcutFallback" })
    }

    func testTheRecordingSwitchPausesOrResumes() throws {
        var recording = true
        let controller = MenuBarController(showQuickAccess: {}, toggleQuickAccess: {}, showLibrary: {},
                                           captureIsEnabled: { recording }, shouldRegisterHotKey: false)
        let menu = try XCTUnwrap(controller.menu)
        func switchTitle() throws -> String {
            controller.menuWillOpen(menu)
            return try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "CaptureRecordingToggleMenuItem" }).title
        }

        // Recording, as it is from first launch, the switch pauses it.
        XCTAssertEqual(try switchTitle(), "Pause Recording")
        // Paused or stopped, it resumes what was recording; there is nothing to start.
        recording = false
        XCTAssertEqual(try switchTitle(), "Resume Recording")
    }

    func testQuitMenuRequestsTerminationOnlyOnceWhileShutdownIsPending() throws {
        var requestCount = 0
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: {},
            canRequestQuit: { true },
            requestQuit: { requestCount += 1 },
            shouldRegisterHotKey: false
        )
        let item = try XCTUnwrap(controller.menu?.item(withTitle: "Quit Keeptide"))
        let action = try XCTUnwrap(item.action)

        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(item.isEnabled)
    }

    func testQuitMenuAndHandlerHonorAnExistingApplicationShutdown() throws {
        var requestCount = 0
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: {},
            canRequestQuit: { false },
            requestQuit: { requestCount += 1 },
            shouldRegisterHotKey: false
        )
        let menu = try XCTUnwrap(controller.menu)
        controller.menuWillOpen(menu)
        let item = try XCTUnwrap(menu.item(withTitle: "Quit Keeptide"))
        let action = try XCTUnwrap(item.action)

        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(requestCount, 0)
    }

    func testSettingsItemUsesCommandCommaAndOpensSettings() throws {
        var settingsOpened = 0
        var libraryOpened = 0
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: { libraryOpened += 1 },
            showSettings: { settingsOpened += 1 },
            shouldRegisterHotKey: false
        )
        let item = try XCTUnwrap(controller.menu?.item(withTitle: "Settings…"))
        let action = try XCTUnwrap(item.action)

        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))

        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(libraryOpened, 0)
    }

    func testMenuOffersWelcomeAndTruthfulDisabledICloudStatus() throws {
        var welcomeShows = 0
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: {},
            showWelcome: { welcomeShows += 1 },
            shouldRegisterHotKey: false
        )
        let menu = try XCTUnwrap(controller.menu)
        let welcome = try XCTUnwrap(menu.item(withTitle: "Show Welcome"))
        let cloud = try XCTUnwrap(menu.item(withTitle: "iCloud: Not available in this build"))

        XCTAssertTrue(welcome.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(welcome.action), to: welcome.target, from: welcome
        ))
        XCTAssertEqual(welcomeShows, 1)
        XCTAssertFalse(cloud.isEnabled)
        XCTAssertNil(cloud.action)
    }

    private func makeController(shortcutCoordinator: GlobalShortcutCoordinator) -> MenuBarController {
        MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: {},
            shouldRegisterHotKey: true,
            shortcutCoordinator: shortcutCoordinator
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MenuBarControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
