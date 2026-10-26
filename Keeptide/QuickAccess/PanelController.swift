import AppKit
import SwiftUI

@MainActor
final class PanelController: NSWindowController, NSWindowDelegate {
    private static let defaultSize = NSSize(width: 680, height: 496)

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Keeptide Quick Access"
        panel.identifier = NSUserInterfaceItemIdentifier("KeeptideQuickAccessPanel")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 520, height: 360)
        panel.contentViewController = NSHostingController(rootView: QuickAccessView())
        panel.center()
        self.init(window: panel)
        panel.delegate = self
    }

    func show() {
        guard let window else { return }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    override func close() {
        window?.orderOut(nil)
    }

    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}
