import AppKit
import SwiftUI

/// The expanded preview of the selected row. Text is selectable and scrolls, an image is
/// shown whole, and other kinds show what is known without pretending to render them.
struct QuickAccessPreviewView: View {
    let preview: PreviewContent?
    let applicationName: String?
    /// Keys pressed in the preview's text that act on the panel: Space and Escape close it, Return copies.
    var onCommand: (QuickAccessCommand) -> Void = { _ in }

    var body: some View {
        Group {
            switch preview {
            case nil:
                ProgressView().controlSize(.small)
            case .text(let text, let isTruncated)?:
                VStack(spacing: 0) {
                    PreviewText(text: text, onCommand: onCommand)
                    if isTruncated {
                        Text("Preview shows the first 256 KB.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            case .image(let image, let pixelSize)?:
                // The picture's own shape comes from its header; ImageIO rounds the decoded size.
                Image(image, scale: 1, label: Text(imageLabel))
                    .resizable()
                    .aspectRatio(pixelSize.width > 0 && pixelSize.height > 0 ? pixelSize.width / pixelSize.height : nil,
                                 contentMode: .fit)
                    .padding()
            case .info(let kind, _)?:
                VStack(spacing: 8) {
                    Image(systemName: kind.symbolName).font(.largeTitle).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(kind.accessibilityName).font(.headline)
                    if let applicationName { Text(applicationName).foregroundStyle(.secondary) }
                    Text("Preview for this type isn't available yet.").foregroundStyle(.secondary)
                }
                .padding()
            case .failed(let refusal)?:
                Text(refusal.message).foregroundStyle(.secondary).padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("QuickAccessPreview")
    }

    /// "Image, from <App>", or "Image" when the source app is not known.
    private var imageLabel: String {
        [ContentKind.image.accessibilityName, applicationName.map { "from \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Read-only, selectable text that keeps its line breaks and indentation.
private struct PreviewText: NSViewRepresentable {
    let text: String
    let onCommand: (QuickAccessCommand) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let textView = PreviewTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Preview text")
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PreviewTextView else { return }
        textView.onCommand = onCommand
        guard textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

/// The preview's text takes the keys once it is clicked. Space and Escape close the preview, Return copies
/// and Tab moves on, as they do anywhere in the panel; the arrows and the rest stay with the text.
private final class PreviewTextView: NSTextView {
    var onCommand: (QuickAccessCommand) -> Void = { _ in }

    override func keyDown(with event: NSEvent) {
        let key = QuickAccessStripView.key(for: event)
        // A held Space, Return or Escape has acted already.
        guard !(event.isARepeat && key.actsOnceWhenHeld) else { return }
        // What these keys do in the preview does not depend on the query or on the filter row.
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: event.modifierFlags.contains(.shift), focus: .preview,
            eventBeganWithMarkedText: hasMarkedText(), queryIsEmpty: true, filtersVisible: false
        ))
        guard command != .passThrough else { return super.keyDown(with: event) }
        onCommand(command)
    }

    /// Escape leaves the preview through the panel's layers instead of text completion.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }
}
