import AppKit

/// The band's top row. In the middle, the search, folded to a round icon until it is wanted, and the filters; at the
/// right end what Return does, or in its place what the panel has to say, and the ⋯ menu; at the left end, while the
/// index rebuilds, that results may be incomplete. The search field is in the row all the time and keeps the keys while
/// it is folded, its caret hidden with it, so the first key typed goes straight into it, an input method's composition
/// included.
@MainActor
final class QuickAccessToolbar: NSView {
    /// What the right end says before the ⋯ button.
    enum Note: Equatable {
        /// "⏎ Copy", which copies when `enabled`.
        case copy(enabled: Bool)
        /// Such as "Searching…".
        case status(String)
        /// Why the last copy failed.
        case failure(String)
        case none
    }

    /// The view is this much taller than the row above and below it, for the focus rings drawn around the search
    /// and the filters.
    static let focusRoom: CGFloat = 4
    static let height = StripLayout.toolbarHeight + 2 * focusRoom
    /// Between the search and the filters.
    static let searchGap: CGFloat = 12
    /// The right end keeps this far from the row's edge, and its parts this far from each other and from the filters;
    /// the rebuild notice at the left end keeps as far from the search's ring.
    static let trailingInset: CGFloat = 16
    static let trailingGap: CGFloat = 12
    /// The rebuild notice starts this far from the row's left edge, and a note at the right end that needs the room
    /// moves the search and the filters left no nearer than this to it.
    static let leadingInset: CGFloat = 16
    /// A status cut shorter than this would say nothing, so it is left out.
    private static let shortestStatus: CGFloat = 24

    let search: QuickAccessSearchControl
    /// The ring around the open search while its field has the keys. It lies beside the search control rather than
    /// in it, so that nothing between them can cut it off.
    let focusHalo = QuickAccessFocusHalo()
    let filters = QuickAccessFilterRow()
    let copyHint = QuickAccessCopyHint()
    let statusLabel = NSTextField(labelWithString: "")
    let moreButton = QuickAccessMoreButton()
    /// The rebuild notice at the row's left end, in a status's type.
    let indexNoticeLabel = NSTextField(labelWithString: QuickAccessStatus.rebuilding)
    var note = Note.none {
        didSet { if note != oldValue { showNote() } }
    }
    /// Whether there are clips, and what the index says about itself. While there are clips and the index rebuilds,
    /// the row's left end says so; with no clips the empty state says it instead.
    var hasClips = false {
        didSet { if hasClips != oldValue { needsLayout = true } }
    }
    var indexNotice: IndexNotice? {
        didSet { if indexNotice != oldValue { needsLayout = true } }
    }
    /// Whether the search field has the keys. The open search is ringed then.
    var showsSearchFocus = false {
        didSet { updateHalo() }
    }
    /// Whether the folded search is ringed too while its field has the keys, as when they came to it by the keyboard.
    var ringsFoldedSearch = false {
        didSet { updateHalo() }
    }
    /// The search folds and unfolds in a fifth of a second, or at once with Reduce Motion.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The row within the view.
    var rowFrame: NSRect { NSRect(x: 0, y: Self.focusRoom, width: bounds.width, height: StripLayout.toolbarHeight) }

    init(field: QuickAccessSearchField) {
        search = QuickAccessSearchControl(field: field)
        super.init(frame: .zero)
        // Layers let the search grow and shrink, and the filters move with it, as one animation.
        wantsLayer = true
        for label in [statusLabel, indexNoticeLabel] {
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.isHidden = true
        }
        indexNoticeLabel.textColor = ToolbarPalette.secondary
        indexNoticeLabel.setAccessibilityIdentifier("QuickAccessIndexNotice")
        copyHint.isHidden = true
        focusHalo.isHidden = true
        for view in [focusHalo, indexNoticeLabel, search, filters, copyHint, statusLabel, moreButton] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Folds or unfolds the search. The views take their new places at once, and on screen the pill grows out of the
    /// circle while the filters move over to make room, in a fifth of a second. Off screen, as when the panel opens
    /// again, and with Reduce Motion it all switches at once.
    func setSearchExpanded(_ expanded: Bool) {
        guard expanded != search.isExpanded else { return }
        let moving = [search, focusHalo, filters] + search.subviews
        let before = moving.map { ($0.layer, $0.layer?.position, $0.layer?.bounds, $0.layer?.opacity) }
        search.isExpanded = expanded
        updateHalo()
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard window?.isVisible == true, !reducesMotion() else { return }
        for case let (layer?, position?, bounds?, opacity?) in before {
            if layer.position != position { Self.animate(layer, "position", from: NSValue(point: position)) }
            if layer.bounds != bounds { Self.animate(layer, "bounds", from: NSValue(rect: bounds)) }
            if layer.opacity != opacity { Self.animate(layer, "opacity", from: opacity) }
        }
    }

    /// Eases `keyPath` of `layer` from `value` to where the layer now is.
    private static func animate(_ layer: CALayer, _ keyPath: String, from value: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = value
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "fold \(keyPath)")
    }

    /// The search and the filters are centred together; the right end is laid out from the edge in. A status or a
    /// failure that the centred pair leaves too little room moves them left, as far as `leadingInset` from the row's
    /// edge, before it is cut short.
    override func layout() {
        super.layout()
        let row = rowFrame
        let searchWidth = search.isExpanded ? QuickAccessSearchControl.openWidth : QuickAccessSearchControl.foldedWidth
        let filtersSize = filters.intrinsicContentSize
        let groupWidth = searchWidth + Self.searchGap + filtersSize.width
        let side = QuickAccessMoreButton.side
        let moreFrame = NSRect(x: bounds.width - Self.trailingInset - side, y: row.midY - side / 2, width: side,
                               height: side)
        let end = moreFrame.minX - Self.trailingGap
        var left = ((bounds.width - groupWidth) / 2).rounded()
        if let wanted = statusWidth {
            let short = wanted - (end - Self.trailingGap - (left + groupWidth))
            left -= max(0, min(short, left - Self.leadingInset))
        }
        let searchFrame = NSRect(x: left, y: row.minY, width: searchWidth, height: row.height)
        let filtersFrame = NSRect(x: searchFrame.maxX + Self.searchGap, y: row.midY - filtersSize.height / 2,
                                  width: filtersSize.width, height: filtersSize.height)
        let fieldMoves = search.frame.origin != searchFrame.origin
        search.frame = searchFrame
        focusHalo.frame = searchFrame.insetBy(dx: -QuickAccessFocusHalo.width, dy: -QuickAccessFocusHalo.width)
        filters.frame = filtersFrame
        moreButton.frame = moreFrame
        // The field has moved, as it does when a note moves it aside, so an input method's candidates move with it.
        if fieldMoves { (search.field.currentEditor() as? NSTextView)?.inputContext?.invalidateCharacterCoordinates() }
        layoutNote(endingAt: end, room: end - (filtersFrame.maxX + Self.trailingGap))
        layoutIndexNotice(endingBefore: focusHalo.frame.minX - Self.trailingGap)
    }

    /// The rebuild notice starts `leadingInset` from the row's left edge and ends by `end`, `trailingGap` before the
    /// search's ring: it takes only the room the search and the filters leave once the right end has what it needs.
    /// Short of that room it is cut short with an ellipsis, its whole text in its help tag; below `shortestStatus` it is
    /// left out. VoiceOver reads its whole text either way.
    private func layoutIndexNotice(endingBefore end: CGFloat) {
        let label = indexNoticeLabel
        label.isHidden = true
        label.toolTip = nil
        guard hasClips, indexNotice == .rebuilding else { return }
        let full = Self.fullWidth(of: label)
        let width = min(full, end - Self.leadingInset)
        if width < full { label.toolTip = label.stringValue }
        guard width >= Self.shortestStatus else { return }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: Self.leadingInset, y: rowFrame.midY - height / 2, width: width, height: height)
        label.isHidden = false
    }

    /// How wide a status or a failure is in full; nil for any other note.
    private var statusWidth: CGFloat? {
        switch note {
        case .status, .failure: Self.fullWidth(of: statusLabel)
        case .copy, .none: nil
        }
    }

    /// How wide a label must be to show its whole text: the text's own width, which is the label's intrinsic one, and
    /// the room the label leaves at either side of it.
    private static func fullWidth(of label: NSTextField) -> CGFloat {
        let insets = label.alignmentRectInsets
        return ceil(label.intrinsicContentSize.width + insets.left + insets.right)
    }

    /// The note ends `trailingGap` before the ⋯ button and takes at most `room`. Short of room, "⏎ Copy" first drops
    /// its word, then goes; a status is cut short with an ellipsis, its whole text in its help tag.
    private func layoutNote(endingAt end: CGFloat, room: CGFloat) {
        let row = rowFrame
        copyHint.isHidden = true
        statusLabel.isHidden = true
        statusLabel.toolTip = nil
        switch note {
        case .copy(let enabled):
            copyHint.isEnabled = enabled
            if room >= copyHint.fullWidth {
                copyHint.showsTitle = true
            } else if room >= copyHint.compactWidth {
                copyHint.showsTitle = false
            } else {
                return
            }
            let width = copyHint.showsTitle ? copyHint.fullWidth : copyHint.compactWidth
            let height = QuickAccessKeycap.minimumSize.height
            copyHint.frame = NSRect(x: end - width, y: row.midY - height / 2, width: width, height: height)
            copyHint.isHidden = false
        case .status, .failure:
            let full = Self.fullWidth(of: statusLabel)
            let width = min(full, room)
            if width < full { statusLabel.toolTip = statusLabel.stringValue }
            guard width >= Self.shortestStatus else { return }
            let height = statusLabel.intrinsicContentSize.height
            statusLabel.frame = NSRect(x: end - width, y: row.midY - height / 2, width: width, height: height)
            statusLabel.isHidden = false
        case .none:
            break
        }
    }

    private func updateHalo() {
        focusHalo.isHidden = !(showsSearchFocus && (search.isExpanded || ringsFoldedSearch))
    }

    private func showNote() {
        switch note {
        case .status(let text):
            statusLabel.stringValue = text
            statusLabel.textColor = ToolbarPalette.secondary
            statusLabel.setAccessibilityIdentifier("QuickAccessStatus")
        case .failure(let text):
            statusLabel.stringValue = text
            statusLabel.textColor = ToolbarPalette.failure
            statusLabel.setAccessibilityIdentifier("QuickAccessFailure")
        case .copy, .none:
            break
        }
        needsLayout = true
    }
}

/// The search: a 32 pt circle with a magnifier while folded, and a 300 pt pill holding the magnifier, the field and,
/// once there is a query, a clear button while open. The field is in the control either way; folded, it lies under
/// the circle, not drawn, and keeps the keys if it has them.
@MainActor
final class QuickAccessSearchControl: NSView {
    static let foldedWidth: CGFloat = 32
    static let openWidth: CGFloat = 300
    private static let magnifierSide: CGFloat = 15
    private static let fieldHeight: CGFloat = 20

    let field: QuickAccessSearchField
    let magnifier = NSImageView()
    /// The circle as a button: a click unfolds the search. It is there only while the search is folded.
    let foldButton = QuickAccessFoldButton()
    let clearButton = QuickAccessClearButton()
    /// A click on the folded circle, or on the open pill outside its field and clear button: the search opens, if it
    /// is folded, and its field takes the keys.
    var onUnfold: (() -> Void)?
    var onClear: (() -> Void)?

    var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            needsLayout = true
            needsDisplay = true
            // The field under the icon, and its editor while it is edited, take the text cursor only while it is open.
            for view in [field, field.currentEditor(), foldButton].compactMap({ $0 }) {
                window?.invalidateCursorRects(for: view)
            }
        }
    }
    /// Whether there is a query to clear.
    var hasText = false {
        didSet { if hasText != oldValue { needsLayout = true } }
    }

    init(field: QuickAccessSearchField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.foldedWidth / 2
        layer?.cornerCurve = .continuous
        let glyph = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(glyph)
        magnifier.imageScaling = .scaleProportionallyUpOrDown
        magnifier.contentTintColor = ToolbarPalette.glyph
        magnifier.setAccessibilityElement(false)
        foldButton.target = self
        foldButton.action = #selector(unfold)
        foldButton.setAccessibilityLabel("Search clips")
        foldButton.setAccessibilityIdentifier("QuickAccessSearchButton")
        foldButton.toolTip = "Search clips (⌘F)"
        clearButton.target = self
        clearButton.action = #selector(clear)
        for view in [magnifier, field, clearButton, foldButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isExpanded ? ToolbarPalette.openSearchFill : ToolbarPalette.foldedSearchFill).cgColor
    }

    override func layout() {
        super.layout()
        let side = Self.magnifierSide
        let middle = bounds.midY
        let fieldHeight = Self.fieldHeight
        let clearSide = QuickAccessClearButton.side
        if isExpanded {
            // Magnifier, field and clear button, 8 apart, from 11 in on the left to 8 in on the right.
            magnifier.frame = NSRect(x: 11, y: middle - side / 2, width: side, height: side)
            let clearX = bounds.width - 8 - clearSide
            let fieldX = magnifier.frame.maxX + 8
            field.frame = NSRect(x: fieldX, y: middle - fieldHeight / 2, width: max(0, clearX - 8 - fieldX),
                                 height: fieldHeight)
            clearButton.frame = NSRect(x: clearX, y: middle - clearSide / 2, width: clearSide, height: clearSide)
        } else {
            // The field lies under the circle, not drawn, with the magnifier in the middle.
            magnifier.frame = NSRect(x: bounds.midX - side / 2, y: middle - side / 2, width: side, height: side)
            field.frame = NSRect(x: 0, y: middle - fieldHeight / 2, width: bounds.width, height: fieldHeight)
            clearButton.frame = NSRect(x: bounds.width - clearSide, y: middle - clearSide / 2, width: clearSide,
                                       height: clearSide)
        }
        field.alphaValue = isExpanded ? 1 : 0
        clearButton.isHidden = !(isExpanded && hasText)
        foldButton.isHidden = isExpanded
        foldButton.frame = bounds
    }

    /// Open, a click on the pill outside the field and the clear button, on its magnifier as well, gives the field the
    /// keys, as one on the field would.
    override func mouseDown(with event: NSEvent) {
        guard isExpanded else { return super.mouseDown(with: event) }
        onUnfold?()
    }

    @objc private func unfold() { onUnfold?() }

    @objc private func clear() { onClear?() }
}

/// The folded search's icon as a button. Over it the pointer is the arrow, not the text cursor of the field beneath.
@MainActor
final class QuickAccessFoldButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        refusesFirstResponder = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// A 3 pt ring in the accent colour, at 45 percent, around the search while its field has the keys.
@MainActor
final class QuickAccessFocusHalo: NSView {
    static let width: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = Self.width
        layer?.cornerRadius = QuickAccessSearchControl.foldedWidth / 2 + Self.width
        layer?.cornerCurve = .continuous
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The open search's clear button: an 18 pt disc with a cross, as a search field's own.
@MainActor
final class QuickAccessClearButton: NSButton {
    static let side: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        refusesFirstResponder = true
        setAccessibilityLabel("Clear search")
        setAccessibilityIdentifier("QuickAccessClearSearch")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func draw(_ dirtyRect: NSRect) {
        (isHighlighted ? ToolbarPalette.glyph : ToolbarPalette.clearFill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let cross = NSBezierPath()
        let arm = bounds.width * 4 / 18 - 0.75
        cross.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY - arm))
        cross.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY + arm))
        cross.move(to: NSPoint(x: bounds.midX + arm, y: bounds.midY - arm))
        cross.line(to: NSPoint(x: bounds.midX - arm, y: bounds.midY + arm))
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        ToolbarPalette.clearCross.setStroke()
        cross.stroke()
    }
}

/// All, Text, Links, Images and Files, where All clears the filters. A click chooses directly and leaves the keys
/// where they are. With the keys, the row itself takes them: ← and → move a cursor along the choices, ringed as
/// focus, and Space chooses the one under it.
@MainActor
final class QuickAccessFilterRow: NSView {
    /// The choices in order; nil is All.
    static let choices: [ContentKind?] = [nil] + ContentKind.filters
    static let spacing: CGFloat = 6

    var onCommand: ((QuickAccessCommand) -> Void)?
    /// A choice was clicked; its index in `choices`.
    var onChoose: ((Int) -> Void)?
    /// What a key means here depends on the rest of the panel, which keeps this current.
    var queryIsEmpty = true
    /// The choice ← and → move and Space chooses.
    var cursor = 0 {
        didSet { noteFocusRingMaskChanged() }
    }
    let chips: [QuickAccessFilterChip]

    override init(frame frameRect: NSRect) {
        chips = Self.choices.map { QuickAccessFilterChip(title: $0?.filterTitle ?? "All") }
        super.init(frame: frameRect)
        for (index, chip) in chips.enumerated() {
            chip.tag = index
            chip.target = self
            chip.action = #selector(choose(_:))
            addSubview(chip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Filter by type")
        setAccessibilityIdentifier("QuickAccessFilters")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let widths = chips.map(\.intrinsicContentSize.width)
        return NSSize(width: widths.reduce(0, +) + Self.spacing * CGFloat(max(0, chips.count - 1)),
                      height: QuickAccessFilterChip.height)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for chip in chips {
            let width = chip.intrinsicContentSize.width
            chip.frame = NSRect(x: x, y: (bounds.height - QuickAccessFilterChip.height) / 2, width: width,
                                height: QuickAccessFilterChip.height)
            x += width + Self.spacing
        }
    }

    /// Marks the filters that are on, or All when none is.
    func show(kinds: Set<ContentKind>) {
        for (chip, kind) in zip(chips, Self.choices) {
            let state: NSControl.StateValue = (kind.map(kinds.contains) ?? kinds.isEmpty) ? .on : .off
            if chip.state != state { chip.state = state }
        }
    }

    /// The cursor stops at either end.
    func moveCursor(by offset: Int) {
        cursor = min(max(cursor + offset, 0), chips.count - 1)
    }

    @objc private func choose(_ sender: NSButton) {
        cursor = sender.tag
        onChoose?(sender.tag)
    }

    /// Only the choices take clicks. A click in the gap between two is no choice's, and leaves the keys where they
    /// are rather than bring them here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let key = QuickAccessStripView.key(for: event)
        // A held Space, Return or Escape has acted already.
        guard !(event.isARepeat && key.actsOnceWhenHeld) else { return }
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: event.modifierFlags.contains(.shift), focus: .filters, queryIsEmpty: queryIsEmpty
        ))
        // A key with no meaning here is dropped, not passed on to end in the alert sound.
        guard command != .passThrough else { return }
        onCommand?(command)
    }

    // The focus ring goes around the choice under the cursor, not around the whole row.

    override var focusRingMaskBounds: NSRect { cursorFrame }

    override func drawFocusRingMask() {
        let frame = cursorFrame
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
    }

    private var cursorFrame: NSRect {
        convert(chips[cursor].bounds, from: chips[cursor])
    }
}

/// One filter: its name in a 28 pt capsule, filled and in the semibold weight while it is on.
@MainActor
final class QuickAccessFilterChip: NSButton {
    static let height: CGFloat = 28
    private static let padding: CGFloat = 12

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        // Clicking a choice leaves the keys where they are.
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// As wide in either weight, so that choosing a filter moves no other.
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: Self.font(isOn: true)])
        return NSSize(width: ceil(text.width) + 2 * Self.padding, height: Self.height)
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = state == .on
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isOn {
            ToolbarPalette.chosenFilterFill.setFill()
            capsule.fill()
        } else if isHighlighted {
            ToolbarPalette.pressedFill.setFill()
            capsule.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font(isOn: isOn),
            .foregroundColor: isOn ? ToolbarPalette.chosenFilterText : ToolbarPalette.secondary,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                 withAttributes: attributes)
    }

    private static func font(isOn: Bool) -> NSFont {
        .systemFont(ofSize: 13, weight: isOn ? .semibold : .medium)
    }
}

/// A key drawn as a small cap: Return's, before "Copy".
@MainActor
final class QuickAccessKeycap: NSView {
    static let minimumSize = NSSize(width: 22, height: 20)
    let symbol: String

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ToolbarPalette.glyph]
    }

    override var intrinsicContentSize: NSSize {
        let text = (symbol as NSString).size(withAttributes: attributes)
        return NSSize(width: max(Self.minimumSize.width, ceil(text.width) + 8), height: Self.minimumSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let line: CGFloat = 0.75
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2), xRadius: 5 - line / 2,
                                yRadius: 5 - line / 2)
        edge.lineWidth = line
        ToolbarPalette.keycapEdge.setStroke()
        edge.stroke()
        let size = (symbol as NSString).size(withAttributes: attributes)
        (symbol as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                  withAttributes: attributes)
    }
}

/// "⏎ Copy" at the toolbar's right end: what Return does, and a button that does it for the pointer. Short of room it
/// keeps only its key cap.
@MainActor
final class QuickAccessCopyHint: NSButton {
    private static let spacing: CGFloat = 7
    let keycap = QuickAccessKeycap(symbol: "⏎")
    var showsTitle = true {
        didSet { if showsTitle != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Copy"
        isBordered = false
        refusesFirstResponder = true
        setAccessibilityLabel("Copy")
        setAccessibilityIdentifier("QuickAccessCopyButton")
        addSubview(keycap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ToolbarPalette.secondary]
    }

    /// With its word, and with its key cap alone.
    var fullWidth: CGFloat {
        compactWidth + Self.spacing + ceil((title as NSString).size(withAttributes: titleAttributes).width)
    }
    var compactWidth: CGFloat { keycap.intrinsicContentSize.width }

    override func layout() {
        super.layout()
        let size = keycap.intrinsicContentSize
        keycap.frame = NSRect(x: 0, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsTitle else { return }
        let attributes = titleAttributes
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: compactWidth + Self.spacing, y: bounds.midY - size.height / 2),
                                 withAttributes: attributes)
    }
}

/// The ⋯ at the toolbar's right end, which opens a menu with Open Library and Settings….
@MainActor
final class QuickAccessMoreButton: NSButton {
    static let side: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        refusesFirstResponder = true
        setAccessibilityLabel("More")
        setAccessibilityIdentifier("QuickAccessMoreButton")
        toolTip = "More"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            ToolbarPalette.pressedFill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        // Three dots, 1.6 in radius and 6 apart.
        ToolbarPalette.secondary.setFill()
        for offset in [-6.0, 0, 6] as [CGFloat] {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX + offset - 1.6, y: bounds.midY - 1.6, width: 3.2, height: 3.2))
                .fill()
        }
    }
}

/// The toolbar's colours, as the design gives them in dark and in light. With Increase Contrast every translucent
/// colour among them is half again as strong.
enum ToolbarPalette {
    static let foldedSearchFill = colour(dark: (255, 255, 255, 0.10), light: (0, 0, 0, 0.06))
    static let openSearchFill = colour(dark: (255, 255, 255, 0.12), light: (0, 0, 0, 0.06))
    /// The magnifier and the key cap's symbol.
    static let glyph = colour(dark: (235, 235, 245, 0.85), light: (60, 60, 67, 0.85))
    /// Filters that are off, the hint's word, the status and the ⋯.
    static let secondary = colour(dark: (235, 235, 245, 0.72), light: (60, 60, 67, 0.78))
    static let chosenFilterFill = colour(dark: (255, 255, 255, 0.16), light: (0, 0, 0, 0.08))
    static let chosenFilterText = colour(dark: (255, 255, 255, 1), light: (0x1D, 0x1D, 0x1F, 1))
    static let pressedFill = colour(dark: (255, 255, 255, 0.10), light: (0, 0, 0, 0.06))
    static let keycapEdge = colour(dark: (255, 255, 255, 0.28), light: (0, 0, 0, 0.22))
    static let fieldText = colour(dark: (255, 255, 255, 1), light: (0x1D, 0x1D, 0x1F, 1))
    static let placeholder = colour(dark: (235, 235, 245, 0.5), light: (60, 60, 67, 0.5))
    static let clearFill = colour(dark: (235, 235, 245, 0.35), light: (60, 60, 67, 0.35))
    static let clearCross = colour(dark: (0x1C, 0x1C, 0x1E, 1), light: (255, 255, 255, 1))
    /// Why a copy failed: the system's red in dark mode, and in light mode a deeper red, which reads at 4.5:1 on the
    /// light band as the system's red does not.
    static let failure = NSColor(name: nil) { appearance in
        isDark(appearance) ? .systemRed : NSColor(srgbRed: 0xD7 / 255, green: 0, blue: 0x15 / 255, alpha: 1)
    }

    private typealias Components = (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)

    private static let appearances: [NSAppearance.Name] = [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                                                            .accessibilityHighContrastAqua]

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: appearances)
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }

    private static func colour(dark: Components, light: Components) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: appearances)
            let increased = match == .accessibilityHighContrastDarkAqua || match == .accessibilityHighContrastAqua
            let components = isDark(appearance) ? dark : light
            return NSColor(srgbRed: components.red / 255, green: components.green / 255, blue: components.blue / 255,
                           alpha: increased ? min(1, components.alpha * 1.5) : components.alpha)
        }
    }
}
