import Carbon
import Foundation
import Observation

enum GlobalShortcutStatus: Equatable, Sendable {
    case disabled
    case registered(QuickAccessShortcut)
    case unavailable(QuickAccessShortcut)
    case failed(QuickAccessShortcut, OSStatus)
}

struct GlobalShortcutRegistration {
    var resolveSemanticV: () -> UInt32?
    var register: (UInt32, UInt32, OptionBits, inout EventHotKeyRef?) -> OSStatus
    var unregister: (EventHotKeyRef) -> Void
    var installHandler: (UnsafeMutableRawPointer, inout EventHandlerRef?) -> OSStatus
    var removeHandler: (EventHandlerRef) -> Void

    static func system(resolveSemanticV: @escaping () -> UInt32? = ShortcutKeyResolver.currentCommandV) -> Self {
        Self(
            resolveSemanticV: resolveSemanticV,
            register: { keyCode, modifiers, options, reference in
                RegisterEventHotKey(
                    keyCode,
                    modifiers,
                    EventHotKeyID(
                        signature: GlobalShortcutCoordinator.hotKeySignature,
                        id: GlobalShortcutCoordinator.hotKeyIdentifier
                    ),
                    GetApplicationEventTarget(),
                    options,
                    &reference
                )
            },
            unregister: { UnregisterEventHotKey($0) },
            installHandler: { userData, reference in
                var eventType = EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)
                )
                return InstallEventHandler(
                    GetApplicationEventTarget(),
                    { _, event, userData in
                        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                        var hotKeyID = EventHotKeyID()
                        let status = GetEventParameter(
                            event,
                            EventParamName(kEventParamDirectObject),
                            EventParamType(typeEventHotKeyID),
                            nil,
                            MemoryLayout<EventHotKeyID>.size,
                            nil,
                            &hotKeyID
                        )
                        guard status == noErr,
                              hotKeyID.signature == GlobalShortcutCoordinator.hotKeySignature,
                              hotKeyID.id == GlobalShortcutCoordinator.hotKeyIdentifier else {
                            return OSStatus(eventNotHandledErr)
                        }
                        let coordinator = Unmanaged<GlobalShortcutCoordinator>
                            .fromOpaque(userData)
                            .takeUnretainedValue()
                        MainActor.assumeIsolated { coordinator.invokeActiveShortcut() }
                        return noErr
                    },
                    1,
                    &eventType,
                    userData,
                    &reference
                )
            },
            removeHandler: { RemoveEventHandler($0) }
        )
    }
}

@MainActor @Observable
final class GlobalShortcutCoordinator: NSObject {
    private struct ActiveBinding: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    nonisolated static let hotKeySignature: OSType = 0x4B545044 // KTPD
    nonisolated static let hotKeyIdentifier: UInt32 = 1

    let preferences: GlobalShortcutPreferences
    @ObservationIgnored private let registration: GlobalShortcutRegistration
    @ObservationIgnored private let shouldInstallHandler: Bool
    @ObservationIgnored private var activeHotKey: EventHotKeyRef?
    @ObservationIgnored private var activeBinding: ActiveBinding?
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    @ObservationIgnored var onInvoke: (@MainActor () -> Void)?
    @ObservationIgnored var onStatusChange: (@MainActor (GlobalShortcutStatus) -> Void)?

    private(set) var status: GlobalShortcutStatus = .disabled {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }

    var selection: QuickAccessShortcut { preferences.selection }

    init(
        preferences: GlobalShortcutPreferences,
        shouldInstallHandler: Bool = true,
        registration: GlobalShortcutRegistration = .system()
    ) {
        self.preferences = preferences
        self.registration = registration
        self.shouldInstallHandler = shouldInstallHandler
        super.init()

        if shouldInstallHandler {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(inputSourceNotification),
                name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        guard preferences.selection != .disabled else {
            status = .disabled
            return
        }
        guard ensureHandler(for: preferences.selection) else { return }
        _ = bind(preferences.selection, persistSelection: false)
    }

    isolated deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        if let activeHotKey { registration.unregister(activeHotKey) }
        if let eventHandler { registration.removeHandler(eventHandler) }
    }

    @discardableResult
    func apply(_ proposed: QuickAccessShortcut) -> Bool {
        if proposed == .disabled {
            if let activeHotKey {
                registration.unregister(activeHotKey)
                self.activeHotKey = nil
                activeBinding = nil
            }
            preferences.store(.disabled)
            status = .disabled
            return true
        }
        guard ensureHandler(for: proposed) else { return false }
        return bind(proposed, persistSelection: true)
    }

    func inputSourceChanged() {
        let selected = preferences.selection
        guard selected != .disabled, eventHandler != nil else { return }
        _ = bind(selected, persistSelection: false)
    }

    @objc private func inputSourceNotification() {
        inputSourceChanged()
    }

    fileprivate func invokeActiveShortcut() {
        guard activeHotKey != nil else { return }
        onInvoke?()
    }

    private func ensureHandler(for shortcut: QuickAccessShortcut) -> Bool {
        guard shouldInstallHandler else {
            status = .failed(shortcut, OSStatus(eventNotHandledErr))
            return false
        }
        guard eventHandler == nil else { return true }
        var handler: EventHandlerRef?
        let result = registration.installHandler(Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr, let handler else {
            status = .failed(shortcut, result == noErr ? OSStatus(paramErr) : result)
            return false
        }
        eventHandler = handler
        return true
    }

    private func bind(_ shortcut: QuickAccessShortcut, persistSelection: Bool) -> Bool {
        guard let modifiers = shortcut.carbonModifiers,
              let keyCode = registration.resolveSemanticV() else {
            status = .unavailable(shortcut)
            return false
        }

        let proposedBinding = ActiveBinding(keyCode: keyCode, modifiers: modifiers)
        if activeHotKey != nil, activeBinding == proposedBinding {
            if persistSelection { preferences.store(shortcut) }
            status = .registered(shortcut)
            return true
        }

        var replacement: EventHotKeyRef?
        // Carbon success establishes this registration only; it does not prove that every app will yield the chord.
        let result = registration.register(keyCode, modifiers, 0, &replacement)
        guard result == noErr, let replacement else {
            status = result == OSStatus(eventHotKeyExistsErr)
                ? .unavailable(shortcut)
                : .failed(shortcut, result == noErr ? OSStatus(paramErr) : result)
            return false
        }

        let previous = activeHotKey
        activeHotKey = replacement
        activeBinding = proposedBinding
        if let previous { registration.unregister(previous) }
        if persistSelection { preferences.store(shortcut) }
        status = .registered(shortcut)
        return true
    }
}
