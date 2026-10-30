import AppKit

/// How large the strip's cards are, as the Settings window offers it. Stored as the raw value.
enum CardSize: String, CaseIterable, Sendable {
    case small, medium, large
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
}

/// Where the section labels lie in the band: their left edges, and nil for a label that is hidden.
struct StripSectionLabels: Equatable {
    var frequent: CGFloat? = nil
    var recent: CGFloat? = nil
}

/// Geometry of the quick access strip. The band is the bar holding the toolbar and the frames; the panel is the
/// window around it. All values are in points.
enum StripLayout {
    /// From the band's top edge to its toolbar, and the toolbar's height.
    static let toolbarTop: CGFloat = 16
    static let toolbarHeight: CGFloat = 32
    /// From the toolbar's bottom edge to the cards, and from the cards to the band's bottom edge.
    static let toolbarGap: CGFloat = 20
    static let bottomPadding: CGFloat = 22
    /// How far below the band's top edge the cards' top edges are.
    static let cardTop = toolbarTop + toolbarHeight + toolbarGap
    static let cornerRadius: CGFloat = 36
    /// How far a section label stands from the divider's line.
    static let sectionLabelGap: CGFloat = 8
    /// How far above the cards' top a section label ends, its descenders included. The ring around a selected card
    /// reaches 6 pt above it, 7 with Increase Contrast, so every glyph of a label stays clear of it.
    static let sectionLabelClearance: CGFloat = 8
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
    /// The band is as wide as the visible area less the margin at each side.
    static func metrics(for size: CardSize, visibleWidth: CGFloat) -> StripMetrics {
        let card = cardDimensions(for: size)
        return StripMetrics(
            cardSize: size, bandWidth: visibleWidth - 2 * sideMargin, frameSize: card.frame, gap: 14,
            cornerRadius: card.radius, dockInset: 20, headerHeight: card.header, footerHeight: card.footer,
            iconSize: card.icon
        )
    }

    /// Cards the band shows whole between its docks: floor((bandWidth − 2·dockInset + gap) / step). A band too narrow
    /// for one shows none, never fewer.
    static func firstScreenCount(_ m: StripMetrics) -> Int {
        max(0, Int(((m.bandWidth - 2 * m.dockInset + m.gap) / m.step).rounded(.down)))
    }

    /// The toolbar, the cards and the room around them: 340 with medium cards.
    static func bandHeight(_ m: StripMetrics) -> CGFloat {
        cardTop + m.frameSize.height + bottomPadding
    }

    /// The band, centred in the screen's visible area. Its height is the same whatever the panel shows, so its top
    /// edge, and the search in it, stay where they are.
    static func bandFrame(_ m: StripMetrics, in visible: NSRect) -> NSRect {
        let height = bandHeight(m)
        return NSRect(x: visible.midX - m.bandWidth / 2, y: visible.midY - height / 2, width: m.bandWidth,
                      height: height)
    }

    /// Where the film lies when the row at `position` is selected; `position` is fractional while the fingers
    /// follow. Index 0 sits at the left and the rest run to its right: with `frequentCount` frequent rows leading,
    /// index 0 is the most used frequent clip; without them it is the newest clip (or the best match). When recent
    /// rows follow the frequent ones, a divider makes the gap between the two wings `dividerExtra` wider, and the film
    /// is that much wider too. The film moves to keep the selection in the middle of the band, but stops with its
    /// first frame `dockInset` from the band's left end, so the selection then walks along the film instead. The
    /// right end stops the same way once `oldestIsLoaded`; before that more clips may follow, so the film goes on
    /// moving. A loaded film that fits between the docks is centred as a group. A negative `position` (-1) stands for
    /// a selection that vanished: the film lies as if a selected empty slot came before index 0, and index 0
    /// sits one step to the right of that slot. Going from a negative position to 0, the slot goes and the film
    /// steps left at once; that step is deliberate, since the slot belongs to no clip.
    static func placement(_ m: StripMetrics, count: Int, position: CGFloat, oldestIsLoaded: Bool,
                          frequentCount: Int = 0) -> StripPlacement {
        let vanished = position < 0
        let slots = CGFloat(vanished ? count + 1 : count)
        let dividerBefore = frequentCount > 0 && frequentCount < count ? frequentCount : nil
        let extra = dividerBefore == nil ? 0 : m.dividerExtra
        let filmWidth = slots * m.step - m.gap + extra
        // How far along the film the selected frame's left edge lies. Past the divider it is `extra` further; carried
        // across the divider's gap by the fingers, it takes its share of the extra, so the film moves without a jump.
        let selected = vanished ? 0
            : position * m.step + extra * min(1, max(0, position - CGFloat(frequentCount - 1)))
        let slotOrigin: CGFloat
        if oldestIsLoaded && filmWidth <= m.bandWidth - 2 * m.dockInset {
            slotOrigin = (m.bandWidth - filmWidth) / 2
        } else {
            let centred = m.bandWidth / 2 - m.frameSize.width / 2 - selected
            let lowest = oldestIsLoaded ? m.bandWidth - m.dockInset - filmWidth : -.infinity
            slotOrigin = min(m.dockInset, max(lowest, centred))
        }
        return StripPlacement(firstOrigin: vanished ? slotOrigin + m.step : slotOrigin, dividerBefore: dividerBefore)
    }

    /// The left edge of each frame within the band, one step apart from index 0 at `placement.firstOrigin` on, and
    /// `dividerExtra` further right from the divider on.
    static func frameOrigins(_ m: StripMetrics, count: Int, placement: StripPlacement) -> [CGFloat] {
        let divider = placement.dividerBefore ?? count
        return (0..<count).map { placement.firstOrigin + CGFloat($0) * m.step + ($0 < divider ? 0 : m.dividerExtra) }
    }

    /// The middle of the divider's line within the band, halfway between the last frequent frame and the first recent
    /// one: firstOrigin + k·step + (dividerExtra − gap) / 2. nil without a divider.
    static func dividerX(_ m: StripMetrics, placement: StripPlacement) -> CGFloat? {
        placement.dividerBefore.map { placement.firstOrigin + CGFloat($0) * m.step + (m.dividerExtra - m.gap) / 2 }
    }

    /// Where the section labels go with the divider's line at `dividerX` within the band. "Frequent" ends
    /// `sectionLabelGap` short of the line and "Recent" starts as far past it, so the two never meet. Where that would
    /// take "Recent" past the left dock, the frequent wing has gone off the band's left end: "Recent" rests at
    /// `dockInset` and "Frequent" is hidden. Where it would take "Frequent" past the right dock, the recent clips have
    /// gone off the right end: "Frequent" ends `dockInset` from it and "Recent" is hidden. "Recent" is placed by its
    /// left edge alone, so `recentWidth` changes neither.
    static func sectionLabelOrigins(_ m: StripMetrics, dividerX: CGFloat, frequentWidth: CGFloat,
                                    recentWidth: CGFloat) -> StripSectionLabels {
        if dividerX + sectionLabelGap < m.dockInset {
            return StripSectionLabels(recent: m.dockInset)
        }
        if dividerX - sectionLabelGap > m.bandWidth - m.dockInset {
            return StripSectionLabels(frequent: m.bandWidth - m.dockInset - frequentWidth)
        }
        return sectionLabelsBeside(dividerX: dividerX, frequentWidth: frequentWidth)
    }

    /// Where the section labels stand beside the divider's line at `dividerX`, resting at neither dock: "Frequent" ends
    /// `sectionLabelGap` short of the line and "Recent" starts as far past it.
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
