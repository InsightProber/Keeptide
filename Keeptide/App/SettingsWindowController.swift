import AppKit
import SwiftUI

/// The Settings window. Keeptide is a menu bar app without a Dock icon, and a window of such an
/// accessory app does not come to the front or get a menu bar. So the app becomes a regular app
/// while Settings is open and goes back to accessory when it closes.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    var shouldRestoreAccessory: () -> Bool
    private let model: SettingsModel
    private let hosting: NSHostingController<SettingsView>
    private var isOpen = false

    init(
        model: SettingsModel,
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        shouldRestoreAccessory: @escaping () -> Bool = { true }
    ) {
        self.setActivationPolicy = setActivationPolicy
        self.shouldRestoreAccessory = shouldRestoreAccessory
        self.model = model
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        self.hosting = hosting
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Keeptide Settings"
        window.identifier = NSUserInterfaceItemIdentifier("KeeptideSettingsWindow")
        window.setAccessibilityIdentifier("KeeptideSettingsWindow")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 420)
        window.setContentSize(Self.fittedContentSize(for: hosting, in: window))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    convenience init(preferences: QuickAccessPreferences,
         lifecycle: LifecycleSettingsModel? = nil,
         setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
         shouldRestoreAccessory: @escaping () -> Bool = { true }) {
        self.init(
            model: SettingsModel.compatibility(quickAccess: preferences, lifecycle: lifecycle),
            setActivationPolicy: setActivationPolicy,
            shouldRestoreAccessory: shouldRestoreAccessory
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebinds the store-scoped lifecycle model when a library opens, closes, or is replaced.
    /// The window can be created before storage initialization; retaining the old model would let
    /// a later click target a closed store generation.
    func updateLifecycle(_ lifecycle: LifecycleSettingsModel?) {
        model.updateLifecycle(lifecycle)
        guard let window else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let current = window.contentLayoutRect.size
        let target = Self.fittedContentSize(for: hosting, in: window)
        guard abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1 else { return }
        window.setContentSize(target)
    }

    func show() {
        guard let window else { return }
        let isOpening = !isOpen
        if isOpening {
            isOpen = true
            setActivationPolicy(.regular)
            // Opened again while Keeptide is active, nothing else tells the AI page that anything changed.
            let ai = model.ai
            Task { await ai.refresh() }
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

    /// Reads Settings › AI again while the window shows, as when Keeptide becomes active coming back from System
    /// Settings; a closed window reads nothing, and reads it all as it opens again.
    func refreshIfOpen() {
        guard isOpen else { return }
        let ai = model.ai
        Task { await ai.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        if shouldRestoreAccessory() { setActivationPolicy(.accessory) }
    }

    private static func fittedContentSize(
        for hosting: NSHostingController<SettingsView>,
        in window: NSWindow
    ) -> NSSize {
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let visibleHeight = window.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 800
        return NSSize(width: 600, height: min(max(420, fitting.height), visibleHeight * 0.85))
    }
}
