import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let actions: OnboardingActions
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    var shouldRestoreAccessory: () -> Bool
    private var didFinish = false
    private var isOpen = false

    init(
        actions: OnboardingActions,
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) },
        shouldRestoreAccessory: @escaping () -> Bool = { true }
    ) {
        self.actions = actions
        self.setActivationPolicy = setActivationPolicy
        self.shouldRestoreAccessory = shouldRestoreAccessory
        let window = OnboardingWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.onCancel = { [weak self] in self?.finish(with: .done) }
        window.title = "Welcome to Keeptide"
        window.identifier = NSUserInterfaceItemIdentifier("KeeptideOnboardingWindow")
        window.setAccessibilityIdentifier("KeeptideOnboardingWindow")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(actions: .init(
            done: { [weak self] in self?.finish(with: .done) },
            openLibrary: { [weak self] in self?.finish(with: .openLibrary) }
        )))
        window.setContentSize(window.contentViewController?.view.fittingSize ?? NSSize(width: 560, height: 400))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        if !isOpen {
            isOpen = true
            didFinish = false
            setActivationPolicy(.regular)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing the window is Done.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        complete(.done)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        if shouldRestoreAccessory() { setActivationPolicy(.accessory) }
    }

    enum Completion { case done, openLibrary }

    func finish(with completion: Completion) {
        complete(completion)
        close()
    }

    private func complete(_ completion: Completion) {
        guard !didFinish else { return }
        didFinish = true
        switch completion {
        case .done: actions.done()
        case .openLibrary: actions.openLibrary()
        }
    }
}

/// The welcome's window, where Escape and ⌘. are Done, as its close button is. NSWindow takes them itself otherwise,
/// and they never reach the window's controller.
private final class OnboardingWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
