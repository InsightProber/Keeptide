import AppKit

/// A brief, non-activating confirmation shown where the panel was. It never takes
/// keyboard focus or clicks, and VoiceOver announces the same text.
@MainActor
final class CopyToastController {
    private let duration: Duration
    private var panel: ToastPanel?
    private var hiding: Task<Void, Never>?
    private(set) var isVisible = false

    var window: NSWindow? { panel }

    init(duration: Duration = .milliseconds(1_200)) {
        self.duration = duration
    }

    func show(_ message: String, centeredOn frame: NSRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.label.stringValue = message
        panel.setAccessibilityLabel(message)
        let size = panel.contentView?.fittingSize ?? NSSize(width: 260, height: 44)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        isVisible = true
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        hiding?.cancel()
        hiding = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func makePanel() -> ToastPanel {
        let panel = ToastPanel()
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        panel.label.font = .preferredFont(forTextStyle: .body)
        panel.label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(panel.label)
        NSLayoutConstraint.activate([
            panel.label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            panel.label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            panel.label.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            panel.label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])
        panel.contentView = background
        return panel
    }
}

private final class ToastPanel: NSPanel {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        ignoresMouseEvents = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        setAccessibilityIdentifier("CopyToast")
        label.setAccessibilityIdentifier("CopyToastMessage")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
