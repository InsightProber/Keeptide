import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Places the panel's search field in the band.
struct SearchField: NSViewRepresentable {
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
    /// Whether the panel shows the filter row below the field, where Down then goes. The panel keeps it current.
    var filtersVisible = false

    init() {
        super.init(frame: .zero)
        placeholderString = "Search"
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
        let key: QuickAccessKey
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            return escape(textView)
        case #selector(NSResponder.insertNewline(_:)):
            key = .returnKey
        case #selector(NSResponder.moveDown(_:)):
            key = .down
        case #selector(NSResponder.moveLeft(_:)):
            key = .left
        case #selector(NSResponder.moveRight(_:)):
            key = .right
        case #selector(NSResponder.insertTab(_:)):
            key = .tab
        case #selector(NSResponder.insertBacktab(_:)):
            key = .backTab
        default:
            return false
        }
        return route(key, in: textView)
    }

    /// Space types text, so it never arrives here as a command; the field editor asks before typing it. An
    /// empty field has no use for it and opens the preview; in a query or a composition it is a space.
    func handleSpace(in editor: QuickAccessFieldEditor) -> Bool {
        route(.space, in: editor)
    }

    /// Keys with native meaning in the field, such as the arrows in a query, and keys that belong to a
    /// composition pass through.
    private func route(_ key: QuickAccessKey, in editor: NSTextView) -> Bool {
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false, focus: .searchField,
            eventBeganWithMarkedText: (editor as? QuickAccessFieldEditor)?.currentEventBeganWithMarkedText ?? false,
            queryIsEmpty: editor.string.isEmpty, filtersVisible: filtersVisible
        ))
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
        guard let window, window.isKeyWindow, currentEditor() == nil else { return }
        // Keep focus another control in the panel already holds, such as the strip.
        guard window.firstResponder == nil || window.firstResponder === window else { return }
        window.makeFirstResponder(self)
    }
}

/// The search field's editor. It records whether each key event began inside an input
/// method composition, so the key that commits a candidate never also acts, and lets the
/// field decide what Space means before typing it.
final class QuickAccessFieldEditor: NSTextView {
    private(set) var currentEventBeganWithMarkedText = false

    override func keyDown(with event: NSEvent) {
        currentEventBeganWithMarkedText = hasMarkedText()
        defer { currentEventBeganWithMarkedText = false }
        // The field being edited is the editor's delegate.
        if Int(event.keyCode) == kVK_Space, let field = (delegate as AnyObject?) as? QuickAccessSearchField,
           field.handleSpace(in: self) { return }
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
