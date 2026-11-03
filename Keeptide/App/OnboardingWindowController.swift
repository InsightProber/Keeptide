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
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Welcome to Keeptide"
        window.identifier = NSUserInterfaceItemIdentifier("KeeptideOnboardingWindow")
        window.setAccessibilityIdentifier("KeeptideOnboardingWindow")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(actions: .init(
            startRecording: { [weak self] in self?.finish(with: .startRecording) },
            notNow: { [weak self] in self?.finish(with: .notNow) },
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        complete(.notNow)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        if shouldRestoreAccessory() { setActivationPolicy(.accessory) }
    }

    enum Completion { case startRecording, notNow, openLibrary }

    func finish(with completion: Completion) {
        complete(completion)
        close()
    }

    private func complete(_ completion: Completion) {
        guard !didFinish else { return }
        didFinish = true
        switch completion {
        case .startRecording: actions.startRecording()
        case .notNow: actions.notNow()
        case .openLibrary: actions.openLibrary()
        }
    }
}
