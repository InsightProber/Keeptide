import AppKit
import SwiftUI

/// AppKit owns window geometry and title; SwiftUI lays out only its content.
@MainActor
final class WindowContentController<Content: View>: NSViewController {
    init(rootView: Content, size: NSSize) {
        super.init(nibName: nil, bundle: nil)
        view = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
