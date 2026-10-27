import AppKit
import SwiftUI

@main
enum KeeptideSystemTestHostApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = SystemTestHostDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class SystemTestHostDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keeptide System Test Host"
        window.contentViewController = NSHostingController(rootView: SystemTestHostView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        self.window = window
    }
}
