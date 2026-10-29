import AppKit
import SwiftUI

/// The Settings window. Keeptide is a menu bar app without a Dock icon, and a window of such an
/// accessory app does not come to the front or get a menu bar. So the app becomes a regular app
/// while Settings is open and goes back to accessory when it closes.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private var isOpen = false

    init(preferences: QuickAccessPreferences,
         setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.setActivationPolicy = setActivationPolicy
        let hosting = NSHostingController(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Keeptide Settings"
        window.identifier = NSUserInterfaceItemIdentifier("KeeptideSettingsWindow")
        window.setAccessibilityIdentifier("KeeptideSettingsWindow")
        window.isReleasedWhenClosed = false
        // The form scrolls and has no minimum height, so without a size of its own the window opens as
        // a bare title bar. Sizing it before centring keeps it centred.
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        let isOpening = !isOpen
        if isOpening {
            isOpen = true
            setActivationPolicy(.regular)
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        if isOpening {
            // SwiftUI makes its hosting view the initial first responder, which can leave the first
            // control focused when keyboard navigation is on. Tab still reaches the controls.
            window.initialFirstResponder = nil
            window.makeFirstResponder(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        setActivationPolicy(.accessory)
    }
}
