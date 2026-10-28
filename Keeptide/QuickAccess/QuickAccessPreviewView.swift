import AppKit
import SwiftUI

/// The expanded preview of the selected row. Text is selectable and scrolls, an image is
/// shown whole, and other kinds show what is known without pretending to render them.
struct QuickAccessPreviewView: View {
    let preview: PreviewContent?
    let applicationName: String?

    var body: some View {
        Group {
            switch preview {
            case nil:
                ProgressView().controlSize(.small)
            case .text(let text, let isTruncated)?:
                VStack(spacing: 0) {
                    PreviewText(text: text)
                    if isTruncated {
                        Text("Preview shows the first 256 KB.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            case .image(let image, _)?:
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding()
            case .info(let kind, _)?:
                VStack(spacing: 8) {
                    Image(systemName: kind.symbolName).font(.largeTitle).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(kind.filterTitle).font(.headline)
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
}

/// Read-only, selectable text that keeps its line breaks and indentation.
private struct PreviewText: NSViewRepresentable {
    let text: String

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
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

/// Escape leaves the preview through the panel's layers instead of text completion.
private final class PreviewTextView: NSTextView {
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }
}
