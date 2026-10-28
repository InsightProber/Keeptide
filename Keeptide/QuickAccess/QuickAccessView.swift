import AppKit
import SwiftUI

/// Actions the panel controller supplies to the view.
struct QuickAccessViewActions {
    let primary: () -> Void
    let togglePreview: () -> Void
    let openActions: () -> Void
    let toggleKind: (ContentKind) -> Void
}

/// The compact single-column panel, with the preview opening beside the results
/// when there is room and as a page within the panel when there is not.
struct QuickAccessView: View {
    let searchField: QuickAccessSearchField
    let results: QuickAccessResultsTableView
    let state: QuickAccessState
    let actions: QuickAccessViewActions
    @State private var applicationNames = ApplicationNames()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(field: searchField)
                QuickAccessFilterMenu(kinds: state.kinds, toggle: actions.toggleKind)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            .background(.regularMaterial)
            scopeBar
            Divider()
            GeometryReader { proxy in
                content(width: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            QuickAccessActionBar(
                canAct: state.selection.executableSelection != nil,
                canPreview: state.selection.selection != nil,
                isPreviewExpanded: state.isPreviewExpanded,
                failure: state.failure,
                primary: actions.primary,
                togglePreview: actions.togglePreview,
                openActions: actions.openActions
            )
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 6) {
            Text(state.showsRecentClips ? "Recent Clips" : "All Content")
                .accessibilityLabel(state.scopeTitle)
                .accessibilityIdentifier("QuickAccessScope")
            ForEach(ContentKind.filters.filter(state.kinds.contains), id: \.self) { kind in
                Button { actions.toggleKind(kind) } label: {
                    Label(kind.filterTitle, systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(kind.filterTitle) filter")
            }
            Spacer(minLength: 8)
            if let statusLine {
                Text(statusLine).lineLimit(1).accessibilityIdentifier("QuickAccessStatus")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 24)
    }

    /// Status shown above rows that are still on screen.
    private var statusLine: String? {
        guard !state.selection.rows.isEmpty else { return nil }
        return QuickAccessStatus.line(selectionLost: state.selection.selectionLost, phase: state.phase,
                                      isComplete: state.selection.isComplete, notice: state.indexNotice)
    }

    /// The results stay in one place in the layout whether or not the preview is open,
    /// so the table is never rebuilt and keeps keyboard focus.
    private func content(width: CGFloat) -> some View {
        let split = state.isPreviewExpanded && width >= 900
        let page = state.isPreviewExpanded && !split
        return HStack(spacing: 0) {
            resultArea
                .frame(width: split ? 400 : (page ? 0 : nil))
                .opacity(page ? 0 : 1)
                .accessibilityHidden(page)
            if split {
                Divider()
                preview
            }
            if page {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to Results", action: actions.togglePreview)
                        Spacer()
                    }
                    .padding(8)
                    preview
                }
            }
        }
    }

    private var preview: some View {
        let row = state.selection.rows.first { $0.ref == state.selection.selection }
        return QuickAccessPreviewView(preview: state.preview,
                                      applicationName: row?.sourceApp.flatMap(applicationNames.name(for:)))
    }

    @ViewBuilder
    private var resultArea: some View {
        let rows = state.selection.rows
        if state.phase == .libraryUnavailable {
            emptyState("Library unavailable", detail: "Recent clips appear here once the library opens.")
        } else if rows.isEmpty {
            if state.phase == .noContent {
                emptyState("No content yet", detail: "Your saved content will appear here.")
            } else {
                status(QuickAccessStatus.empty(phase: state.phase, notice: state.indexNotice))
            }
        } else {
            QuickAccessResultsView(table: results, rows: rows, selection: state.selection.selection)
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc.on.clipboard")
        } description: {
            Text(detail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("QuickAccessEmptyState")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func status(_ message: QuickAccessStatus.Message) -> some View {
        VStack(spacing: 6) {
            Text(message.text)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("QuickAccessStatus")
            if let detail = message.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuickAccessFilterMenu: View {
    let kinds: Set<ContentKind>
    let toggle: (ContentKind) -> Void

    var body: some View {
        Menu {
            ForEach(ContentKind.filters, id: \.self) { kind in
                Toggle(kind.filterTitle, isOn: Binding(get: { kinds.contains(kind) }, set: { _ in toggle(kind) }))
            }
        } label: {
            Image(systemName: kinds.isEmpty ? "line.3.horizontal.decrease.circle"
                                           : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by type")
        .accessibilityLabel("Filter by type")
        .accessibilityIdentifier("QuickAccessFilterButton")
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
        guard let window, window.isKeyWindow, currentEditor() == nil else { return }
        // Keep focus another control in the panel already holds, such as the results.
        guard window.firstResponder == nil || window.firstResponder === window else { return }
        window.makeFirstResponder(self)
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
