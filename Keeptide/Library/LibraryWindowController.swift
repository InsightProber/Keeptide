import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    private static let defaultSize = NSSize(width: 1120, height: 740)
    private static let minimumSize = NSSize(width: 840, height: 560)

    init(session: CaptureSession, autosaveName: String? = "KeeptideLibraryWindow") {
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
        window.toolbarStyle = .unified
        window.contentViewController = WindowContentController(rootView: LibraryView(session: session), size: Self.defaultSize)
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = Self.minimumSize
        window.standardWindowButton(.closeButton)?.setAccessibilityIdentifier("Close Library")
        window.center()
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
