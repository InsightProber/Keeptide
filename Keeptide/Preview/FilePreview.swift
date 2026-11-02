import AppKit
import QuickLookUI
import SwiftUI

struct FilePreview: NSViewRepresentable {
    let lease: FilePreviewAccessLease

    func makeNSView(context: Context) -> FilePreviewContainerView {
        let container = FilePreviewContainerView(frame: .zero)
        container.setLease(lease)
        return container
    }

    func updateNSView(_ container: FilePreviewContainerView, context: Context) {
        container.setLease(lease)
    }

    static func dismantleNSView(_ container: FilePreviewContainerView, coordinator: ()) {
        container.clearPreview()
    }
}

enum FilePreviewCleanup {
    static func run(
        clearPreviewItem: () -> Void,
        closePreview: () -> Void,
        removePreview: () -> Void,
        closeLease: () -> Void
    ) {
        clearPreviewItem()
        closePreview()
        removePreview()
        closeLease()
    }
}

final class FilePreviewContainerView: NSView {
    private var previewView: QLPreviewView?
    private var lease: FilePreviewAccessLease?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("File preview")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setLease(_ lease: FilePreviewAccessLease) {
        guard self.lease !== lease else { return }
        clearPreview()
        guard lease.url.isFileURL,
              let preview = QLPreviewView(frame: bounds, style: .normal) else {
            lease.close()
            return
        }

        preview.autoresizingMask = [.width, .height]
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        addSubview(preview)
        self.previewView = preview
        self.lease = lease
        preview.previewItem = lease.url as NSURL
    }

    func clearPreview() {
        guard previewView != nil || lease != nil else { return }
        let preview = previewView
        let retainedLease = lease
        previewView = nil
        lease = nil
        FilePreviewCleanup.run(
            clearPreviewItem: { preview?.previewItem = nil },
            closePreview: { preview?.close() },
            removePreview: { preview?.removeFromSuperview() },
            closeLease: { retainedLease?.close() }
        )
    }

    isolated deinit {
        clearPreview()
    }
}
