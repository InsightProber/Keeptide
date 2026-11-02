import AppKit
import SwiftUI

/// The Settings window. Keeptide is a menu bar app without a Dock icon, and a window of such an
/// accessory app does not come to the front or get a menu bar. So the app becomes a regular app
/// while Settings is open and goes back to accessory when it closes.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let preferences: QuickAccessPreferences
    private let hosting: NSHostingController<SettingsView>
    private var lifecycle: LifecycleSettingsModel?
    private var isOpen = false

    init(preferences: QuickAccessPreferences,
         lifecycle: LifecycleSettingsModel? = nil,
         setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.setActivationPolicy = setActivationPolicy
        self.preferences = preferences
        self.lifecycle = lifecycle
        let hosting = NSHostingController(rootView: SettingsView(preferences: preferences, lifecycle: lifecycle))
        self.hosting = hosting
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

    /// Rebinds the store-scoped lifecycle model when a library opens, closes, or is replaced.
    /// The window can be created before storage initialization; retaining the old model would let
    /// a later click target a closed store generation.
    func updateLifecycle(_ lifecycle: LifecycleSettingsModel?) {
        guard !Self.sameIdentity(self.lifecycle, lifecycle) else { return }
        self.lifecycle = lifecycle
        hosting.rootView = SettingsView(preferences: preferences, lifecycle: lifecycle)
        guard let window else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let current = window.contentLayoutRect.size
        let visibleHeight = window.screen?.visibleFrame.height ?? fitting.height
        let target = NSSize(
            width: fitting.width,
            height: min(fitting.height, max(360, visibleHeight * 0.85))
        )
        guard abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1 else { return }
        window.setContentSize(target)
    }

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

    private static func sameIdentity(
        _ lhs: LifecycleSettingsModel?,
        _ rhs: LifecycleSettingsModel?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)): lhs === rhs
        default: false
        }
    }
}
