import AppKit

/// One place the list cursor can rest on: a segment, a collection's chip, or More.
enum QuickAccessListStop: Equatable {
    case all, snippets, collection(CollectionID), more
}

/// The toolbar's left end: the All | Snippets switch and, under Snippets, a chip for each collection in the sidebar's
/// order, with those that do not fit behind More. It is one stop of the panel's Tab round. With the keys, ← and → move a
/// cursor along the segments and the chips, ringed as focus, and Space chooses the one under it. A click chooses
/// directly and leaves the keys where they are.
@MainActor
final class QuickAccessListNavigation: NSView {
    static let height: CGFloat = 28
    /// Between the switch and the first chip.
    static let chipsInset: CGFloat = 12
    static let chipGap: CGFloat = 6

    let segments = QuickAccessListSegments()
    /// The chips, More and the notice that the collections could not be read, as one group of choices.
    let chipsView = QuickAccessChipsView()
    private(set) var chips: [QuickAccessCollectionChip] = []
    let moreChip = QuickAccessMoreChip()
    let unavailableChip = QuickAccessCollectionChip(title: "Collections unavailable", color: nil)
    private(set) var list: QuickAccessList = .all
    private(set) var collections: [CollectionSummary] = []
    private(set) var collectionsUnavailable = false
    /// How many chips fit beside the switch; the collections after them are behind More.
    private(set) var visibleChipCount = 0
    private var moreFits = false
    private var unavailableFits = false
    /// The stop ← and → move and Space chooses: an index into `stops`.
    var cursor = 0 {
        didSet {
            noteFocusRingMaskChanged()
            // VoiceOver follows the cursor while the lists have the keys.
            if cursor != oldValue, window?.firstResponder === self, let view = cursorView {
                NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
            }
        }
    }
    /// A segment, a chip or More was clicked.
    var onChoose: ((QuickAccessListStop) -> Void)?
    var onCommand: ((QuickAccessCommand) -> Void)?
    /// What a key means here depends on the rest of the panel, which keeps this current.
    var queryIsEmpty = true
    /// The chips come and go in 0.15 s, or at once with Reduce Motion.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for (index, button) in segments.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(chooseSegment(_:))
        }
        segments.buttons[0].state = .on
        moreChip.target = self
        moreChip.action = #selector(chooseMore)
        unavailableChip.isEnabled = false
        unavailableChip.toolTip = "Close and reopen quick access to try again."
        unavailableChip.setAccessibilityRole(.staticText)
        chipsView.addSubview(moreChip)
        chipsView.addSubview(unavailableChip)
        chipsView.isHidden = true
        addSubview(segments)
        addSubview(chipsView)
        setAccessibilityElement(true)
        // A view is no control, so the element says it is enabled; VoiceOver would call it dimmed otherwise.
        setAccessibilityEnabled(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Lists")
        setAccessibilityIdentifier("QuickAccessListNavigation")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Chips are shown under Snippets and a collection's list, never under All.
    var showsChips: Bool { list != .all }

    /// The collections whose chips did not fit: More lists them.
    var hiddenCollections: [CollectionSummary] { Array(collections.dropFirst(visibleChipCount)) }

    /// Where the cursor can rest, left to right: the two segments, the chips shown, and More.
    var stops: [QuickAccessListStop] {
        var stops: [QuickAccessListStop] = [.all, .snippets]
        guard showsChips, !collectionsUnavailable else { return stops }
        stops += collections.prefix(visibleChipCount).map { .collection($0.id) }
        if moreFits, visibleChipCount < collections.count { stops.append(.more) }
        return stops
    }

    var stopUnderCursor: QuickAccessListStop {
        let stops = stops
        return stops[min(max(cursor, 0), stops.count - 1)]
    }

    var segmentsWidth: CGFloat { segments.intrinsicContentSize.width }

    /// The narrowest room the chips can do with: More alone while there are collections, as wide as it gets naming any
    /// of them, or the notice that they could not be read.
    var minimumChipsRoom: CGFloat {
        if collectionsUnavailable { return unavailableChip.intrinsicContentSize.width }
        return collections.isEmpty ? 0 : moreChip.widestWidth(for: collections)
    }

    /// The width the switch and the chips shown take.
    var contentWidth: CGFloat {
        let chips = chipsContentWidth
        return chips > 0 ? segmentsWidth + Self.chipsInset + chips : segmentsWidth
    }

    private var chipsContentWidth: CGFloat {
        guard showsChips else { return 0 }
        if collectionsUnavailable { return unavailableFits ? unavailableChip.intrinsicContentSize.width : 0 }
        var widths = chips.prefix(visibleChipCount).map(\.intrinsicContentSize.width)
        if moreFits, visibleChipCount < collections.count { widths.append(moreChip.intrinsicContentSize.width) }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + Self.chipGap * CGFloat(widths.count - 1)
    }

    func show(list: QuickAccessList, collections: [CollectionSummary], unavailable: Bool) {
        guard list != self.list || collections != self.collections || unavailable != collectionsUnavailable else { return }
        let chipsWereShown = showsChips
        if collections != self.collections { makeChips(for: collections) }
        self.list = list
        collectionsUnavailable = unavailable
        applyStates()
        showChosenHiddenCollection()
        if showsChips != chipsWereShown || chipsView.isHidden == showsChips { fadeChips(in: showsChips) }
        if cursor >= stops.count { moveCursor(to: list) }
        needsLayout = true
        // The toolbar places the lists and fits the chips to the room it leaves them.
        superview?.needsLayout = true
    }

    /// The segment and the chip of the list shown are on, the others off. A click toggles its button before the choice
    /// is made, so this follows every click too: the chosen segment clicked again stays on.
    private func applyStates() {
        segments.buttons[0].state = list == .all ? .on : .off
        segments.buttons[1].state = list == .all ? .off : .on
        for (chip, collection) in zip(chips, collections) {
            let state: NSControl.StateValue = list == .collection(collection.id) ? .on : .off
            if chip.state != state { chip.state = state }
        }
    }

    /// Fits as many chips into `room` as there is space for, More taking the rest. More keeps room for the widest of the
    /// collections it may have to show, so choosing one of them moves no chip.
    func fitChips(in room: CGFloat) {
        if collectionsUnavailable {
            visibleChipCount = 0
            moreFits = false
            unavailableFits = unavailableChip.intrinsicContentSize.width <= room
            needsLayout = true
            return
        }
        unavailableFits = false
        let widths = chips.map(\.intrinsicContentSize.width)
        var count = 0
        var fitsMore = false
        for shown in stride(from: widths.count, through: 0, by: -1) {
            let shownWidth = widths.prefix(shown).reduce(0, +) + Self.chipGap * CGFloat(max(0, shown - 1))
            let hidden = Array(collections.dropFirst(shown))
            if hidden.isEmpty {
                guard shownWidth <= room else { continue }
                count = shown
                break
            }
            let total = shownWidth + (shown > 0 ? Self.chipGap : 0) + moreChip.widestWidth(for: hidden)
            if total <= room {
                count = shown
                fitsMore = true
                break
            }
        }
        if count != visibleChipCount || fitsMore != moreFits { needsLayout = true }
        visibleChipCount = count
        moreFits = fitsMore
        showChosenHiddenCollection()
        if cursor >= stops.count { cursor = max(0, stops.count - 1) }
    }

    /// The cursor stops at either end.
    func moveCursor(by offset: Int) {
        cursor = min(max(cursor + offset, 0), stops.count - 1)
    }

    /// Puts the cursor on `list`: its segment, its chip, or More for a collection whose chip did not fit. The toolbar
    /// fits the chips first, when a change of list or collections is still to be laid out, so the stops are current.
    func moveCursor(to list: QuickAccessList) {
        superview?.layoutSubtreeIfNeeded()
        let stops = stops
        let stop: QuickAccessListStop
        switch list {
        case .all: stop = .all
        case .snippets: stop = .snippets
        case .collection(let id): stop = stops.contains(.collection(id)) ? .collection(id)
            : (stops.contains(.more) ? .more : .snippets)
        }
        cursor = stops.firstIndex(of: stop) ?? 0
    }

    override func layout() {
        super.layout()
        let size = segments.intrinsicContentSize
        segments.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let chipsX = size.width + Self.chipsInset
        chipsView.frame = NSRect(x: chipsX, y: (bounds.height - QuickAccessCollectionChip.height) / 2,
                                 width: max(0, bounds.width - chipsX), height: QuickAccessCollectionChip.height)
        var x: CGFloat = 0
        for (index, chip) in chips.enumerated() {
            let visible = index < visibleChipCount && !collectionsUnavailable
            chip.isHidden = !visible
            guard visible else { continue }
            let width = chip.intrinsicContentSize.width
            chip.frame = NSRect(x: x, y: 0, width: width, height: QuickAccessCollectionChip.height)
            x += width + Self.chipGap
        }
        moreChip.isHidden = !(moreFits && visibleChipCount < collections.count && !collectionsUnavailable)
        if !moreChip.isHidden {
            moreChip.frame = NSRect(x: x, y: 0, width: moreChip.intrinsicContentSize.width,
                                    height: QuickAccessCollectionChip.height)
        }
        unavailableChip.isHidden = !(collectionsUnavailable && unavailableFits)
        if !unavailableChip.isHidden {
            unavailableChip.frame = NSRect(x: 0, y: 0, width: unavailableChip.intrinsicContentSize.width,
                                           height: QuickAccessCollectionChip.height)
        }
    }

    /// Only the segments and the chips take clicks. A click in a gap between two is no choice's, and leaves the keys
    /// where they are rather than bring them here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self || view === chipsView || view === segments ? nil : view
    }

    override var acceptsFirstResponder: Bool { true }

    /// Taking the keys, the cursor goes to the list shown.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { moveCursor(to: list) }
        return became
    }

    override func keyDown(with event: NSEvent) {
        let key = QuickAccessStripView.key(for: event)
        // A held Space, Return or Escape has acted already.
        guard !(event.isARepeat && key.actsOnceWhenHeld) else { return }
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: event.modifierFlags.contains(.shift), focus: .lists, queryIsEmpty: queryIsEmpty
        ))
        // A key with no meaning here is dropped, not passed on to end in the alert sound.
        guard command != .passThrough else { return }
        onCommand?(command)
    }

    // The focus ring goes around the segment or chip under the cursor, not around the whole row.

    override var focusRingMaskBounds: NSRect { cursorFrame }

    override func drawFocusRingMask() {
        let frame = cursorFrame
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
    }

    private var cursorFrame: NSRect {
        guard let view = cursorView else { return .zero }
        return convert(view.bounds, from: view)
    }

    /// The segment or chip under the cursor.
    private var cursorView: NSView? {
        switch stopUnderCursor {
        case .all: return segments.buttons[0]
        case .snippets: return segments.buttons[1]
        case .collection(let id):
            guard let index = collections.firstIndex(where: { $0.id == id }) else { return nil }
            return chips[index]
        case .more: return moreChip
        }
    }

    /// With the keys here, what VoiceOver has in focus is the segment or chip under the cursor, not the row. AppKit
    /// asks on the main thread, but this property is not main-actor isolated in every SDK, so that is assumed here.
    override var accessibilityFocusedUIElement: Any? {
        let focused: NSView? = MainActor.assumeIsolated { window?.firstResponder === self ? cursorView : nil }
        return focused ?? super.accessibilityFocusedUIElement
    }

    private func makeChips(for collections: [CollectionSummary]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = collections.map { collection in
            let chip = QuickAccessCollectionChip(title: collection.name, color: collection.color)
            chip.target = self
            chip.action = #selector(chooseChip(_:))
            chipsView.addSubview(chip, positioned: .below, relativeTo: moreChip)
            return chip
        }
        self.collections = collections
        visibleChipCount = min(visibleChipCount, collections.count)
    }

    /// More names the collection shown when it is one whose chip did not fit, and says "More" otherwise.
    private func showChosenHiddenCollection() {
        if case .collection(let id) = list, let index = collections.firstIndex(where: { $0.id == id }),
           index >= visibleChipCount {
            moreChip.show(collections[index])
        } else {
            moreChip.show(nil)
        }
    }

    private func fadeChips(in shown: Bool) {
        guard window?.isVisible == true, !reducesMotion() else {
            chipsView.alphaValue = 1
            chipsView.isHidden = !shown
            return
        }
        if shown {
            chipsView.alphaValue = 0
            chipsView.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            chipsView.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.showsChips { self.chipsView.isHidden = true }
                self.chipsView.alphaValue = 1
            }
        })
    }

    @objc private func chooseSegment(_ sender: NSButton) {
        let stop: QuickAccessListStop = sender.tag == 0 ? .all : .snippets
        cursor = stops.firstIndex(of: stop) ?? cursor
        onChoose?(stop)
        applyStates()
    }

    @objc private func chooseChip(_ sender: QuickAccessCollectionChip) {
        guard let index = chips.firstIndex(where: { $0 === sender }) else { return }
        let stop = QuickAccessListStop.collection(collections[index].id)
        cursor = stops.firstIndex(of: stop) ?? cursor
        onChoose?(stop)
        applyStates()
    }

    @objc private func chooseMore() {
        cursor = stops.firstIndex(of: .more) ?? cursor
        onChoose?(.more)
    }
}

/// All and Snippets: two 24 pt segments in a 28 pt capsule, the chosen one filled.
@MainActor
final class QuickAccessListSegments: NSView {
    static let padding: CGFloat = 2
    let buttons = [QuickAccessSegmentButton(title: "All"), QuickAccessSegmentButton(title: "Snippets")]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buttons.forEach(addSubview)
        setAccessibilityElement(true)
        // A view is no control, so the element says it is enabled; VoiceOver would call it dimmed otherwise.
        setAccessibilityEnabled(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("List")
        setAccessibilityIdentifier("QuickAccessListSegments")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let widths = buttons.map(\.intrinsicContentSize.width)
        return NSSize(width: widths.reduce(0, +) + Self.padding * CGFloat(widths.count + 1),
                      height: QuickAccessCollectionChip.height)
    }

    override func layout() {
        super.layout()
        var x = Self.padding
        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + Self.padding
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarPalette.segmentsFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// One segment: its name, filled and in the semibold weight while it is chosen. VoiceOver reads it as a radio button.
@MainActor
final class QuickAccessSegmentButton: NSButton {
    static let height: CGFloat = 24
    private static let padding: CGFloat = 12

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        // Clicking a segment leaves the keys where they are.
        refusesFirstResponder = true
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("QuickAccessList\(title)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// As wide in either weight, so that choosing a segment moves nothing.
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(ToolbarText.width(title, weight: .semibold)) + 2 * Self.padding, height: Self.height)
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override func accessibilityValue() -> Any? { NSNumber(value: state == .on ? 1 : 0) }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = state == .on
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isOn {
            ToolbarPalette.chosenSegmentFill.setFill()
            shape.fill()
        } else if isHighlighted {
            ToolbarPalette.pressedFill.setFill()
            shape.fill()
        }
        ToolbarText.draw(title, centredIn: bounds, weight: isOn ? .semibold : .medium,
                         color: isOn ? ToolbarPalette.chosenFilterText : ToolbarPalette.secondary)
    }
}

/// The collections' chips, More and the notice that they could not be read, as one group of choices.
@MainActor
final class QuickAccessChipsView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        // A view is no control, so the element says it is enabled; VoiceOver would call it dimmed otherwise.
        setAccessibilityEnabled(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Collections")
        setAccessibilityIdentifier("QuickAccessCollectionChips")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A collection's chip: a dot in its colour and its name, 28 pt high, with no fill until it is chosen. A name longer
/// than 160 pt is cut in the middle, whole in the help tag. VoiceOver reads it as a radio button.
@MainActor
final class QuickAccessCollectionChip: NSButton {
    static let height: CGFloat = 28
    static let longestName: CGFloat = 160
    private static let padding: CGFloat = 10
    private static let dot: CGFloat = 9
    private static let dotGap: CGFloat = 6
    let colorName: String?

    init(title: String, color: String?) {
        colorName = color
        super.init(frame: .zero)
        self.title = title
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        refusesFirstResponder = true
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        if ToolbarText.width(title, weight: .semibold) > Self.longestName { toolTip = title }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// As wide in either weight, so that choosing a chip moves no other.
    override var intrinsicContentSize: NSSize {
        let name = min(ceil(ToolbarText.width(title, weight: .semibold)), Self.longestName)
        let dot = colorName == nil ? 0 : Self.dot + Self.dotGap
        return NSSize(width: Self.padding + dot + name + Self.padding, height: Self.height)
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    /// A chip says whether it is chosen; the notice that the collections could not be read is text, and reads as such.
    override func accessibilityValue() -> Any? {
        accessibilityRole() == .staticText ? title : NSNumber(value: state == .on ? 1 : 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = state == .on && isEnabled
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isOn {
            ToolbarPalette.chosenFilterFill.setFill()
            shape.fill()
        } else if isHighlighted {
            ToolbarPalette.pressedFill.setFill()
            shape.fill()
        }
        var x = Self.padding
        if let colorName {
            NSColor.collection(colorName).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - Self.dot / 2, width: Self.dot, height: Self.dot)).fill()
            x += Self.dot + Self.dotGap
        }
        let color = !isEnabled ? ToolbarPalette.placeholder : (isOn ? ToolbarPalette.chosenFilterText : ToolbarPalette.secondary)
        ToolbarText.draw(title, in: NSRect(x: x, y: 0, width: max(0, bounds.width - x - Self.padding),
                                          height: bounds.height),
                         weight: isOn ? .semibold : .medium, color: color, cutsInTheMiddle: true)
    }
}

/// The chip at the end that opens a menu of the collections that did not fit: "More" and a chevron, or, while one of
/// those collections is the list shown, its dot and name, chosen. VoiceOver reads it as a pop-up button.
@MainActor
final class QuickAccessMoreChip: NSButton {
    private static let padding: CGFloat = 10
    private static let dot: CGFloat = 9
    private static let gap: CGFloat = 6
    private static let chevron: CGFloat = 9
    private(set) var shown: CollectionSummary?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "More"
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .none
        refusesFirstResponder = true
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("More Collections")
        setAccessibilityIdentifier("QuickAccessMoreCollections")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ collection: CollectionSummary?) {
        // The toolbar's every layout comes here; More changes only when what it shows does.
        guard collection != shown else { return }
        shown = collection
        title = collection?.name ?? "More"
        state = collection == nil ? .off : .on
        toolTip = collection.map(\.name) ?? "More Collections"
        setAccessibilityLabel("More Collections")
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// As wide as it is showing `collection`, or "More" with nil.
    func width(showing collection: CollectionSummary?) -> CGFloat {
        let name = min(ceil(ToolbarText.width(collection?.name ?? "More", weight: .semibold)),
                       QuickAccessCollectionChip.longestName)
        let dot = collection == nil ? 0 : Self.dot + Self.gap
        return Self.padding + dot + name + Self.gap + Self.chevron + Self.padding
    }

    /// As wide as it can be while these collections are behind it.
    func widestWidth(for hidden: [CollectionSummary]) -> CGFloat {
        hidden.map { width(showing: $0) }.reduce(width(showing: nil), max)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width(showing: shown), height: QuickAccessCollectionChip.height)
    }

    override func accessibilityValue() -> Any? { shown?.name ?? "" }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = shown != nil
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isOn {
            ToolbarPalette.chosenFilterFill.setFill()
            shape.fill()
        } else if isHighlighted {
            ToolbarPalette.pressedFill.setFill()
            shape.fill()
        }
        var x = Self.padding
        if let shown {
            NSColor.collection(shown.color).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - Self.dot / 2, width: Self.dot, height: Self.dot)).fill()
            x += Self.dot + Self.gap
        }
        let color = isOn ? ToolbarPalette.chosenFilterText : ToolbarPalette.secondary
        let textEnd = bounds.width - Self.padding - Self.chevron - Self.gap
        ToolbarText.draw(title, in: NSRect(x: x, y: 0, width: max(0, textEnd - x), height: bounds.height),
                         weight: isOn ? .semibold : .medium, color: color, cutsInTheMiddle: true)
        let glyph = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        if let glyph {
            let image = glyph.tinted(color)
            let size = image.size
            image.draw(in: NSRect(x: bounds.width - Self.padding - size.width, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
    }
}

/// Favorites Only and the types, behind one button left of the search. With nothing on it is a 32 pt circle; with
/// filters on, a 32 pt capsule that names them: one by its name, more by their number. It is one stop of the panel's
/// Tab round; Space opens its menu, and so does a click, which leaves the keys where they are.
@MainActor
final class QuickAccessFilterButton: NSView {
    static let height: CGFloat = 32
    let face = QuickAccessFilterFace()
    private(set) var favoritesOnly = false
    private(set) var kinds: Set<ContentKind> = []
    var onOpen: (() -> Void)?
    var onCommand: ((QuickAccessCommand) -> Void)?
    var queryIsEmpty = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        face.target = self
        face.action = #selector(open)
        addSubview(face)
        // The face, a real button, is what VoiceOver reads and what is clicked: a pop-up button named Filter. This
        // view only holds it and takes Tab, and VoiceOver's focus then goes to the face.
        setAccessibilityElement(false)
        apply(favoritesOnly: false, kinds: [])
    }

    /// With the keys here, what VoiceOver has in focus is the face. AppKit asks on the main thread, but this property
    /// is not main-actor isolated in every SDK, so that is assumed here.
    override var accessibilityFocusedUIElement: Any? {
        let focused: NSView? = MainActor.assumeIsolated { window?.firstResponder === self ? face : nil }
        return focused ?? super.accessibilityFocusedUIElement
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// What the capsule says; nil while the button is a circle.
    var title: String? { face.label }

    /// As wide as the button can be, whatever filters are on.
    var maximumWidth: CGFloat {
        var labels: [(String, String?)] = [("Favorites", "star.fill")]
        labels += ContentKind.filters.map { ($0.filterTitle, $0.symbolName) }
        labels += (2...ContentKind.filters.count + 1).map { ("\($0) Filters", nil) }
        return labels.map { QuickAccessFilterFace.width(label: $0.0, symbol: $0.1) }.max() ?? Self.height
    }

    func show(favoritesOnly: Bool, kinds: Set<ContentKind>) {
        guard favoritesOnly != self.favoritesOnly || kinds != self.kinds else { return }
        apply(favoritesOnly: favoritesOnly, kinds: kinds)
    }

    private func apply(favoritesOnly: Bool, kinds: Set<ContentKind>) {
        self.favoritesOnly = favoritesOnly
        self.kinds = kinds
        let names = (favoritesOnly ? ["Favorites"] : []) + ContentKind.filters.filter(kinds.contains).map(\.filterTitle)
        let value: String
        let help: String
        switch names.count {
        case 0:
            (value, help) = ("None", "Filter")
            face.show(label: nil, symbol: "line.3.horizontal.decrease", help: help)
        case 1:
            let symbol = favoritesOnly ? "star.fill" : ContentKind.filters.first(where: kinds.contains)?.symbolName
            (value, help) = (names[0], names[0])
            face.show(label: names[0], symbol: symbol, help: help)
        default:
            let all = names.joined(separator: ", ")
            (value, help) = (all, all)
            face.show(label: "\(names.count) Filters", symbol: nil, help: help)
        }
        face.setAccessibilityValue(value)
        face.setAccessibilityHelp(help == "Filter" ? nil : help)
        invalidateIntrinsicContentSize()
        needsLayout = true
        // The toolbar sizes the button and moves the search's neighbours.
        superview?.needsLayout = true
    }

    override var intrinsicContentSize: NSSize { face.intrinsicContentSize }

    override func layout() {
        super.layout()
        face.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let key = QuickAccessStripView.key(for: event)
        guard !(event.isARepeat && key.actsOnceWhenHeld) else { return }
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: event.modifierFlags.contains(.shift), focus: .filterButton, queryIsEmpty: queryIsEmpty
        ))
        guard command != .passThrough else { return }
        onCommand?(command)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    @objc private func open() { onOpen?() }
}

/// The filter button's face: the circle or the capsule, and what VoiceOver reads as a pop-up button named Filter.
@MainActor
final class QuickAccessFilterFace: NSButton {
    private static let leading: CGFloat = 11
    private static let trailing: CGFloat = 13
    private static let iconGap: CGFloat = 6
    private static let icon: CGFloat = 14
    private(set) var label: String?
    private var symbol: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        focusRingType = .none
        refusesFirstResponder = true
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("Filter")
        setAccessibilityIdentifier("QuickAccessFilterButton")
    }

    /// VoiceOver's press and its Show Menu open the menu, as a click does.
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        sendAction(action, to: target)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        accessibilityPerformPress()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func width(label: String, symbol: String?) -> CGFloat {
        leading + (symbol == nil ? 0 : icon + iconGap) + ceil(ToolbarText.width(label, weight: .semibold)) + trailing
    }

    func show(label: String?, symbol: String?, help: String) {
        self.label = label
        self.symbol = symbol
        toolTip = help
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// As a pop-up button's, the menu opens as the mouse goes down, and the release lands in the menu. The button's own
    /// tracking would not do: with no title or image of its own, its cell takes no click at all.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isHighlighted = true
        sendAction(action, to: target)
        isHighlighted = false
    }

    override var intrinsicContentSize: NSSize {
        guard let label else { return NSSize(width: QuickAccessFilterButton.height, height: QuickAccessFilterButton.height) }
        return NSSize(width: Self.width(label: label, symbol: symbol), height: QuickAccessFilterButton.height)
    }


    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (label == nil ? (isHighlighted ? ToolbarPalette.pressedFill : ToolbarPalette.foldedSearchFill)
            : ToolbarPalette.chosenFilterFill).setFill()
        shape.fill()
        guard let label else {
            draw(symbol: symbol, in: bounds, color: ToolbarPalette.glyph)
            return
        }
        var x = Self.leading
        if let symbol {
            draw(symbol: symbol, in: NSRect(x: x, y: bounds.midY - Self.icon / 2, width: Self.icon, height: Self.icon),
                 color: symbol == "star.fill" ? .systemYellow : ToolbarPalette.chosenFilterText)
            x += Self.icon + Self.iconGap
        }
        ToolbarText.draw(label, in: NSRect(x: x, y: 0, width: max(0, bounds.width - x - Self.trailing),
                                          height: bounds.height),
                         weight: .semibold, color: ToolbarPalette.chosenFilterText)
    }

    private func draw(symbol: String?, in rect: NSRect, color: NSColor) {
        guard let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) else { return }
        let tinted = image.tinted(color)
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                               height: size.height))
    }
}

/// Text in the toolbar's 13 pt type.
@MainActor
enum ToolbarText {
    static func width(_ text: String, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight)]).width
    }

    static func draw(_ text: String, centredIn rect: NSRect, weight: NSFont.Weight, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: weight),
                                                         .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: attributes)
    }

    static func draw(_ text: String, in rect: NSRect, weight: NSFont.Weight, color: NSColor,
                     cutsInTheMiddle: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = cutsInTheMiddle ? .byTruncatingMiddle : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: weight),
                                                         .foregroundColor: color, .paragraphStyle: style]
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                                withAttributes: attributes)
    }
}

private extension NSImage {
    /// The symbol drawn in `color`.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
