import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The strip of clips in the quick access panel. AppKit lays the frames out and owns focus, keys,
/// scrolling, clicks and what VoiceOver reads; SwiftUI draws each frame. The selected clip sits in the
/// middle, older clips to its left and newer ones to its right.
///
/// The strip shows the selection it is given and nothing else. A click, a key or a swipe only asks for
/// a change through `onSelect` or `onCommand`; the frames move when `show` brings the new selection.
/// A selected frame's ring is drawn outside the frame, so nothing in the strip clips to its bounds.
@MainActor
final class QuickAccessStripView: NSView {
    var onSelect: ((ContentRef) -> Void)?
    var onCommand: ((QuickAccessCommand) -> Void)?
    /// The rows that have a frame, the selected one first, and the last row on screen, which decides
    /// when to load more. Called when either changes, and again while a framed row has no details.
    var onVisibleRefsChanged: (([ContentRef], Int) -> Void)?
    var onContextMenu: ((ContentRef) -> NSMenu?)?
    var haptics: any HapticPerforming = SystemHaptics()
    /// Whether the trackpad ticks as each clip passes. The strip moves the same either way.
    var ticksEnabled = true
    /// What a key means here depends on the rest of the panel, which keeps these current.
    var filtersVisible = false
    var queryIsEmpty = true

    /// Frames kept beyond each end of the visible ones, so a step or a push never shows a gap.
    private static let spareFrames = 2
    /// A step takes about this long and ends with a slight bounce.
    private static let slideDuration: CFTimeInterval = 0.2
    private static let slideBounce: CGFloat = 0.15

    private var rows: [QuickAccessRow] = []
    private var selection: ContentRef?
    /// The row in the middle: the selected one, or -1 when the selection vanished and the middle is empty.
    private var centredIndex = -1
    private var details: [ContentRef: ClipDetail] = [:]
    private var metrics: StripMetrics?
    private var applicationNames: ApplicationNames?
    /// Holds the frames and moves them as one: it follows the fingers and carries each slide.
    private let film = NSView()
    private var frames: [ContentRef: StripFrameHost] = [:]
    private var scroller = DetentScroller()
    /// How far the fingers have pushed the frames off their places: part of a step, or a stretch past an end.
    private var pushed: CGFloat = 0
    private var fingersDown = false
    /// The middle a slide started from. Its frames stay until the slide settles, so none vanishes on screen.
    private var slideStart: Int?
    private var settling: Task<Void, Never>?
    private var hovered: ContentRef?
    private var reported: (refs: [ContentRef], lastOnScreen: Int)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = false
        film.wantsLayer = true
        film.clipsToBounds = false
        film.frame = bounds
        addSubview(film)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                                .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Clips")
        setAccessibilityIdentifier("QuickAccessStrip")
        setAccessibilityOrientation(.horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ rows: [QuickAccessRow], selection: ContentRef?, details: [ContentRef: ClipDetail],
              metrics: StripMetrics, applicationNames: ApplicationNames) {
        let selectionChanged = selection != self.selection
        // Where the newly selected clip was drawn, so that it can slide from there to the middle.
        let start = selectionChanged && metrics == self.metrics ? selection.flatMap { frames[$0]?.frame.midX } : nil
        self.rows = rows
        self.selection = selection
        self.details = details
        self.metrics = metrics
        self.applicationNames = applicationNames
        centredIndex = selection.flatMap { selected in rows.firstIndex { $0.ref == selected } } ?? -1
        if selectionChanged {
            hovered = nil
            settling?.cancel()
            // Under the fingers the frames already follow them; off screen or with Reduce Motion they go
            // straight to their places.
            slideStart = start.flatMap { start in
                guard slidesAreShown, !fingersDown else { return nil }
                return centredIndex + Int(((start - bounds.midX) / metrics.step).rounded())
            }
        }
        placeFrames()
        if selectionChanged, slideStart != nil, let start, let end = selection.flatMap({ frames[$0]?.frame.midX }) {
            settle(after: springBack(from: start - end))
        }
        if selectionChanged { announceSelection() }
        reportFramedRows()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        film.frame = bounds.offsetBy(dx: pushed, dy: 0)
        placeFrames()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    /// A swipe cannot go on in a window that is no longer key, as when the panel closes under the
    /// fingers, so the frames go back to their places instead of waiting for a lift that never comes.
    @objc private func windowDidResignKey(_ notification: Notification) {
        fingersDown = false
        push(to: 0, springing: false)
    }

    // MARK: Frames

    /// The rows that get a frame for middles from `first` to `last`: those on screen and the spare ones.
    private func framedRows(middles first: Int, _ last: Int) -> Range<Int> {
        guard let metrics else { return 0..<0 }
        let reach = metrics.density.rawValue / 2 + Self.spareFrames
        let lower = max(0, first - reach), upper = min(rows.count, last + reach + 1)
        return lower < upper ? lower..<upper : 0..<0
    }

    /// Puts a frame on every row near the middle, and near where a settling slide started. A frame whose
    /// row moves away draws the next row that arrives, so moving along the strip creates no views.
    private func placeFrames() {
        guard let metrics, let applicationNames else { return }
        let start = slideStart ?? centredIndex
        let indices = framedRows(middles: min(start, centredIndex), max(start, centredIndex))
        let wanted = Set(rows[indices].map(\.ref))
        var spare = frames.filter { !wanted.contains($0.key) }.map(\.value)
        frames = frames.filter { wanted.contains($0.key) }
        let origins = StripLayout.frameOrigins(metrics, count: indices.upperBound, centredIndex: centredIndex)
        // The band is centred in the strip, in case the strip is the wider of the two.
        let bandLeft = bounds.midX - metrics.bandWidth / 2
        let y = (bounds.height - metrics.frameSize.height) / 2
        for index in indices {
            let row = rows[index]
            let view = StripFrameView(
                content: StripFrameContent.make(row: row, detail: details[row.ref], density: metrics.density),
                applicationIcon: applicationNames.icon(for: row.sourceApp), density: metrics.density,
                isSelected: row.ref == selection
            )
            let host = frames[row.ref] ?? spare.popLast() ?? addFrame(view)
            frames[row.ref] = host
            host.show(view, for: row, applicationName: row.sourceApp.flatMap(applicationNames.name(for:)),
                      cornerRadius: metrics.cornerRadius, isHovered: row.ref == hovered)
            let rect = NSRect(origin: NSPoint(x: bandLeft + origins[index], y: y), size: metrics.frameSize)
            host.frame = backingAlignedRect(rect, options: .alignAllEdgesNearest)
        }
        spare.forEach { $0.removeFromSuperview() }
    }

    private func addFrame(_ view: StripFrameView) -> StripFrameHost {
        let host = StripFrameHost(view)
        film.addSubview(host)
        return host
    }

    /// Tells the panel which rows have frames, so it reads details for those alone, and how far the
    /// strip reaches, so it loads more rows before the strip runs out.
    private func reportFramedRows() {
        guard let metrics else { return }
        let framed = framedRows(middles: centredIndex, centredIndex)
        // The selected clip first and then outward, so the details nearest the middle are read first.
        let refs = framed.sorted { (abs($0 - centredIndex), $0) < (abs($1 - centredIndex), $1) }.map { rows[$0].ref }
        let lastOnScreen = min(rows.count - 1, centredIndex + metrics.density.rawValue / 2)
        if let reported, reported.refs == refs, reported.lastOnScreen == lastOnScreen,
           refs.allSatisfy({ details[$0] != nil }) { return }
        reported = (refs, lastOnScreen)
        onVisibleRefsChanged?(refs, lastOnScreen)
    }

    // MARK: Motion

    /// Frames slide only on screen, and never with Reduce Motion: they then go straight to their places.
    private var slidesAreShown: Bool {
        window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Starts the frames `displacement` away from where they now belong and lets them spring into place.
    /// Each spring adds to those still running, so a new target takes over at once from wherever the
    /// frames are, without a jump and without waiting for the last one. Returns how long it runs.
    @discardableResult
    private func springBack(from displacement: CGFloat) -> CFTimeInterval {
        guard displacement != 0, let layer = film.layer else { return 0 }
        let spring = CASpringAnimation(perceptualDuration: Self.slideDuration, bounce: Self.slideBounce)
        spring.keyPath = "position.x"
        spring.isAdditive = true
        spring.fromValue = displacement
        spring.toValue = 0
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: nil)
        return spring.duration
    }

    /// Once a slide has come to rest, the frames kept around where it started go.
    private func settle(after delay: CFTimeInterval) {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.slideStart = nil
            self.placeFrames()
        }
    }

    /// Moves the frames off their places by what the fingers have pushed. When the fingers lift, the
    /// frames spring back instead of jumping.
    private func push(to offset: CGFloat, springing: Bool) {
        guard offset != pushed else { return }
        let previous = pushed
        pushed = offset
        setHovered(nil)
        film.frame = bounds.offsetBy(dx: offset, dy: 0)
        if springing, slidesAreShown { springBack(from: previous - offset) }
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard let metrics else { return super.scrollWheel(with: event) }
        let phase = Self.detentPhase(event.phase)
        switch phase {
        case .began, .changed: fingersDown = true
        case .ended, .cancelled: fingersDown = false
        case .none: break
        }
        let output = scroller.handle(DetentInput(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas,
            phase: phase, isMomentum: !event.momentumPhase.isEmpty, time: event.timestamp
        ), olderRoom: rows.count - 1 - centredIndex, newerRoom: max(0, centredIndex))
        if output.steps != 0 { onCommand?(.move(output.steps)) }
        // The scroller has already left out coasting, the mouse wheel and ticks that come too close together.
        if output.ticks == 1, ticksEnabled { haptics.tick() }
        push(to: output.progress * metrics.step + output.rubberBand, springing: !fingersDown)
    }

    /// The phase of a trackpad gesture. Fingers touching down or resting without moving, and events of a
    /// device without phases, change nothing.
    private static func detentPhase(_ phase: NSEvent.Phase) -> DetentPhase {
        switch phase {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        default: .none
        }
    }

    // MARK: Pointer

    /// The frames' drawing never takes the pointer: clicks, menus, scrolling and hovering all come here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        // The click count is not looked at: a double click is two clicks and never copies.
        guard let ref = ref(at: event) else { return super.mouseDown(with: event) }
        onSelect?(ref)
        window?.makeFirstResponder(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        ref(at: event).flatMap { onContextMenu?($0) }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(ref(at: event)) }

    override func mouseMoved(with event: NSEvent) { setHovered(ref(at: event)) }

    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// The row whose frame is under the pointer where it is drawn at this moment, even in mid-slide.
    private func ref(at event: NSEvent) -> ContentRef? {
        var point = film.convert(event.locationInWindow, from: nil)
        if let layer = film.layer, layer.animationKeys()?.isEmpty == false, let drawn = layer.presentation() {
            point.x -= drawn.position.x - layer.position.x
        }
        return frames.first { $0.value.frame.contains(point) }?.key
    }

    /// A faint wash on the frame under the pointer. It only shows the pointer; it never selects.
    private func setHovered(_ ref: ContentRef?) {
        guard ref != hovered else { return }
        hovered = ref
        for (row, host) in frames { host.isHovered = row == ref }
    }

    // MARK: Keys

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: Self.key(for: event), shift: event.modifierFlags.contains(.shift), focus: .results,
            queryIsEmpty: queryIsEmpty, filtersVisible: filtersVisible
        ))
        // A key with no meaning here is dropped, not passed on to end in the alert sound.
        guard command != .passThrough else { return }
        onCommand?(command)
    }

    /// Tab and ⇧Tab are `tab` and `backTab`, and Space, Return and Tab are never typing. Any other key
    /// that types text with neither ⌘ nor ⌃ held is `character`, including a dead key, which types
    /// nothing yet but starts an accent.
    private static func key(for event: NSEvent) -> QuickAccessKey {
        switch Int(event.keyCode) {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_Return, kVK_ANSI_KeypadEnter: return .returnKey
        case kVK_Space: return .space
        case kVK_Escape: return .escape
        case kVK_Tab: return event.modifierFlags.contains(.shift) ? .backTab : .tab
        default:
            guard event.modifierFlags.isDisjoint(with: [.command, .control]) else { return .other }
            let characters = event.characters ?? ""
            let typed = characters.isEmpty ? event.charactersIgnoringModifiers ?? "" : characters
            // Control characters such as Delete, and the function keys' private characters, type nothing.
            let types = !typed.isEmpty && typed.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
            return types ? .character : .other
        }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        // The spare frames beyond the ends of the band are not on screen, so they are not read.
        guard let metrics else { return [] }
        let band = NSRect(x: bounds.midX - metrics.bandWidth / 2, y: bounds.minY, width: metrics.bandWidth,
                          height: bounds.height)
        return frames.values
            .filter { convert($0.frame, from: film).intersects(band) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        selection.flatMap { frames[$0] }.map { [$0] } ?? []
    }

    /// Lets VoiceOver know the selection changed. The list reports it while it has focus; while the keys
    /// go to the search field and the strip only follows them, the new clip is announced as well.
    private func announceSelection() {
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        guard let window, window.isKeyWindow, window.firstResponder !== self,
              let label = selection.flatMap({ frames[$0] })?.accessibilityLabel() else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: label,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// One frame of the strip: the clip drawn by SwiftUI, a faint wash while the pointer is over it, and the
/// one element VoiceOver reads for the frame. Its label and value say what the drawing shows, so the
/// text inside the drawing is not read a second time.
private final class StripFrameHost: NSView {
    private let drawing: NSHostingView<StripFrameView>
    private let wash = HoverWash()
    private var row: QuickAccessRow?
    private var applicationName: String?

    init(_ view: StripFrameView) {
        drawing = NSHostingView(rootView: view)
        super.init(frame: .zero)
        // The selection ring is drawn outside the frame.
        clipsToBounds = false
        drawing.clipsToBounds = false
        drawing.sizingOptions = []
        wash.wantsLayer = true
        wash.layer?.cornerCurve = .continuous
        wash.isHidden = true
        addSubview(drawing)
        addSubview(wash)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isHovered: Bool {
        get { !wash.isHidden }
        set {
            wash.isHidden = !newValue
            // The wash takes its color when it is drawn, which it never is while hidden.
            if newValue { wash.needsDisplay = true }
        }
    }

    func show(_ view: StripFrameView, for row: QuickAccessRow, applicationName: String?, cornerRadius: CGFloat,
              isHovered: Bool) {
        self.row = row
        self.applicationName = applicationName
        wash.layer?.cornerRadius = cornerRadius
        self.isHovered = isHovered
        // A new root view redraws the frame, so an unchanged one is kept.
        let shown = drawing.rootView
        if view.content != shown.content || view.isSelected != shown.isSelected || view.density != shown.density
            || view.applicationIcon !== shown.applicationIcon {
            drawing.rootView = view
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        drawing.frame = bounds
        wash.frame = bounds
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    /// "<kind>, from <App>, <time>: <title>", then the frame's marks. Without a known source app the
    /// "from" part is left out.
    override func accessibilityLabel() -> String? {
        guard let row else { return nil }
        let source = [row.kind.accessibilityName, applicationName.map { "from \($0)" },
                      QuickAccessRowContent.detail(for: row, applicationName: nil)].compactMap { $0 }
        let marks = [(row.savedAsMemo, "Saved as Memo"), (row.isPartiallyIndexed, "Partially indexed"),
                     (row.isTextUnavailable, "Text unavailable")].filter { $0.0 }.map { $0.1 }
        return ([source.joined(separator: ", ") + ": " + row.displayTitle] + marks).joined(separator: ", ")
    }

    /// The frame's info line, such as "25 characters", once the details have arrived.
    override func accessibilityValue() -> Any? { drawing.rootView.content.info }

    override func isAccessibilitySelected() -> Bool { drawing.rootView.isSelected }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? { self }
}

/// A faint wash over a frame, in the label color so that it shows on light and dark paper alike.
private final class HoverWash: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
}
