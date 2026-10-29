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
    /// The middle of a frame, between its colour band and its footer, where the clip itself is drawn.
    var contentSize: CGSize {
        CGSize(width: frameSize.width, height: max(0, frameSize.height - headerHeight - footerHeight))
    }
}

/// Where the film of frames lies in the band.
struct StripPlacement: Equatable {
    /// The left edge of index 0's frame within the band.
    let firstOrigin: CGFloat
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
    /// The band stands this far in from each side of the screen's visible area. The panel reaches the edge, so its
    /// shadow has that room beside the band.
    static let sideMargin: CGFloat = 32
    /// The room the panel gives the band's shadow above and below it, where the screen's visible area has it.
    static let shadowRoom = (above: CGFloat(40), below: CGFloat(100))
    /// When the preview card moves the band down, the two keep at least this far from the visible area's top and
    /// bottom.
    static let screenMargin: CGFloat = 24
    static let previewGap: CGFloat = 16
    static let previewMaximum = CGSize(width: 760, height: 470)

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

    /// Where the film lies when the clip at `position` is selected; `position` is fractional while the fingers
    /// follow. Index 0 is the newest (or best match) and sits at the left, older clips to its right. The film
    /// moves to keep the selection in the middle of the band, but stops with its first frame `dockInset` from
    /// the band's left end, so the selection then walks along the film instead. The right end stops the same
    /// way once `oldestIsLoaded`; before that more clips may follow, so the film goes on moving. A loaded film
    /// that fits between the docks is centred as a group. A negative `position` (-1) stands for a
    /// selection that vanished: the film lies as if a selected empty slot came before index 0, and index 0
    /// sits one step to the right of that slot. Going from a negative position to 0, the slot goes and the film
    /// steps left at once; that step is deliberate, since the slot belongs to no clip.
    static func placement(_ m: StripMetrics, count: Int, position: CGFloat, oldestIsLoaded: Bool) -> StripPlacement {
        let vanished = position < 0
        let slots = CGFloat(vanished ? count + 1 : count)
        let selected = vanished ? 0 : position
        let filmWidth = slots * m.step - m.gap
        let slotOrigin: CGFloat
        if oldestIsLoaded && filmWidth <= m.bandWidth - 2 * m.dockInset {
            slotOrigin = (m.bandWidth - filmWidth) / 2
        } else {
            let centred = m.bandWidth / 2 - m.frameSize.width / 2 - selected * m.step
            let lowest = oldestIsLoaded ? m.bandWidth - m.dockInset - filmWidth : -.infinity
            slotOrigin = min(m.dockInset, max(lowest, centred))
        }
        return StripPlacement(firstOrigin: vanished ? slotOrigin + m.step : slotOrigin)
    }

    /// The left edge of each frame within the band, one step apart from index 0 at `placement.firstOrigin` on.
    static func frameOrigins(_ m: StripMetrics, count: Int, placement: StripPlacement) -> [CGFloat] {
        (0..<count).map { placement.firstOrigin + CGFloat($0) * m.step }
    }

    /// The card goes above the band, which stays where it is. Where the card has no room above it, the
    /// card and the band are centred vertically as one group, so the band moves down to make room. The card is
    /// at most `previewMaximum`; when the room is smaller it shrinks to fit, in height and in width.
    static func previewLayout(band: NSRect, in visible: NSRect) -> (preview: NSRect, band: NSRect) {
        let room = visible.insetBy(dx: sideMargin, dy: screenMargin)
        let size = CGSize(width: min(previewMaximum.width, room.width),
                          height: min(previewMaximum.height, room.height - band.height - previewGap))
        var movedBand = band
        if band.maxY + previewGap + size.height > room.maxY {
            let groupHeight = size.height + previewGap + band.height
            movedBand.origin.y = max(room.midY - groupHeight / 2, room.minY)
        }
        let preview = NSRect(x: band.midX - size.width / 2, y: movedBand.maxY + previewGap,
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
