import AppKit
import SwiftUI

@MainActor
final class PanelController: NSWindowController, NSWindowDelegate {
    private static let defaultSize = NSSize(width: 680, height: 496)
    private let searchField = QuickAccessSearchField()
    private lazy var fieldEditor: QuickAccessFieldEditor = {
        let editor = QuickAccessFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()
    private(set) var isSessionOpen = false

    init() {
        let panel = QuickAccessPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init(window: panel)
        panel.title = "Keeptide Quick Access"
        panel.identifier = NSUserInterfaceItemIdentifier("KeeptideQuickAccessPanel")
        panel.setAccessibilityIdentifier("KeeptideQuickAccessPanel")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = WindowContentController(
            rootView: QuickAccessView(searchField: searchField), size: Self.defaultSize
        )
        panel.setContentSize(Self.defaultSize)
        panel.contentMinSize = NSSize(width: 520, height: 360)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        if !isSessionOpen {
            searchField.stringValue = ""
            // Resolve the working screen before this panel takes keyboard focus.
            let screen = NSScreen.main
                ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.screens.first
            if let screen {
                window.setFrame(Self.frame(for: window.frame.size, in: screen.visibleFrame), display: false)
            }
            isSessionOpen = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    override func close() {
        guard isSessionOpen else { return }
        isSessionOpen = false
        window?.makeFirstResponder(nil)
        window?.orderOut(nil)
    }

    func toggle() { isSessionOpen ? close() : show() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? QuickAccessSearchField) === searchField ? fieldEditor : nil
    }

    static func frame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let size = NSSize(width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
        return NSRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
