import AppKit
import SwiftUI

@MainActor
final class PanelController: NSWindowController, NSWindowDelegate {
    private static let defaultSize = NSSize(width: 680, height: 496)
    static let expandedSize = NSSize(width: 960, height: 560)
    let state: QuickAccessState
    private let searchField = QuickAccessSearchField()
    private let results = QuickAccessResultsTableView()
    private lazy var fieldEditor: QuickAccessFieldEditor = {
        let editor = QuickAccessFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()
    private(set) var isSessionOpen = false
    /// The compact frame to restore when an expanded preview collapses.
    private var compactFrame: NSRect?

    init(state: QuickAccessState = QuickAccessState(services: { nil })) {
        self.state = state
        let panel = QuickAccessPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init(window: panel)
        panel.title = "Keeptide Quick Access"
        panel.identifier = NSUserInterfaceItemIdentifier("KeeptideQuickAccessPanel")
        panel.setAccessibilityIdentifier("KeeptideQuickAccessPanel")
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let actions = QuickAccessViewActions(
            primary: { [weak self] in self?.perform(.primary) },
            togglePreview: { [weak self] in self?.togglePreview() },
            openActions: { [weak self] in self?.openActions() },
            toggleKind: { [weak self] in self?.state.toggleKind($0) }
        )
        panel.contentViewController = WindowContentController(
            rootView: QuickAccessView(searchField: searchField, results: results, state: state, actions: actions),
            size: Self.defaultSize
        )
        panel.setContentSize(Self.defaultSize)
        panel.contentMinSize = NSSize(width: 520, height: 360)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onKeyEquivalent = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
        connect()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        if !isSessionOpen {
            searchField.stringValue = ""
            state.open()
            // Resolve the working screen before this panel takes keyboard focus.
            let screen = NSScreen.main
                ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.screens.first
            if let screen {
                window.setFrame(Self.frame(for: window.frame.size, in: screen.visibleFrame), display: false)
            }
            isSessionOpen = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    override func close() {
        guard isSessionOpen else { return }
        isSessionOpen = false
        state.close()
        if let compactFrame {
            window?.setFrame(compactFrame, display: false)
            self.compactFrame = nil
        }
        window?.makeFirstResponder(nil)
        window?.orderOut(nil)
    }

    func toggle() { isSessionOpen ? close() : show() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? QuickAccessSearchField) === searchField ? fieldEditor : nil
    }

    static func frame(for size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let size = NSSize(width: min(size.width, visibleFrame.width), height: min(size.height, visibleFrame.height))
        return NSRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The preview frame: the same top edge and centre as `compact`, moved inside the
    /// screen. Nil when the screen is too small, so the preview opens as a page instead.
    static func expandedFrame(from compact: NSRect, in visible: NSRect) -> NSRect? {
        let size = expandedSize
        guard visible.width >= size.width, visible.height >= size.height else { return nil }
        let x = min(max(compact.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(compact.maxY - size.height, visible.minY), visible.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func connect() {
        searchField.onQueryChange = { [weak self] in self?.state.setQuery($0) }
        searchField.onCommand = { [weak self] in self?.perform($0) }
        searchField.onEscape = { [weak self] in self?.applyEscape($0) }
        searchField.escapeContext = { [weak self] in
            QuickAccessEscapeContext(isPreviewExpanded: self?.state.isPreviewExpanded ?? false,
                                     hasFilters: !(self?.state.kinds.isEmpty ?? true))
        }
        results.onSelect = { [weak self] in self?.state.select($0) }
        results.onCommand = { [weak self] in self?.perform($0) }
        results.onRowVisible = { [weak self] in self?.state.loadMoreIfNeeded(visibleRow: $0) }
        state.onCopied = { [weak self] in self?.close() }
        state.onPreviewCollapsed = { [weak self] in self?.restoreCompactFrame() }
    }

    func perform(_ command: QuickAccessCommand) {
        switch command {
        case .passThrough:
            break
        case .focusResults:
            guard !state.selection.rows.isEmpty else { return }
            if state.selection.selection == nil { state.moveSelection(by: 1) }
            window?.makeFirstResponder(results)
        case .move(let offset):
            if state.moveSelection(by: offset) == .atTop { window?.makeFirstResponder(searchField) }
        case .primary:
            Task { await state.copySelection(.original) }
        case .plainText:
            Task { await state.copySelection(.plainText) }
        case .togglePreview:
            togglePreview()
        case .escape:
            escape()
        }
    }

    func togglePreview() {
        guard let window else { return }
        let wasExpanded = state.isPreviewExpanded
        state.togglePreview()
        if state.isPreviewExpanded, compactFrame == nil,
           let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
           let expanded = Self.expandedFrame(from: window.frame, in: visible) {
            compactFrame = window.frame
            window.setFrame(expanded, display: true)
        } else if wasExpanded, !state.isPreviewExpanded {
            restoreCompactFrame()
        }
    }

    /// Returns to the compact layout and keeps keyboard focus in the panel.
    private func restoreCompactFrame() {
        guard let window else { return }
        if let compactFrame {
            window.setFrame(compactFrame, display: true)
            self.compactFrame = nil
        }
        if !(window.firstResponder === results) {
            window.makeFirstResponder(state.selection.rows.isEmpty ? searchField : results)
        }
    }

    func openActions() {
        guard let content = window?.contentView else { return }
        let row = state.selection.rows.first { $0.ref == state.selection.selection }
        let menu = ActionMenu.make(row: row, canAct: state.selection.executableSelection != nil,
                                   isPreviewExpanded: state.isPreviewExpanded) { [weak self] command in
            switch command {
            case .copy: self?.perform(.primary)
            case .copyPlainText: self?.perform(.plainText)
            case .togglePreview: self?.togglePreview()
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: content.bounds.maxX - 200, y: 44), in: content)
    }

    /// Escape from the results or the preview; the search field peels its own layers first.
    private func escape() {
        let action = QuickAccessEscapePolicy.action(hasMarkedText: false, isPreviewExpanded: state.isPreviewExpanded,
                                                    hasQuery: !searchField.stringValue.isEmpty,
                                                    hasFilters: !state.kinds.isEmpty)
        switch action {
        case .closePanel:
            close()
        case .clearQuery:
            searchField.stringValue = ""
            applyEscape(action)
        case .cancelComposition, .collapsePreview:
            applyEscape(action)
        }
    }

    private func applyEscape(_ action: QuickAccessEscapeAction) {
        switch action {
        case .collapsePreview: togglePreview()
        case .clearQuery: state.clearQueryAndFilters()
        case .cancelComposition, .closePanel: break
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isSessionOpen, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return false
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k":
            openActions()
            return true
        case "y":
            togglePreview()
            return true
        default:
            return false
        }
    }
}

private final class QuickAccessPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }
}
