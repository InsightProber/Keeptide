import AppKit

/// How large the strip's cards are, as the Settings window offers it. Stored as the raw value.
enum CardSize: String, CaseIterable, Sendable {
    case small, medium, large
}

/// How the strip draws its selected card, as Settings chose it when the panel opened.
struct StripStyle: Equatable, Sendable {
    /// From the selected card as large as the others to a quarter larger.
    static let scaleRange: ClosedRange<CGFloat> = 1.0...1.25
    /// The selected card a little larger than the others, as Settings has it until it is changed.
    static let standard = StripStyle(selectedScale: 1.12)
    /// How much larger the selected card is drawn than the others, kept within `scaleRange`.
    let selectedScale: CGFloat

    /// A scale outside `scaleRange` is taken to its nearer end, and one that is not a number to no enlargement.
    init(selectedScale: CGFloat) {
        self.selectedScale = selectedScale.isNaN ? Self.scaleRange.lowerBound
            : min(max(selectedScale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }
}

/// Frame sizes for one card size and screen width.
struct StripMetrics: Equatable {
    let cardSize: CardSize
    let bandWidth: CGFloat
    let frameSize: CGSize
    let gap: CGFloat
    let cornerRadius: CGFloat
    /// How far in from the band's ends the film rests when it stops there.
    let dockInset: CGFloat
    /// The colour band across the top of a frame.
    let headerHeight: CGFloat
    /// The line along a frame's bottom edge.
    let footerHeight: CGFloat
    /// Side of the source app's icon in the colour band.
    let iconSize: CGFloat
    /// From the toolbar's bottom edge to the cards: 20 pt, and the distance the enlarged selected card reaches above
    /// the others.
    let toolbarGap: CGFloat
    /// From the cards to the band's bottom edge: 22 pt, or 28 with the frequent wing turned on, so that its section
    /// icons have room there below the ring around a selected card; and the distance the enlarged selected card reaches
    /// below the others.
    let bottomPadding: CGFloat
    /// How much larger the selected card is drawn than the others. Metrics made up for a test leave it at 1, and the
    /// push at 0, so that the strip lies as it did before the selected card was enlarged.
    var selectedScale: CGFloat = 1
    /// How far each neighbour of the selected card stands aside from its place, to keep clear of the enlarged card's
    /// ring.
    var neighbourPush: CGFloat = 0

    /// How far the enlarged selected card reaches past an unscaled card's top and bottom edges.
    var selectionGrowth: CGFloat { StripLayout.selectionGrowth(scale: selectedScale, cardHeight: frameSize.height) }
    /// Distance between the left edges of neighbouring frames.
    var step: CGFloat { frameSize.width + gap }
    /// What the divider adds to the gap after the frequent wing: a third of a card, rounded (67 / 76 / 87).
    var dividerExtra: CGFloat { (frameSize.width / 3).rounded() }
    /// The middle of a frame, between its colour band and its footer, where the clip itself is drawn.
    var contentSize: CGSize {
        CGSize(width: frameSize.width, height: max(0, frameSize.height - headerHeight - footerHeight))
    }
}

/// Where the film of frames lies in the band.
struct StripPlacement: Equatable {
    /// The left edge of index 0's frame within the band.
    let firstOrigin: CGFloat
    /// The first recent row's index when the frequent wing comes before it; from there each frame stands
    /// `dividerExtra` further right. nil without a divider.
    var dividerBefore: Int? = nil
    /// The row a vanished selection's empty slot stands just before: the newest recent clip, past the divider, or index
    /// 0 without a frequent wing. From a slot after index 0 on, each frame stands a step further right; `firstOrigin`
    /// already makes room for one before index 0. nil while a row is selected.
    var slotBefore: Int? = nil
}

/// Where the section icons lie in the band: their left edges, and nil for an icon that is hidden.
struct StripSectionLabels: Equatable {
    var frequent: CGFloat? = nil
    var recent: CGFloat? = nil
}

/// Geometry of the quick access strip. The band is the bar holding the toolbar and the frames; the panel is the
/// window around it. All values are in points.
enum StripLayout {
    /// From the band's top edge to its toolbar, and the toolbar's height. Below the toolbar, `StripMetrics.toolbarGap`
    /// lies between it and the cards, and below the cards `StripMetrics.bottomPadding`.
    static let toolbarTop: CGFloat = 16
    static let toolbarHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 36
    /// How far a section icon stands from the divider's line.
    static let sectionLabelGap: CGFloat = 8
    /// No section icon stands closer than this to either end of the band: one that follows the divider toward an end
    /// stops here, and one whose wing alone is left at that end rests here. The band's corners are rounded over
    /// `cornerRadius`; this far in, the ink of either icon keeps about 10 pt from the rounded corner, 2 more than the 8
    /// it needs, so a symbol drawn a little differently on another release of macOS still clears it. At the dock inset
    /// it came within 2 pt of the corner, at 40 pt the flame cleared 8 pt by less than half a point, and beside a
    /// divider resting 34 to 66 pt from an end it came within 0.4 to 4 pt.
    static let sectionLabelPinInset: CGFloat = 42
    /// From a selected card's edge to the inner edge of the ring around it.
    static let selectionRingGap: CGFloat = 3
    /// How far beyond a selected card the ring around it reaches: 6 pt, and 7 with Increase Contrast. The section icons
    /// below the cards are kept clear of the wider ring.
    static let selectionRingReach = selectionRingGap + selectionRingWidth(increasedContrast: true)
    /// The neighbours of a selected card enlarged by 1.12 or more stand at least this far aside.
    static let minimumNeighbourPush: CGFloat = 18
    /// The band stands this far in from each side of the screen's visible area. The panel reaches the edge, so its
    /// shadow has that room beside the band.
    static let sideMargin: CGFloat = 32
    /// The room the panel gives the band's shadow above and below it, where the screen's visible area has it.
    static let shadowRoom = (above: CGFloat(40), below: CGFloat(100))
    /// When the preview card moves the band down, the two keep this far from the visible area's top and bottom where
    /// it is tall enough for them.
    static let screenMargin: CGFloat = 24
    static let previewGap: CGFloat = 16
    static let previewMaximum = CGSize(width: 760, height: 470)
    /// The preview card is never lower than this, however low the screen.
    static let previewMinimumHeight: CGFloat = 160

    /// The frames are as large on every screen as the card size makes them; a narrow screen shows fewer of them.
    /// The band is as wide as the visible area less the margin at each side. Above and below the cards it has room for
    /// the selected card as `style` enlarges it: the 20 pt between the toolbar and the cards, and the 22 pt below them,
    /// each grow by `selectionGrowth`. With the frequent wing turned on, the room below the cards is 6 pt more, for the
    /// section icons in it, and the band is that much taller. It stays so while the strip shows no wing, as for a
    /// search, so the band keeps its height while it is open.
    static func metrics(for size: CardSize, visibleWidth: CGFloat, showsFrequentClips: Bool = false,
                        style: StripStyle = .standard) -> StripMetrics {
        let card = cardDimensions(for: size)
        let gap: CGFloat = 14
        let growth = selectionGrowth(scale: style.selectedScale, cardHeight: card.frame.height)
        return StripMetrics(
            cardSize: size, bandWidth: visibleWidth - 2 * sideMargin, frameSize: card.frame, gap: gap,
            cornerRadius: card.radius, dockInset: 20, headerHeight: card.header, footerHeight: card.footer,
            iconSize: card.icon, toolbarGap: 20 + growth, bottomPadding: (showsFrequentClips ? 28 : 22) + growth,
            selectedScale: style.selectedScale,
            neighbourPush: neighbourPush(scale: style.selectedScale, cardWidth: card.frame.width, gap: gap)
        )
    }

    /// The width of the ring around a selected card: 3 pt, and 4 with Increase Contrast.
    static func selectionRingWidth(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 4 : 3
    }

    /// How far each neighbour of a card enlarged by `scale` stands aside so that the card's ring keeps 2 pt from it, or
    /// 1 pt from Increase Contrast's wider ring. The enlarged card reaches (scale − 1)·cardWidth/2 into the `gap` on
    /// either side, and its ring 6 pt beyond that. From 1.12 on the neighbours stand at least `minimumNeighbourPush`
    /// aside; below that, in proportion to the enlargement, so that at 1.00 they stand where they did before the
    /// selected card was enlarged. The millionth taken off keeps a sum that should be whole from rounding up to the
    /// next point when the arithmetic leaves it a hair over.
    static func neighbourPush(scale: CGFloat, cardWidth: CGFloat, gap: CGFloat) -> CGFloat {
        let reach = selectionRingGap + selectionRingWidth(increasedContrast: false)
        let clear = ((scale - 1) * cardWidth / 2 + reach + 2 - gap - 0.000001).rounded(.up)
        return max(clear, min(minimumNeighbourPush, minimumNeighbourPush * (scale - 1) / 0.12))
    }

    /// How far a card enlarged by `scale` about its middle reaches past its unscaled top and bottom edges, in whole
    /// points: 15 for a medium card at 1.12. The millionth taken off keeps 15 from rounding up to 16 where the
    /// arithmetic leaves it a hair over.
    static func selectionGrowth(scale: CGFloat, cardHeight: CGFloat) -> CGFloat {
        max(((scale - 1) * cardHeight / 2 - 0.000001).rounded(.up), 0)
    }

    /// How many of the newest clips the band shows whole as the strip opens with `frequentCount` frequent clips before
    /// them and the newest selected: from the newest clip on, the cards that end short of the right dock. A wing long
    /// enough to put the newest clip in the middle leaves floor((bandWidth/2 + W/2 + gap − dockInset) / step) of them
    /// whole, the newest and those wholly right of the middle. A shorter wing rests at the left dock with the newest
    /// clip left of the middle, which leaves more whole; and without a wing the newest clip rests at the left dock
    /// itself, which leaves floor((bandWidth − 2·dockInset + gap) / step). So the count never grows with the wing. A
    /// band too narrow for one shows none, never fewer.
    static func recentShownWhole(_ m: StripMetrics, frequentCount: Int) -> Int {
        let wing = max(0, frequentCount)
        // A film with no end in sight, so that it neither centres as a short group nor stops at its oldest end: the
        // band's whole-card count does not depend on how many clips there are.
        let film = placement(m, count: wing + 1, position: CGFloat(wing), oldestIsLoaded: false, frequentCount: wing)
        let newest = frameOrigins(m, count: wing + 1, placement: film)[wing]
        return max(0, Int(((m.bandWidth - m.dockInset - newest + m.gap) / m.step).rounded(.down)))
    }

    /// How far below the band's top edge the cards' top edges are: 68, and the enlarged selected card's growth; 83 with
    /// medium cards at the standard enlargement.
    static func cardTop(_ m: StripMetrics) -> CGFloat {
        toolbarTop + toolbarHeight + m.toolbarGap
    }

    /// The toolbar, the cards and the room around them: 370 with medium cards at the standard enlargement, 376 with
    /// the frequent wing; 340 and 346 with the selected card not enlarged.
    static func bandHeight(_ m: StripMetrics) -> CGFloat {
        cardTop(m) + m.frameSize.height + m.bottomPadding
    }

    /// How far above the band's bottom edge a section icon `height` tall starts: centred between that edge and the
    /// lowest reach of the ring around the enlarged selected card, its growth and then `selectionRingReach` below the
    /// cards. A 15 pt icon starts 3 above the edge in the frequent wing's room below the cards, at every enlargement.
    static func sectionLabelBottom(_ m: StripMetrics, height: CGFloat) -> CGFloat {
        (m.bottomPadding - m.selectionGrowth - selectionRingReach - height) / 2
    }

    /// The band, centred in the screen's visible area. Its height is the same whatever the panel shows, so its top
    /// edge, and the search in it, stay where they are.
    static func bandFrame(_ m: StripMetrics, in visible: NSRect) -> NSRect {
        let height = bandHeight(m)
        return NSRect(x: visible.midX - m.bandWidth / 2, y: visible.midY - height / 2, width: m.bandWidth,
                      height: height)
    }

    /// Where the film lies when the row at `position` is selected; `position` is fractional while the fingers
    /// follow. Index 0 sits at the left and the rest run to its right: with `frequentCount` frequent rows leading, they
    /// run from the least used frequent clip to the most used, which stands beside the newest clip; without them index
    /// 0 is the newest clip (or the best match). When recent rows follow the frequent ones, a divider makes the gap
    /// between the two wings `dividerExtra` wider, and the film is that much wider too. The film moves to keep the
    /// selection in the middle of the band, but stops with its first frame `dockInset` from the band's left end, so
    /// the selection then walks along the film instead. The right end stops the same way once `oldestIsLoaded`; before
    /// that more clips may follow, so the film goes on moving. A loaded film that fits between the docks is centred as
    /// a group. A negative `position` (-1) stands for a selection that vanished: the film lies as if a selected empty
    /// slot stood where the newest clip rests as the strip opens, past the divider, or before index 0 without one, with
    /// the newest clip a step to its right. Going from a negative position to a row, the slot goes and the frames after
    /// it step left at once; that step is deliberate, since the slot belongs to no clip.
    static func placement(_ m: StripMetrics, count: Int, position: CGFloat, oldestIsLoaded: Bool,
                          frequentCount: Int = 0) -> StripPlacement {
        let dividerBefore = frequentCount > 0 && frequentCount < count ? frequentCount : nil
        let extra = dividerBefore == nil ? 0 : m.dividerExtra
        let slot = position < 0 ? dividerBefore ?? 0 : nil
        let filmWidth = CGFloat(slot == nil ? count : count + 1) * m.step - m.gap + extra
        // How far along the film the selected place's left edge lies. Past the divider it is `extra` further; carried
        // across the divider's gap by the fingers, it takes its share of the extra, so the film moves without a jump.
        let selected = slot.map { CGFloat($0) * m.step + extra }
            ?? position * m.step + extra * min(1, max(0, position - CGFloat(frequentCount - 1)))
        let filmStart: CGFloat
        if oldestIsLoaded && filmWidth <= m.bandWidth - 2 * m.dockInset {
            filmStart = (m.bandWidth - filmWidth) / 2
        } else {
            let centred = m.bandWidth / 2 - m.frameSize.width / 2 - selected
            let lowest = oldestIsLoaded ? m.bandWidth - m.dockInset - filmWidth : -.infinity
            filmStart = min(m.dockInset, max(lowest, centred))
        }
        // A slot before index 0 is where the film starts, and index 0 stands a step to its right.
        return StripPlacement(firstOrigin: slot == 0 ? filmStart + m.step : filmStart, dividerBefore: dividerBefore,
                              slotBefore: slot)
    }

    /// The left edge of each frame within the band, one step apart from index 0 at `placement.firstOrigin` on,
    /// `dividerExtra` further right from the divider on, and a step further right from a vanished selection's slot on
    /// where it stands after index 0.
    static func frameOrigins(_ m: StripMetrics, count: Int, placement: StripPlacement) -> [CGFloat] {
        let divider = placement.dividerBefore ?? count
        let slot = placement.slotBefore.flatMap { $0 > 0 ? $0 : nil } ?? count
        return (0..<count).map {
            placement.firstOrigin + CGFloat($0) * m.step + ($0 < divider ? 0 : m.dividerExtra)
                + ($0 < slot ? 0 : m.step)
        }
    }

    /// The left edge within the band of a vanished selection's empty slot: a step before the row it stands before.
    /// nil while a row is selected.
    static func slotOrigin(_ m: StripMetrics, placement: StripPlacement) -> CGFloat? {
        placement.slotBefore.map { frameOrigins(m, count: $0 + 1, placement: placement)[$0] - m.step }
    }

    /// The middle of the divider's line within the band, halfway between the last frequent frame and the first recent
    /// one: firstOrigin + k·step + (dividerExtra − gap) / 2. nil without a divider.
    static func dividerX(_ m: StripMetrics, placement: StripPlacement) -> CGFloat? {
        placement.dividerBefore.map { placement.firstOrigin + CGFloat($0) * m.step + (m.dividerExtra - m.gap) / 2 }
    }

    /// Where the section icons go with the divider's line at `dividerX` within the band. Each stands beside the line,
    /// "Frequent" ending `sectionLabelGap` short of it and "Recent" starting as far past it, but never closer to either
    /// end of the band than `sectionLabelPinInset`, which keeps it out of the band's rounded corner: it follows the
    /// line until it reaches that inset, then stays there, as a sticky header does. Once the line has passed an icon
    /// it would mark the other wing, its own having gone off that end, so it is hidden; the other icon stays on its own
    /// side of the line, so the two never meet, and rests at that end once the line has gone off it.
    static func sectionLabelOrigins(_ m: StripMetrics, dividerX: CGFloat, frequentWidth: CGFloat,
                                    recentWidth: CGFloat) -> StripSectionLabels {
        func kept(_ x: CGFloat, width: CGFloat) -> CGFloat {
            min(max(x, sectionLabelPinInset), m.bandWidth - sectionLabelPinInset - width)
        }
        let frequent = kept(dividerX - sectionLabelGap - frequentWidth, width: frequentWidth)
        let recent = kept(dividerX + sectionLabelGap, width: recentWidth)
        return StripSectionLabels(frequent: frequent + frequentWidth <= dividerX ? frequent : nil,
                                  recent: recent >= dividerX ? recent : nil)
    }

    /// Where the section icons stand beside the divider's line at `dividerX`, kept from neither end: "Frequent" ends
    /// `sectionLabelGap` short of the line and "Recent" starts as far past it. An icon leaving with the film goes
    /// there.
    static func sectionLabelsBeside(dividerX: CGFloat, frequentWidth: CGFloat) -> StripSectionLabels {
        StripSectionLabels(frequent: dividerX - sectionLabelGap - frequentWidth, recent: dividerX + sectionLabelGap)
    }

    /// The card goes above the band, which stays where it is. Where the card has no room above it, the
    /// card and the band are centred vertically as one group, so the band moves down to make room. The card is
    /// at most `previewMaximum`; when the room is smaller it shrinks to fit, in height and in width, but never below
    /// `previewMinimumHeight`. A group too tall for the room between the screen margins takes the visible area's
    /// whole height, and one too tall even for that rests on the visible area's bottom with the card at its top, over
    /// the band's top edge.
    static func previewLayout(band: NSRect, in visible: NSRect) -> (preview: NSRect, band: NSRect) {
        let room = visible.insetBy(dx: sideMargin, dy: screenMargin)
        let size = CGSize(width: min(previewMaximum.width, room.width),
                          height: max(previewMinimumHeight,
                                      min(previewMaximum.height, room.height - band.height - previewGap)))
        var movedBand = band
        if band.maxY + previewGap + size.height > room.maxY {
            let groupHeight = size.height + previewGap + band.height
            let area = groupHeight <= room.height ? room : visible
            movedBand.origin.y = max(area.midY - groupHeight / 2, area.minY)
        }
        let preview = NSRect(x: band.midX - size.width / 2,
                             y: min(movedBand.maxY + previewGap, visible.maxY - size.height),
                             width: size.width, height: size.height)
        return (preview, movedBand)
    }

    /// The window around the band, and around the preview card when it is open: `sideMargin` beside them, and
    /// above and below as much of `shadowRoom` as the visible area has, so the window never leaves it.
    static func panelFrame(band: NSRect, preview: NSRect?, in visible: NSRect) -> NSRect {
        let content = preview.map { band.union($0) } ?? band
        let above = max(0, min(shadowRoom.above, visible.maxY - content.maxY))
        let below = max(0, min(shadowRoom.below, content.minY - visible.minY))
        return NSRect(x: content.minX - sideMargin, y: content.minY - below, width: content.width + 2 * sideMargin,
                      height: content.height + above + below)
    }

    /// A frame's size, the heights of its colour band and its footer, the side of the app icon in the band, and the
    /// radius of its corners, which grows with the card.
    static func cardDimensions(
        for size: CardSize
    ) -> (frame: CGSize, header: CGFloat, footer: CGFloat, icon: CGFloat, radius: CGFloat) {
        switch size {
        case .small: (CGSize(width: 200, height: 220), 52, 28, 36, 18)
        case .medium: (CGSize(width: 228, height: 250), 56, 30, 40, 20)
        case .large: (CGSize(width: 260, height: 286), 60, 32, 44, 22)
        }
    }
}
