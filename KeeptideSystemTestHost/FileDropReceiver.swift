import AppKit
import SwiftUI

struct FileDropReceiver: NSViewRepresentable {
    let onReceive: ([URL]) -> Void

    func makeNSView(context: Context) -> DropView {
        DropView(onReceive: onReceive)
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.onReceive = onReceive
    }
}

final class DropView: NSView {
    var onReceive: ([URL]) -> Void

    init(onReceive: @escaping ([URL]) -> Void) {
        self.onReceive = onReceive
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]) ?? []
        onReceive(urls)
        return !urls.isEmpty
    }
}
