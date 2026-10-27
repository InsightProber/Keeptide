import AppKit
import SwiftUI

struct QuickAccessView: View {
    let searchField: QuickAccessSearchField

    var body: some View {
        VStack(spacing: 0) {
            SearchField(field: searchField)
                .padding(.horizontal, 20)
                .frame(height: 58)
                .background(.regularMaterial)
            Divider()
            ContentUnavailableView {
                Label("No content yet", systemImage: "doc.on.clipboard")
            } description: {
                Text("Your saved content will appear here.")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("QuickAccessEmptyState")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct SearchField: NSViewRepresentable {
    let field: QuickAccessSearchField
    func makeNSView(context: Context) -> QuickAccessSearchField { field }
    func updateNSView(_ nsView: QuickAccessSearchField, context: Context) {}
}

final class QuickAccessSearchField: NSSearchField, NSSearchFieldDelegate {
    init() {
        super.init(frame: .zero)
        placeholderString = "Search Keeptide"
        font = .preferredFont(forTextStyle: .title3)
        delegate = self
        setAccessibilityLabel("Quick access query")
        setAccessibilityIdentifier("Quick access query")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        switch QuickAccessEscapePolicy.action(hasMarkedText: textView.hasMarkedText(), hasQuery: !stringValue.isEmpty) {
        case .cancelComposition:
            // The input method already declined Escape. Remove only its marked range;
            // discardMarkedText alone does not clear the editor's marked range.
            textView.insertText("", replacementRange: textView.markedRange())
            textView.inputContext?.discardMarkedText()
            return true
        case .clearQuery:
            // Use native clearing so Undo and change notifications are preserved.
            return false
        case .closePanel:
            window?.performClose(nil)
            return true
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                              name: NSWindow.didBecomeKeyNotification, object: window)
        focusIfNeeded()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) { focusIfNeeded() }

    private func focusIfNeeded() {
        guard window?.isKeyWindow == true, currentEditor() == nil else { return }
        window?.makeFirstResponder(self)
    }
}

enum QuickAccessEscapeAction: Equatable {
    case cancelComposition, clearQuery, closePanel
}

enum QuickAccessEscapePolicy {
    static func action(hasMarkedText: Bool, hasQuery: Bool) -> QuickAccessEscapeAction {
        if hasMarkedText { return .cancelComposition }
        return hasQuery ? .clearQuery : .closePanel
    }
}
