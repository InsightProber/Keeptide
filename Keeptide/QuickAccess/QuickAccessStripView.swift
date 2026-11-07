import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The strip of clips in the quick access panel. AppKit lays the frames out and owns focus, keys,
/// scrolling, clicks and what VoiceOver reads; SwiftUI draws each frame. Index 0 is at the left and the rest
/// run to its right: with a frequent wing, the wing runs from the least used frequent clip to the most used, and the
/// newest clip follows it, beside the most used; without one, index 0 is the newest clip (or the best match). Older
/// clips run to the newest one's right. A divider stands in the wider gap after the wing, and below the cards a section
/// icon marks each wing beside it. The film of frames keeps the selected clip in the middle of the band, but near
/// either end of the clips it stops at the band's end and the selection walks along it instead.
///
/// The strip shows the selection it is given and nothing else. A click, a key or a swipe only asks for
/// a change through `onSelect` or `onCommand`; the frames move when `show` brings the new selection.
/// A selected frame's ring is drawn outside the frame, so nothing in the strip clips to its bounds.
/// Each row has a frame of its own, so a clip listed in both wings has two, told apart by row ID.
@MainActor
final class QuickAccessStripView: NSView {
    var onSelect: ((QuickAccessRow.ID) -> Void)?
    var onCommand: ((QuickAccessCommand) -> Void)?
    /// A double click asks to act on its clip as Return does, or as ⇧Return does when the second click held ⇧ (`true`).
    var onActivate: ((QuickAccessRow.ID, Bool) -> Void)?
    /// The clips of the rows that have a frame, each once and the selected one first, and the last row on screen,
    /// which decides when to load more. Called when either changes, and again while a framed row has no details.
    var onVisibleRefsChanged: (([ContentRef], Int) -> Void)?
    var onContextMenu: ((QuickAccessRow.ID) -> NSMenu?)?
    var haptics: any HapticPerforming = SystemHaptics()
    /// Whether the trackpad ticks for each step of the selection. The strip moves the same either way.
    var ticksEnabled = true
    /// What a key means here depends on the rest of the panel, which keeps this current.
    var queryIsEmpty = true
    /// With Reduce Motion the frames go straight to their places instead of sliding. Asked each time, since the
    /// setting can change while the app runs.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// With Increase Contrast the divider between the wings is 2 pt wide instead of 1. Asked each time the frames are
    /// placed, and again when the system's display options change.
    var increasesContrast: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    /// The two section icons. The band places this view below the cards, as wide as the band and reaching down to its
    /// bottom edge; it takes no clicks and VoiceOver does not read it.
    let sectionLabels: NSView = StripSectionLabelsView()
    /// While the preview is open, the frames beside the selected one step back to half strength.
    var dimsSideFrames = false {
        didSet { if dimsSideFrames != oldValue { dimSideFrames() } }
    }
    /// Where ⌘K's menu is anchored, in the strip's coordinates: the selected clip's frame where it rests, even in
    /// mid-slide, since the menu does not follow the film. With the selection vanished it is the empty slot where the
    /// newest clip rests as the strip opens: past the divider, just before the newest clip, or before it at the left
    /// dock without a frequent wing. nil without clips.
    var selectionAnchorFrame: NSRect? {
        guard let metrics, let rest = restingPlacement else { return nil }
        let card = frameRect(origin: origin(of: selectedIndex, metrics, in: rest), metrics)
        return convert(StripLayout.scaled(card, by: StripLayout.scale(of: selectedIndex, selected: selectedIndex, metrics)),
                       from: film)
    }

    /// Frames kept beyond each end of the ones on screen, so a step or a push never shows a gap.
    private static let spareFrames = 1
    static let springResponse: CGFloat = 0.35
    static let springDampingRatio: CGFloat = 0.86

    /// Additive values return to their neutral value: zero for geometry, identity for a transform.
    static func spring(_ keyPath: String, from offset: Any) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        let frequency = 2 * CGFloat.pi / springResponse
        spring.mass = 1
        spring.stiffness = frequency * frequency
        spring.damping = 2 * springDampingRatio * frequency
        spring.initialVelocity = 0
        spring.isAdditive = true
        spring.fromValue = offset
        switch keyPath {
        case "transform": spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        case "position": spring.toValue = NSValue(point: .zero)
        case "bounds.size": spring.toValue = NSValue(size: .zero)
        default: spring.toValue = 0
        }
        spring.duration = spring.settlingDuration
        return spring
    }

    private(set) var edgeFades = StripEdgeFades()
    /// Whether per-frame tracking keeps the mask with the drawn film.
    private(set) var isFollowingMotion = false
    private var motionLink: CADisplayLink?
    private let endMask = CAGradientLayer()

    private var rows: [QuickAccessRow] = []
    /// How many rows lead the list as the frequent wing.
    private var frequentCount = 0
    private var selection: QuickAccessRow.ID?
    /// The selected row, or -1 when the selection vanished and its place stays empty: beside the divider, or at the
    /// dock without a frequent wing.
    private var selectedIndex = -1
    /// Whether the last row is the oldest there is. Until it is, the film does not stop at its right end.
    private var oldestIsLoaded = true
    private var details: [ContentRef: ClipDetail] = [:]
    private var metrics: StripMetrics?
    private var applicationNames: ApplicationNames?
    /// The collections a memo's card may name.
    private var collections: [CollectionID: CollectionSummary] = [:]
    /// Every collection's colour, which a snippet's card takes as its accent.
    private var collectionColors: [CollectionID: String] = [:]
    /// Holds the frames and moves them as one: it follows the fingers and carries each slide.
    private let film = NSView()
    private var frames: [QuickAccessRow.ID: StripFrameHost] = [:]
    /// The line between the frequent wing and the recent clips. It lies in the film, so it moves with the frames.
    private let divider = StripDivider()
    private let ring = StripSelectionRing()
    private let frequentLabel = StripSectionLabel.hosted("Frequent", symbol: "flame",
                                                         identifier: "QuickAccessFrequentLabel")
    private let recentLabel = StripSectionLabel.hosted("Recent", symbol: "clock", identifier: "QuickAccessRecentLabel")
    /// The groups VoiceOver reads the two wings in, made once and kept.
    private let frequentGroup = QuickAccessStripView.wingGroup("Frequent", identifier: "QuickAccessFrequentGroup")
    private let recentGroup = QuickAccessStripView.wingGroup("Recent", identifier: "QuickAccessRecentGroup")
    private var scroller = DetentScroller()
    /// How far past the selected clip the fingers have carried the selection, as a share of a step.
    private var progress: CGFloat = 0
    /// How far the fingers stretch an end, positive past the oldest clip, as they last showed it.
    private var rubberBand: CGFloat = 0
    /// How far the fingers have pushed the film off its place: as far as the selection they carry moves it, and
    /// any stretch past an end.
    private var pushed: CGFloat = 0
    private var fingersDown = false
    /// Set while the panel shows a step the scroller asked for, so that `show` can tell it from a change made
    /// elsewhere.
    private var showingScrollStep = false
    /// Where index 0's frame is drawn within the band as the last slide starts, the springs still running then
    /// included. The frames on screen anywhere from there stay until the slides settle, so none vanishes on screen.
    private var slideStart: CGFloat?
    private var settling: Task<Void, Never>?
    /// Springs get names so that `drawnOffset` can tell one is running, since a layer does not list nameless
    /// animations. Each name is new: a spring added under a running one's name would replace it.
    private var springCount = 0
    private var settlingUntil: CFTimeInterval = 0
    private var dividerPush: CGFloat = 0
    private var hovered: QuickAccessRow.ID?
    /// The row chosen by the click that began the current run of clicks on the strip, and when the run's latest press
    /// came.
    private var clickRun: (row: QuickAccessRow.ID, lastPress: TimeInterval)?
    /// A double click's row, and whether its second press held ⇧, until that press is released.
    private var pendingActivation: (row: QuickAccessRow.ID, plainText: Bool)?
    private var reported: (refs: [ContentRef], lastOnScreen: Int)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        film.wantsLayer = true
        film.clipsToBounds = false
        film.frame = bounds
        addSubview(film)
        divider.wantsLayer = true
        divider.isHidden = true
        divider.setAccessibilityIdentifier("QuickAccessDivider")
        film.addSubview(divider)
        ring.wantsLayer = true
        ring.isHidden = true
        ring.setAccessibilityIdentifier("QuickAccessSelectionRing")
        film.addSubview(ring)
        sectionLabels.addSubview(frequentLabel)
        sectionLabels.addSubview(recentLabel)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                                .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Clips")
        setAccessibilityIdentifier("QuickAccessStrip")
        setAccessibilityOrientation(.horizontal)
        for group in [frequentGroup, recentGroup] { group.setAccessibilityParent(self) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    isolated deinit { motionLink?.invalidate() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `oldestIsLoaded` is false while more rows may follow the last one, so the film does not stop there.
    func show(_ rows: [QuickAccessRow], selection: QuickAccessRow.ID?, details: [ContentRef: ClipDetail],
              metrics: StripMetrics, applicationNames: ApplicationNames, oldestIsLoaded: Bool = true,
              collections: [CollectionID: CollectionSummary] = [:], collectionColors: [CollectionID: String] = [:],
              slides: Bool = true) {
        let selectionChanged = selection != self.selection
        // Where the selected clip was drawn, the fingers' push included, so that the film can slide from there to
        // where it now rests: a newly selected clip, or the same one when rows before it come or go or its place
        // moves. The springs still running are read before another joins them. Rows of another list take the place
        // of the last list's where they stand, without sliding.
        let start = slides && metrics == self.metrics
            ? selection.flatMap { frames[$0] }.map { $0.frame.midX - $0.placedPush + pushed } : nil
        let running = drawnOffset
        let previousIndex = selectedIndex
        let previousPush = pushed
        let previousPosition = livePosition
        let previousDividerPush = dividerPush
        let labelsBefore = labelPlaces
        // The row the empty slot of a vanished selection stood before, which goes once a row is chosen among the rows
        // it opened in.
        let closingSlot = previousIndex < 0 ? restingPlacement?.slotBefore : nil
        let rowsBefore = previousIndex < 0 ? self.rows.map(\.id) : nil
        self.rows = rows
        frequentCount = rows.prefix { $0.isFrequent }.count
        self.selection = selection
        self.details = details
        self.metrics = metrics
        self.oldestIsLoaded = oldestIsLoaded
        self.applicationNames = applicationNames
        self.collections = collections
        self.collectionColors = collectionColors
        let index = selection.flatMap { selected in rows.firstIndex { $0.id == selected } } ?? -1
        if index != previousIndex {
            // The fingers carried the clip selected before; their next event measures from this one.
            progress = 0
            // A clip chosen elsewhere, by a key, a click or a refresh, starts the fingers afresh, so that resting
            // fingers do not play their old push back against it.
            if !showingScrollStep {
                scroller = DetentScroller()
                rubberBand = 0
                push(to: 0, springing: false)
            }
        }
        selectedIndex = index
        if selectionChanged { hovered = nil }
        // Rebase the fingers on the new selection before taking the ring's target. A scroll step resets progress;
        // scrollWheel supplies that event's remaining fraction afterward, carrying the film and ring together.
        if fingersDown { follow(progress: progress, rubberBand: rubberBand, springing: false) }
        let rest = restingPlacement
        // The film moves as far as the selected clip does, and slides there on screen without Reduce Motion. A step
        // the fingers take follows them instead, except one that leaves the empty dock, whose slot goes at once; the
        // springs add up, so the step stays smooth.
        var displacement: CGFloat = 0
        var slides = false
        if let rest, let start, index >= 0, slidesAreShown, !(fingersDown && showingScrollStep) || previousIndex < 0 {
            slides = true
            displacement = start - pushed - frameRect(origin: origin(of: index, metrics, in: rest), metrics).midX
        }
        if fingersDown, showingScrollStep, previousIndex >= 0, index >= 0, slidesAreShown {
            let before = StripLayout.placement(metrics, count: rows.count, position: previousPosition,
                                               oldestIsLoaded: oldestIsLoaded, frequentCount: frequentCount,
                                               selected: previousIndex)
            let after = StripLayout.placement(metrics, count: rows.count, position: previousPosition,
                                              oldestIsLoaded: oldestIsLoaded, frequentCount: frequentCount,
                                              selected: index)
            displacement += before.firstOrigin - after.firstOrigin
        }
        if displacement != 0, let rest {
            settling?.cancel()
            // Where index 0's frame starts out, drawn where the springs already running have it too: the frames on
            // screen anywhere from there stay until the slides settle.
            slideStart = rest.firstOrigin + displacement + running
            placeFrames(sliding: displacement - previousPush + pushed, animating: true)
            springBack(film.layer, from: displacement, named: "film")
        } else {
            // A new selection that moves nothing, such as a step along a docked film, keeps the frames for the springs
            // still running, and the settle already on its way lets them go.
            if selectionChanged {
                if running == 0 {
                    settling?.cancel()
                    slideStart = nil
                } else if let rest {
                    slideStart = rest.firstOrigin + running
                }
            }
            placeFrames(sliding: displacement - previousPush + pushed, animating: true)
        }
        // New rows, such as a new query's, select their first row from scratch: the slot went with the rows it opened
        // in, and nothing closes.
        var dividerSpring: CGFloat = 0
        if slides, let closingSlot, closingSlot > 0, rowsBefore == rows.map(\.id) {
            dividerSpring = closeSlot(before: closingSlot, selecting: index, metrics)
        }
        // The icons beside the divider slide as far as it starts out from its place: with the film, and with its own
        // spring as a slot closes.
        placeSectionLabels(from: labelsBefore, sliding: slidesAreShown
                           ? displacement + dividerSpring + previousDividerPush - dividerPush : 0)
        if selectionChanged { announceSelection() }
        reportFramedRows()
        updateEdgeFades()
    }

    /// The empty slot a vanished selection left between the wings goes as `index` is chosen among the same rows:
    /// from `slot` on, the frames close up a step within the film. The film slides with the chosen clip, so the frames
    /// on its side of the slot slide with it from where they were drawn. Those on the other side, and the divider when
    /// it is one of them, would then start a step off, so each springs that step back on its own, and starts out where
    /// it was drawn too. Returns how far the divider's own spring starts it from its place.
    private func closeSlot(before slot: Int, selecting index: Int, _ metrics: StripMetrics) -> CGFloat {
        let chosenAfter = index >= slot
        let places = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        for (id, host) in frames {
            guard let place = places[id], (place >= slot) != chosenAfter else { continue }
            springBack(host.layer, from: place >= slot ? metrics.step : -metrics.step, named: "slot")
        }
        guard chosenAfter else { return 0 }
        springBack(divider.layer, from: -metrics.step, named: "divider-slot")
        return -metrics.step
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        film.frame = bounds.offsetBy(dx: pushed, dy: 0)
        placeFrames()
        updateEdgeFades()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if newWindow == nil { stopMotion() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    /// Display options apply while the panel is open, including ending any deferred icon motion with Reduce Motion.
    @objc private func displayOptionsDidChange(_ notification: Notification) {
        placeFrames()
        placeSectionLabels(from: labelPlaces, sliding: 0, settled: !slidesAreShown)
        updateEdgeFades()
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
        return StripLayout.placement(metrics, count: rows.count, position: position, oldestIsLoaded: oldestIsLoaded,
                                     frequentCount: frequentCount, selected: selectedIndex)
    }

    /// Where the film rests with the selected clip.
    private var restingPlacement: StripPlacement? { placement(at: CGFloat(selectedIndex)) }

    /// Where the fingers have carried the selection: `progress` of a step past the selected clip. A real selection
    /// never goes below 0, where the film would take it for a vanished one.
    private var livePosition: CGFloat {
        let position = CGFloat(selectedIndex) + progress
        return selectedIndex < 0 ? position : max(0, position)
    }

    /// The left edge within the band of the frame at `index` where the film lies at `placement`, the divider's room
    /// included. Index -1 is the empty slot of a vanished selection.
    private func origin(of index: Int, _ metrics: StripMetrics, in placement: StripPlacement) -> CGFloat {
        guard index >= 0 else {
            return StripLayout.slotOrigin(metrics, placement: placement) ?? placement.firstOrigin - metrics.step
        }
        return StripLayout.frameOrigins(metrics, count: index + 1, placement: placement)[index]
    }

    /// A frame whose left edge is `origin` within the band, on whole pixels.
    private func frameRect(origin: CGFloat, _ metrics: StripMetrics) -> NSRect {
        backingAlignedRect(cardRow(from: origin, width: metrics.frameSize.width, metrics),
                           options: .alignAllEdgesNearest)
    }

    /// `width` from `x` within the band, as tall as the frames and level with them.
    private func cardRow(from x: CGFloat, width: CGFloat, _ metrics: StripMetrics) -> NSRect {
        // The band is centred in the strip, in case the strip is the wider of the two.
        NSRect(x: bounds.midX - metrics.bandWidth / 2 + x, y: (bounds.height - metrics.frameSize.height) / 2,
               width: width, height: metrics.frameSize.height)
    }

    /// The first and the last index whose frames reach into the band while index 0's frame starts anywhere in
    /// `origins`, which are measured from the band's left end. Either index may lie beyond the rows there are. The
    /// frames from the divider on stand `dividerExtra` further right, and those from a vanished selection's slot
    /// between the wings on a step further still, so both are reckoned at even steps: the last as if no frame stood
    /// further right, and the first as if every frame did. Either may then take in a row or two more than the band
    /// shows, never fewer, so the spare beyond each end stays spare. Push only moves cards outward; enlargement and
    /// the divider together reach less than one step, so one spare frame at each end also covers their overhang.
    private func rowsOnScreen(_ metrics: StripMetrics, origins: ClosedRange<CGFloat>) -> (first: Int, last: Int) {
        let rest = restingPlacement
        let extra = (rest?.dividerBefore == nil ? 0 : metrics.dividerExtra)
            + ((rest?.slotBefore ?? 0) > 0 ? metrics.step : 0)
        // A frame is on screen while its right edge is past the band's left end and its left edge short of the right.
        return (Int(((-origins.upperBound - extra - metrics.frameSize.width) / metrics.step).rounded(.down)) + 1,
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
    private func placeFrames(sliding displacement: CGFloat = 0, animating: Bool = false) {
        guard let metrics, let applicationNames else { return }
        if !slidesAreShown { stopMotion() }
        let animate = animating && slidesAreShown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rest = restingPlacement
        let indices = rest.map { rest in
            let start = slideStart ?? rest.firstOrigin
            return framedRows(metrics, origins: min(start, rest.firstOrigin)...max(start, rest.firstOrigin))
        } ?? 0..<0
        let wanted = Set(rows[indices].map(\.id))
        var spare = frames.filter { !wanted.contains($0.key) }.map(\.value)
        frames = frames.filter { wanted.contains($0.key) }
        let origins = rest.map { StripLayout.frameOrigins(metrics, count: indices.upperBound, placement: $0) } ?? []
        for index in indices {
            let row = rows[index]
            let icon = applicationNames.icon(for: row.sourceApp)
            // A card in no collection takes its accent from the very icon it shows, worked out with the app's first
            // card.
            let accent = CardAccent(row: row, collectionColors: collectionColors,
                                    tint: row.sourceApp.map { HeaderTint.tint(forIconOf: $0, icon: icon) })
            let view = StripFrameView(
                content: StripFrameContent.make(row: row, detail: details[row.ref], cardSize: metrics.cardSize,
                                                collections: collections),
                applicationIcon: icon, metrics: metrics, accent: accent, isSelected: row.id == selection
            )
            let retained = frames[row.id] != nil
            let host: StripFrameHost
            if let kept = frames[row.id] {
                host = kept
            } else if let reused = spare.popLast() {
                // A frame that takes another row lets go of any spring it ran for the one before.
                Self.removeSprings(from: reused.layer)
                host = reused
            } else {
                host = addFrame(view)
            }
            frames[row.id] = host
            host.show(view, for: row, applicationName: row.sourceApp.flatMap(applicationNames.name(for:)),
                      isHovered: row.id == hovered)
            let push = StripLayout.push(of: index, selected: selectedIndex, metrics)
            let rect = frameRect(origin: origins[index] + push, metrics)
            let oldPush = host.placedPush, oldScale = host.placedScale
            let pushTarget = rect.minX - frameRect(origin: origins[index], metrics).minX
            let scale = StripLayout.scale(of: index, selected: selectedIndex, metrics)
            host.place(at: rect, index: index, push: pushTarget, scale: scale)
            if animate, retained {
                springBack(host.layer, from: oldPush - pushTarget, named: "card-push")
                if oldScale != scale {
                    addSpring(host.layer, keyPath: "transform",
                              from: NSValue(caTransform3D: host.scaleTransform(oldScale / scale)), named: "card-scale")
                }
            }
            // VoiceOver finds a frame in its wing's group, or in the list itself without a wing.
            host.setAccessibilityParent(frequentCount == 0 ? self : row.isFrequent ? frequentGroup : recentGroup)
        }
        spare.forEach { $0.removeFromSuperview() }
        fillWingGroups()
        placeDivider(metrics, at: rest, animating: animate)
        placeRing(metrics, sliding: displacement, animating: animate)
        dimSideFrames()
    }

    /// The divider's line stands in the middle of the wider gap after the frequent wing, as tall as the frames and
    /// level with them: 1 pt wide, and 2 pt with Increase Contrast. Without a wing there is none.
    private func placeDivider(_ metrics: StripMetrics, at rest: StripPlacement?, animating: Bool) {
        guard let line = rest.flatMap({ StripLayout.dividerX(metrics, placement: $0) }) else {
            divider.isHidden = true
            Self.removeSprings(from: divider.layer)
            dividerPush = 0
            return
        }
        let width: CGFloat = increasesContrast() ? 2 : 1
        let push = StripLayout.dividerPush(selected: selectedIndex, frequentCount: frequentCount, metrics)
        let oldPush = dividerPush
        let wasShown = !divider.isHidden
        dividerPush = push
        divider.frame = backingAlignedRect(cardRow(from: line + push - width / 2, width: width, metrics),
                                           options: [.alignMinXNearest, .alignWidthNearest, .alignMinYNearest,
                                                     .alignHeightNearest])
        if animating, wasShown { springBack(divider.layer, from: oldPush - push, named: "divider-push") }
        if divider.isHidden {
            divider.isHidden = false
            // It takes its colour when it is drawn, which it never is while hidden.
            divider.needsDisplay = true
        }
    }

    /// One ring belongs to the strip, outside the scaled card rather than inside its transformed drawing.
    private func placeRing(_ metrics: StripMetrics, sliding displacement: CGFloat, animating: Bool) {
        guard let selection, let host = frames[selection] else {
            ring.isHidden = true
            Self.removeSprings(from: ring.layer)
            return
        }
        let width = StripLayout.selectionRingWidth(increasedContrast: increasesContrast())
        let reach = StripLayout.selectionRingGap + width
        let wasShown = !ring.isHidden
        let oldFrame = ring.frame
        let oldRadius = ring.layer?.cornerRadius ?? 0
        ring.frame = backingAlignedRect(StripLayout.ringFrame(around: host.frame, scale: metrics.selectedScale,
                                                              reach: reach), options: .alignAllEdgesNearest)
        ring.layer?.cornerCurve = .continuous
        ring.layer?.borderWidth = width
        ring.layer?.cornerRadius = metrics.cornerRadius * metrics.selectedScale + reach
        if animating, let layer = ring.layer {
            let before = wasShown ? oldFrame : backingAlignedRect(
                StripLayout.ringFrame(around: host.frame, scale: 1, reach: reach), options: .alignAllEdgesNearest)
            let size = NSSize(width: before.width - ring.frame.width, height: before.height - ring.frame.height)
            let position = NSPoint(x: before.minX - ring.frame.minX + layer.anchorPoint.x * size.width
                                   - (wasShown ? displacement : 0),
                                   y: before.minY - ring.frame.minY + layer.anchorPoint.y * size.height)
            if position != .zero { addSpring(layer, keyPath: "position", from: NSValue(point: position), named: "ring-position") }
            if size != .zero { addSpring(layer, keyPath: "bounds.size", from: NSValue(size: size), named: "ring-size") }
            let radius = (wasShown ? oldRadius : metrics.cornerRadius + reach) - layer.cornerRadius
            if radius != 0 { addSpring(layer, keyPath: "cornerRadius", from: radius, named: "ring-radius") }
        }
        ring.isHidden = false
        ring.needsDisplay = true
    }

    private func drawnRect(of host: StripFrameHost) -> NSRect {
        convert(host.drawnFrame.offsetBy(dx: drawnOffset, dy: 0), from: film)
    }

    /// Where the section labels stand, springs aside; nil for a hidden one.
    private var labelPlaces: StripSectionLabels {
        StripSectionLabels(frequent: frequentLabel.isHidden ? nil : frequentLabel.frame.minX,
                           recent: recentLabel.isHidden ? nil : recentLabel.frame.minX)
    }

    /// Puts the section icons beside the divider where the film lies, the fingers' push included, or one of them at an
    /// end of the band once the divider has gone off that end; without a divider both are hidden. Each is centred
    /// between the band's bottom edge and the ring around a selected card. `shown` is where they stood before the film
    /// moved. While the divider slides from `slide` away, with the film or on its own as a vanished selection's slot
    /// closes, an icon still shown slides from where it is drawn with the same spring, and one that comes into view
    /// rides in with the divider; one that stays where it was, such as one resting at an end, does not move. Without a
    /// slide, and with Reduce Motion, they go straight there. While the film is still sliding or springing back, an
    /// icon still shown is not hidden when the divider leaves its end of the band: it stays beside the divider, with
    /// the film, until the motion has `settled` and each icon goes where the divider puts it.
    private func placeSectionLabels(from shown: StripSectionLabels, sliding slide: CGFloat, settled: Bool = false) {
        var places = StripSectionLabels()
        if let metrics, let rest = restingPlacement, let line = StripLayout.dividerX(metrics, placement: rest) {
            let divider = line + pushed
                + StripLayout.dividerPush(selected: selectedIndex, frequentCount: frequentCount, metrics)
            places = StripLayout.sectionLabelOrigins(metrics, dividerX: divider,
                                                     frequentWidth: frequentLabel.frame.width,
                                                     recentWidth: recentLabel.frame.width)
            if !settled, filmIsSliding {
                let beside = StripLayout.sectionLabelsBeside(dividerX: divider,
                                                             frequentWidth: frequentLabel.frame.width)
                if shown.frequent != nil, places.frequent == nil { places.frequent = beside.frequent }
                if shown.recent != nil, places.recent == nil { places.recent = beside.recent }
            }
        }
        for (label, stood, place) in [(frequentLabel, shown.frequent, places.frequent),
                                      (recentLabel, shown.recent, places.recent)] {
            label.isHidden = place == nil
            guard let place, let metrics else { continue }
            let size = label.frame.size
            label.frame = sectionLabels.backingAlignedRect(
                NSRect(x: place, y: StripLayout.sectionLabelBottom(metrics, height: size.height), width: size.width,
                       height: size.height),
                options: [.alignMinXNearest, .alignWidthNearest, .alignMinYNearest, .alignHeightNearest]
            )
            if slide != 0 { springBack(label.layer, from: stood.map { $0 - label.frame.minX } ?? slide, named: "section-icon") }
        }
    }

    private func dimSideFrames() {
        for (row, host) in frames { host.alphaValue = dimsSideFrames && row != selection ? 0.5 : 1 }
    }

    private func addFrame(_ view: StripFrameView) -> StripFrameHost {
        let host = StripFrameHost(view)
        film.addSubview(host, positioned: .below, relativeTo: ring)
        return host
    }

    /// Tells the panel which rows have frames, so it reads details for those alone, and how far the
    /// strip reaches, so it loads more rows before the strip runs out.
    private func reportFramedRows() {
        guard let metrics else { return }
        let rest = restingPlacement.map { $0.firstOrigin...$0.firstOrigin }
        let framed = rest.map { framedRows(metrics, origins: $0) } ?? 0..<0
        // The selected clip first and then outward, so the details nearest it are read first; with the selection
        // gone, the clips nearest its empty slot. A clip framed in both wings is asked for once, where it is nearest.
        var asked = Set<ContentRef>()
        let centre = selectedIndex >= 0 ? selectedIndex : restingPlacement?.slotBefore ?? 0
        let refs = framed.sorted { (abs($0 - centre), $0) < (abs($1 - centre), $1) }
            .map { rows[$0].ref }.filter { asked.insert($0).inserted }
        let lastOnScreen = rest.map { min(rows.count - 1, rowsOnScreen(metrics, origins: $0).last) } ?? -1
        if let reported, reported.refs == refs, reported.lastOnScreen == lastOnScreen,
           refs.allSatisfy({ details[$0] != nil }) { return }
        reported = (refs, lastOnScreen)
        onVisibleRefsChanged?(refs, lastOnScreen)
    }

    // MARK: Motion

    /// Frames slide only on screen, and never with Reduce Motion: they then go straight to their places.
    private var slidesAreShown: Bool {
        window?.isVisible == true && !reducesMotion()
    }

    /// Whether a slide or a spring back is still moving the film.
    private var filmIsSliding: Bool { film.layer?.animationKeys()?.isEmpty == false }

    /// How far the springs still running draw the film from its place. The presentation layer shows the film as of
    /// the start of the current transaction, so a spring added earlier in the same transaction is missing, and a move
    /// of the film's place made in it is included.
    private var drawnOffset: CGFloat { drawnShift(of: film.layer) }

    /// How far the springs still running on `layer`, the film's or a frame's own, draw it from its place.
    private func drawnShift(of layer: CALayer?) -> CGFloat {
        guard let layer, layer.animationKeys()?.isEmpty == false, let drawn = layer.presentation() else { return 0 }
        return drawn.position.x - layer.position.x
    }

    /// Starts `layer` `displacement` away from where it now belongs and lets it spring into place: the film's, a
    /// section label's, or that of a frame or of the divider closing a vanished selection's slot. Each spring adds to
    /// those still running, so a new target takes over at once from wherever the layer is drawn, without a jump and
    /// without waiting for the last one. Returns how long it runs.
    @discardableResult
    private func springBack(_ layer: CALayer?, from displacement: CGFloat, named name: String = "film") -> CFTimeInterval {
        guard displacement != 0 else { return 0 }
        return addSpring(layer, keyPath: "position.x", from: displacement, named: name)
    }

    @discardableResult
    private func addSpring(_ layer: CALayer?, keyPath: String, from offset: Any, named name: String) -> CFTimeInterval {
        guard slidesAreShown, let layer else { return 0 }
        let spring = Self.spring(keyPath, from: offset)
        springCount += 1
        layer.add(spring, forKey: "strip.\(name).\(springCount)")
        settle(after: spring.duration)
        startFollowingMotion()
        return spring.duration
    }

    private static func removeSprings(from layer: CALayer?) {
        for key in layer?.animationKeys() ?? [] where key.hasPrefix("strip.") { layer?.removeAnimation(forKey: key) }
    }

    private func stopMotion() {
        stopFollowingMotion()
        settling?.cancel()
        settling = nil
        settlingUntil = 0
        slideStart = nil
        for layer in [film.layer, divider.layer, ring.layer, frequentLabel.layer, recentLabel.layer]
            + frames.values.map(\.layer) { Self.removeSprings(from: layer) }
    }

    /// Once a slide or a spring back has come to rest, the frames kept around where it started go, and so does a label
    /// kept beside the divider after the divider left the band.
    private func settle(after delay: CFTimeInterval) {
        settling?.cancel()
        let now = CACurrentMediaTime()
        settlingUntil = max(settlingUntil, now + delay)
        let remaining = settlingUntil - now
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.settlingUntil = 0
            self.slideStart = nil
            self.placeFrames()
            self.placeSectionLabels(from: self.labelPlaces, sliding: 0, settled: true)
            self.updateEdgeFades()
            // AppKit pauses display-link callbacks for hidden/offscreen views. The independent settle deadline
            // still releases its run-loop source and target after the last spring's lifetime.
            if self.window?.isVisible != true || self.isHiddenOrHasHiddenAncestor || self.visibleRect.isEmpty
                || self.window?.occlusionState.contains(.visible) != true {
                self.stopFollowingMotion()
            } else {
                self.finishFollowingMotionIfSettled()
            }
        }
    }

    /// Moves the frames off their places by what the fingers have pushed, and the section labels with them. When the
    /// fingers lift, the frames and the labels spring back instead of jumping. The wings' groups follow the frames, so
    /// VoiceOver finds each group where its frames now are.
    private func push(to offset: CGFloat, springing: Bool) {
        if !slidesAreShown { stopMotion() }
        guard offset != pushed else { return }
        let previous = pushed
        let labels = labelPlaces
        pushed = offset
        setHovered(nil)
        film.frame = bounds.offsetBy(dx: offset, dy: 0)
        let slide = springing && slidesAreShown ? previous - offset : 0
        if slide != 0 { springBack(film.layer, from: slide) }
        placeSectionLabels(from: labels, sliding: slide)
        fillWingGroups()
        updateEdgeFades()
    }

    /// The fingers have carried the selection `progress` of a step past the selected clip and stretched an end by
    /// `rubberBand`, positive past the oldest clip. The film moves as far as its place moves with the selection,
    /// which is not at all while the selection walks along a docked film, and the stretch pulls it the way the
    /// fingers go.
    private func follow(progress: CGFloat, rubberBand: CGFloat, springing: Bool) {
        self.progress = progress
        self.rubberBand = rubberBand
        var offset = -rubberBand
        if let rest = restingPlacement, let carried = placement(at: livePosition) {
            offset += carried.firstOrigin - rest.firstOrigin
        }
        push(to: offset, springing: springing)
    }

    // MARK: Edge fades

    /// Uses presentation geometry only while this strip owns a spring on that layer. AppKit can leave a stale
    /// presentation after a direct model update, which must not hold an immediate (Reduce Motion) fade back.
    private static func hasSprings(_ layer: CALayer?) -> Bool {
        layer?.animationKeys()?.contains { $0.hasPrefix("strip.") } == true
    }

    private var hasMotion: Bool {
        ([film.layer, divider.layer, ring.layer, frequentLabel.layer, recentLabel.layer]
            + frames.values.map(\.layer)).contains { Self.hasSprings($0) }
    }

    /// Takes the fades from where the film is drawn now, and sets the mask to them.
    func updateEdgeFades() {
        guard let metrics else { return }
        if !metrics.fadesEnds { stopFollowingMotion() }
        let bandMinX = bounds.midX - metrics.bandWidth / 2
        func edge(of row: QuickAccessRow?, leading: Bool) -> CGFloat {
            guard let row, let host = frames[row.id] else {
                return leading ? -StripLayout.fadeRamp : metrics.bandWidth + StripLayout.fadeRamp
            }
            let layer = host.layer
            let rect = Self.hasSprings(layer) ? host.drawnFrame : layer?.frame ?? host.frame
            let drawn = convert(rect.offsetBy(dx: drawnOffset, dy: 0), from: film)
            return (leading ? drawn.minX : drawn.maxX) - bandMinX
        }
        edgeFades = rows.isEmpty ? StripEdgeFades()
            : StripLayout.edgeFades(metrics, filmLeft: edge(of: rows.first, leading: true),
                                    filmRight: edge(of: rows.last, leading: false))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard bounds.width > 0, let stops = StripLayout.fadeStops(metrics, fades: edgeFades) else {
            layer?.mask = nil
            return
        }
        endMask.startPoint = CGPoint(x: 0, y: 0.5)
        endMask.endPoint = CGPoint(x: 1, y: 0.5)
        endMask.frame = bounds.insetBy(dx: 0, dy: -bounds.height)
        endMask.colors = stops.map { NSColor.black.withAlphaComponent($0.opacity).cgColor }
        endMask.locations = stops.map { NSNumber(value: Double((bandMinX + $0.x) / bounds.width)) }
        layer?.mask = endMask
    }

    private func startFollowingMotion() {
        guard metrics?.fadesEnds == true, motionLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(followMotion(_:)))
        motionLink = link
        isFollowingMotion = true
        link.add(to: .main, forMode: .common)
    }

    private func stopFollowingMotion() {
        motionLink?.invalidate()
        motionLink = nil
        isFollowingMotion = false
    }

    private func finishFollowingMotionIfSettled() {
        if !hasMotion { stopFollowingMotion() }
    }

    @objc private func followMotion(_ link: CADisplayLink) {
        updateEdgeFades()
        finishFollowingMotionIfSettled()
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
        // The scroller counts toward older clips, which lie to the right: content moving left brings them in. From a
        // vanished selection's slot, the rows before it are the newer ones.
        let slot = selectedIndex < 0 ? restingPlacement?.slotBefore ?? 0 : nil
        let output = scroller.handle(DetentInput(
            deltaX: -event.scrollingDeltaX, deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas,
            phase: phase, isMomentum: !event.momentumPhase.isEmpty, time: event.timestamp
        ), olderRoom: rows.count - (slot ?? selectedIndex + 1), newerRoom: slot ?? selectedIndex)
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

    /// A click that the system counts as one more of a run continues the strip's run when the strip took the run's
    /// previous press within the double-click interval: it goes to the clip the run's first click chose, even after the
    /// film has slid and another frame lies under the pointer. Any other click starts a run on the clip under the
    /// pointer, as when the run's first click closed the preview. A double click begun on the strip asks to act on its
    /// clip once the second press is released.
    override func mouseDown(with event: NSEvent) {
        pendingActivation = nil
        let continuesRun: Bool
        if event.clickCount > 1, let run = clickRun, event.timestamp - run.lastPress <= NSEvent.doubleClickInterval {
            clickRun = (run.row, event.timestamp)
            continuesRun = true
        } else {
            clickRun = row(at: event).map { ($0, event.timestamp) }
            continuesRun = false
        }
        guard let row = clickRun?.row else { return super.mouseDown(with: event) }
        if continuesRun, event.clickCount == 2 {
            pendingActivation = (row, event.modifierFlags.contains(.shift))
        }
        onSelect?(row)
        window?.makeFirstResponder(self)
    }

    /// Acting waits for the release: hiding the panel with the button down would leave the release to the window
    /// beneath. A third click acts no more.
    override func mouseUp(with event: NSEvent) {
        guard let pending = pendingActivation else { return super.mouseUp(with: event) }
        pendingActivation = nil
        onActivate?(pending.row, pending.plainText)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        row(at: event).flatMap { onContextMenu?($0) }
    }

    override func mouseEntered(with event: NSEvent) { setHovered(row(at: event)) }

    override func mouseMoved(with event: NSEvent) { setHovered(row(at: event)) }

    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// The row whose frame is under the pointer where it is drawn at this moment, even in mid-slide, and even while a
    /// frame closing a vanished selection's slot runs a spring of its own.
    private func row(at event: NSEvent) -> QuickAccessRow.ID? {
        var point = film.convert(event.locationInWindow, from: nil)
        point.x -= drawnOffset
        if let selection, let host = frames[selection], host.drawnFrame.contains(point) { return selection }
        return frames.first { $0.value.drawnFrame.contains(point) }?.key
    }

    /// A faint wash on the frame under the pointer. It only shows the pointer; it never selects.
    private func setHovered(_ row: QuickAccessRow.ID?) {
        guard row != hovered else { return }
        hovered = row
        for (framed, host) in frames { host.isHovered = framed == row }
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

    /// The frames on screen, left to right: the frequent wing first, from the least used clip to the most used, and
    /// then the newest clip, or the best match. With a frequent wing they are read in two groups, "Frequent" and
    /// "Recent", and a group without a frame on screen is left out.
    override func accessibilityChildren() -> [Any]? {
        frequentCount == 0 ? framesOnScreen.map(\.host) : fillWingGroups()
    }

    /// The frames VoiceOver reads, left to right, with the rows they show. The spare frames beyond the ends of the band
    /// are not on screen, so they are not read.
    private var framesOnScreen: [(row: QuickAccessRow.ID, host: StripFrameHost)] {
        guard let metrics else { return [] }
        let band = NSRect(x: bounds.midX - metrics.bandWidth / 2, y: bounds.minY, width: metrics.bandWidth,
                          height: bounds.height)
        return frames.map { (row: $0.key, host: $0.value) }
            .filter { drawnRect(of: $0.host).intersects(band) }
            .sorted { $0.host.frame.minX < $1.host.frame.minX }
    }

    /// A group VoiceOver reads one wing in, by the wing's name; UI tests find it by `identifier`. The strip is its
    /// parent and gives it its frames.
    private static func wingGroup(_ name: String, identifier: String) -> NSAccessibilityElement {
        let group = NSAccessibilityElement()
        group.setAccessibilityRole(.group)
        group.setAccessibilityLabel(name)
        group.setAccessibilityIdentifier(identifier)
        return group
    }

    /// Gives each wing's group the wing's frames on screen and the room they take together in the strip, and returns
    /// the groups that have any. Without a wing both are left empty. The groups are filled again each time the frames
    /// are placed or pushed, so a group never holds a frame that has gone or now shows another row, and covers its
    /// frames where the fingers have carried them.
    @discardableResult
    private func fillWingGroups() -> [Any] {
        let onScreen = frequentCount == 0 ? [] : framesOnScreen
        return [(frequentGroup, true), (recentGroup, false)].compactMap { group, frequent in
            let hosts = onScreen.filter { $0.row.isFrequent == frequent }.map(\.host)
            let rects = hosts.map { drawnRect(of: $0) }
            group.setAccessibilityChildren(hosts)
            group.setAccessibilityFrameInParentSpace(rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) })
            return hosts.isEmpty ? nil : group
        }
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
    private(set) var placedIndex = -1
    private(set) var placedPush: CGFloat = 0
    private(set) var placedScale: CGFloat = 1

    var drawnFrame: NSRect {
        guard let layer else { return frame }
        return (layer.presentation() ?? layer).frame
    }

    func place(at rect: NSRect, index: Int, push: CGFloat, scale: CGFloat) {
        placedIndex = index
        placedPush = push
        placedScale = scale
        frame = rect
        applyScale()
    }

    /// All relative scale springs share the same centre as the model transform, so they compose without drift.
    func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        let anchor = layer?.anchorPoint ?? .zero
        let cx = (0.5 - anchor.x) * bounds.width
        let cy = (0.5 - anchor.y) * bounds.height
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = cx * (1 - scale)
        transform.m42 = cy * (1 - scale)
        return transform
    }

    private func applyScale() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = scaleTransform(placedScale)
        CATransaction.commit()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        applyScale()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // AppKit synchronizes a backing layer after layout and may replace its transform. Restore our scale after
        // that synchronization as well as after frame changes, including the first draw in a SwiftUI container.
        applyScale()
    }

    override func accessibilityFrame() -> NSRect {
        guard let film = superview, let window else { return super.accessibilityFrame() }
        let shift = (film.layer?.presentation()?.position.x ?? film.layer?.position.x ?? 0)
            - (film.layer?.position.x ?? 0)
        return window.convertToScreen(film.convert(drawnFrame.offsetBy(dx: shift, dy: 0), to: nil))
    }

    init(_ view: StripFrameView) {
        drawing = NSHostingView(rootView: view)
        super.init(frame: .zero)
        // The shadow extends outside the frame.
        wantsLayer = true
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
            || view.accent != shown.accent || view.applicationIcon !== shown.applicationIcon {
            drawing.rootView = view
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        drawing.frame = bounds
        wash.frame = bounds
        applyScale()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    /// "<kind>, <time>, from <App>, <footer>: <title>", then the frame's marks: the card's band and footer in the
    /// order the card shows them, then the title it shows, such as a link's page title rather than its address.
    /// Without a known source app the "from" part is left out, and the footer, such as "25 characters" or "2880 by
    /// 1800", until the details have arrived. A frequent clip says how often it was used in place of the time, as its
    /// card does: "Text, used 12 times: <title>". A memo is a snippet, said with where it is filed and whether it is a
    /// favorite: "Snippet in Prompts, favorite, <time>: <title>".
    override func accessibilityLabel() -> String? {
        guard let row else { return nil }
        let content = drawing.rootView.content
        let when = row.frequentUses.map { ClipInfoFormatter.uses($0, spoken: true) }
            ?? QuickAccessRowContent.time(of: row.date, spoken: true)
        let what = content.facet == .memo
            ? "Snippet" + (content.collection.map { " in \($0.name)" } ?? "") + (content.isFavorite ? ", favorite" : "")
            : row.kind.accessibilityName
        let card = [what, when, applicationName.map { "from \($0)" }, content.info.map(ClipInfoFormatter.spoken)]
        let marks = [(row.savedAsMemo, "Saved as Snippet"), (row.isPartiallyIndexed, "Partially indexed"),
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

/// The strip's single selection ring. It follows system accent changes and never takes pointer or accessibility input.
private final class StripSelectionRing: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerCurve = .continuous
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// The line between the frequent wing and the recent clips, in the colour of the line over each card's footer.
private final class StripDivider: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ToolbarPalette.divider.cgColor
    }
}

/// Holds the section icons where the band places it. It takes no clicks, and VoiceOver reads none of it. AppKit shows
/// an icon's help tag all the same, since it finds help tags by where the pointer rests, not by hit-testing.
private final class StripSectionLabelsView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? { [] }
}

/// A section icon below the strip: the wing's symbol alone, 11 pt semibold in the toolbar's secondary colour. No name
/// is drawn beside it; its help tag and its accessibility label give the name. The tests measure the ink it draws, so
/// it is not private.
struct StripSectionLabel: View {
    /// The symbol's size: a step under the toolbar's 12 pt type, and small enough that its 12 pt of ink keeps 4 pt
    /// from the band's bottom edge and from the ring around the selected card above it.
    static let pointSize: CGFloat = 11

    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: Self.pointSize, weight: .semibold))
            .foregroundStyle(Color(nsColor: ToolbarPalette.secondary))
            .fixedSize()
            // The hosting view carries the wing's name; the symbol itself is for the eye alone.
            .accessibilityHidden(true)
    }

    /// The icon hosted for AppKit, hidden until it is placed: as wide and as high as its symbol in whole points, and
    /// kept as far above the bottom of the view holding it as it is put, whatever height that view is given. `title`,
    /// the wing's name, is its help tag and its accessibility label.
    static func hosted(_ title: String, symbol: String, identifier: String) -> NSHostingView<StripSectionLabel> {
        let label = NSHostingView(rootView: StripSectionLabel(symbol: symbol))
        let size = label.fittingSize
        label.sizingOptions = []
        label.wantsLayer = true
        label.frame.size = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        label.autoresizingMask = [.maxYMargin]
        label.isHidden = true
        label.toolTip = title
        label.setAccessibilityLabel(title)
        label.setAccessibilityIdentifier(identifier)
        return label
    }
}
