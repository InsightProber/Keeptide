import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The strip of clips in the quick access panel. AppKit lays the frames out and owns focus, keys,
/// scrolling, clicks and what VoiceOver reads; SwiftUI draws each frame. The newest clip is at the left
/// and older clips run to its right. The film of frames keeps the selected clip in the middle of the band,
/// but near either end of the clips it stops at the band's end and the selection walks along it instead.
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
    /// Whether the trackpad ticks for each step of the selection. The strip moves the same either way.
    var ticksEnabled = true
    /// What a key means here depends on the rest of the panel, which keeps this current.
    var queryIsEmpty = true
    /// While the preview is open, the frames beside the selected one step back to half strength.
    var dimsSideFrames = false {
        didSet { if dimsSideFrames != oldValue { dimSideFrames() } }
    }
    /// The selected clip's frame in the strip's coordinates, or nil while nothing is selected.
    var selectedFrame: NSRect? {
        selection.flatMap { frames[$0] }.map { convert($0.frame, from: film) }
    }

    /// Frames kept beyond each end of the ones on screen, so a step or a push never shows a gap.
    private static let spareFrames = 1
    /// A step takes about this long and ends with a slight bounce.
    private static let slideDuration: CFTimeInterval = 0.2
    private static let slideBounce: CGFloat = 0.15

    private var rows: [QuickAccessRow] = []
    private var selection: ContentRef?
    /// The selected row, or -1 when the selection vanished and its place at the dock stays empty.
    private var selectedIndex = -1
    /// Whether the last row is the oldest there is. Until it is, the film does not stop at its right end.
    private var oldestIsLoaded = true
    private var details: [ContentRef: ClipDetail] = [:]
    private var metrics: StripMetrics?
    private var applicationNames: ApplicationNames?
    /// Holds the frames and moves them as one: it follows the fingers and carries each slide.
    private let film = NSView()
    private var frames: [ContentRef: StripFrameHost] = [:]
    private var scroller = DetentScroller()
    /// How far past the selected clip the fingers have carried the selection, as a share of a step.
    private var progress: CGFloat = 0
    /// How far the fingers have pushed the film off its place: as far as the selection they carry moves it, and
    /// any stretch past an end.
    private var pushed: CGFloat = 0
    private var fingersDown = false
    /// Set while the panel shows a step the scroller asked for, so that `show` can tell it from a change made
    /// elsewhere.
    private var showingScrollStep = false
    /// Where index 0's frame was when a slide started, within the band. The frames on screen there stay until the
    /// slide settles, so none vanishes on screen.
    private var slideStart: CGFloat?
    private var settling: Task<Void, Never>?
    /// Springs get names so that `ref(at:)` can tell one is running, since a layer does not list nameless
    /// animations. Each name is new: a spring added under a running one's name would replace it.
    private var springCount = 0
    private var hovered: ContentRef?
    /// The clip chosen by the click that began the current run of clicks.
    private var clickedRef: ContentRef?
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

    /// `oldestIsLoaded` is false while more rows may follow the last one, so the film does not stop there.
    func show(_ rows: [QuickAccessRow], selection: ContentRef?, details: [ContentRef: ClipDetail],
              metrics: StripMetrics, applicationNames: ApplicationNames, oldestIsLoaded: Bool = true) {
        let selectionChanged = selection != self.selection
        // Where the selected clip was drawn, so that the film can slide from there to where it now rests: a newly
        // selected clip, or the same one when rows before it come or go or its place moves.
        let start = metrics == self.metrics ? selection.flatMap { frames[$0]?.frame.midX } : nil
        let previousIndex = selectedIndex
        self.rows = rows
        self.selection = selection
        self.details = details
        self.metrics = metrics
        self.oldestIsLoaded = oldestIsLoaded
        self.applicationNames = applicationNames
        let index = selection.flatMap { selected in rows.firstIndex { $0.ref == selected } } ?? -1
        if index != previousIndex {
            // The fingers carried the clip selected before; their next event measures from this one.
            progress = 0
            // A clip chosen elsewhere, by a key, a click or a refresh, starts the fingers afresh, so that resting
            // fingers do not play their old push back against it.
            if !showingScrollStep {
                scroller = DetentScroller()
                push(to: 0, springing: false)
            }
        }
        selectedIndex = index
        if selectionChanged { hovered = nil }
        let rest = restingPlacement
        // The film moves as far as the selected clip does. It slides there on screen without Reduce Motion. Under
        // the fingers it follows them instead, except when it leaves the empty dock, whose slot goes at once; the
        // springs add up, so the step stays smooth.
        var displacement: CGFloat = 0
        if let rest, let start, index >= 0, slidesAreShown, !fingersDown || previousIndex < 0 {
            displacement = start - frameRect(origin: rest.firstOrigin + CGFloat(index) * metrics.step, metrics).midX
        }
        if displacement != 0, let rest {
            settling?.cancel()
            // Where index 0's frame starts out: the frames on screen there stay until the slide settles.
            slideStart = rest.firstOrigin + displacement
            placeFrames()
            settle(after: springBack(from: displacement))
        } else {
            if selectionChanged {
                settling?.cancel()
                slideStart = nil
            }
            placeFrames()
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
    /// fingers, so the frames go back to their places instead of waiting for a lift that never comes, and
    /// the scroller forgets the push it would otherwise report again with the next event.
    @objc private func windowDidResignKey(_ notification: Notification) {
        fingersDown = false
        scroller = DetentScroller()
        follow(progress: 0, rubberBand: 0, springing: false)
    }

    // MARK: Frames

    /// Where the film lies with the selection at `position`, which is fractional while the fingers carry it. Nil
    /// while there are no clips: there is no film to place then.
    private func placement(at position: CGFloat) -> StripPlacement? {
        guard let metrics, !rows.isEmpty else { return nil }
        return StripLayout.placement(metrics, count: rows.count, position: position, oldestIsLoaded: oldestIsLoaded)
    }

    /// Where the film rests with the selected clip.
    private var restingPlacement: StripPlacement? { placement(at: CGFloat(selectedIndex)) }

    /// Where the fingers have carried the selection: `progress` of a step past the selected clip. A real selection
    /// never goes below 0, where the film would take it for a vanished one.
    private var livePosition: CGFloat {
        let position = CGFloat(selectedIndex) + progress
        return selectedIndex < 0 ? position : max(0, position)
    }

    /// A frame whose left edge is `origin` within the band, on whole pixels.
    private func frameRect(origin: CGFloat, _ metrics: StripMetrics) -> NSRect {
        // The band is centred in the strip, in case the strip is the wider of the two.
        let rect = NSRect(origin: NSPoint(x: bounds.midX - metrics.bandWidth / 2 + origin,
                                          y: (bounds.height - metrics.frameSize.height) / 2), size: metrics.frameSize)
        return backingAlignedRect(rect, options: .alignAllEdgesNearest)
    }

    /// The first and the last index whose frames reach into the band while index 0's frame starts anywhere in
    /// `origins`, which are measured from the band's left end. Either index may lie beyond the rows there are.
    private func rowsOnScreen(_ metrics: StripMetrics, origins: ClosedRange<CGFloat>) -> (first: Int, last: Int) {
        // A frame is on screen while its right edge is past the band's left end and its left edge short of the right.
        (Int(((-origins.upperBound - metrics.frameSize.width) / metrics.step).rounded(.down)) + 1,
         Int(((metrics.bandWidth - origins.lowerBound) / metrics.step).rounded(.up)) - 1)
    }

    /// The rows that get a frame while index 0's frame starts anywhere in `origins`: those on screen, and a spare
    /// beyond each end.
    private func framedRows(_ metrics: StripMetrics, origins: ClosedRange<CGFloat>) -> Range<Int> {
        let onScreen = rowsOnScreen(metrics, origins: origins)
        let lower = max(0, onScreen.first - Self.spareFrames)
        let upper = min(rows.count, onScreen.last + 1 + Self.spareFrames)
        return lower < upper ? lower..<upper : 0..<0
    }

    /// Puts a frame on every row on screen, and on those on screen where a settling slide started, and on a spare
    /// beyond each end. A frame whose row moves away draws the next row that arrives, so moving along the strip
    /// creates no views.
    private func placeFrames() {
        guard let metrics, let applicationNames else { return }
        let rest = restingPlacement
        let indices = rest.map { rest in
            let start = slideStart ?? rest.firstOrigin
            return framedRows(metrics, origins: min(start, rest.firstOrigin)...max(start, rest.firstOrigin))
        } ?? 0..<0
        let wanted = Set(rows[indices].map(\.ref))
        var spare = frames.filter { !wanted.contains($0.key) }.map(\.value)
        frames = frames.filter { wanted.contains($0.key) }
        let origins = rest.map { StripLayout.frameOrigins(metrics, count: indices.upperBound, placement: $0) } ?? []
        for index in indices {
            let row = rows[index]
            let icon = applicationNames.icon(for: row.sourceApp)
            let view = StripFrameView(
                content: StripFrameContent.make(row: row, detail: details[row.ref], cardSize: metrics.cardSize),
                applicationIcon: icon, metrics: metrics,
                // The band takes its colour from the very icon the frame shows, worked out with the app's first frame.
                headerTint: row.sourceApp.map { HeaderTint.tint(forIconOf: $0, icon: icon) },
                isSelected: row.ref == selection
            )
            let host = frames[row.ref] ?? spare.popLast() ?? addFrame(view)
            frames[row.ref] = host
            host.show(view, for: row, applicationName: row.sourceApp.flatMap(applicationNames.name(for:)),
                      isHovered: row.ref == hovered)
            host.frame = frameRect(origin: origins[index], metrics)
        }
        spare.forEach { $0.removeFromSuperview() }
        dimSideFrames()
    }

    private func dimSideFrames() {
        for (row, host) in frames { host.alphaValue = dimsSideFrames && row != selection ? 0.5 : 1 }
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
        let rest = restingPlacement.map { $0.firstOrigin...$0.firstOrigin }
        let framed = rest.map { framedRows(metrics, origins: $0) } ?? 0..<0
        // The selected clip first and then outward, so the details nearest it are read first.
        let refs = framed.sorted { (abs($0 - selectedIndex), $0) < (abs($1 - selectedIndex), $1) }.map { rows[$0].ref }
        let lastOnScreen = rest.map { min(rows.count - 1, rowsOnScreen(metrics, origins: $0).last) } ?? -1
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
        springCount += 1
        layer.add(spring, forKey: "spring \(springCount)")
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

    /// The fingers have carried the selection `progress` of a step past the selected clip and stretched an end by
    /// `rubberBand`, positive past the oldest clip. The film moves as far as its place moves with the selection,
    /// which is not at all while the selection walks along a docked film, and the stretch pulls it the way the
    /// fingers go.
    private func follow(progress: CGFloat, rubberBand: CGFloat, springing: Bool) {
        self.progress = progress
        var offset = -rubberBand
        if let rest = restingPlacement, let carried = placement(at: livePosition) {
            offset += carried.firstOrigin - rest.firstOrigin
        }
        push(to: offset, springing: springing)
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard metrics != nil else { return super.scrollWheel(with: event) }
        let phase = Self.detentPhase(event.phase)
        switch phase {
        case .began, .changed: fingersDown = true
        case .ended, .cancelled: fingersDown = false
        case .none: break
        }
        // The scroller counts toward older clips, which lie to the right: content moving left brings them in.
        let output = scroller.handle(DetentInput(
            deltaX: -event.scrollingDeltaX, deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas,
            phase: phase, isMomentum: !event.momentumPhase.isEmpty, time: event.timestamp
        ), olderRoom: rows.count - 1 - selectedIndex, newerRoom: max(0, selectedIndex))
        if output.steps != 0 {
            showingScrollStep = true
            onCommand?(.move(output.steps))
            showingScrollStep = false
        }
        // The scroller has already left out coasting, the mouse wheel and ticks that come too close together.
        if output.ticks == 1, ticksEnabled { haptics.tick() }
        follow(progress: output.progress, rubberBand: output.rubberBand, springing: !fingersDown)
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
        // A double click is a click: it never copies, and its second click goes to the clip the first one
        // chose, even after the film has slid and another frame lies under the pointer.
        if event.clickCount <= 1 { clickedRef = ref(at: event) }
        guard let ref = clickedRef else { return super.mouseDown(with: event) }
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
        let key = Self.key(for: event)
        // A held Space, Return or Escape has acted already.
        guard !(event.isARepeat && key.actsOnceWhenHeld) else { return }
        let command = QuickAccessKeyRouter.command(for: QuickAccessKeyInput(
            key: key, shift: event.modifierFlags.contains(.shift), focus: .results, queryIsEmpty: queryIsEmpty
        ))
        // A key with no meaning here is dropped, not passed on to end in the alert sound.
        guard command != .passThrough else { return }
        onCommand?(command)
    }

    /// Tab and ⇧Tab are `tab` and `backTab`, and Space, Return and Tab are never typing. Any other key
    /// that types text with neither ⌘ nor ⌃ held is `character`, including a dead key, which types
    /// nothing yet but starts an accent.
    static func key(for event: NSEvent) -> QuickAccessKey {
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
        // The spare frames beyond the ends of the band are not on screen, so they are not read. Left to right is
        // newest first, the order of the rows.
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

    func show(_ view: StripFrameView, for row: QuickAccessRow, applicationName: String?, isHovered: Bool) {
        self.row = row
        self.applicationName = applicationName
        wash.layer?.cornerRadius = view.metrics.cornerRadius
        self.isHovered = isHovered
        // A new root view redraws the frame, so an unchanged one is kept.
        let shown = drawing.rootView
        if view.content != shown.content || view.isSelected != shown.isSelected || view.metrics != shown.metrics
            || view.headerTint != shown.headerTint || view.applicationIcon !== shown.applicationIcon {
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

    /// "<kind>, <time>, from <App>, <footer>: <title>", then the frame's marks: the card's band and footer in the
    /// order the card shows them, then the title it shows, such as a link's page title rather than its address.
    /// Without a known source app the "from" part is left out, and the footer, such as "25 characters" or "2880 by
    /// 1800", until the details have arrived.
    override func accessibilityLabel() -> String? {
        guard let row else { return nil }
        let content = drawing.rootView.content
        let card = [row.kind.accessibilityName, QuickAccessRowContent.time(of: row.date, spoken: true),
                    applicationName.map { "from \($0)" }, content.info.map(ClipInfoFormatter.spoken)]
        let marks = [(row.savedAsMemo, "Saved as Memo"), (row.isPartiallyIndexed, "Partially indexed"),
                     (row.isTextUnavailable, "Text unavailable")].filter { $0.0 }.map { $0.1 }
        return ([card.compactMap { $0 }.joined(separator: ", ") + ": " + content.accessibilityTitle] + marks)
            .joined(separator: ", ")
    }

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
