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
    private let showSettings: () -> Void
    private let showWelcome: () -> Void
    private let captureIsReady: () -> Bool
    private let captureIsEnabled: () -> Bool
    private let captureStatus: () -> String
    private let toggleCapture: () -> Void
    private let canRequestQuit: () -> Bool
    private let requestQuit: () -> Void
    private let statusItem: NSStatusItem
    private var shortcutCoordinator: GlobalShortcutCoordinator?
    private var fallbackPreferencesSuiteName: String?
    private weak var captureToggleItem: NSMenuItem?
    private weak var captureStatusItem: NSMenuItem?
    private weak var quitItem: NSMenuItem?
    private var isQuitPending = false

    private(set) var shortcutStatus: ShortcutStatus = .disabledForTesting

    init(
        showQuickAccess: @escaping () -> Void,
        toggleQuickAccess: @escaping () -> Void,
        showLibrary: @escaping () -> Void,
        showSettings: @escaping () -> Void = {},
        showWelcome: @escaping () -> Void = {},
        captureIsReady: @escaping () -> Bool = { true },
        captureIsEnabled: @escaping () -> Bool = { false },
        captureStatus: @escaping () -> String = { "Clipboard recording is off" },
        toggleCapture: @escaping () -> Void = {},
        canRequestQuit: @escaping () -> Bool = { true },
        requestQuit: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
        shouldRegisterHotKey: Bool,
        registration: ShortcutRegistration? = nil,
        shortcutCoordinator: GlobalShortcutCoordinator? = nil
    ) {
        self.showQuickAccess = showQuickAccess
        self.toggleQuickAccess = toggleQuickAccess
        self.showLibrary = showLibrary
        self.showSettings = showSettings
        self.showWelcome = showWelcome
        self.captureIsReady = captureIsReady
        self.captureIsEnabled = captureIsEnabled
        self.captureStatus = captureStatus
        self.toggleCapture = toggleCapture
        self.canRequestQuit = canRequestQuit
        self.requestQuit = requestQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(named: "KeeptideStatusTemplate")?.copy() as? NSImage {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
            button.imagePosition = .imageOnly
            button.toolTip = "Keeptide"
            button.setAccessibilityLabel("Keeptide")
        }

        if shouldRegisterHotKey {
            let coordinator: GlobalShortcutCoordinator
            if let shortcutCoordinator {
                coordinator = shortcutCoordinator
            } else {
                let suiteName = "Keeptide.MenuBarFallback.\(UUID().uuidString)"
                fallbackPreferencesSuiteName = suiteName
                coordinator = GlobalShortcutCoordinator(
                    preferences: GlobalShortcutPreferences(defaults: UserDefaults(suiteName: suiteName)!),
                    registration: registration.map(Self.globalRegistration) ?? .system()
                )
            }
            self.shortcutCoordinator = coordinator
            coordinator.onInvoke = { [weak self] in self?.toggleQuickAccess() }
            coordinator.onStatusChange = { [weak self] status in
                guard let self else { return }
                self.shortcutStatus = Self.legacyStatus(status)
                self.rebuildMenu()
            }
            self.shortcutStatus = Self.legacyStatus(coordinator.status)
        }
        rebuildMenu()
    }

    isolated deinit {
        shortcutCoordinator?.onStatusChange = nil
        shortcutCoordinator?.onInvoke = nil
        if let fallbackPreferencesSuiteName {
            UserDefaults(suiteName: fallbackPreferencesSuiteName)?
                .removePersistentDomain(forName: fallbackPreferencesSuiteName)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc func inputSourceChanged() {
        shortcutCoordinator?.inputSourceChanged()
        if let shortcutCoordinator {
            shortcutStatus = Self.legacyStatus(shortcutCoordinator.status)
        }
        rebuildMenu()
    }

    var menu: NSMenu? { statusItem.menu }
    var statusButton: NSStatusBarButton? { statusItem.button }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "Open Quick Access", action: #selector(openQuickAccess), keyEquivalent: "")
        menu.addItem(withTitle: "Open Library", action: #selector(openLibrary), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Show Welcome", action: #selector(openWelcome), keyEquivalent: "")

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

        let cloudItem = NSMenuItem(title: "iCloud: Not available in this build", action: nil, keyEquivalent: "")
        cloudItem.isEnabled = false
        menu.addItem(cloudItem)

        if let shortcutMenuTitle {
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
        let quitItem = menu.addItem(withTitle: "Quit Keeptide", action: #selector(quit), keyEquivalent: "q")
        quitItem.identifier = NSUserInterfaceItemIdentifier("QuitKeeptide")
        self.quitItem = quitItem
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
        updateCaptureMenuItems()
        updateQuitMenuItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateCaptureMenuItems()
        updateQuitMenuItem()
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

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func openWelcome() {
        showWelcome()
    }

    @objc private func toggleCaptureRecording() {
        guard captureIsReady() else { return }
        toggleCapture()
        updateCaptureMenuItems()
    }

    @objc private func quit() {
        guard !isQuitPending, canRequestQuit() else {
            updateQuitMenuItem()
            return
        }
        isQuitPending = true
        updateQuitMenuItem()
        requestQuit()
    }

    private func updateQuitMenuItem() {
        quitItem?.isEnabled = !isQuitPending && canRequestQuit()
    }

    private var shortcutMenuTitle: String? {
        guard let shortcutCoordinator else { return shortcutStatus.menuTitle }
        return switch shortcutCoordinator.status {
        case .disabled, .registered:
            nil
        case .unavailable(let shortcut):
            "\(shortcut.displayName) is already in use — open Quick Access here"
        case .failed(let shortcut, let status):
            "\(shortcut.displayName) is unavailable (error \(status)) — open Quick Access here"
        }
    }

    private static func globalRegistration(_ legacy: ShortcutRegistration) -> GlobalShortcutRegistration {
        var registration = GlobalShortcutRegistration.system(resolveSemanticV: legacy.keyCode)
        registration.register = { keyCode, _, options, reference in
            legacy.register(keyCode, options, &reference)
        }
        registration.unregister = legacy.unregister
        return registration
    }

    private static func legacyStatus(_ status: GlobalShortcutStatus) -> ShortcutStatus {
        switch status {
        case .disabled: .disabledForTesting
        case .registered: .registered
        case .unavailable: .unavailable
        case .failed(_, let error): .failed(error)
        }
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
