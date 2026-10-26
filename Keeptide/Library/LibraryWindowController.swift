import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    private static let defaultSize = NSSize(width: 1120, height: 740)
    private static let minimumSize = NSSize(width: 840, height: 560)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Keeptide Library"
        window.identifier = NSUserInterfaceItemIdentifier("KeeptideLibraryWindow")
        window.setAccessibilityIdentifier("KeeptideLibraryWindow")
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.setFrameAutosaveName("KeeptideLibraryWindow")
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: LibraryView())
        window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("Close Library")
        window.center()
        self.init(window: window)
    }

    func show() {
        guard let window else { return }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
