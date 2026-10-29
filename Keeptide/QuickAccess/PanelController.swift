import AppKit
import SwiftUI

/// The quick access panel: a borderless, see-through, non-activating window around the band. It owns the window,
/// where the keys go among the search field, the filter row and the strip, and what each command does.
/// `QuickAccessBandView` draws the band and `QuickAccessState` holds what it shows.
@MainActor
final class PanelController: NSWindowController, NSWindowDelegate {
    let state: QuickAccessState
    private let preferences: QuickAccessPreferences
    private let searchField = QuickAccessSearchField()
    private let filterRow = QuickAccessFilterRow()
    private let strip = QuickAccessStripView()
    private let applicationNames = ApplicationNames()
    private var hosting: NSHostingView<QuickAccessBandView>?
    private lazy var fieldEditor: QuickAccessFieldEditor = {
        let editor = QuickAccessFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()
    private(set) var isSessionOpen = false
    private let toast = CopyToastController(duration: PanelController.toastDuration)
    /// The visible area of the screen the panel opens on and the frame sizes for it, settled each time it opens.
    private var visibleFrame: NSRect
    private var metrics: StripMetrics
    /// Where the band is on screen, for the copy confirmation.
    private var bandFrame = NSRect.zero
    /// Whether the strip's last row is the oldest there is: not while a search is still scanning, nor while another
    /// page may follow. While a new query has brought no rows yet, the rows still on screen keep what they had.
    private var oldestIsLoaded = true
    /// The key last posted again for the search field. Posting copies an event, so the copy is known by when
    /// it was pressed and which key it is; no two presses share a time.
    private var repostedKey: (timestamp: TimeInterval, keyCode: UInt16)?
    /// Shows the actions menu. Tests replace it, since a real menu waits for a choice.
    var presentActionMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }

    /// `preferences` defaults to a fresh copy for tests; the app passes the one its Settings window edits.
    init(state: QuickAccessState = QuickAccessState(services: { nil }),
         preferences: QuickAccessPreferences = QuickAccessPreferences()) {
        self.state = state
        self.preferences = preferences
        visibleFrame = Self.workingScreen()?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        metrics = StripLayout.metrics(for: preferences.cardSize, visibleWidth: visibleFrame.width)
        let panel = QuickAccessPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Keeptide Quick Access"
        panel.identifier = NSUserInterfaceItemIdentifier("KeeptideQuickAccessPanel")
        panel.setAccessibilityIdentifier("KeeptideQuickAccessPanel")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The band fades out at its ends and draws its own shadow, so the window has neither a background nor one.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let hosting = NSHostingView(rootView: bandView(QuickAccessBandView.Layout(
            metrics: metrics, filtersVisible: false, previewSize: nil
        )))
        // AppKit owns the window's geometry; SwiftUI lays out only what is inside it.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onKeyEquivalent = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
        connect()
        followState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        if !isSessionOpen {
            searchField.stringValue = ""
            filterRow.cursor = 0
            state.open()
            // Settle the screen before this panel takes keyboard focus, and take the settings as they are now.
            visibleFrame = Self.workingScreen()?.visibleFrame ?? visibleFrame
            metrics = StripLayout.metrics(for: preferences.cardSize, visibleWidth: visibleFrame.width)
            strip.ticksEnabled = preferences.trackpadTicks
            update()
            isSessionOpen = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    override func close() {
        guard isSessionOpen else { return }
        isSessionOpen = false
        state.close()
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

    /// The main screen, or the one under the pointer when there is none.
    private static func workingScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.screens.first
    }

    private func connect() {
        searchField.onQueryChange = { [weak self] in
            self?.state.setQuery($0)
            self?.update()
        }
        searchField.onCommand = { [weak self] in self?.perform($0) }
        searchField.onEscape = { [weak self] in self?.applyEscape($0) }
        searchField.escapeContext = { [weak self] in
            QuickAccessEscapeContext(isPreviewExpanded: self?.state.isPreviewExpanded ?? false,
                                     hasFilters: self?.state.filtersVisible ?? false)
        }
        filterRow.onCommand = { [weak self] in self?.perform($0) }
        filterRow.onChoose = { [weak self] in self?.chooseFilter(at: $0) }
        strip.onSelect = { [weak self] in
            self?.state.select($0)
            self?.update()
        }
        strip.onCommand = { [weak self] in self?.perform($0) }
        strip.onVisibleRefsChanged = { [weak self] in self?.loadFramedRows($0, lastOnScreen: $1) }
        strip.onContextMenu = { [weak self] in self?.actionMenu(for: $0) }
        // The band fades the ends the strip's film goes on beyond.
        strip.onFadesChanged = { [weak self] in self?.layoutPanel() }
        state.onCopied = { [weak self] in self?.confirmCopy() }
        state.onPreviewCollapsed = { [weak self] in self?.previewCollapsed() }
    }

    // MARK: Following the state

    /// Keeps the panel in step with what the state changes on its own, such as results arriving. Observation
    /// reports a change before it is made, so the panel follows just after; what the panel changes itself it
    /// brings up to date at once.
    private func followState() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followState() }
        }
    }

    /// Lays the panel out for the state, then brings the AppKit views up to date: what they show and what
    /// their keys mean.
    private func update() {
        layoutPanel()
        searchField.filtersVisible = state.filtersVisible
        filterRow.isHidden = !state.filtersVisible
        filterRow.queryIsEmpty = state.query.isEmpty
        filterRow.show(kinds: state.kinds)
        strip.filtersVisible = state.filtersVisible
        strip.queryIsEmpty = state.query.isEmpty
        strip.dimsSideFrames = state.isPreviewExpanded
        if state.phase != .loading { oldestIsLoaded = state.selection.isComplete && !state.hasMoreRows }
        strip.show(state.selection.rows, selection: state.selection.selection, details: state.details,
                   metrics: metrics, applicationNames: applicationNames, oldestIsLoaded: oldestIsLoaded)
    }

    /// Places the panel around the band, and around the preview card above it while the preview is open, and
    /// lays the band out to match. The band sits in the middle of the screen's visible area, and its search row
    /// stays put when the filter row shows; a card with no room above the band moves it down.
    private func layoutPanel() {
        guard let window, let hosting else { return }
        let filtersVisible = state.filtersVisible
        var band = StripLayout.bandFrame(metrics, filtersVisible: filtersVisible, in: visibleFrame)
        var preview: NSRect?
        if state.isPreviewExpanded {
            let placed = StripLayout.previewLayout(band: band, filtersVisible: filtersVisible, in: visibleFrame)
            band = placed.band
            preview = placed.preview
        }
        let layout = QuickAccessBandView.Layout(metrics: metrics, filtersVisible: filtersVisible,
                                                previewSize: preview?.size, fadesLeading: strip.fades.leading,
                                                fadesTrailing: strip.fades.trailing, animatesFades: strip.animatesFades)
        if hosting.rootView.layout != layout { hosting.rootView = bandView(layout) }
        // On whole points, which are whole pixels on every screen; AppKit would cut a window's frame to them anyway.
        let frame = NSIntegralRectWithOptions(StripLayout.panelFrame(band: band, preview: preview), .alignAllEdgesNearest)
        if window.frame != frame { window.setFrame(frame, display: window.isVisible) }
        bandFrame = NSRect(x: frame.minX + StripLayout.sideMargin, y: frame.minY + StripLayout.shadowMargin,
                           width: band.width, height: band.height)
        // A filter row that went away cannot keep the keys; the search field takes them.
        if !filtersVisible, currentFocus == .filters { focusSearchField() }
    }

    private func bandView(_ layout: QuickAccessBandView.Layout) -> QuickAccessBandView {
        QuickAccessBandView(
            layout: layout, state: state, searchField: searchField, filterRow: filterRow, strip: strip,
            applicationNames: applicationNames,
            actions: QuickAccessBandView.Actions(
                copy: { [weak self] in self?.perform(.primary) },
                toggleFilters: { [weak self] in self?.toggleFilters() },
                previewCommand: { [weak self] in self?.perform($0) }
            )
        )
    }

    /// Reads details for the framed clips alone, at the frames' size in pixels, and loads more results before
    /// the strip runs out. Neither repeats work already done, so the strip may ask as often as it likes.
    private func loadFramedRows(_ refs: [ContentRef], lastOnScreen: Int) {
        let scale = window?.backingScaleFactor ?? 2
        state.loadDetails(for: refs, frameSize: CGSize(width: metrics.frameSize.width * scale,
                                                       height: metrics.frameSize.height * scale))
        state.loadMoreIfNeeded(visibleRow: lastOnScreen)
    }

    // MARK: Commands

    func perform(_ command: QuickAccessCommand) {
        switch command {
        case .passThrough:
            break
        case .focusResults:
            guard !state.selection.rows.isEmpty else { return }
            window?.makeFirstResponder(strip)
        case .focusFilters:
            focusFilters()
        case .focusSearchField:
            focusSearchField()
        case .cycleFocus(let forward):
            cycleFocus(forward: forward)
        case .move(let offset):
            // At either end nothing happens.
            guard state.moveSelection(by: offset) == .moved else { return }
            // In the same turn as the step, so the frames never lag behind the fingers.
            update()
        case .moveFilter(let offset):
            filterRow.moveCursor(by: offset)
        case .toggleFilter:
            chooseFilter(at: filterRow.cursor)
        case .typeIntoSearch:
            typeIntoSearch()
        case .primary:
            copy(.original)
        case .plainText:
            copy(.plainText)
        case .togglePreview:
            togglePreview()
        case .escape:
            escape()
        }
    }

    func togglePreview() {
        let wasExpanded = state.isPreviewExpanded
        // Nothing selected means nothing to preview.
        guard wasExpanded || state.selection.selection != nil else { return }
        let focus = currentFocus
        state.togglePreview()
        update()
        keepFocus(focus)
    }

    /// The state closed the preview because its clip disappeared.
    private func previewCollapsed() {
        let focus = currentFocus
        update()
        keepFocus(focus)
    }

    /// Tab and ⇧Tab go round the search field, the filter row and the strip, showing the filter row when it is
    /// hidden. The strip is left out while it has no clips. From the preview's text, Tab goes on to the search
    /// field and ⇧Tab back to the strip.
    private func cycleFocus(forward: Bool) {
        var order: [QuickAccessFocus] = [.searchField, .filters]
        if !state.selection.rows.isEmpty { order.append(.results) }
        let target: QuickAccessFocus
        if let index = currentFocus.flatMap(order.firstIndex(of:)) {
            target = order[(index + (forward ? 1 : order.count - 1)) % order.count]
        } else {
            target = forward ? order[0] : order[order.count - 1]
        }
        switch target {
        case .searchField:
            focusSearchField()
        case .filters:
            state.revealFilters()
            update()
            focusFilters()
        case .results, .preview:
            window?.makeFirstResponder(strip)
        }
    }

    private func focusFilters() {
        guard state.filtersVisible else { return }
        window?.makeFirstResponder(filterRow)
    }

    /// All clears the filters; each kind turns on or off. The row stays while it is used, even when the choice
    /// leaves no query or filter to hold it up.
    private func chooseFilter(at index: Int) {
        state.revealFilters()
        if let kind = QuickAccessFilterRow.choices[index] {
            state.toggleKind(kind)
        } else {
            for kind in state.kinds { state.toggleKind(kind) }
        }
        update()
    }

    /// The filter button shows a hidden filter row and hides one brought up by hand. A row a query or a filter
    /// holds up stays; brought up by hand as well, it goes once they do.
    private func toggleFilters() {
        if !state.filtersVisible {
            state.revealFilters()
        } else if state.filtersRevealed {
            state.toggleFiltersRevealed()
        }
        update()
    }

    /// A key typed below the search field belongs in it. The field takes the keys, and the key event is posted
    /// again at the front of the queue, so that it reaches the field after the change of focus, once the field's
    /// input context is active and the key can start an input method's composition. Should the key come back
    /// here all the same, it is dropped rather than posted once more.
    private func typeIntoSearch() {
        let event = NSApp.currentEvent
        if let event, let reposted = repostedKey, reposted == (event.timestamp, event.keyCode) {
            repostedKey = nil
            return
        }
        focusSearchField()
        guard let event, event.type == .keyDown, searchField.currentEditor() != nil else { return }
        repostedKey = (event.timestamp, event.keyCode)
        NSApp.postEvent(event, atStart: true)
    }

    // MARK: Focus

    private var currentFocus: QuickAccessFocus? {
        guard let responder = window?.firstResponder else { return nil }
        if responder === strip { return .results }
        if responder === filterRow { return .filters }
        guard let editor = responder as? NSTextView else { return nil }
        if editor.isFieldEditor { return editor.delegate === searchField ? .searchField : nil }
        // Besides the field's editor, the preview's text is the panel's only text view.
        return .preview
    }

    /// Restores focus now and again once SwiftUI has applied the new layout. Focus that was in the preview goes
    /// to the strip, or to the search field when there are no clips.
    private func keepFocus(_ focus: QuickAccessFocus?) {
        restoreFocus(focus)
        DispatchQueue.main.async { [weak self] in self?.restoreFocus(focus) }
    }

    private func restoreFocus(_ focus: QuickAccessFocus?) {
        guard let window else { return }
        let rowsShown = !state.selection.rows.isEmpty
        switch focus {
        case .filters? where state.filtersVisible:
            if window.firstResponder !== filterRow { window.makeFirstResponder(filterRow) }
        case .results? where rowsShown, .preview? where rowsShown, nil where rowsShown:
            if window.firstResponder !== strip { window.makeFirstResponder(strip) }
        default:
            if currentFocus != .searchField { focusSearchField() }
        }
    }

    /// NSTextField selects all of its text when it takes focus; the caret goes to the end instead, so typing
    /// continues the query.
    private func focusSearchField() {
        guard let window, window.makeFirstResponder(searchField), let editor = searchField.currentEditor() else {
            return
        }
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }

    // MARK: Copying

    /// Captures what is selected when the key is pressed; the copy finishes later.
    private func copy(_ mode: PasteMode) {
        guard let target = state.copyTarget else { return }
        Task { await state.copy(target, mode: mode) }
    }

    /// Closes the panel and confirms the copy where the band was.
    private func confirmCopy() {
        let band = bandFrame
        close()
        toast.show("Copied — press ⌘V to paste", centeredOn: band)
    }

    private static var toastDuration: Duration {
        #if DEBUG
        // UI tests poll about once a second; keep the confirmation up long enough to observe.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return .seconds(4) }
        #endif
        return .milliseconds(1_200)
    }

    // MARK: Actions menu

    /// ⌘K: the selected clip's actions, beside it; with nothing selected, beside the middle of the strip.
    func openActions() {
        let size = metrics.frameSize
        let centre = NSRect(x: strip.bounds.midX - size.width / 2, y: strip.bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        presentActionMenu(actionMenu(for: state.selection.selection),
                          ActionMenu.anchor(beside: strip.selectedFrame ?? centre, in: strip), strip)
    }

    /// The actions for one clip: the selected one for ⌘K, the one under the pointer for a right-click. A clip
    /// other than the selected one is selected before its action runs, so the action is for the clip clicked;
    /// one that left the list while the menu was open gets no action at all, never another clip's.
    private func actionMenu(for ref: ContentRef?) -> NSMenu {
        let row = ref.flatMap { ref in state.selection.rows.first { $0.ref == ref } }
        return ActionMenu.make(row: row, canAct: state.selection.executableSelection != nil,
                               isPreviewExpanded: state.isPreviewExpanded) { [weak self] command in
            guard let self else { return }
            if let ref, ref != state.selection.selection {
                state.select(ref)
                update()
                guard state.selection.selection == ref else { return }
            }
            switch command {
            case .copy: perform(.primary)
            case .copyPlainText: perform(.plainText)
            case .togglePreview: togglePreview()
            }
        }
    }

    // MARK: Escape

    /// Escape from the strip, the filter row or the preview; the search field peels its own layers first.
    private func escape() {
        let action = QuickAccessEscapePolicy.action(hasMarkedText: false, isPreviewExpanded: state.isPreviewExpanded,
                                                    hasQuery: !searchField.stringValue.isEmpty,
                                                    hasFilters: state.filtersVisible)
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
        case .collapsePreview:
            togglePreview()
        case .clearQuery:
            state.clearQueryAndFilters()
            update()
        case .cancelComposition, .closePanel:
            break
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

    // A borderless window cannot become key unless it says so.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// A borderless panel has no close button, which `performClose` otherwise needs; closing goes through the
    /// delegate as it would.
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true { close() }
    }

    /// ⌘W reaches `performClose` through the Window menu's Close, which NSWindow disables for a window without a
    /// close button; ⌘W would then only beep.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(performClose(_:)) || super.validateMenuItem(menuItem)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }
}
