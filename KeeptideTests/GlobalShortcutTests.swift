import Carbon
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class GlobalShortcutTests: XCTestCase {
    func testPreferencesDefaultAndCorruptFallbackDoNotRewriteStorage() {
        let defaults = makeDefaults()
        let fresh = GlobalShortcutPreferences(defaults: defaults)
        XCTAssertEqual(fresh.selection, .commandShiftV)
        XCTAssertNil(defaults.object(forKey: GlobalShortcutPreferences.selectionKey))

        defaults.set("future-value", forKey: GlobalShortcutPreferences.selectionKey)
        let corrupt = GlobalShortcutPreferences(defaults: defaults)
        XCTAssertEqual(corrupt.selection, .commandShiftV)
        XCTAssertEqual(defaults.string(forKey: GlobalShortcutPreferences.selectionKey), "future-value")
    }

    func testPresetSymbolsAndModifiersAreFixed() {
        XCTAssertEqual(QuickAccessShortcut.commandShiftV.displayName, "⇧⌘V")
        XCTAssertEqual(QuickAccessShortcut.commandOptionV.displayName, "⌥⌘V")
        XCTAssertEqual(QuickAccessShortcut.commandControlV.displayName, "⌃⌘V")
        XCTAssertEqual(QuickAccessShortcut.disabled.displayName, "Off")
        XCTAssertEqual(QuickAccessShortcut.commandShiftV.carbonModifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(QuickAccessShortcut.commandOptionV.carbonModifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(QuickAccessShortcut.commandControlV.carbonModifiers, UInt32(cmdKey | controlKey))
        XCTAssertNil(QuickAccessShortcut.disabled.carbonModifiers)
    }

    func testDisabledPreferenceDoesNotInstallOrRegisterShortcut() {
        let defaults = makeDefaults()
        defaults.set(QuickAccessShortcut.disabled.rawValue, forKey: GlobalShortcutPreferences.selectionKey)
        let preferences = GlobalShortcutPreferences(defaults: defaults)
        let platform = ShortcutPlatformFake()

        let coordinator = GlobalShortcutCoordinator(
            preferences: preferences,
            shouldInstallHandler: true,
            registration: platform.registration
        )

        XCTAssertEqual(coordinator.selection, .disabled)
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertEqual(platform.registered, [])
    }

    func testApplyingPresetRegistersNewBeforeUnregisteringOldAndThenPersists() {
        let defaults = makeDefaults()
        let preferences = GlobalShortcutPreferences(defaults: defaults)
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)
        XCTAssertEqual(platform.events, ["register:9:\(UInt32(cmdKey | shiftKey))"])

        XCTAssertTrue(coordinator.apply(.commandOptionV))

        XCTAssertEqual(
            platform.events,
            [
                "register:9:\(UInt32(cmdKey | shiftKey))",
                "register:9:\(UInt32(cmdKey | optionKey))",
                "unregister:1",
            ]
        )
        XCTAssertEqual(preferences.selection, .commandOptionV)
        XCTAssertEqual(defaults.string(forKey: GlobalShortcutPreferences.selectionKey), "commandOptionV")
        XCTAssertEqual(coordinator.status, .registered(.commandOptionV))
    }

    func testRegistrationConflictKeepsOldHandleAndPreference() {
        let defaults = makeDefaults()
        let preferences = GlobalShortcutPreferences(defaults: defaults)
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)
        platform.nextRegistrationStatus = OSStatus(eventHotKeyExistsErr)

        XCTAssertFalse(coordinator.apply(.commandControlV))

        XCTAssertEqual(preferences.selection, .commandShiftV)
        XCTAssertNil(defaults.object(forKey: GlobalShortcutPreferences.selectionKey))
        XCTAssertEqual(coordinator.status, .unavailable(.commandControlV))
        XCTAssertFalse(platform.events.contains("unregister:1"))
    }

    func testArbitraryRegistrationFailureKeepsOldHandleAndPreference() {
        let preferences = GlobalShortcutPreferences(defaults: makeDefaults())
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)
        platform.nextRegistrationStatus = OSStatus(-9876)

        XCTAssertFalse(coordinator.apply(.commandOptionV))

        XCTAssertEqual(preferences.selection, .commandShiftV)
        XCTAssertEqual(coordinator.status, .failed(.commandOptionV, OSStatus(-9876)))
        XCTAssertFalse(platform.events.contains("unregister:1"))
    }

    func testInputSourceRebindRegistersReplacementBeforeRemovingOld() {
        let preferences = GlobalShortcutPreferences(defaults: makeDefaults())
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)
        platform.keyCode = 47

        coordinator.inputSourceChanged()

        XCTAssertEqual(
            platform.events,
            [
                "register:9:\(UInt32(cmdKey | shiftKey))",
                "register:47:\(UInt32(cmdKey | shiftKey))",
                "unregister:1",
            ]
        )
        XCTAssertEqual(coordinator.status, .registered(.commandShiftV))
    }

    func testInputSourceNotificationWithUnchangedBindingDoesNotRegisterAgainstItself() {
        let preferences = GlobalShortcutPreferences(defaults: makeDefaults())
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)

        coordinator.inputSourceChanged()

        XCTAssertEqual(platform.events, ["register:9:\(UInt32(cmdKey | shiftKey))"])
        XCTAssertEqual(coordinator.status, .registered(.commandShiftV))
        XCTAssertEqual(platform.registered.count, 1)
    }

    func testInputSourceResolutionFailureKeepsOldRegistrationAndShowsFallbackStatus() {
        let preferences = GlobalShortcutPreferences(defaults: makeDefaults())
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)
        platform.keyCode = nil

        coordinator.inputSourceChanged()

        XCTAssertEqual(platform.events, ["register:9:\(UInt32(cmdKey | shiftKey))"])
        XCTAssertEqual(coordinator.status, .unavailable(.commandShiftV))
        XCTAssertEqual(preferences.selection, .commandShiftV)
    }

    func testDisablingUnregistersActiveHandleAndPersistsOff() {
        let defaults = makeDefaults()
        let preferences = GlobalShortcutPreferences(defaults: defaults)
        let platform = ShortcutPlatformFake()
        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)

        XCTAssertTrue(coordinator.apply(.disabled))

        XCTAssertEqual(platform.events.last, "unregister:1")
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertEqual(preferences.selection, .disabled)
        XCTAssertEqual(defaults.string(forKey: GlobalShortcutPreferences.selectionKey), "disabled")
    }

    func testHandlerFailureDoesNotAttemptHotKeyRegistration() {
        let preferences = GlobalShortcutPreferences(defaults: makeDefaults())
        let platform = ShortcutPlatformFake()
        platform.handlerStatus = OSStatus(-1234)

        let coordinator = GlobalShortcutCoordinator(preferences: preferences, registration: platform.registration)

        XCTAssertEqual(coordinator.status, .failed(.commandShiftV, OSStatus(-1234)))
        XCTAssertEqual(platform.registered, [])
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "GlobalShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

@MainActor
final class ShortcutPlatformFake {
    var keyCode: UInt32? = 9
    var nextRegistrationStatus: OSStatus = noErr
    var handlerStatus: OSStatus = noErr
    private(set) var events: [String] = []
    private(set) var registered: [EventHotKeyRef] = []
    private var nextHandle = 1

    lazy var registration = GlobalShortcutRegistration(
        resolveSemanticV: { [weak self] in self?.keyCode },
        register: { [weak self] keyCode, modifiers, options, reference in
            guard let self else { return OSStatus(paramErr) }
            XCTAssertEqual(options, 0)
            self.events.append("register:\(keyCode):\(modifiers)")
            let status = self.nextRegistrationStatus
            self.nextRegistrationStatus = noErr
            guard status == noErr else { return status }
            let handle = EventHotKeyRef(bitPattern: self.nextHandle)!
            self.nextHandle += 1
            self.registered.append(handle)
            reference = handle
            return noErr
        },
        unregister: { [weak self] reference in
            guard let self else { return }
            self.events.append("unregister:\(Int(bitPattern: reference))")
            self.registered.removeAll { $0 == reference }
        },
        installHandler: { [weak self] _, reference in
            guard let self else { return OSStatus(paramErr) }
            guard self.handlerStatus == noErr else { return self.handlerStatus }
            reference = EventHandlerRef(bitPattern: 100)
            return noErr
        },
        removeHandler: { _ in }
    )
}
