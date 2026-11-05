import AppKit
import Carbon

enum DirectPasteKeystroke {
    /// One ⌘V down and up, and the source that holds back local keys while they are posted. Builds, never posts.
    static func make(keyCode: CGKeyCode) -> (source: CGEventSource, down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return nil }
        // Keys typed during the suppression interval after each post are held back; mouse and
        // system-defined events still pass.
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                          state: .eventSuppressionStateSuppressionInterval)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return nil }
        // Exactly ⌘, whatever modifiers the user is holding.
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (source, down, up)
    }
}

/// Whether Keeptide can paste directly, as Settings and the panel say it.
enum DirectPasteAccessState: Equatable, Sendable {
    /// This run of Keeptide may send ⌘V.
    case on
    /// Keeptide is allowed in Accessibility, or this run asked for access, but this run still cannot send ⌘V: the
    /// system lets Keeptide use a grant once it reopens.
    case awaitsReopen
    case off

    init(canPostEvents: Bool, isTrusted: Bool, accessRequested: Bool) {
        if canPostEvents {
            self = .on
        } else {
            self = isTrusted || accessRequested ? .awaitsReopen : .off
        }
    }
}

/// Everything direct paste asks of the system. Tests inject a fake or `unavailable`.
@MainActor
struct DirectPasteSystem {
    var frontmostTarget: () -> PasteTarget?
    var canPostEvents: () -> Bool
    /// Whether Keeptide is allowed in Accessibility now. Unlike `canPostEvents`, the system answers it afresh, so it
    /// can tell that a grant made while Keeptide runs waits for a reopen. It never decides whether to paste.
    var isAccessibilityTrusted: () -> Bool
    var requestPostEventAccess: () -> Bool
    var openAccessibilitySettings: () -> Void
    var isSecureInputEnabled: () -> Bool
    var commandVKeyCode: () -> CGKeyCode?
    var postCommandV: (CGKeyCode) -> Bool

    static var live: DirectPasteSystem {
        DirectPasteSystem(
            frontmostTarget: {
                let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
                guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownProcessIdentifier
                else { return nil }
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                         kCGNullWindowID) as? [[String: Any]] ?? []
                guard let window = PasteTarget.targetWindow(in: windows, frontProcessIdentifier: app.processIdentifier,
                                                            ownProcessIdentifier: ownProcessIdentifier)
                else { return nil }
                return PasteTarget(processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                                   name: PasteTarget.name(localizedName: app.localizedName,
                                                          bundleIdentifier: app.bundleIdentifier),
                                   windowNumber: window)
            },
            // Preflight answers for this process: after the user grants access, posting works at
            // once, but preflight stays false until Keeptide relaunches.
            canPostEvents: { CGPreflightPostEventAccess() },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            requestPostEventAccess: { CGRequestPostEventAccess() },
            openAccessibilitySettings: {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                else { return }
                NSWorkspace.shared.open(url)
            },
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            // currentCommandV() calls TIS input-source APIs, which need the main thread; @MainActor guarantees it.
            commandVKeyCode: { ShortcutKeyResolver.currentCommandV().flatMap { CGKeyCode(exactly: $0) } },
            postCommandV: { keyCode in
                guard let keystroke = DirectPasteKeystroke.make(keyCode: keyCode) else { return false }
                withExtendedLifetime(keystroke.source) {
                    keystroke.down.post(tap: .cgSessionEventTap)
                    keystroke.up.post(tap: .cgSessionEventTap)
                }
                return true
            })
    }

    static var unavailable: DirectPasteSystem {
        DirectPasteSystem(frontmostTarget: { nil }, canPostEvents: { false }, isAccessibilityTrusted: { false },
                          requestPostEventAccess: { false },
                          openAccessibilitySettings: {}, isSecureInputEnabled: { false }, commandVKeyCode: { nil },
                          postCommandV: { _ in false })
    }
}
