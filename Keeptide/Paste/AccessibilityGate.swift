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

/// Everything direct paste asks of the system. Tests inject a fake or `unavailable`.
@MainActor
struct DirectPasteSystem {
    var frontmostTarget: () -> PasteTarget?
    var canPostEvents: () -> Bool
    var requestPostEventAccess: () -> Bool
    var openAccessibilitySettings: () -> Void
    var isSecureInputEnabled: () -> Bool
    var commandVKeyCode: () -> CGKeyCode?
    var postCommandV: (CGKeyCode) -> Bool

    static var live: DirectPasteSystem {
        DirectPasteSystem(
            frontmostTarget: {
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                         kCGNullWindowID) as? [[String: Any]] ?? []
                guard let window = PasteTarget.frontmostWindow(in: windows, processIdentifier: app.processIdentifier)
                else { return nil }
                return PasteTarget(processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
                                   name: app.localizedName ?? app.bundleIdentifier ?? "App", windowNumber: window)
            },
            // Preflight answers for this process: after the user grants access, posting works at
            // once, but preflight stays false until Keeptide relaunches.
            canPostEvents: { CGPreflightPostEventAccess() },
            requestPostEventAccess: { CGRequestPostEventAccess() },
            openAccessibilitySettings: {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                else { return }
                NSWorkspace.shared.open(url)
            },
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
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
        DirectPasteSystem(frontmostTarget: { nil }, canPostEvents: { false }, requestPostEventAccess: { false },
                          openAccessibilitySettings: {}, isSecureInputEnabled: { false }, commandVKeyCode: { nil },
                          postCommandV: { _ in false })
    }
}
