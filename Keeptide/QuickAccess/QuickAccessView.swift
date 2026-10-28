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

/// What Escape may peel in the panel besides the search field's own text.
struct QuickAccessEscapeContext {
    var isPreviewExpanded = false
    var hasFilters = false
}

final class QuickAccessSearchField: NSSearchField, NSSearchFieldDelegate {
    /// The committed query; never reported while an input method has marked text.
    var onQueryChange: ((String) -> Void)?
    /// Commands from keys the field does not handle natively.
    var onCommand: ((QuickAccessCommand) -> Void)?
    /// Escape layers handled outside the field: collapsing the preview, clearing filters.
    var onEscape: ((QuickAccessEscapeAction) -> Void)?
    var escapeContext: () -> QuickAccessEscapeContext = { QuickAccessEscapeContext() }

    init() {
        super.init(frame: .zero)
        placeholderString = "Search Keeptide"
        font = .preferredFont(forTextStyle: .title3)
        delegate = self
        setAccessibilityLabel("Quick access query")
        setAccessibilityIdentifier("Quick access query")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        onQueryChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let beganWithMarkedText = (textView as? QuickAccessFieldEditor)?.currentEventBeganWithMarkedText ?? false
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            return escape(textView)
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            return route(QuickAccessKeyInput(key: .returnKey, shift: shift, focus: .searchField,
                                             eventBeganWithMarkedText: beganWithMarkedText))
        case #selector(NSResponder.moveDown(_:)):
            return route(QuickAccessKeyInput(key: .down, focus: .searchField,
                                             eventBeganWithMarkedText: beganWithMarkedText))
        default:
            return false
        }
    }

    private func route(_ input: QuickAccessKeyInput) -> Bool {
        let command = QuickAccessKeyRouter.command(for: input)
        guard command != .passThrough else { return false }
        onCommand?(command)
        return true
    }

    private func escape(_ textView: NSTextView) -> Bool {
        let context = escapeContext()
        let action = QuickAccessEscapePolicy.action(hasMarkedText: textView.hasMarkedText(),
                                                    isPreviewExpanded: context.isPreviewExpanded,
                                                    hasQuery: !stringValue.isEmpty, hasFilters: context.hasFilters)
        switch action {
        case .cancelComposition:
            // The input method already declined Escape. Remove only its marked range;
            // discardMarkedText alone does not clear the editor's marked range.
            textView.insertText("", replacementRange: textView.markedRange())
            textView.inputContext?.discardMarkedText()
            return true
        case .collapsePreview:
            onEscape?(action)
            return true
        case .clearQuery:
            onEscape?(action)
            // Use native clearing so Undo and change notifications are preserved.
            return stringValue.isEmpty
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

/// The search field's editor. It records whether each key event began inside an input
/// method composition, so the key that commits a candidate never also acts.
final class QuickAccessFieldEditor: NSTextView {
    private(set) var currentEventBeganWithMarkedText = false

    override func keyDown(with event: NSEvent) {
        currentEventBeganWithMarkedText = hasMarkedText()
        defer { currentEventBeganWithMarkedText = false }
        super.keyDown(with: event)
    }
}

enum QuickAccessEscapeAction: Equatable {
    case cancelComposition, collapsePreview, clearQuery, closePanel
}

/// Escape handles only the top layer: composition, then preview, then the query and
/// temporary filters, then the panel.
enum QuickAccessEscapePolicy {
    static func action(hasMarkedText: Bool, isPreviewExpanded: Bool = false,
                       hasQuery: Bool, hasFilters: Bool = false) -> QuickAccessEscapeAction {
        if hasMarkedText { return .cancelComposition }
        if isPreviewExpanded { return .collapsePreview }
        return hasQuery || hasFilters ? .clearQuery : .closePanel
    }
}
