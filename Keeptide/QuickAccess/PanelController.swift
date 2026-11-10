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
    private var listNavigation: QuickAccessListNavigation { toolbar.lists }
    private var filterButton: QuickAccessFilterButton { toolbar.filterButton }
    private let strip = QuickAccessStripView()
    /// The light behind the selected card, kept where the card rests.
    private let glow = QuickAccessGlowView()
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
    private var previewFrameInWindow: NSRect?
    /// Whether the strip's last row is the oldest there is: not while a search is still scanning, nor while another
    /// page may follow. While a new query has brought no rows yet, the rows still on screen keep what they had.
    private var oldestIsLoaded = true
    /// The key last posted again for the search field. Posting copies an event, so the copy is known by when
    /// it was pressed and which key it is; no two presses share a time.
    private var repostedKey: (timestamp: TimeInterval, keyCode: UInt16)?
    /// When ⌘⌫ last went to text rather than to the selection, and how long after it ⌘⌫ in the emptied search field
    /// still means the text.
    private var lastTextCommandDelete: TimeInterval?
    private static let textCommandDeleteGrace: TimeInterval = 1
    /// The moves on the window's undo stack, oldest first: the stack holds them only weakly.
    private var undoableMoves: [MoveUndo] = []
    /// Counts the panel's changes, so ⌘Z can tell whether a move or typing came last: `lastTyping` is the count when
    /// the search field's text last changed other than by its own undo.
    private var changeCount = 0
    private var lastTyping = 0
    private var undoingTyping = false
    /// Whether the keys came to the search field with Tab, ⇧Tab or ↑, so that its circle is ringed even while it is
    /// folded. Keys the field has from the start, as the panel opens, leave the circle as it is.
    private var searchReachedByKeyboard = false
    /// The list the cards were last shown for, and whether the first page of a new one is still to come.
    private var listShown = QuickAccessList.all
    private var awaitsNewListPage = false
    /// Shows the actions menu. Tests replace it, since a real menu waits for a choice.
    var presentActionMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Whether changes of list come without the cards' fade, as Reduce Motion asks.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Shows the filter button's menu, or More's with the collections that did not fit. Tests catch them here.
    var presentToolbarMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Shows the ⋯ menu. Tests replace it, as they do the actions menu.
    var presentMoreMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// The ⋯ menu's Open Library and Settings…, which the app points at its own commands.
    var onOpenLibrary: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Show in Library: the selected clip's exact content identity, and whether the library shows the snippet it was
    /// saved as rather than the clip, as it does for a snippet's card and a clip saved as one.
    var onOpenInLibrary: ((ContentRef, Bool) -> Void)?
    /// New Snippet: the collection the panel lists, where the new snippet goes; nil for Unfiled.
    var onNewSnippet: ((CollectionID?) -> Void)?
    /// The actions menu's Enable Direct Paste…, once the panel has closed. The app explains it and asks for access,
    /// which takes Keeptide to the front: the panel never does that itself.
    var onEnableDirectPaste: (() -> Void)?
    /// Why new copies are not kept, which the toolbar says after the filters, or nil while they are. The app reads it
    /// from the capture session. `update()` reads it, so the panel follows the session as it changes, and VoiceOver
    /// hears it as it appears or changes while the panel is open.
    var captureNotice: () -> String? = { nil }
    /// Reads `message` out to VoiceOver. Tests replace it to hear what is read.
    var announce: (String) -> Void = { _ in }
    /// What `update()` says as a recognition ends without text.
    private var textColumnEndings = ResultColumnEndings()
    private var translationColumnEndings = ResultColumnEndings()
    /// Tells the input method that the search field's characters moved, as when the search folds or unfolds. Tests replace it
    /// to count the calls.
    var fieldCharactersMoved: (NSTextView) -> Void = { $0.inputContext?.invalidateCharacterCoordinates() }
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
        metrics = Self.metrics(for: preferences, visibleWidth: self.visibleFrame.width)
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
        panel.onPreviewKeyDown = { [weak self] in self?.handlePreviewKeyDown($0) ?? false }
        panel.onContentMouseDown = { [weak self] point in
            // Over the band, a click closes the preview that lies over it. Below the split card or a command's review,
            // which stand above the band, it goes to the band, as it does with no card at all.
            guard let self, state.isPreviewExpanded, state.commandReview == nil, !state.isPreviewSplit,
                  let previewFrameInWindow, !previewFrameInWindow.contains(point),
                  contentFrames.first?.contains(point) == true else { return false }
            // Dismissal owns this click: it must not also select a clip or activate the copy button beneath it.
            togglePreview()
            return true
        }
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
            listNavigation.cursor = 0
            // Settle the screen before this panel takes keyboard focus, and take the settings as they are now. They
            // come before the session opens: the frequent wing leaves out the newest clips the band shows whole beside
            // it as it opens.
            visibleFrame = fixedVisibleFrame ?? Self.workingScreen()?.visibleFrame ?? visibleFrame
            metrics = Self.metrics(for: preferences, visibleWidth: visibleFrame.width)
            strip.ticksEnabled = preferences.trackpadTicks
            state.restoreKeepsLineBreaks(preferences.keepsLineBreaks)
            // The app in front is recorded as the paste target before this panel shows (decision 1). How many of the
            // newest clips the band shows whole depends on how many frequent clips stand before them.
            let metrics = metrics
            state.open(frequentWingFirstScreen: preferences.showsFrequentClips
                ? { StripLayout.recentShownWhole(metrics, frequentCount: $0) } : nil)
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
        textColumnEndings.reset()
        translationColumnEndings.reset()
        state.close()
        // The undo stack is the showing's: a move stays in Recently Deleted, where the library recovers it.
        window?.undoManager?.removeAllActions()
        undoableMoves = []
        lastTextCommandDelete = nil
        changeCount = 0
        lastTyping = 0
    }

    func toggle() { isSessionOpen || closingOnceReturnIsUp != nil ? close() : show() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }

    /// A file-permission sheet temporarily owns the keys while keeping this
    /// preview alive. Unrelated focus changes still end the quick-access session.
    func windowDidResignKey(_ notification: Notification) {
        guard !isHiddenForPaste, window?.attachedSheet == nil else { return }
        close()
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? QuickAccessSearchField) === searchField ? fieldEditor : nil
    }

    /// The frame sizes for the card size Settings chose on a screen `visibleWidth` wide, with room around the cards for
    /// the selected card as Settings enlarges it, and below them for the frequent wing's icons while Settings shows the
    /// frequent clips. The panel takes them only as it is made and as it opens, so the band keeps its size while it is
    /// open and a change in Settings shows the next time it opens.
    private static func metrics(for preferences: QuickAccessPreferences, visibleWidth: CGFloat) -> StripMetrics {
        StripLayout.metrics(for: preferences.cardSize, visibleWidth: visibleWidth,
                            showsFrequentClips: preferences.showsFrequentClips, style: preferences.stripStyle)
    }

    /// The main screen, or the one under the pointer when there is none.
    private static func workingScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.screens.first
    }

    private func connect() {
        searchField.onQueryChange = { [weak self] in
            if let self, !self.undoingTyping {
                self.changeCount += 1
                self.lastTyping = self.changeCount
            }
            self?.state.setQuery($0)
            self?.update()
        }
        searchField.onType = { [weak self] in self?.searchTyped() }
        searchField.onCommand = { [weak self] in self?.perform($0) }
        searchField.onEscape = { [weak self] in self?.applyEscape($0) }
        searchField.escapeContext = { [weak self] in self?.escapeContext ?? QuickAccessEscapeContext() }
        state.announce = { [weak self] in self?.announce($0) }
        toolbar.search.onUnfold = { [weak self] in self?.unfoldSearch() }
        toolbar.search.onClear = { [weak self] in self?.clearSearchText() }
        listNavigation.onCommand = { [weak self] in self?.perform($0) }
        listNavigation.onChoose = { [weak self] in self?.chooseList($0) }
        filterButton.onCommand = { [weak self] in self?.perform($0) }
        filterButton.onOpen = { [weak self] in self?.showFilterMenu() }
        toolbar.copyHint.target = self
        toolbar.copyHint.action = #selector(copyFromToolbar)
        toolbar.moreButton.target = self
        toolbar.moreButton.action = #selector(showMoreMenu)
        strip.onSelect = { [weak self] in
            self?.state.select($0)
            self?.update()
        }
        strip.onCommand = { [weak self] in self?.perform($0) }
        strip.onActivate = { [weak self] in self?.activate($0, plainText: $1) }
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
        if toolbar.search.isExpanded != wasExpanded, let editor = searchField.currentEditor() as? NSTextView {
            // The field has moved and changed size, so an input method's candidates move with it.
            fieldCharactersMoved(editor)
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
        let notice = captureNotice()
        // VoiceOver hears a notice that appears or changes while the panel is open. One already there as it opens is
        // only shown: it would be read each time the panel opens.
        if isSessionOpen, let notice, notice != toolbar.captureNotice { announce(notice) }
        toolbar.captureNotice = notice
        // And why a recognition that just ended left the text column without text.
        let textColumn = state.textColumnRef.flatMap { ref in
            state.textColumn.map { (ref: ref, ending: state.textColumnEnding, words: $0.endingWords, isRead: $0.isRead) }
        }
        if let words = textColumnEndings.words(for: textColumn, isOpen: isSessionOpen) { announce(words) }
        // And how a translation that just ended left its column.
        let translationColumn = state.translationColumnRef.flatMap { ref in
            state.translationColumn.map {
                (ref: ref, ending: state.translationColumnEnding, words: $0.endingWords, isRead: $0.isRead)
            }
        }
        if let words = translationColumnEndings.words(for: translationColumn, isOpen: isSessionOpen) {
            announce(words)
        }
        toolbar.reservedNotes = state.possibleActions.map {
            .action(title: $0.primaryTitle, enabled: true, hint: $0.hint)
        }
        listNavigation.queryIsEmpty = state.query.isEmpty
        listNavigation.show(list: state.list, collections: state.collections, unavailable: state.collectionsUnavailable)
        filterButton.queryIsEmpty = state.query.isEmpty
        filterButton.show(favoritesOnly: state.favoritesOnly, kinds: state.kinds)
        toolbar.search.setPrompt(Self.searchPrompt(for: state.list, collectionName: state.collectionName))
        let showsNewList = showsNewListPage()
        strip.queryIsEmpty = state.query.isEmpty
        strip.dimsSideFrames = hasCard
        if state.phase != .loading { oldestIsLoaded = state.selection.isComplete && !state.hasMoreRows }
        let colors = collectionColors
        // What each image's card says of its text, and each text's card of its translation, read here so that the
        // cards follow the jobs.
        let textMark = state.textMarker()
        let textMarks = Dictionary(state.selection.rows.compactMap { row in textMark(row).map { (row.ref, $0) } },
                                   uniquingKeysWith: { first, _ in first })
        let translationMark = state.translationMarker()
        let translationMarks = Dictionary(
            state.selection.rows.compactMap { row in translationMark(row).map { (row.ref, $0) } },
            uniquingKeysWith: { first, _ in first })
        strip.show(state.selection.rows, selection: state.selection.selectedID, details: state.details,
                   metrics: metrics, applicationNames: applicationNames, oldestIsLoaded: oldestIsLoaded,
                   collections: cardCollections, collectionColors: colors, slides: !showsNewList,
                   textMarks: textMarks, translationMarks: translationMarks)
        glow.show(selectedCardGlow(collectionColors: colors))
    }

    /// Every collection's colour, which a snippet's card in it takes as its accent, whatever list is shown.
    private var collectionColors: [CollectionID: String] {
        Dictionary(state.collections.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
    }

    /// The light behind the selected card where the strip rests it, in the card's own accent, as the strip works it
    /// out for the card: the same collection colours and the same icon. None without a selected card, as in the empty
    /// state, or for a card without an accent.
    private func selectedCardGlow(collectionColors: [CollectionID: String]) -> QuickAccessGlow? {
        guard let row = state.selection.selectedRow, let card = strip.selectionAnchorFrame else { return nil }
        let tint = row.sourceApp.map { HeaderTint.tint(forIconOf: $0, icon: applicationNames.icon(for: $0)) }
        // The strip is as wide as the band and starts at its left end, so the card's middle lies as far into both.
        return QuickAccessGlow.make(row: row, accent: CardAccent(row: row, collectionColors: collectionColors, tint: tint),
                                    cardMidX: card.midX, metrics: metrics)
    }

    /// The collections the cards may name: every one but the one whose list is shown, which every card there is in.
    private var cardCollections: [CollectionID: CollectionSummary] {
        Dictionary(uniqueKeysWithValues: state.collections.filter { state.list != .collection($0.id) }.map { ($0.id, $0) })
    }

    /// What the toolbar's right end says. A refused action's reason answers what was just done, so it comes first;
    /// then what Save as Snippet, or its undo, came to for the selected clip; then a status over clips on screen; then,
    /// with a clip selected, what Return does, under the name the session gives it, with why it only copies when the
    /// user can do something about that. With no clips the empty state says it all. An index that is rebuilding is told
    /// after the filters, and leaves Return's hint in place.
    private var toolbarNote: QuickAccessToolbar.Note {
        if let failure = state.failure { return .failure(failure.message) }
        if let message = state.saveMessage { return .status(message) }
        if !state.selection.rows.isEmpty,
           let line = QuickAccessStatus.line(selectionLost: state.selection.selectionLost, phase: state.phase,
                                             isComplete: state.selection.isComplete) {
            return .status(line)
        }
        guard state.selection.selection != nil else { return .none }
        let actions = state.actions
        // While a command waits on the review card, only the card confirms it.
        return .action(title: actions.primaryTitle, enabled: state.actionTarget != nil && state.commandReview == nil,
                       hint: actions.hint)
    }

    private var hasCard: Bool { state.isPreviewExpanded || state.commandReview != nil }

    /// The preview overlays the stationary band. A command review, and the preview split for a column beside it, stand
    /// above the band instead, which moves down where they need the room. The transparent host expands to fit the
    /// content without animating.
    private func layoutPanel() {
        guard let window, let hosting else { return }
        var band = StripLayout.bandFrame(metrics, in: visibleFrame)
        var preview: NSRect?
        if state.commandReview != nil {
            let placed = StripLayout.previewLayout(band: band, in: visibleFrame)
            band = placed.band
            preview = placed.preview
        } else if state.isPreviewSplit {
            let placed = StripLayout.splitLayout(band: band, in: visibleFrame)
            band = placed.band
            preview = placed.preview
        } else if state.isPreviewExpanded {
            preview = StripLayout.previewOverlayFrame(band: band, in: visibleFrame)
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
        previewFrameInWindow = preview.map { NSRect(
            x: bandInWindow.midX - $0.width / 2, y: bandInWindow.maxY + previewGap, width: $0.width,
            height: $0.height
        ) }
        contentFrames = [bandInWindow] + (previewFrameInWindow.map { [$0] } ?? [])
    }

    private func bandView(_ layout: QuickAccessBandView.Layout) -> QuickAccessBandView {
        QuickAccessBandView(
            layout: layout, state: state, toolbar: toolbar, strip: strip, glow: glow, applicationNames: applicationNames,
            actions: QuickAccessBandView.Actions(previewCommand: { [weak self] in self?.perform($0) },
                                                 confirmCommand: { [weak self] in self?.confirmFromCard() },
                                                 cancelCommandReview: { [weak self] in self?.cancelFromCard() },
                                                 copyText: { [weak self] in self?.copyShownText($0) })
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
        case .moveListCursor(let offset):
            listNavigation.moveCursor(by: offset)
        case .chooseListAtCursor:
            chooseList(listNavigation.stopUnderCursor)
        case .openFilterMenu:
            showFilterMenu()
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
        case .showTextInImage:
            let focus = currentFocus
            let wasShowing = state.textColumnRef != nil
            state.showTextInImage()
            update()
            keepFocus(focus)
            // VoiceOver hears the column once, as it opens.
            if !wasShowing, state.textColumnRef != nil { announce("\(TextColumnWords.title), on this Mac") }
        case .closeResultColumn:
            let focus = currentFocus
            state.closeResultColumn()
            update()
            keepFocus(focus)
        case .extractText:
            state.extractText()
        case .stopTextRecognition:
            state.stopTextRecognition()
        case .toggleKeepLineBreaks:
            preferences.keepsLineBreaks = state.toggleKeepLineBreaks()
        case .copyText:
            copyShownText(nil)
        case .saveTextAsSnippet:
            saveShownText()
        case .showTranslation:
            let focus = currentFocus
            let wasShowing = state.translationColumnRef != nil
            state.showTranslation()
            update()
            keepFocus(focus)
            // VoiceOver hears the column once, as it opens.
            if !wasShowing, state.translationColumnRef != nil {
                announce("\(TranslationColumnWords.title), on this Mac")
            }
        case .translate(let language):
            state.translate(into: language.map(Locale.Language.init(identifier:)))
        case .stopTranslation:
            state.stopTranslation()
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
        case .lists:
            window?.makeFirstResponder(listNavigation)
        case .filterButton:
            window?.makeFirstResponder(filterButton)
        case .results, .preview:
            window?.makeFirstResponder(strip)
        }
    }

    // MARK: Lists

    /// A segment, a chip or More, by a click or by Space at the cursor. A chip chosen again goes back to all the
    /// snippets; More opens the collections that did not fit.
    private func chooseList(_ stop: QuickAccessListStop) {
        switch stop {
        case .all: switchList(to: .all)
        case .snippets: switchList(to: .snippets)
        case .collection(let id): switchList(to: state.list == .collection(id) ? .snippets : .collection(id))
        case .more: showMoreCollectionsMenu()
        }
    }

    /// Lists `list` and leaves the keys where they are.
    private func switchList(to list: QuickAccessList) {
        guard list != state.list else { return }
        let focus = currentFocus
        state.setList(list)
        update()
        keepFocus(focus)
    }

    /// ⌘[ and ⌘]: the list before or after this one, from All to Snippets and each collection in the sidebar's order.
    /// At either end nothing happens.
    private func stepList(by offset: Int) {
        let order = [QuickAccessList.all, .snippets] + state.collections.map { .collection($0.id) }
        // A collection that could not be read again is no longer in the order; stepping from it goes to Snippets.
        let index = order.firstIndex(of: state.list)
        let target = index.map { order[min(max($0 + offset, 0), order.count - 1)] } ?? .snippets
        guard target != state.list else { return }
        switchList(to: target)
        // With the keys on the lists, the cursor goes with the list, so that Space does not undo the step.
        listNavigation.moveCursor(to: state.list)
    }

    /// ⌘L: the keys go to the lists, the cursor on the list shown.
    private func focusLists() {
        window?.makeFirstResponder(listNavigation)
        listNavigation.moveCursor(to: state.list)
    }

    /// Favorites Only, then All Types and each type, each on or off. Favorites Only needs the index, and is off while
    /// it cannot answer.
    private func showFilterMenu() {
        let menu = NSMenu(title: "Filter")
        menu.autoenablesItems = false
        let favorites = ClosureMenuItem("Favorites Only") { [weak self] in self?.changeFilters { $0.toggleFavoritesOnly() } }
        favorites.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        favorites.state = state.favoritesOnly ? .on : .off
        if state.indexNotice != nil, !state.favoritesOnly {
            favorites.isEnabled = false
            favorites.toolTip = "Needs the search index"
        }
        menu.addItem(favorites)
        menu.addItem(.separator())
        let all = ClosureMenuItem("All Types") { [weak self] in self?.changeFilters { $0.clearKinds() } }
        all.state = state.kinds.isEmpty ? .on : .off
        menu.addItem(all)
        for kind in ContentKind.filters {
            let item = ClosureMenuItem(kind.filterTitle) { [weak self] in self?.changeFilters { $0.toggleKind(kind) } }
            item.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            item.state = state.kinds.contains(kind) ? .on : .off
            menu.addItem(item)
        }
        let button = filterButton
        presentToolbarMenu(menu, NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), button)
    }

    /// The collections whose chips did not fit, the one listed checked.
    private func showMoreCollectionsMenu() {
        let hidden = listNavigation.hiddenCollections
        guard !hidden.isEmpty else { return }
        let menu = NSMenu(title: "More Collections")
        menu.autoenablesItems = false
        for collection in hidden {
            let item = ClosureMenuItem(collection.name) { [weak self] in
                self?.switchList(to: .collection(collection.id))
            }
            item.image = ActionMenu.dot(collection.color)
            item.state = state.list == .collection(collection.id) ? .on : .off
            menu.addItem(item)
        }
        let chip = listNavigation.moreChip
        presentToolbarMenu(menu, NSPoint(x: 0, y: chip.isFlipped ? chip.bounds.maxY + 4 : -4), chip)
    }

    /// A change of filter from the menu, which leaves the keys where they are.
    private func changeFilters(_ change: (QuickAccessState) -> Void) {
        let focus = currentFocus
        change(state)
        update()
        keepFocus(focus)
    }

    /// The search's prompt for a list.
    private static func searchPrompt(for list: QuickAccessList, collectionName: String?) -> String {
        switch list {
        case .all: "Search Clips and Snippets"
        case .snippets: "Search Snippets"
        case .collection: "Search “\(collectionName ?? "Collection")”"
        }
    }

    /// Whether this update shows the first page of a list just chosen. Its cards take the last list's place where they
    /// stand, without sliding, fading in over them in 0.15 s; with Reduce Motion they change at once.
    private func showsNewListPage() -> Bool {
        if state.list != listShown {
            listShown = state.list
            awaitsNewListPage = window?.isVisible == true
        }
        guard awaitsNewListPage, state.phase != .loading else { return false }
        awaitsNewListPage = false
        if !reducesMotion() {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            // Core Animation keeps a transition under this key whatever key it is given.
            strip.layer?.add(fade, forKey: kCATransition)
        }
        return true
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
        if responder === listNavigation { return .lists }
        if responder === filterButton { return .filterButton }
        guard let editor = responder as? NSTextView else { return nil }
        if editor.isFieldEditor { return editor.delegate === searchField ? .searchField : nil }
        // Besides the field's editor, the panel's text views are the preview's: its own text, a review's command, or
        // the text recognized in an image.
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
        case .lists?:
            if window.firstResponder !== listNavigation { window.makeFirstResponder(listNavigation) }
        case .filterButton?:
            if window.firstResponder !== filterButton { window.makeFirstResponder(filterButton) }
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

    /// Return, ⇧Return, a double click and the toolbar's button: the clip selected when the key is pressed, delivered as
    /// the toolbar says (decision 2). The action finishes later. While a command waits on the review card they do
    /// nothing: only ⌘Return and the card's button confirm it.
    ///
    /// A paste waits for Return and keypad Enter to come up, for up to `returnReleaseWait`, and then goes ahead: with
    /// one still down, the paste service copies instead (`.returnHeld`), and the panel stays until the key is up. A
    /// panel closed meanwhile does nothing; one shown again meanwhile has a session of its own, which the paste service
    /// refuses the old action for.
    ///
    /// `guessesReturn` says that the menu choice that asks for the action may have left Return down unseen: the action
    /// takes Return for down (`returnMayBeDown`) until the guess goes, at the latest when the action ends with the
    /// panel still open, as when a review card shows, the clip is refused or the selection has moved on.
    private func act(_ mode: PasteMode, guessesReturn: Bool = false, subject: ActionSubject = .asReturn) {
        guard state.commandReview == nil else { return }
        guard let target = target(for: subject) else {
            // The text beside the image has nothing to take yet; the image is not taken in its place.
            if subject != .clip, state.resultColumnRef != nil { NSSound.beep() }
            return
        }
        if guessesReturn { heldReturnKeys.insert(Self.returnMayBeDown) }
        let delivery = state.preferredDelivery
        Task {
            if delivery == .paste, !heldReturnKeys.isEmpty, await returnKeysComeUp() == nil { return }
            await state.act(on: target, mode: mode, delivery: delivery)
            if guessesReturn, isSessionOpen { forgetGuessedReturn() }
        }
    }

    /// What an action takes: what Return takes now, which is the text beside an image while the preview shows it; the
    /// clip itself, as a double-click on its card or a menu made for the clip offers it; or the text, as a menu made
    /// while it showed offers it, and nothing once it no longer shows.
    private enum ActionSubject { case asReturn, clip, text }

    private func target(for subject: ActionSubject) -> QuickAccessState.CopyTarget? {
        switch subject {
        case .asReturn: state.actionTarget
        case .clip: state.copyTarget
        case .text: state.actionTarget.flatMap { $0.derivedText == nil ? nil : $0 }
        }
    }

    /// A double click on a clip does what Return does with that clip, or ⇧Return with ⇧, once the clip it chose is the
    /// selected one: the state may have refused to select it, and then nothing acts. It takes the clip, not text
    /// shown beside it.
    private func activate(_ row: QuickAccessRow.ID, plainText: Bool) {
        guard state.selection.selectedID == row else { return }
        act(plainText ? .plainText : .original, subject: .clip)
    }

    /// The menu's copy that never pastes: "Copy", or "Copy As-Is" in a terminal's session, as the clip's own actions
    /// name it.
    private func copyOnly() {
        guard let target = state.copyTarget else { return }
        let mode = state.actions(for: target.ref).copyOnlyMode
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

    /// The ⋯ menu, below its button. Open Library and Settings… close the panel, then open what they name.
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
    /// where the newest clip rests as the strip opens, past the divider or, without a frequent wing, at the left dock;
    /// with no clips, beside the middle of the strip.
    func openActions() {
        let size = metrics.frameSize
        let centre = NSRect(x: strip.bounds.midX - size.width / 2, y: strip.bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        presentActionMenu(actionMenu(for: state.selection.selectedID),
                          ActionMenu.anchor(beside: strip.selectionAnchorFrame ?? centre, in: strip), strip)
    }

    /// The actions for one row: the selected one for ⌘K, the one under the pointer for a right-click, named for its
    /// clip. A row other than the selected one is selected before its action runs, so the action is for the row
    /// clicked; one that left the list while the menu was open gets no action at all, never another row's. A clip
    /// listed in both wings is two rows, and the menu is for the one it was opened on. Only the selected row's menu
    /// offers to undo its save: selecting another row lets that save go.
    private func actionMenu(for id: QuickAccessRow.ID?) -> NSMenu {
        let row = id.flatMap { id in state.selection.rows.first { $0.id == id } }
        let canUndoSave = state.canUndoSave && id == state.selection.selectedID
        // The text beside the selected image, while the preview shows it.
        let isSelected = id != nil && id == state.selection.selectedID
        let showsText = isSelected && state.textColumnRef != nil
        var textInImage = ActionMenu.TextInImage(isOffered: row?.kind == .image && state.canRecognizeText)
        if showsText, let column = state.textColumn {
            textInImage.column = ActionMenu.TextInImage.Column(
                canTake: state.actionTarget != nil, hasText: state.textColumnText != nil,
                keepsLineBreaks: state.isKeepLineBreaksOn, canStop: state.canStopTextRecognition,
                canExtract: column == .notStarted || column.isFailed, failed: column.isFailed)
        }
        // And the translation beside the selected text.
        let showsTranslation = isSelected && state.translationColumnRef != nil
        var translation = ActionMenu.Translation(isOffered: row?.kind == .text && state.canRecognizeText)
        if showsTranslation, let column = state.translationColumn {
            translation.column = ActionMenu.Translation.Column(
                canTake: state.actionTarget != nil, hasText: state.translationColumnText != nil,
                canStop: state.canStopTranslation, canTranslate: column == .notStarted || column.offersTryAgain,
                failed: column.offersTryAgain)
        }
        let showsResult = showsText || showsTranslation
        return ActionMenu.make(actions: showsResult ? state.actions : state.actions(for: id?.ref), row: row,
                               canAct: state.selection.executableSelection != nil,
                               isReviewing: state.commandReview != nil,
                               isPreviewExpanded: state.isPreviewExpanded,
                               canUndoSave: canUndoSave, collections: state.collections,
                               canMoveToRecentlyDeleted: state.canMoveToRecentlyDeleted,
                               listedCollection: state.listedCollection(of: row),
                               canUndoMoveToRecentlyDeleted: canUndoMoveToRecentlyDeleted,
                               textInImage: textInImage, translation: translation) { [weak self] command in
            guard let self else { return }
            let returnMayBeDown = followMenuChoice()
            if let id, id != state.selection.selectedID {
                state.select(id)
                update()
                guard state.selection.selectedID == id else { return }
            }
            switch command {
            // What the menu named when it was made: the text or the translation that showed, or the clip.
            case .primary: act(.original, guessesReturn: returnMayBeDown, subject: showsResult ? .text : .clip)
            case .plainText: act(.plainText, guessesReturn: returnMayBeDown, subject: .clip)
            case .copyOnly: copyOnly()
            case .togglePreview: togglePreview()
            case .saveSnippet: saveSelectedClipAsSnippet()
            case .saveToCollection(let collection): saveSelected(into: collection)
            case .undoSave: undoSave()
            case .toggleFavorite: toggleFavoriteOfSelected()
            case .showInLibrary: openSelectedInLibraryFromMenu()
            case .newSnippet: newSnippetFromMenu()
            case .enableDirectPaste: enableDirectPaste()
            case .undoMoveToRecentlyDeleted: undoLastMove()
            case .removeFromCollection: removeSelectedFromListedCollection()
            case .moveToRecentlyDeleted: moveSelectedToRecentlyDeleted()
            case .showTextInImage: perform(.showTextInImage)
            case .extractText: perform(.extractText)
            case .copyText: perform(.copyText)
            case .saveTextAsSnippet: perform(.saveTextAsSnippet)
            case .toggleKeepLineBreaks: perform(.toggleKeepLineBreaks)
            case .stopTextRecognition: perform(.stopTextRecognition)
            case .showTranslation: perform(.showTranslation)
            case .translate: perform(.translate(into: nil))
            case .stopTranslation: perform(.stopTranslation)
            }
        }
    }

    // MARK: Recently Deleted

    /// ⌘⌫ and the actions menu's Move to Recently Deleted. The card leaves the strip at once and the keys stay where
    /// they were, or go to the search field once no card is left. The move joins the panel's undo as it is asked for,
    /// so ⌘Z undoes moves in the order they were asked for, one still under way included; one the library refuses
    /// leaves the undo again.
    private func moveSelectedToRecentlyDeleted() {
        guard let target = state.copyTarget, let moving = state.moveToRecentlyDeleted(target) else { return }
        let focus = currentFocus
        update()
        keepFocus(focus)
        changeCount += 1
        let move = MoveUndo(moving, change: changeCount)
        registerUndo(of: move)
        Task {
            guard await moving.value == nil else { return }
            window?.undoManager?.removeAllActions(withTarget: move)
            undoableMoves.removeAll { $0 === move }
        }
    }

    /// Undo Move to Recently Deleted, on the panel window's undo stack. The search field keeps its typing on an undo stack
    /// of its own, so `undoFromKeyboard` decides which ⌘Z undoes. The undo manager holds its targets weakly, so the panel
    /// keeps the moves until the stack goes with the showing.
    private func registerUndo(of move: MoveUndo) {
        guard let undoManager = window?.undoManager else { return }
        undoableMoves.append(move)
        // A top-level group of its own, so each move is undone by itself however quickly the next key comes. Grouping
        // by event stays off while it is made: on, beginning a group would first open the event's group around it, and
        // the next move would join that one.
        let ownsGroup = undoManager.groupingLevel == 0
        let groupsByEvent = undoManager.groupsByEvent
        if ownsGroup {
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: move) { [weak self] move in self?.undo(move) }
        undoManager.setActionName(ActionMenu.moveToRecentlyDeletedName)
        if ownsGroup {
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupsByEvent
        }
    }

    /// Waits for the move, which may still be under way, and puts back what it took.
    private func undo(_ move: MoveUndo) {
        undoableMoves.removeAll { $0 === move }
        Task {
            guard let deletion = await move.moving.value, isSessionOpen,
                  await state.undoMoveToRecentlyDeleted(deletion), isSessionOpen else { return }
            let focus = currentFocus
            update()
            keepFocus(focus)
        }
    }

    /// Whether the panel's last undoable change is a move to Recently Deleted, which the actions menu then offers to
    /// undo.
    private var canUndoMoveToRecentlyDeleted: Bool {
        guard let undoManager = window?.undoManager else { return false }
        return undoManager.canUndo && undoManager.undoActionName == ActionMenu.moveToRecentlyDeletedName
    }

    /// The actions menu's Undo Move to Recently Deleted, and ⌘Z when it means the move: the last move undone.
    private func undoLastMove() {
        guard let undoManager = window?.undoManager, undoManager.canUndo, !undoableMoves.isEmpty else { return }
        undoManager.undo()
    }

    /// ⌘Z. The search field's typing and the moves to Recently Deleted are on two undo stacks, the field's own and the
    /// window's. While nothing has been typed in the field since the last move, or while the keys are away from it,
    /// ⌘Z undoes the move; after typing it undoes the field's edits, as Edit › Undo does, until there are none left, and
    /// then the moves.
    private func undoFromKeyboard() {
        let fieldCanUndo = currentFocus == .searchField && window?.firstResponder?.undoManager?.canUndo == true
        if let move = undoableMoves.last, !fieldCanUndo || move.change > lastTyping {
            undoLastMove()
        } else if fieldCanUndo {
            undoingTyping = true
            NSApp.sendAction(Selector(("undo:")), to: nil, from: self)
            undoingTyping = false
        }
    }

    /// The actions menu's Remove from “Prompts”, in that collection's list. The toolbar says it, and VoiceOver reads it.
    private func removeSelectedFromListedCollection() {
        guard let target = state.copyTarget else { return }
        let focus = currentFocus
        Task {
            await state.removeFromListedCollection(target)
            guard isSessionOpen else { return }
            update()
            keepFocus(focus)
            announceSaveMessage()
        }
    }

    /// ⌘S: the selected clip, or while the preview shows the text beside an image, that text. The toolbar shows what
    /// the save came to, and VoiceOver reads it.
    private func saveSelectedSnippet() {
        guard state.resultColumnRef != nil else { return saveSelectedClipAsSnippet() }
        saveShownText()
    }

    /// Save Text as Snippet, from ⌘S, the preview's bar or the menu: the text beside an image, and never the image in
    /// its place. With no whole text to keep, nothing is kept and nothing is said again.
    private func saveShownText() {
        Task {
            switch await state.saveTextAsSnippet() {
            case .nothingToSave: NSSound.beep()
            case .said(let message): if isSessionOpen { announce(message) }
            case .interrupted: break
            }
        }
    }

    /// The menu's Save as Snippet: the selected clip itself, whatever the preview shows beside it.
    private func saveSelectedClipAsSnippet() {
        guard let target = state.copyTarget else { return }
        Task {
            await state.saveSelection(target)
            announceSaveMessage()
        }
    }

    /// Copies the text beside an image, or `part` of it, and keeps the panel open; VoiceOver hears that it copied.
    private func copyShownText(_ part: String?) {
        if state.copyText(part) { announce("Copied") } else { NSSound.beep() }
    }

    /// ⇧⌘M's menu and the actions menu's Save to Collection or Add to Collection: the collection chosen. A collection
    /// that went while the menu was open is saved into by name no more: the state reads the collections again and
    /// says so.
    private func saveSelected(into id: CollectionID) {
        guard let target = state.copyTarget else { return }
        guard let collection = state.collections.first(where: { $0.id == id }) else {
            state.explainCollectionGone()
            return announceSaveMessage()
        }
        Task {
            await state.saveSelection(target, into: collection)
            announceSaveMessage()
        }
    }

    /// ⌘D and the actions menu's Add to Favorites or Remove from Favorites.
    private func toggleFavoriteOfSelected() {
        guard let target = state.copyTarget else { return }
        Task {
            await state.toggleFavoriteSelection(target)
            announceSaveMessage()
        }
    }

    /// ⇧⌘M: the collections, beside the selected card, where the actions menu opens. With none to choose, the toolbar
    /// says what it takes.
    private func showCollectionMenu() {
        guard let row = state.selection.selectedRow, state.selection.executableSelection != nil else { return }
        guard !state.collections.isEmpty else { return state.explainNoCollections() }
        let menu = NSMenu(title: row.facet == .memo ? "Add to Collection" : "Save to Collection")
        menu.autoenablesItems = false
        // The choice is for the card the menu opened beside, as the actions menu's are.
        let id = row.id
        let items = ActionMenu.collectionItems(collections: state.collections, row: row) { [weak self] collection in
            guard let self else { return }
            _ = followMenuChoice()
            if id != state.selection.selectedID {
                state.select(id)
                update()
                guard state.selection.selectedID == id else { return }
            }
            saveSelected(into: collection)
        }
        items.forEach(menu.addItem)
        let size = metrics.frameSize
        let centre = NSRect(x: strip.bounds.midX - size.width / 2, y: strip.bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
        presentActionMenu(menu, ActionMenu.anchor(beside: strip.selectionAnchorFrame ?? centre, in: strip), strip)
    }

    /// The menu's Undo Save as Snippet, which it offers only while the selected clip's save can be undone.
    private func undoSave() {
        Task {
            await state.undoSaveSelection()
            announceSaveMessage()
        }
    }

    /// Reads out what a save or its undo came to, as the toolbar now shows it, while the session that asked is still
    /// open: a closed or reopened panel has nothing to say about it.
    private func announceSaveMessage() {
        guard isSessionOpen, let message = state.saveMessage else { return }
        announce(message)
    }

    private func openSelectedInLibrary() {
        guard let ref = state.copyTarget?.ref else { return }
        onOpenInLibrary?(ref, showsSnippet(of: ref))
    }

    /// Whether Show in Library shows the snippet: for a snippet's card, and for a clip saved as one.
    private func showsSnippet(of ref: ContentRef) -> Bool {
        ref.facet == .memo || state.selection.rows.contains { $0.ref == ref && $0.savedAsMemo }
    }

    /// The collection a new snippet goes into: the one the panel lists, while it is still there.
    private var newSnippetCollection: CollectionID? {
        guard case .collection(let id) = state.list, state.collections.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    /// A menu item chosen with Return must keep the keys until that Return is up, so its repeats cannot reach the
    /// library editor. The content identity is captured before the wait: moving the strip meanwhile cannot redirect
    /// the action to a different clip.
    private func openSelectedInLibraryFromMenu() {
        guard let ref = state.copyTarget?.ref else { return }
        let showsSnippet = showsSnippet(of: ref)
        handOverWhenChoosingReturnIsUp { [weak self] in self?.onOpenInLibrary?(ref, showsSnippet) }
    }

    private func newSnippetFromMenu() {
        let collection = newSnippetCollection
        handOverWhenChoosingReturnIsUp { [weak self] in self?.onNewSnippet?(collection) }
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
        handOverWhenChoosingReturnIsUp { [weak self] in self?.handOverEnableDirectPaste() }
    }

    /// A Return or keypad Enter the panel actually saw choose a menu item fences a handoff to another interface. A
    /// pointer choice, shortcut, or accessibility action with no observed Return hands over immediately. If the key
    /// stays down past `returnReleaseWait`, the choice lapses; a later key-up cannot revive it.
    private func handOverWhenChoosingReturnIsUp(_ handoff: @escaping @MainActor @Sendable () -> Void) {
        guard heldReturnKeys.contains(where: { $0 != Self.returnMayBeDown }) else { return handoff() }
        Task {
            guard await returnKeysComeUp() == true else { return }
            // A handoff starts on a turn of its own, outside the menu item's action.
            DispatchQueue.main.async(execute: handoff)
        }
    }

    private func handOverEnableDirectPaste() {
        close()
        onEnableDirectPaste?()
    }

    // MARK: Escape

    /// Native controls and embedded previews may consume Escape before the responder chain reaches the panel.
    /// Route it here while preserving input-method and sheet ownership. A held key cannot peel a second layer.
    private func handlePreviewKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == kVK_Escape,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              window?.attachedSheet == nil,
              (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        if event.isARepeat { return true }
        guard state.isPreviewExpanded || state.commandReview != nil else { return false }
        escape()
        return true
    }

    /// What Escape has to peel, the same for the search field and for the strip, the preview and the review card.
    private var escapeContext: QuickAccessEscapeContext {
        QuickAccessEscapeContext(hasCommandReview: state.commandReview != nil,
                                 hasResultColumn: state.isPreviewSplit,
                                 isPreviewExpanded: state.isPreviewExpanded,
                                 hasFilters: !state.kinds.isEmpty || state.favoritesOnly,
                                 hasList: state.hasList,
                                 isSearchExpanded: state.isSearchExpanded)
    }

    /// Escape from the strip, the filters, the preview or the review card; the search field peels its own layers first.
    /// A panel that waits for Return after its action has nothing left to peel, and closes.
    private func escape() {
        guard closingOnceReturnIsUp == nil else { return close() }
        let context = escapeContext
        let action = QuickAccessEscapePolicy.action(hasMarkedText: false, hasCommandReview: context.hasCommandReview,
                                                    hasResultColumn: context.hasResultColumn,
                                                    isPreviewExpanded: context.isPreviewExpanded,
                                                    hasQuery: !searchField.stringValue.isEmpty,
                                                    hasFilters: context.hasFilters, hasList: context.hasList,
                                                    isSearchExpanded: context.isSearchExpanded)
        switch action {
        case .closePanel:
            close()
        case .clearQuery:
            searchField.stringValue = ""
            applyEscape(action)
        case .cancelComposition, .cancelCommandReview, .closeResultColumn, .collapsePreview, .foldSearch:
            applyEscape(action)
        }
    }

    private func applyEscape(_ action: QuickAccessEscapeAction) {
        guard closingOnceReturnIsUp == nil else { return close() }
        switch action {
        case .cancelCommandReview:
            cancelCommandReview()
        case .closeResultColumn:
            perform(.closeResultColumn)
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
        // Caps Lock, like the keypad's and the function key's flags, is no modifier a shortcut asks for. ⇧⌘M is the one
        // shortcut here with Shift.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isShiftCommandM = modifiers == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "m"
        let isShiftCommandT = modifiers == [.command, .shift] && event.charactersIgnoringModifiers?.lowercased() == "t"
        // ⌘. comes with Shift where "." needs it.
        let isCommandPeriod = event.charactersIgnoringModifiers == "."
            && (modifiers == .command || modifiers == [.command, .shift])
        guard isSessionOpen, modifiers == .command || isShiftCommandM || isShiftCommandT || isCommandPeriod else {
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
        let isComposing = (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        // ⌘⌫ and ⌘Z never go on to the menu bar: its Item › Move to Recently Deleted and Edit › Undo would act on the
        // library window behind the panel. What the panel leaves to text goes to that text as a key.
        //
        // ⌘⌫, known by the key, moves the selected clip to Recently Deleted. Text in the search field, and a
        // composition, keep it: it deletes to the start of the line there. Pressed again just after it emptied the
        // field, it still means the text, so a query cleared with two presses never takes a clip.
        if Int(event.keyCode) == kVK_Delete, modifiers == .command {
            // Held down, it has acted already: its repeats would take one clip after another.
            guard !event.isARepeat else { return true }
            let focus = currentFocus
            let clearedTextJustNow = lastTextCommandDelete.map { event.timestamp - $0 < Self.textCommandDeleteGrace }
                == true
            if QuickAccessKeyRouter.commandDeleteTakesSelection(focus: focus,
                                                                queryIsEmpty: searchField.stringValue.isEmpty,
                                                                hasMarkedText: isComposing),
               !(focus == .searchField && clearedTextJustNow) {
                lastTextCommandDelete = nil
                moveSelectedToRecentlyDeleted()
            } else {
                lastTextCommandDelete = event.timestamp
                window?.firstResponder?.keyDown(with: event)
            }
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // ⇧⌘T shows the text in the selected image beside its preview. It never goes on to the menu bar; a composition
        // keeps it, and held down it has acted already.
        if isShiftCommandT {
            if !isComposing, !event.isARepeat, state.offersTextInImage { perform(.showTextInImage) }
            return true
        }
        // ⌘T shows the translation of the selected text beside its preview, in the same way.
        if key == "t", modifiers == .command {
            if !isComposing, !event.isARepeat, state.commandReview == nil, state.offersTranslation {
                perform(.showTranslation)
            }
            return true
        }
        // ⌘. stops the recognition beside the preview. While the preview is split, every ⌘. is taken here, so that one
        // pressed just as the recognition ends never becomes Escape. Elsewhere it becomes Escape, once: held down, ⌘.
        // has acted already, as Escape or as Stop, and its repeats peel nothing.
        if isCommandPeriod, !isComposing {
            if event.isARepeat { return true }
            guard state.isPreviewSplit else { return false }
            if state.canStopTextRecognition { perform(.stopTextRecognition) }
            if state.canStopTranslation { perform(.stopTranslation) }
            return true
        }
        // ⌘C while the preview shows the text beside an image copies that text: what is selected in it, or with the
        // keys elsewhere, all of it. A selection in another text, the search field's or a review's command, is that
        // text's to copy, and so is everything while a review shows. The panel stays. Held down, it has copied already.
        if key == "c", modifiers == .command, !isComposing, state.resultColumnRef != nil, state.commandReview == nil {
            if event.isARepeat { return true }
            let responder = window?.firstResponder
            if let text = responder as? GeneratedTextView {
                text.copy(nil)
                return true
            }
            if let other = responder as? NSTextView, other.selectedRange().length > 0 { return false }
            copyShownText(nil)
            return true
        }
        // ⌘Z undoes a move to Recently Deleted or the search field's typing, whichever `undoFromKeyboard` finds; a
        // composition has it as a key.
        if key == "z", modifiers == .command {
            if isComposing { window?.firstResponder?.keyDown(with: event) } else { undoFromKeyboard() }
            return true
        }
        // Library commands must not interrupt composition. Existing panel
        // commands keep their own composition behavior; in particular, Command-F
        // in the active search editor leaves its marked text and caret intact.
        // A list does not change under a composition either.
        if ["s", "e", "n", "[", "]", "l", "d"].contains(key) || isShiftCommandM,
           (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return true }
        // Held down, ⌘S, ⌘E, ⌘N, ⌘L, ⌘D and ⇧⌘M have acted already: their repeats are taken and do nothing, as ⌘Y's
        // are; a held ⌘D would turn the favorite mark over and back. A save
        // again would find the clip already in Snippets and let the first save's undo go. ⌘[ and ⌘] step on while held,
        // as the arrows do.
        if ["s", "e", "n", "l", "d"].contains(key) || isShiftCommandM, event.isARepeat { return true }
        if isShiftCommandM {
            showCollectionMenu()
            return true
        }
        switch key {
        case "s":
            saveSelectedSnippet()
            return true
        case "e":
            openSelectedInLibrary()
            return true
        case "n":
            onNewSnippet?(newSnippetCollection)
            return true
        case "d":
            toggleFavoriteOfSelected()
            return true
        case "f":
            unfoldSearch()
            return true
        case "[":
            stepList(by: -1)
            return true
        case "]":
            stepList(by: 1)
            return true
        case "l":
            focusLists()
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

/// One move to Recently Deleted on the panel's undo stack: its undo waits for the move, and undoes it if it went.
@MainActor
private final class MoveUndo {
    let moving: Task<QuickAccessDeletion?, Never>
    /// The panel's change count as the move was asked for.
    let change: Int

    init(_ moving: Task<QuickAccessDeletion?, Never>, change: Int) {
        self.moving = moving
        self.change = change
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
    var onContentMouseDown: ((NSPoint) -> Bool)?
    var onPreviewKeyDown: ((NSEvent) -> Bool)?

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
           onContentMouseDown?(event.locationInWindow) == true { return }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           isOutsideContent?(event.locationInWindow) == true {
            onClickOutside?()
            return
        }
        if event.type == .keyDown || event.type == .keyUp { onKeyEvent?(event) }
        if event.type == .keyDown, onPreviewKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}
