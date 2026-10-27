import AppKit
import Carbon

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    enum ShortcutStatus: Equatable {
        case disabledForTesting
        case registered
        case unavailable
        case failed(OSStatus)

        var menuTitle: String? {
            switch self {
            case .registered:
                nil
            case .disabledForTesting:
                "Global shortcut disabled for this test run — open Quick Access here"
            case .unavailable:
                "Shift-Command-V is already in use — open Quick Access here"
            case let .failed(status):
                "Shift-Command-V is unavailable (error \(status)) — open Quick Access here"
            }
        }
    }

    struct ShortcutRegistration {
        var keyCode: () -> UInt32?
        var register: (UInt32, OptionBits, inout EventHotKeyRef?) -> OSStatus
        var unregister: (EventHotKeyRef) -> Void

        static func system(keyCode: @escaping () -> UInt32? = ShortcutKeyResolver.currentCommandV,
                           modifiers: UInt32 = UInt32(cmdKey | shiftKey)) -> Self {
            Self(keyCode: keyCode, register: { keyCode, options, reference in
                RegisterEventHotKey(keyCode, modifiers,
                                    EventHotKeyID(signature: hotKeySignature, id: hotKeyIdentifier),
                                    GetApplicationEventTarget(), options, &reference)
            }, unregister: { UnregisterEventHotKey($0) })
        }
    }

    nonisolated private static let hotKeySignature: OSType = 0x4B545044 // KTPD
    nonisolated private static let hotKeyIdentifier: UInt32 = 1

    private let showQuickAccess: () -> Void
    private let toggleQuickAccess: () -> Void
    private let showLibrary: () -> Void
    private let captureIsReady: () -> Bool
    private let captureIsEnabled: () -> Bool
    private let captureStatus: () -> String
    private let toggleCapture: () -> Void
    private let registration: ShortcutRegistration
    private let statusItem: NSStatusItem
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private weak var captureToggleItem: NSMenuItem?
    private weak var captureStatusItem: NSMenuItem?

    private(set) var shortcutStatus: ShortcutStatus = .disabledForTesting

    init(
        showQuickAccess: @escaping () -> Void,
        toggleQuickAccess: @escaping () -> Void,
        showLibrary: @escaping () -> Void,
        captureIsReady: @escaping () -> Bool = { true },
        captureIsEnabled: @escaping () -> Bool = { false },
        captureStatus: @escaping () -> String = { "Clipboard recording is off" },
        toggleCapture: @escaping () -> Void = {},
        shouldRegisterHotKey: Bool,
        registration: ShortcutRegistration = .system()
    ) {
        self.showQuickAccess = showQuickAccess
        self.toggleQuickAccess = toggleQuickAccess
        self.showLibrary = showLibrary
        self.captureIsReady = captureIsReady
        self.captureIsEnabled = captureIsEnabled
        self.captureStatus = captureStatus
        self.toggleCapture = toggleCapture
        self.registration = registration
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "Keeptide"
        )
        statusItem.button?.setAccessibilityLabel("Keeptide")

        if shouldRegisterHotKey {
            installHotKeyHandler()
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(inputSourceChanged),
                name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        rebuildMenu()
    }

    isolated deinit {
        if let hotKey {
            registration.unregister(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        DistributedNotificationCenter.default().removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr,
                      hotKeyID.signature == MenuBarController.hotKeySignature,
                      hotKeyID.id == MenuBarController.hotKeyIdentifier else {
                    return OSStatus(eventNotHandledErr)
                }

                let controller = Unmanaged<MenuBarController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    controller.toggleQuickAccess()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            shortcutStatus = .failed(handlerStatus)
            return
        }

        refreshHotKey()
    }

    @objc func inputSourceChanged() {
        refreshHotKey()
        rebuildMenu()
    }

    private func refreshHotKey() {
        guard eventHandler != nil else { return }
        if let hotKey {
            registration.unregister(hotKey)
            self.hotKey = nil
        }
        guard let keyCode = registration.keyCode() else {
            shortcutStatus = .failed(OSStatus(paramErr))
            return
        }
        var registeredHotKey: EventHotKeyRef?
        // Registration success does not prove a combination is unused by other apps.
        let registrationStatus = registration.register(keyCode, 0, &registeredHotKey)

        switch registrationStatus {
        case noErr:
            hotKey = registeredHotKey
            shortcutStatus = .registered
        case OSStatus(eventHotKeyExistsErr):
            shortcutStatus = .unavailable
        default:
            shortcutStatus = .failed(registrationStatus)
        }
    }

    var menu: NSMenu? { statusItem.menu }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "Open Quick Access", action: #selector(openQuickAccess), keyEquivalent: "")
        menu.addItem(withTitle: "Open Library", action: #selector(openLibrary), keyEquivalent: "")

        menu.addItem(.separator())
        let captureToggleItem = menu.addItem(
            withTitle: "Start Recording",
            action: #selector(toggleCaptureRecording),
            keyEquivalent: ""
        )
        captureToggleItem.identifier = NSUserInterfaceItemIdentifier("CaptureRecordingToggleMenuItem")
        self.captureToggleItem = captureToggleItem
        let captureStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        captureStatusItem.identifier = NSUserInterfaceItemIdentifier("CaptureStatusMenuItem")
        captureStatusItem.isEnabled = false
        menu.addItem(captureStatusItem)
        self.captureStatusItem = captureStatusItem

        if let shortcutMenuTitle = shortcutStatus.menuTitle {
            menu.addItem(.separator())
            let shortcutItem = NSMenuItem(
                title: shortcutMenuTitle,
                action: #selector(openQuickAccess),
                keyEquivalent: ""
            )
            shortcutItem.identifier = NSUserInterfaceItemIdentifier("ShortcutFallback")
            shortcutItem.setAccessibilityIdentifier("ShortcutFallback")
            shortcutItem.target = self
            menu.addItem(shortcutItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Keeptide", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
        updateCaptureMenuItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateCaptureMenuItems()
    }

    private func updateCaptureMenuItems() {
        captureToggleItem?.isEnabled = captureIsReady()
        let toggleTitle = captureIsEnabled() ? "Pause Recording" : "Start Recording"
        if captureToggleItem?.title != toggleTitle { captureToggleItem?.title = toggleTitle }
        let status = captureStatus()
        if captureStatusItem?.title != status { captureStatusItem?.title = status }
    }

    @objc private func openQuickAccess() {
        showQuickAccess()
    }

    @objc private func openLibrary() {
        showLibrary()
    }

    @objc private func toggleCaptureRecording() {
        guard captureIsReady() else { return }
        toggleCapture()
        updateCaptureMenuItems()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}


/// Carbon registration needs a virtual key before a keyboard event exists.
/// Resolve the Command layout (including Dvorak-QWERTY Command) without changing it.
enum ShortcutKeyResolver {
    static func currentCommandV() -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return commandV(in: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue())
    }

    static func commandV(in data: CFData) -> UInt32? {
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for keyCode in UInt16(0)...UInt16(127) {
            var state: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                                        UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask), &state,
                                        characters.count, &length, &characters)
            if status == noErr, String(utf16CodeUnits: characters, count: length).lowercased() == "v" {
                return UInt32(keyCode)
            }
        }
        return nil
    }
}
