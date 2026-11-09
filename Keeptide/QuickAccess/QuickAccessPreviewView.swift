import AppKit
import SwiftUI

/// The expanded preview of the selected row. Text is selectable and scrolls, an image is
/// shown whole, and other kinds show what is known without pretending to render them.
struct QuickAccessPreviewView: View {
    let preview: PreviewContent?
    let applicationName: String?
    /// Keys pressed in the preview's text that act on the panel: Space and Escape close it, Return copies, and
    /// typing goes to the search field.
    var onCommand: (QuickAccessCommand) -> Void = { _ in }
    var fileAccessStore: FileAccessStore? = nil
    var fileAccessIdentity: StoreIdentity? = nil
    var isLoadingOriginal = false
    var previewMessage: String? = nil
    var onRequestOriginal: (() -> Void)? = nil
    /// Whether the preview lies straight on quick access's tray, with no background of its own, and its scrollers
    /// stop short of the tray's round corners. In the Library it lies on a text background.
    var isOnTray = false

    var body: some View {
        Group {
            switch preview {
            case nil:
                ProgressView().controlSize(.small)
            case .text(let text, let isTruncated)?:
                VStack(spacing: 0) {
                    PreviewText(text: text, scrollerBottomInset: scrollerBottomInset, onCommand: onCommand)
                    if isTruncated {
                        Text("Preview shows the first 256 KB.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
            case .image(let image, let pixelSize)?:
                VStack(spacing: 8) {
                    ImagePreview(image: image, pixelSize: pixelSize, accessibilityLabel: imageLabel,
                                 isLoadingOriginal: isLoadingOriginal, onRequestOriginal: onRequestOriginal)
                    if let previewMessage {
                        Text(verbatim: previewMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            case .markdown(let document, let isTruncated)?:
                VStack(spacing: 0) {
                    ScrollView { MarkdownPreviewView(document: document).padding(16) }
                        .contentMargins(.bottom, scrollerBottomInset, for: .scrollIndicators)
                    if isTruncated {
                        Text("Preview shows the first 256 KB.")
                            .font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                }
            case .url(let title, let address)?:
                if let url = URL(string: address) {
                    URLPreview(title: title, url: url) { NSWorkspace.shared.open($0) }
                        .padding(16)
                } else {
                    PreviewText(text: address, scrollerBottomInset: scrollerBottomInset, onCommand: onCommand)
                }
            case .files(let references)?:
                FilePreviewPane(references: references, store: fileAccessStore, identity: fileAccessIdentity)
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
        .background(Color(nsColor: .textBackgroundColor).opacity(isOnTray ? 0 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("QuickAccessPreview")
    }

    /// On the tray, a scroller ends this far above the card's bottom edge, clear of most of its round corner.
    private var scrollerBottomInset: CGFloat { isOnTray ? StripLayout.cornerRadius / 2 : 0 }

    /// "Image, from <App>", or "Image" when the source app is not known.
    private var imageLabel: String {
        [ContentKind.image.accessibilityName, applicationName.map { "from \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Read-only, selectable text that keeps its line breaks and indentation: a clip in the preview card, or a command in
/// the review card, in the system's monospaced type.
struct PreviewText: NSViewRepresentable {
    let text: String
    var monospaced = false
    /// What VoiceOver calls the text, and the identifier UI tests find it by.
    var accessibilityName = "Preview text"
    var accessibilityID: String?
    /// How far above the view's bottom edge the scroller ends.
    var scrollerBottomInset: CGFloat = 0
    let onCommand: (QuickAccessCommand) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: scrollerBottomInset, right: 0)
        let textView = PreviewTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = monospaced ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(accessibilityName)
        if let accessibilityID { textView.setAccessibilityIdentifier(accessibilityID) }
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

/// What the keys do in text in the preview, which can't be edited: Space and Escape close the preview, Return copies
/// and Tab moves on, as they do anywhere in the panel, and a key that types goes to the search field. The arrows and
/// the rest stay with the text.
@MainActor
enum PreviewTextKeys {
    /// True when the panel took the key, or it was a held key that has acted already.
    static func handle(_ event: NSEvent, hasMarkedText: Bool, onCommand: (QuickAccessCommand) -> Void) -> Bool {
        let key = QuickAccessStripView.key(for: event)
        // A held Space, Return or Escape has acted already.
        guard !(event.isARepeat && key.actsOnceWhenHeld) else { return true }
        // What these keys do in the preview does not depend on the query.
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: event.modifierFlags.contains(.shift), focus: .preview,
            eventBeganWithMarkedText: hasMarkedText, queryIsEmpty: true
        ))
        guard command != .passThrough else { return false }
        onCommand(command)
        return true
    }
}

/// The preview's text takes the keys once it is clicked, as `PreviewTextKeys` says.
private final class PreviewTextView: NSTextView {
    var onCommand: (QuickAccessCommand) -> Void = { _ in }

    override func keyDown(with event: NSEvent) {
        if PreviewTextKeys.handle(event, hasMarkedText: hasMarkedText(), onCommand: onCommand) { return }
        super.keyDown(with: event)
    }

    /// Escape leaves the preview through the panel's layers instead of text completion.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }
}
