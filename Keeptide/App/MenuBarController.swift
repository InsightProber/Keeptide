import AppKit
import Carbon

@MainActor
final class MenuBarController: NSObject {
    enum ShortcutStatus: Equatable {
        case disabledForTesting
        case available
        case unavailable
        case failed(OSStatus)
    }

    private static let hotKeySignature: OSType = 0x4B545044 // KTPD
    private static let hotKeyIdentifier: UInt32 = 1

    private let panelController: PanelController
    private let libraryWindowController: LibraryWindowController
    private let statusItem: NSStatusItem
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    private(set) var shortcutStatus: ShortcutStatus = .disabledForTesting

    init(
        panelController: PanelController,
        libraryWindowController: LibraryWindowController,
        shouldRegisterHotKey: Bool
    ) {
        self.panelController = panelController
        self.libraryWindowController = libraryWindowController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "Keeptide"
        )

        if shouldRegisterHotKey {
            registerHotKey()
        }
        rebuildMenu()
    }

    isolated deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func registerHotKey() {
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
                    controller.panelController.toggle()
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

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyIdentifier
        )
        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registeredHotKey
        )

        switch registrationStatus {
        case noErr:
            hotKey = registeredHotKey
            shortcutStatus = .available
        case OSStatus(eventHotKeyExistsErr):
            shortcutStatus = .unavailable
        default:
            shortcutStatus = .failed(registrationStatus)
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Quick Access", action: #selector(openQuickAccess), keyEquivalent: "")
        menu.addItem(withTitle: "Open Library", action: #selector(openLibrary), keyEquivalent: "")

        if shortcutStatus == .unavailable {
            let conflictItem = NSMenuItem(
                title: "Shift-Command-V is already in use",
                action: nil,
                keyEquivalent: ""
            )
            conflictItem.isEnabled = false
            menu.addItem(.separator())
            menu.addItem(conflictItem)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Keeptide", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func openQuickAccess() {
        panelController.show()
    }

    @objc private func openLibrary() {
        libraryWindowController.show()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
