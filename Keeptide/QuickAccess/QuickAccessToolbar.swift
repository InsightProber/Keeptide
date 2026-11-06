import AppKit

/// The band's top row. At the left end, the All | Snippets switch and, under Snippets, the collection chips; at the right
/// end the filter button, the search, folded to a round icon until it is wanted, what Return does, with why it only
/// copies when the user can do something about it, or in its place what the panel has to say, and the ⋯ menu; between
/// them, why new copies are not kept, or while the index rebuilds, that results may be incomplete.
/// The search field is in the row all the time and keeps the keys while it is folded, its caret hidden with it, so
/// the first key typed goes straight into it, an input method's composition included.
@MainActor
final class QuickAccessToolbar: NSView {
    /// What the right end says before the ⋯ button.
    enum Note: Equatable {
        /// "⏎ <title>": what Return does, such as "Copy" or "Paste into TextEdit", which it does when `enabled`. Left of
        /// it, `hint` says why Return only copies, when the user can do something about that.
        case action(title: String, enabled: Bool, hint: String?)
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
    /// The right end keeps this far from the row's edge, and its parts this far from each other and from the filters.
    /// The notice after the filters keeps the same gap from them and from the first visible part of the right end.
    static let trailingInset: CGFloat = 16
    static let trailingGap: CGFloat = 12
    /// The search starts this far from the row's left edge, whatever the right end says.
    static let leadingInset: CGFloat = 16
    /// A status, a reason or the action's word cut shorter than this would say nothing, so it is left out.
    private static let shortestStatus: CGFloat = 24

    let search: QuickAccessSearchControl
    /// The ring around the open search while its field has the keys. It lies beside the search control rather than
    /// in it, so that nothing between them can cut it off.
    let focusHalo = QuickAccessFocusHalo()
    /// The All | Snippets switch and, under Snippets, the collection chips.
    let lists = QuickAccessListNavigation()
    /// Favorites Only and the types, behind one button.
    let filterButton = QuickAccessFilterButton()
    /// "⏎ <title>", the button for what Return does. Its identifier stays the one it had when it only copied.
    let copyHint = QuickAccessCopyHint()
    /// Why Return only copies, left of it, in a status's type.
    let directPasteHint = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let moreButton = QuickAccessMoreButton()
    /// The rebuild notice after the filters, in a status's type.
    let indexNoticeLabel = NSTextField(labelWithString: QuickAccessStatus.rebuilding)
    /// Why new copies are not kept, in the rebuild notice's place and type.
    let captureNoticeLabel = NSTextField(labelWithString: "")
    var note = Note.none {
        didSet { if note != oldValue { showNote() } }
    }
    /// What Return can do in this session, whatever clip is selected. The right end keeps room for the widest of them
    /// and for the common statuses, so that typing, a status or another clip never moves the search.
    var reservedNotes: [Note] = [] {
        didSet {
            guard reservedNotes != oldValue else { return }
            updateNoteReserve()
            needsLayout = true
        }
    }
    /// The room the right end keeps for what Return does.
    private(set) var noteReserve: CGFloat = 0
    /// What the panel says often in Return's place, as while a search runs or after a save.
    static let commonStatuses = ["Searching…", "Saved to Snippets", "Already in Snippets", "Save undone"]
    /// Whether there are clips, and what the index says about itself. While there are clips and the index rebuilds,
    /// the gap after the filters says so; with no clips the empty state says it instead.
    var hasClips = false {
        didSet { if hasClips != oldValue { needsLayout = true } }
    }
    var indexNotice: IndexNotice? {
        didSet { if indexNotice != oldValue { needsLayout = true } }
    }
    /// Why new copies are not kept, as when the system denies Keeptide the clipboard, or nil while they are. It shows
    /// over clips and without them, where the empty state's "Copy something" would not hold, and the rebuild notice
    /// gives way to it.
    var captureNotice: String? {
        didSet {
            guard captureNotice != oldValue else { return }
            captureNoticeLabel.stringValue = captureNotice ?? ""
            needsLayout = true
        }
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
        // Layers let the search grow and shrink, and the filters and notice move with it, as one animation.
        wantsLayer = true
        for label in [statusLabel, indexNoticeLabel, captureNoticeLabel, directPasteHint] {
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.isHidden = true
        }
        for notice in [indexNoticeLabel, captureNoticeLabel] {
            notice.wantsLayer = true
            notice.textColor = ToolbarPalette.secondary
        }
        indexNoticeLabel.setAccessibilityIdentifier("QuickAccessIndexNotice")
        captureNoticeLabel.setAccessibilityIdentifier("QuickAccessCaptureNotice")
        directPasteHint.textColor = ToolbarPalette.secondary
        directPasteHint.setAccessibilityIdentifier("QuickAccessDirectPasteHint")
        copyHint.isHidden = true
        focusHalo.isHidden = true
        updateNoteReserve()
        for view in [focusHalo, indexNoticeLabel, captureNoticeLabel, search, lists, filterButton, directPasteHint,
                     copyHint, statusLabel, moreButton] as [NSView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Folds or unfolds the search. The views take their new places at once, and on screen the pill grows out of the
    /// circle to the left while the filter button and the notice before it make room, in a fifth of a second. Off screen,
    /// as when the panel opens again, and with Reduce Motion it all switches at once.
    func setSearchExpanded(_ expanded: Bool) {
        guard expanded != search.isExpanded else { return }
        let moving = [search, focusHalo, filterButton, indexNoticeLabel, captureNoticeLabel] + search.subviews
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

    /// From the left: the switch at the left inset and, under Snippets, the chips, fitted as if the right end were at
    /// its widest, so that nothing there ever moves them. From the right: the ⋯ button, the room kept for what Return
    /// does, the search and the filter button, 12 apart. A notice takes what is left between them.
    override func layout() {
        super.layout()
        let row = rowFrame
        let gap = Self.trailingGap
        let side = QuickAccessMoreButton.side
        let moreFrame = NSRect(x: bounds.width - Self.trailingInset - side, y: row.midY - side / 2, width: side,
                               height: side)
        moreButton.frame = moreFrame
        let noteRight = moreFrame.minX - gap
        let chipsStart = Self.leadingInset + lists.segmentsWidth + QuickAccessListNavigation.chipsInset
        // The filter button at its widest and the open search.
        let widest = filterButton.maximumWidth + gap + QuickAccessSearchControl.openWidth
        func chipsRoom(noteSlot: CGFloat) -> CGFloat {
            noteRight - (noteSlot > 0 ? noteSlot + gap : 0) - widest - gap - chipsStart
        }
        // A narrow row puts collections behind More first; only then does the room for the note shrink.
        var noteSlot = noteReserve
        let shortfall = lists.minimumChipsRoom - chipsRoom(noteSlot: noteSlot)
        if shortfall > 0 { noteSlot = max(0, noteSlot - shortfall) }
        lists.fitChips(in: chipsRoom(noteSlot: noteSlot))
        let height = QuickAccessListNavigation.height
        lists.frame = NSRect(x: Self.leadingInset, y: row.midY - height / 2, width: lists.contentWidth, height: height)
        let leftBound = lists.frame.maxX + gap
        let searchWidth = search.isExpanded ? QuickAccessSearchControl.openWidth : QuickAccessSearchControl.foldedWidth
        let filterSize = filterButton.intrinsicContentSize
        // What Return does keeps to its room. A status or a failure may borrow more while the search is folded, never
        // from the lists: the search and the filter button make way, and come back when it goes.
        let borrows: Bool
        switch note {
        case .status, .failure: borrows = !search.isExpanded
        case .action, .none: borrows = false
        }
        let free = noteRight - leftBound - (filterSize.width + gap + searchWidth + gap)
        let noteWidth = layoutNote(endingAt: noteRight, room: borrows ? max(noteSlot, free) : noteSlot)
        let span = max(noteSlot, noteWidth)
        let searchRight = span > 0 ? noteRight - span - gap : noteRight
        let searchFrame = NSRect(x: searchRight - searchWidth, y: row.minY, width: searchWidth, height: row.height)
        search.frame = searchFrame
        focusHalo.frame = searchFrame.insetBy(dx: -QuickAccessFocusHalo.width, dy: -QuickAccessFocusHalo.width)
        filterButton.frame = NSRect(x: searchFrame.minX - gap - filterSize.width, y: row.midY - filterSize.height / 2,
                                    width: filterSize.width, height: filterSize.height)
        layoutNotice(from: leftBound, to: filterButton.frame.minX - gap)
    }

    /// The notice between the lists and the filter button: why new copies are not kept, or else, over clips, that the
    /// index rebuilds. It takes only the room the rest of the row leaves. Short of that room it is cut short with an
    /// ellipsis, its whole text in its help tag; below `shortestStatus` it is left out. VoiceOver reads its whole text
    /// either way.
    private func layoutNotice(from start: CGFloat, to end: CGFloat) {
        for notice in [captureNoticeLabel, indexNoticeLabel] {
            notice.isHidden = true
            notice.toolTip = nil
        }
        let label: NSTextField
        if captureNotice != nil {
            label = captureNoticeLabel
        } else if hasClips, indexNotice == .rebuilding {
            label = indexNoticeLabel
        } else {
            return
        }
        let full = Self.fullWidth(of: label)
        let width = min(full, end - start)
        if width < full { label.toolTip = label.stringValue }
        guard width >= Self.shortestStatus else { return }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: start, y: rowFrame.midY - height / 2, width: width, height: height)
        label.isHidden = false
    }

    /// How wide `note` is with nothing cut.
    func fullWidth(of note: Note) -> CGFloat {
        switch note {
        case .action(let title, _, let hint):
            let action = copyHint.compactWidth + QuickAccessCopyHint.spacing + QuickAccessCopyHint.titleWidth(title)
            return hint.map { action + Self.trailingGap + Self.labelWidth($0) } ?? action
        case .status(let text), .failure(let text):
            return Self.labelWidth(text)
        case .none:
            return 0
        }
    }

    private func updateNoteReserve() {
        let widths = Self.commonStatuses.map(Self.labelWidth) + reservedNotes.map(fullWidth(of:))
        noteReserve = ceil(widths.max() ?? 0)
    }

    /// How wide a status label must be to show `text` whole.
    private static func labelWidth(_ text: String) -> CGFloat {
        let probe = NSTextField(labelWithString: text)
        probe.font = .systemFont(ofSize: 13)
        return fullWidth(of: probe)
    }

    /// How wide a label must be to show its whole text: the text's own width, which is the label's intrinsic one, and
    /// the room the label leaves at either side of it.
    private static func fullWidth(of label: NSTextField) -> CGFloat {
        let insets = label.alignmentRectInsets
        return ceil(label.intrinsicContentSize.width + insets.left + insets.right)
    }

    /// The note ends `trailingGap` before the ⋯ button and takes at most `room`; it returns the width it took. A status is
    /// cut short with an ellipsis, its whole text in its help tag. What Return does gives way in steps, each with the
    /// whole text in its help tag: first its reason is cut and then left out, then its word is cut, then only the key cap
    /// is left, and last it goes.
    @discardableResult
    private func layoutNote(endingAt end: CGFloat, room: CGFloat) -> CGFloat {
        copyHint.isHidden = true
        copyHint.toolTip = nil
        directPasteHint.isHidden = true
        directPasteHint.toolTip = nil
        statusLabel.isHidden = true
        statusLabel.toolTip = nil
        switch note {
        case .action(let title, _, let hint):
            let width: CGFloat
            if room >= copyHint.fullWidth {
                width = copyHint.fullWidth
                copyHint.showsTitle = true
            } else if room - copyHint.compactWidth - QuickAccessCopyHint.spacing >= Self.shortestStatus {
                width = room
                copyHint.showsTitle = true
            } else if room >= copyHint.compactWidth {
                width = copyHint.compactWidth
                copyHint.showsTitle = false
            } else {
                return 0
            }
            if width < copyHint.fullWidth { copyHint.toolTip = title }
            let height = QuickAccessKeycap.minimumSize.height
            copyHint.frame = NSRect(x: end - width, y: rowFrame.midY - height / 2, width: width, height: height)
            copyHint.isHidden = false
            guard hint != nil else { return width }
            let reason = place(directPasteHint, endingAt: copyHint.frame.minX - Self.trailingGap,
                               room: room - width - Self.trailingGap)
            return reason > 0 ? width + Self.trailingGap + reason : width
        case .status, .failure:
            return place(statusLabel, endingAt: end, room: room)
        case .none:
            return 0
        }
    }

    /// Puts `label` in the row, ending at `end` and taking at most `room`: cut short with an ellipsis where that is
    /// less than it needs, its whole text in its help tag, and left out below `shortestStatus`. It returns the width it
    /// took.
    @discardableResult
    private func place(_ label: NSTextField, endingAt end: CGFloat, room: CGFloat) -> CGFloat {
        let full = Self.fullWidth(of: label)
        let width = min(full, room)
        if width < full { label.toolTip = label.stringValue }
        guard width >= Self.shortestStatus else { return 0 }
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: end - width, y: rowFrame.midY - height / 2, width: width, height: height)
        label.isHidden = false
        return width
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
        case .action(let title, let enabled, let hint):
            copyHint.title = title
            copyHint.isEnabled = enabled
            directPasteHint.stringValue = hint ?? ""
        case .none:
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
        foldButton.setAccessibilityIdentifier("QuickAccessSearchButton")
        setPrompt("Search Clips and Snippets")
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === magnifier ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard isExpanded else { return super.mouseDown(with: event) }
        onUnfold?()
    }

    /// What the search searches, as its field's placeholder and the folded circle's name say it.
    func setPrompt(_ prompt: String) {
        guard foldButton.accessibilityLabel() != prompt else { return }
        field.setPrompt(prompt)
        foldButton.setAccessibilityLabel(prompt)
        foldButton.toolTip = "\(prompt) (⌘F)"
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

/// "⏎ Copy" at the toolbar's right end, or "⏎ Paste into TextEdit": what Return does, and a button that does it for the
/// pointer. Its word is the title, which VoiceOver reads whole. Given less room than it needs, the word is cut at its
/// tail; with less still, only the key cap is left.
@MainActor
final class QuickAccessCopyHint: NSButton {
    /// Between the key cap and the word.
    static let spacing: CGFloat = 7
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

    override var title: String {
        didSet {
            guard title != oldValue else { return }
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ToolbarPalette.secondary]
    }

    /// How wide `title` is in the hint's type.
    static func titleWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width)
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
        let height = (title as NSString).size(withAttributes: titleAttributes).height
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var attributes = titleAttributes
        attributes[.paragraphStyle] = style
        let x = compactWidth + Self.spacing
        (title as NSString).draw(in: NSRect(x: x, y: bounds.midY - height / 2, width: max(0, bounds.width - x),
                                            height: height), withAttributes: attributes)
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
/// colour among them but the divider is half again as strong.
enum ToolbarPalette {
    static let foldedSearchFill = colour(dark: (255, 255, 255, 0.10), light: (0, 0, 0, 0.06))
    static let openSearchFill = colour(dark: (255, 255, 255, 0.12), light: (0, 0, 0, 0.06))
    /// The magnifier and the key cap's symbol.
    static let glyph = colour(dark: (235, 235, 245, 0.85), light: (60, 60, 67, 0.85))
    /// Filters that are off, the hint's word, the status and the ⋯.
    static let secondary = colour(dark: (235, 235, 245, 0.72), light: (60, 60, 67, 0.78))
    static let chosenFilterFill = colour(dark: (255, 255, 255, 0.16), light: (0, 0, 0, 0.08))
    /// The All | Snippets capsule, and its chosen segment.
    static let segmentsFill = colour(dark: (255, 255, 255, 0.08), light: (0, 0, 0, 0.05))
    static let chosenSegmentFill = colour(dark: (255, 255, 255, 0.18), light: (255, 255, 255, 0.95))
    static let chosenFilterText = colour(dark: (255, 255, 255, 1), light: (0x1D, 0x1D, 0x1F, 1))
    static let pressedFill = colour(dark: (255, 255, 255, 0.10), light: (0, 0, 0, 0.06))
    static let keycapEdge = colour(dark: (255, 255, 255, 0.28), light: (0, 0, 0, 0.22))
    static let fieldText = colour(dark: (255, 255, 255, 1), light: (0x1D, 0x1D, 0x1F, 1))
    static let placeholder = colour(dark: (235, 235, 245, 0.5), light: (60, 60, 67, 0.5))
    static let clearFill = colour(dark: (235, 235, 245, 0.35), light: (60, 60, 67, 0.35))
    static let clearCross = colour(dark: (0x1C, 0x1C, 0x1E, 1), light: (255, 255, 255, 1))
    /// The divider between the frequent wing and the recent clips: the line over each card's footer, white at 7 percent
    /// in dark mode and black at 7 percent in light. Increase Contrast widens the divider instead of strengthening it.
    static let divider = NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07)
    }
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
