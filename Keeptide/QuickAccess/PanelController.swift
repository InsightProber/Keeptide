import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The quick access panel: a borderless, see-through, non-activating window around the band. It owns the window,
/// where the keys go among the search field, the filters and the strip, and what each command does.
/// `QuickAccessBandView` draws the band and `QuickAccessState` holds what it shows. The panel never activates Keeptide:
/// for a paste it hides, leaving the keys with the window it pastes into, and closes once the paste is done.
@MainActor
final class PanelController: NSWindowController, NSWindowDelegate {
    let state: QuickAccessState
    private let preferences: QuickAccessPreferences
    private let searchField = QuickAccessSearchField()
    private lazy var toolbar = QuickAccessToolbar(field: searchField)
    private var filterRow: QuickAccessFilterRow { toolbar.filters }
    private let strip = QuickAccessStripView()
    private let applicationNames = ApplicationNames()
    private var hosting: NSHostingView<QuickAccessBandView>?
    private lazy var fieldEditor: QuickAccessFieldEditor = {
        let editor = QuickAccessFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()
    private(set) var isSessionOpen = false
    /// Whether the panel is off screen for a paste while its session goes on, for the check before ⌘V. It gives up the
    /// keys as it hides, which does not close it; the paste's end does.
    private(set) var isHiddenForPaste = false
    /// Says what an action did, where the band was, as the panel closes.
    let toast = CopyToastController(duration: PanelController.toastDuration(for: .copied))
    /// Return and keypad Enter while they are down in the panel, by key code, and `returnMayBeDown` while either may be.
    /// A paste waits until they are up, and the panel does not close while one is down: hidden or gone, it would leave
    /// a held key's repeats to the app below, where a terminal would run what was pasted, or the line typed there.
    /// The panel forgets them as it closes, since it no longer sees them come up.
    private var heldReturnKeys: Set<UInt16> = []
    /// Stands in `heldReturnKeys` for Return or keypad Enter when a menu item that pastes was chosen neither with the
    /// pointer nor with either key: one of them may still be down. It is a guess for that one choice. It goes when
    /// either key comes up, when the action ends with the panel still open, when the pointer acts, and when the panel
    /// opens a session; keys the panel saw go down stay.
    private static let returnMayBeDown = UInt16.max
    /// How long a paste waits for Return to come up before it copies instead.
    static let returnReleaseWait: Duration = .seconds(1)
    /// Set when an action ended while Return or keypad Enter was down: the session is over, but the panel stays on
    /// screen with the keys, which drop the key's repeats, until the key comes up. Then it closes and says what the
    /// action did, where the band was. Escape or a click beside the panel closes it as at any other time.
    private var closingOnceReturnIsUp: (completion: QuickAccessCompletion, band: NSRect)?
    /// The visible area of the screen the panel opens on and the frame sizes for it, settled each time it opens.
    private var visibleFrame: NSRect
    /// A visible area given for tests in place of the screen's.
    private let fixedVisibleFrame: NSRect?
    private var metrics: StripMetrics
    /// Where the band is on screen, for the copy confirmation.
    private var bandFrame = NSRect.zero
    /// What the panel shows in its window: the band, and the preview card while it is open. A click anywhere else
    /// falls on the room left around them for the band's shadow.
    private var contentFrames: [NSRect] = []
    /// Whether the strip's last row is the oldest there is: not while a search is still scanning, nor while another
    /// page may follow. While a new query has brought no rows yet, the rows still on screen keep what they had.
    private var oldestIsLoaded = true
    /// The key last posted again for the search field. Posting copies an event, so the copy is known by when
    /// it was pressed and which key it is; no two presses share a time.
    private var repostedKey: (timestamp: TimeInterval, keyCode: UInt16)?
    /// Whether the keys came to the search field with Tab, ⇧Tab or ↑, so that its circle is ringed even while it is
    /// folded. Keys the field has from the start, as the panel opens, leave the circle as it is.
    private var searchReachedByKeyboard = false
    /// Shows the actions menu. Tests replace it, since a real menu waits for a choice.
    var presentActionMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Shows the ⋯ menu. Tests replace it, as they do the actions menu.
    var presentMoreMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// The ⋯ menu's Open Library and Settings…, which the app points at its own commands.
    var onOpenLibrary: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The actions menu's Enable Direct Paste…, once the panel has closed. The app explains it and asks for access,
    /// which takes Keeptide to the front: the panel never does that itself.
    var onEnableDirectPaste: (() -> Void)?
    /// Reads `message` out to VoiceOver. Tests replace it to hear what is read.
    var announce: (String) -> Void = { _ in }
    /// The event the app is handling now. For a menu item chosen with Return, it is the key-down that chose it, which
    /// the menu took before the panel could see it. Tests replace it.
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    /// `preferences` defaults to a fresh copy for tests; the app passes the one its Settings window edits.
    /// `visibleFrame` stands in for the screen's visible area, so a test can lay the panel out for a screen of its own.
    init(state: QuickAccessState = QuickAccessState(services: { nil }),
         preferences: QuickAccessPreferences = QuickAccessPreferences(), visibleFrame: NSRect? = nil) {
        self.state = state
        self.preferences = preferences
        fixedVisibleFrame = visibleFrame
        self.visibleFrame = visibleFrame ?? Self.workingScreen()?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        metrics = StripLayout.metrics(for: preferences.cardSize, visibleWidth: self.visibleFrame.width)
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
        // The band draws its own material, edge and shadow, so the window has neither a background nor a shadow.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let hosting = NSHostingView(rootView: bandView(QuickAccessBandView.Layout(
            metrics: metrics, previewSize: nil, roomBelow: StripLayout.shadowRoom.below
        )))
        // AppKit owns the window's geometry; SwiftUI lays out only what is inside it.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onKeyEquivalent = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
        panel.onFirstResponderChange = { [weak self] in self?.focusChanged() }
        panel.isOutsideContent = { [weak self] point in
            guard let self else { return false }
            return !contentFrames.contains { $0.contains(point) }
        }
        // Hidden for a paste, the panel stays open until the paste is done.
        panel.onClickOutside = { [weak self] in
            guard let self, !isHiddenForPaste else { return }
            close()
        }
        panel.onKeyEvent = { [weak self] in self?.followReturnKey($0) }
        announce = { [weak panel] message in
            guard let panel else { return }
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        connect()
        followState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        // Shown again while it waits for Return after an action, the panel opens a session of its own, and what the
        // ended one waited to say no longer applies.
        closingOnceReturnIsUp = nil
        let opening = !isSessionOpen
        if opening {
            // A Return guessed down for the ended session's last choice is no guess for this one.
            forgetGuessedReturn()
            searchField.stringValue = ""
            filterRow.cursor = 0
            // The app in front is recorded as the paste target before this panel shows (decision 1).
            state.open()
            // Settle the screen before this panel takes keyboard focus, and take the settings as they are now.
            visibleFrame = fixedVisibleFrame ?? Self.workingScreen()?.visibleFrame ?? visibleFrame
            metrics = StripLayout.metrics(for: preferences.cardSize, visibleWidth: visibleFrame.width)
            strip.ticksEnabled = preferences.trackpadTicks
            update()
            isSessionOpen = true
        }
        window.makeKeyAndOrderFront(nil)
        // The search opens folded, its field holding the keys, so the first key typed is the search's.
        if opening { focusSearchField() }
    }

    /// Ends the session, if it is open, and takes the panel off screen, also when it waits for Return after an action:
    /// what the toast was to say then is said now.
    override func close() {
        let closing = closingOnceReturnIsUp
        guard isSessionOpen || closing != nil else { return }
        closingOnceReturnIsUp = nil
        if isSessionOpen { endSession() }
        heldReturnKeys = []
        window?.makeFirstResponder(nil)
        window?.orderOut(nil)
        if let closing { showToast(for: closing.completion, centeredOn: closing.band) }
    }

    /// Ends the session and the state's, so that nothing in the panel acts any more. It does not move the panel.
    private func endSession() {
        isSessionOpen = false
        isHiddenForPaste = false
        searchReachedByKeyboard = false
        state.close()
    }

    func toggle() { isSessionOpen || closingOnceReturnIsUp != nil ? close() : show() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    /// The panel closes when it loses the keys, except while it is hidden for a paste (decision 11).
    func windowDidResignKey(_ notification: Notification) {
        guard !isHiddenForPaste else { return }
        close()
    }

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
        searchField.onType = { [weak self] in self?.searchTyped() }
        searchField.onCommand = { [weak self] in self?.perform($0) }
        searchField.onEscape = { [weak self] in self?.applyEscape($0) }
        searchField.escapeContext = { [weak self] in
            QuickAccessEscapeContext(hasCommandReview: self?.state.commandReview != nil,
                                     isPreviewExpanded: self?.state.isPreviewExpanded ?? false,
                                     hasFilters: !(self?.state.kinds.isEmpty ?? true),
                                     isSearchExpanded: self?.state.isSearchExpanded ?? false)
        }
        toolbar.search.onUnfold = { [weak self] in self?.unfoldSearch() }
        toolbar.search.onClear = { [weak self] in self?.clearSearchText() }
        filterRow.onCommand = { [weak self] in self?.perform($0) }
        filterRow.onChoose = { [weak self] in self?.chooseFilter(at: $0) }
        toolbar.copyHint.target = self
        toolbar.copyHint.action = #selector(copyFromToolbar)
        toolbar.moreButton.target = self
        toolbar.moreButton.action = #selector(showMoreMenu)
        strip.onSelect = { [weak self] in
            self?.state.select($0)
            self?.update()
        }
        strip.onCommand = { [weak self] in self?.perform($0) }
        strip.onVisibleRefsChanged = { [weak self] in self?.loadFramedRows($0, lastOnScreen: $1) }
        strip.onContextMenu = { [weak self] in self?.actionMenu(for: $0) }
        state.onCompleted = { [weak self] in self?.finish($0) }
        state.onCommandReviewChanged = { [weak self] in self?.commandReviewChanged() }
        state.dismissForPaste = { [weak self] in self?.hideForPaste() }
        state.returnIsDown = { [weak self] in self?.heldReturnKeys.isEmpty == false }
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
        let wasExpanded = toolbar.search.isExpanded
        toolbar.setSearchExpanded(state.isSearchExpanded)
        if toolbar.search.isExpanded != wasExpanded {
            // The field has moved and changed size, so an input method's candidates move with it.
            (searchField.currentEditor() as? NSTextView)?.inputContext?.invalidateCharacterCoordinates()
        }
        if toolbar.search.isExpanded, !wasExpanded {
            // Open, the search is ringed while its field has the keys, however they came. Folded again, it is as the
            // panel opened it until the keyboard brings the keys back.
            searchReachedByKeyboard = false
            toolbar.ringsFoldedSearch = false
        }
        toolbar.search.hasText = !state.query.isEmpty
        toolbar.note = toolbarNote
        toolbar.hasClips = !state.selection.rows.isEmpty
        toolbar.indexNotice = state.indexNotice
        filterRow.queryIsEmpty = state.query.isEmpty
        filterRow.show(kinds: state.kinds)
        strip.queryIsEmpty = state.query.isEmpty
        strip.dimsSideFrames = hasCard
        if state.phase != .loading { oldestIsLoaded = state.selection.isComplete && !state.hasMoreRows }
        strip.show(state.selection.rows, selection: state.selection.selection, details: state.details,
                   metrics: metrics, applicationNames: applicationNames, oldestIsLoaded: oldestIsLoaded)
    }

    /// What the toolbar's right end says. A refused action's reason answers what was just done, so it comes first;
    /// then a status over clips on screen; then, with a clip selected, what Return does, under the name the session
    /// gives it, with why it only copies when the user can do something about that. With no clips the empty state says
    /// it all. An index that is rebuilding is told at the toolbar's left end, and leaves Return's hint in place.
    private var toolbarNote: QuickAccessToolbar.Note {
        if let failure = state.failure { return .failure(failure.message) }
        if !state.selection.rows.isEmpty,
           let line = QuickAccessStatus.line(selectionLost: state.selection.selectionLost, phase: state.phase,
                                             isComplete: state.selection.isComplete) {
            return .status(line)
        }
        guard state.selection.selection != nil else { return .none }
        let actions = state.actions
        // While a command waits on the review card, only the card confirms it.
        return .action(title: actions.primaryTitle,
                       enabled: state.selection.executableSelection != nil && state.commandReview == nil,
                       hint: actions.hint)
    }

    /// Whether a card lies above the band: the preview, or in its place a command's review.
    private var hasCard: Bool { state.isPreviewExpanded || state.commandReview != nil }

    /// Places the panel around the band, and around the card above it while the preview or a command's review is
    /// open, and lays the band out to match. The band sits in the middle of the screen's visible area; a card with no
    /// room above it moves the band down, and on a screen too low for that it lies over the band's top edge. The panel
    /// leaves room around them for the band's shadow, as much as the screen has.
    private func layoutPanel() {
        guard let window, let hosting else { return }
        var band = StripLayout.bandFrame(metrics, in: visibleFrame)
        var preview: NSRect?
        if hasCard {
            let placed = StripLayout.previewLayout(band: band, in: visibleFrame)
            band = placed.band
            preview = placed.preview
        }
        // On whole points, which are whole pixels on every screen; AppKit would cut a window's frame to them anyway.
        let frame = NSIntegralRectWithOptions(StripLayout.panelFrame(band: band, preview: preview, in: visibleFrame),
                                              .alignAllEdgesNearest)
        let roomBelow = (band.minY - frame.minY).rounded()
        let previewGap = preview.map { $0.minY - band.maxY } ?? StripLayout.previewGap
        let layout = QuickAccessBandView.Layout(metrics: metrics, previewSize: preview?.size, previewGap: previewGap,
                                                roomBelow: roomBelow)
        if hosting.rootView.layout != layout { hosting.rootView = bandView(layout) }
        if window.frame != frame { window.setFrame(frame, display: window.isVisible) }
        let bandInWindow = NSRect(x: StripLayout.sideMargin, y: roomBelow, width: band.width, height: band.height)
        bandFrame = bandInWindow.offsetBy(dx: frame.minX, dy: frame.minY)
        contentFrames = [bandInWindow] + (preview.map { [NSRect(
            x: bandInWindow.midX - $0.width / 2, y: bandInWindow.maxY + previewGap, width: $0.width,
            height: $0.height
        )] } ?? [])
    }

    private func bandView(_ layout: QuickAccessBandView.Layout) -> QuickAccessBandView {
        QuickAccessBandView(
            layout: layout, state: state, toolbar: toolbar, strip: strip, applicationNames: applicationNames,
            actions: QuickAccessBandView.Actions(previewCommand: { [weak self] in self?.perform($0) },
                                                 confirmCommand: { [weak self] in self?.confirmFromCard() },
                                                 cancelCommandReview: { [weak self] in self?.cancelFromCard() })
        )
    }

    /// Reads details for the framed clips alone, with pictures cut to the size in pixels of a card's middle, where
    /// they show, and loads more results before the strip runs out. Neither repeats work already done, so the strip
    /// may ask as often as it likes.
    private func loadFramedRows(_ refs: [ContentRef], lastOnScreen: Int) {
        let scale = window?.backingScaleFactor ?? 2
        state.loadDetails(for: refs, frameSize: CGSize(width: metrics.contentSize.width * scale,
                                                       height: metrics.contentSize.height * scale))
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
        case .focusSearchField:
            searchReachedByKeyboard = true
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
            act(.original)
        case .plainText:
            act(.plainText)
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

    /// A command's review appeared, was replaced or went: the card above the band follows, and VoiceOver reads the
    /// title of one that appears, after the notice of one that replaces a review that no longer applied.
    private func commandReviewChanged() {
        let focus = currentFocus
        update()
        keepFocus(focus)
        guard let review = state.commandReview else { return }
        let title = CommandReviewView.title(for: review)
        announce(review.isRenewal ? "\(CommandReviewView.renewalNotice) \(title)" : title)
    }

    /// The state closed the preview because its clip disappeared.
    private func previewCollapsed() {
        let focus = currentFocus
        update()
        keepFocus(focus)
    }

    /// Tab and ⇧Tab go round the search field, the filters and the strip.
    private func cycleFocus(forward: Bool) {
        switch QuickAccessKeyRouter.focus(after: currentFocus, forward: forward,
                                          hasClips: !state.selection.rows.isEmpty) {
        case .searchField:
            searchReachedByKeyboard = true
            focusSearchField()
        case .filters:
            window?.makeFirstResponder(filterRow)
        case .results, .preview:
            window?.makeFirstResponder(strip)
        }
    }

    /// All clears the filters; each kind turns on or off.
    private func chooseFilter(at index: Int) {
        if let kind = QuickAccessFilterRow.choices[index] {
            state.toggleKind(kind)
        } else {
            for kind in state.kinds { state.toggleKind(kind) }
        }
        update()
    }

    /// A click on the folded search or on the open one, or ⌘F: the search opens and its field takes the keys. A field
    /// that has them already keeps its editing as it is: its caret, its Undo and any composition under way.
    private func unfoldSearch() {
        state.unfoldSearch()
        update()
        if currentFocus != .searchField { focusSearchField() }
    }

    /// Something was typed into the field, perhaps while it was folded: the search opens to show it.
    private func searchTyped() {
        guard !state.isSearchExpanded else { return }
        state.unfoldSearch()
        update()
    }

    /// The clear button empties the field, as deleting its text would, and leaves the search open with the keys.
    private func clearSearchText() {
        if currentFocus != .searchField { focusSearchField() }
        guard let editor = searchField.currentEditor() as? NSTextView else { return }
        // Through the editor, so the change is reported as typing is and Undo brings the query back.
        editor.selectAll(nil)
        editor.delete(nil)
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

    /// The open search is ringed while its field has the keys, and the folded one when they came by the keyboard. A
    /// moment with no view holding the keys, as they pass from one view to another, leaves the ring as it is.
    private func focusChanged() {
        let focus = currentFocus
        if let focus, focus != .searchField { searchReachedByKeyboard = false }
        toolbar.showsSearchFocus = focus == .searchField
        toolbar.ringsFoldedSearch = searchReachedByKeyboard
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
        case .filters?:
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

    // MARK: Acting

    /// Return, ⇧Return and the toolbar's button: the clip selected when the key is pressed, delivered as the toolbar
    /// says (decision 2). The action finishes later. While a command waits on the review card they do nothing: only
    /// ⌘Return and the card's button confirm it.
    ///
    /// A paste waits for Return and keypad Enter to come up, for up to `returnReleaseWait`, and then goes ahead: with
    /// one still down, the paste service copies instead (`.returnHeld`), and the panel stays until the key is up. A
    /// panel closed meanwhile does nothing; one shown again meanwhile has a session of its own, which the paste service
    /// refuses the old action for.
    ///
    /// `guessesReturn` says that the menu choice that asks for the action may have left Return down unseen: the action
    /// takes Return for down (`returnMayBeDown`) until the guess goes, at the latest when the action ends with the
    /// panel still open, as when a review card shows, the clip is refused or the selection has moved on.
    private func act(_ mode: PasteMode, guessesReturn: Bool = false) {
        guard state.commandReview == nil, let target = state.copyTarget else { return }
        if guessesReturn { heldReturnKeys.insert(Self.returnMayBeDown) }
        let delivery = state.preferredDelivery
        Task {
            if delivery == .paste, !heldReturnKeys.isEmpty, await returnKeysComeUp() == nil { return }
            await state.act(on: target, mode: mode, delivery: delivery)
            if guessesReturn, isSessionOpen { forgetGuessedReturn() }
        }
    }

    /// The menu's copy that never pastes: "Copy", or "Copy As-Is" in a terminal's session.
    private func copyOnly() {
        guard let target = state.copyTarget else { return }
        let mode = state.actions.copyOnlyMode
        Task { await state.act(on: target, mode: mode, delivery: .copy) }
    }

    /// ⌘Return and the card's button confirm the review on the card when they are used, never one that replaced it
    /// meanwhile. A confirmed paste goes once Return is up; with Return held past `returnReleaseWait`, nothing is
    /// confirmed and the card stays, since confirming it as a copy would need a review of its own.
    private func confirmCommand() {
        guard let review = state.commandReview else { return }
        let delivery = review.confirmation.delivery
        Task {
            if delivery == .paste, !heldReturnKeys.isEmpty, await returnKeysComeUp() != true { return }
            guard state.commandReview == review else { return }
            await state.confirmCommand()
        }
    }

    private func cancelCommandReview() {
        state.cancelCommandReview()
    }

    /// The review card's Confirm and Cancel, pressed with the pointer or by VoiceOver. A Return only guessed down
    /// holds them back no longer; ⌘Return still waits for a Return the panel saw go down.
    private func confirmFromCard() {
        forgetGuessedReturn()
        confirmCommand()
    }

    private func cancelFromCard() {
        forgetGuessedReturn()
        cancelCommandReview()
    }

    /// Whether Return and keypad Enter are up within `returnReleaseWait`: true once they are, false when one is still
    /// down then, and nil once the panel has closed meanwhile.
    private func returnKeysComeUp() async -> Bool? {
        let deadline = ContinuousClock.now.advanced(by: Self.returnReleaseWait)
        while !heldReturnKeys.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            guard isSessionOpen else { return nil }
        }
        return heldReturnKeys.isEmpty
    }

    /// Follows Return and keypad Enter going down and coming up while the panel has the keys. Any other event, and any
    /// other key, is left alone; only a key event has a key code to read. Either key coming up also ends a Return that
    /// was only taken for down, and once none is left down, a panel that waits for that after its action closes.
    private func followReturnKey(_ event: NSEvent) {
        guard Self.isReturnOrEnter(event) else { return }
        guard event.type == .keyUp else {
            heldReturnKeys.insert(event.keyCode)
            return
        }
        heldReturnKeys.remove(event.keyCode)
        heldReturnKeys.remove(Self.returnMayBeDown)
        if heldReturnKeys.isEmpty, closingOnceReturnIsUp != nil { close() }
    }

    /// Whether `event` is Return or keypad Enter going down or coming up. Only a key event has a key code to read.
    private static func isReturnOrEnter(_ event: NSEvent) -> Bool {
        [.keyDown, .keyUp].contains(event.type) && [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
    }

    /// Return or keypad Enter was only guessed down, and the guess no longer applies: it goes, while keys the panel saw
    /// go down stay. A panel that waits after its action for nothing but the guess closes.
    private func forgetGuessedReturn() {
        guard heldReturnKeys.remove(Self.returnMayBeDown) != nil else { return }
        if heldReturnKeys.isEmpty, closingOnceReturnIsUp != nil { close() }
    }

    /// The toolbar's "⏎ Copy" or "⏎ Paste into …", for the pointer and VoiceOver. A Return only guessed down holds it
    /// back no longer.
    @objc private func copyFromToolbar() {
        forgetGuessedReturn()
        perform(.primary)
    }

    /// Hides the panel for a paste, before ⌘V is posted. The session goes on for the check that follows; the paste's
    /// end closes the panel (decision 11).
    private func hideForPaste() {
        isHiddenForPaste = true
        window?.orderOut(nil)
    }

    /// The action wrote the clipboard: the session ends, and the panel closes and says what happened where the band
    /// was. After ⌘V it says nothing, since the keystroke does not prove that the target pasted. With Return or keypad
    /// Enter still down, the panel stays on screen with the keys until the key comes up (`closingOnceReturnIsUp`).
    private func finish(_ completion: QuickAccessCompletion) {
        let band = bandFrame
        guard !heldReturnKeys.isEmpty, isSessionOpen, window?.isVisible == true else {
            close()
            return showToast(for: completion, centeredOn: band)
        }
        let focus = currentFocus
        endSession()
        closingOnceReturnIsUp = (completion, band)
        // The keys stay with a view that drops the held key's repeats, out of a card that goes with the session.
        restoreFocus(focus)
    }

    private func showToast(for completion: QuickAccessCompletion, centeredOn band: NSRect) {
        guard let message = completion.toastMessage else { return }
        toast.show(message, centeredOn: band, duration: Self.toastDuration(for: completion))
    }

    /// How long the toast stays: 1.2 s for a copy, and 2.5 s for one that says why a paste became a copy. UI tests poll
    /// about once a second, so there every toast stays 4 s.
    static func toastDuration(for completion: QuickAccessCompletion,
                              arguments: [String] = ProcessInfo.processInfo.arguments) -> Duration {
        #if DEBUG
        if arguments.contains("--ui-testing") { return .seconds(4) }
        #endif
        switch completion {
        case .copiedInstead(let fallback) where fallback != .noTarget: return .milliseconds(2_500)
        case .copied, .copiedInstead, .dispatched: return .milliseconds(1_200)
        }
    }

    // MARK: Menus

    /// The ⋯ menu, below its button. Each item closes the panel, then opens what it names.
    @objc private func showMoreMenu() {
        let menu = NSMenu(title: "More")
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Open Library") { [weak self] in
            self?.close()
            self?.onOpenLibrary?()
        })
        menu.addItem(ClosureMenuItem("Settings…") { [weak self] in
            self?.close()
            self?.onOpenSettings?()
        })
        let button = toolbar.moreButton
        presentMoreMenu(menu, NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), button)
    }

    /// ⌘K: the selected clip's actions, beside it where it rests; with the selection vanished, beside the empty slot
    /// just before the newest clip; with no clips, beside the middle of the strip.
    func openActions() {
        let size = metrics.frameSize
        let centre = NSRect(x: strip.bounds.midX - size.width / 2, y: strip.bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        presentActionMenu(actionMenu(for: state.selection.selection),
                          ActionMenu.anchor(beside: strip.selectionAnchorFrame ?? centre, in: strip), strip)
    }

    /// The actions for one clip: the selected one for ⌘K, the one under the pointer for a right-click, named for that
    /// clip. A clip other than the selected one is selected before its action runs, so the action is for the clip
    /// clicked; one that left the list while the menu was open gets no action at all, never another clip's.
    private func actionMenu(for ref: ContentRef?) -> NSMenu {
        let row = ref.flatMap { ref in state.selection.rows.first { $0.ref == ref } }
        return ActionMenu.make(actions: state.actions(for: ref), row: row,
                               canAct: state.selection.executableSelection != nil,
                               isReviewing: state.commandReview != nil,
                               isPreviewExpanded: state.isPreviewExpanded) { [weak self] command in
            guard let self else { return }
            let returnMayBeDown = followMenuChoice()
            if let ref, ref != state.selection.selection {
                state.select(ref)
                update()
                guard state.selection.selection == ref else { return }
            }
            switch command {
            case .primary: act(.original, guessesReturn: returnMayBeDown)
            case .plainText: act(.plainText, guessesReturn: returnMayBeDown)
            case .copyOnly: copyOnly()
            case .togglePreview: togglePreview()
            case .enableDirectPaste: enableDirectPaste()
            }
        }
    }

    /// How the menu item was chosen, as far as Return goes; true when Return may still be down from choosing it.
    /// - With Return or keypad Enter going down, the item acts while the key is still down: the menu took its key-down,
    ///   which the panel notes here, so that what the item does waits for the key to come up as it would for a key
    ///   pressed in the panel. The key-up comes to the panel, which still has the keys.
    /// - With the pointer, or as Return or keypad Enter came up, Return is up: a guess that it was down goes.
    /// - Any other way, or with no event to tell, Return may still be down. An item that pastes then takes it for
    ///   down; Enable Direct Paste… does not, so that VoiceOver can turn direct paste on.
    private func followMenuChoice() -> Bool {
        guard let event = currentEvent() else { return true }
        if Self.isReturnOrEnter(event), event.type == .keyDown {
            followReturnKey(event)
            return false
        }
        guard Self.pointerEvents.contains(event.type) || Self.isReturnOrEnter(event) else { return true }
        forgetGuessedReturn()
        return false
    }

    /// The events that choose a menu item with the pointer.
    private static let pointerEvents: [NSEvent.EventType] = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .pressure,
    ]

    /// Enable Direct Paste…: the panel closes, and the app takes it from there. With Return still down, from choosing
    /// the item, the panel first waits for it to come up: held, its repeats would press the alert's default button.
    /// Still down after `returnReleaseWait`, nothing happens. Only a key the panel saw go down holds it back, never one
    /// only guessed down: at worst a held key's repeats press Open System Settings, which is what was asked for.
    private func enableDirectPaste() {
        guard heldReturnKeys.contains(where: { $0 != Self.returnMayBeDown }) else { return handOverEnableDirectPaste() }
        Task {
            guard await returnKeysComeUp() == true else { return }
            // The alert runs a loop of its own, so it starts on a turn of its own rather than inside this task.
            DispatchQueue.main.async { self.handOverEnableDirectPaste() }
        }
    }

    private func handOverEnableDirectPaste() {
        close()
        onEnableDirectPaste?()
    }

    // MARK: Escape

    /// Escape from the strip, the filters, the preview or the review card; the search field peels its own layers first.
    /// A panel that waits for Return after its action has nothing left to peel, and closes.
    private func escape() {
        guard closingOnceReturnIsUp == nil else { return close() }
        let action = QuickAccessEscapePolicy.action(hasMarkedText: false, hasCommandReview: state.commandReview != nil,
                                                    isPreviewExpanded: state.isPreviewExpanded,
                                                    hasQuery: !searchField.stringValue.isEmpty,
                                                    hasFilters: !state.kinds.isEmpty,
                                                    isSearchExpanded: state.isSearchExpanded)
        switch action {
        case .closePanel:
            close()
        case .clearQuery:
            searchField.stringValue = ""
            applyEscape(action)
        case .cancelComposition, .cancelCommandReview, .collapsePreview, .foldSearch:
            applyEscape(action)
        }
    }

    private func applyEscape(_ action: QuickAccessEscapeAction) {
        guard closingOnceReturnIsUp == nil else { return close() }
        switch action {
        case .cancelCommandReview:
            cancelCommandReview()
        case .collapsePreview:
            togglePreview()
        case .clearQuery:
            state.clearQueryAndFilters()
            update()
        case .foldSearch:
            state.foldSearch()
            update()
        case .cancelComposition, .closePanel:
            break
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // Caps Lock, like the keypad's and the function key's flags, is no modifier a shortcut asks for.
        guard isSessionOpen, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else {
            return false
        }
        // ⌘Return, and ⌘ with keypad Enter, which types no "\r", are known by the key. They confirm the command on the
        // review card, and nothing else: a preview is not a review, and while an input method composes in the search
        // field the key is the composition's.
        if Self.isReturnOrEnter(event) {
            let isComposing = (searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true
            guard state.commandReview != nil, !isComposing else { return false }
            // A key equivalent never reaches the window's own handling, so the key going down is noted here.
            followReturnKey(event)
            // Held down, it has confirmed already: its repeats confirm nothing, such as a review that replaced it.
            guard !event.isARepeat else { return true }
            confirmCommand()
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            unfoldSearch()
            return true
        case "k":
            openActions()
            return true
        case "y":
            // Held down, ⌘Y has acted already: its repeats are taken and do nothing.
            guard !event.isARepeat else { return true }
            togglePreview()
            return true
        default:
            return false
        }
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}

private final class QuickAccessPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    /// Every key going down or coming up in the panel, before the panel handles it.
    var onKeyEvent: ((NSEvent) -> Void)?
    /// Called whenever the keys move from one view to another.
    var onFirstResponderChange: (() -> Void)?
    /// Whether a point in the window lies outside what the panel shows, in the room left for the band's shadow.
    var isOutsideContent: ((NSPoint) -> Bool)?
    var onClickOutside: (() -> Void)?

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

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        onFirstResponderChange?()
        return made
    }

    /// The window reaches well beyond the band, for its shadow, and the shadow is not quite transparent, so clicks
    /// there come to the panel. Such a click is a click beside the panel, and closes it as one would.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           isOutsideContent?(event.locationInWindow) == true {
            onClickOutside?()
            return
        }
        if event.type == .keyDown || event.type == .keyUp { onKeyEvent?(event) }
        super.sendEvent(event)
    }
}
