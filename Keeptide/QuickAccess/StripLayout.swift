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

/// Where the film of frames lies in the band, and which ends of the band have more content beyond them.
struct StripPlacement: Equatable {
    /// The left edge of index 0's frame within the band.
    let firstOrigin: CGFloat
    /// The film goes on to the left of its dock position, so the band's left end fades out.
    let fadesLeading: Bool
    /// The film goes on to the right of its dock position, or more clips may follow, so the band's right end
    /// fades out.
    let fadesTrailing: Bool
}

/// Geometry of the quick access strip. The band is the glass bar holding the search row, the
/// frames and the caption; the panel is the window around it. All values are in points.
enum StripLayout {
    /// The share of the band's width that fades out at each end.
    static let fade: CGFloat = 0.14
    static let searchHeight: CGFloat = 70
    static let captionHeight: CGFloat = 60
    static let filterHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 30
    /// The band stands this far in from each side of the screen's visible area. The panel, which reaches the edge,
    /// has that room beside the band for the key-cap hint and the shadow.
    static let sideMargin: CGFloat = 32
    /// Panel room above and below the band for the shadow.
    static let shadowMargin: CGFloat = 24
    static let previewGap: CGFloat = 16
    static let previewMaximum = CGSize(width: 760, height: 470)

    /// The frames are as large on every screen as the card size makes them; a narrow screen shows fewer of them.
    /// The band is as wide as the visible area less the margin at each side.
    static func metrics(for size: CardSize, visibleWidth: CGFloat) -> StripMetrics {
        let card = cardDimensions(for: size)
        return StripMetrics(
            cardSize: size, bandWidth: visibleWidth - 2 * sideMargin, frameSize: card.frame, gap: 14,
            cornerRadius: 14, dockInset: 20, headerHeight: card.header, footerHeight: card.footer, iconSize: card.icon
        )
    }

    static func bandHeight(_ m: StripMetrics, filtersVisible: Bool) -> CGFloat {
        searchHeight + m.frameSize.height + captionHeight + (filtersVisible ? filterHeight : 0)
    }

    /// The band. Its top edge is where it is when the band without the filter row is centred in the screen's
    /// visible area, so the filter row moves only the strip and the caption below the search row, never the
    /// search field under the caret. On a screen too short for that, the band moves up just enough for the
    /// panel to stay inside the visible area.
    static func bandFrame(_ m: StripMetrics, filtersVisible: Bool, in visible: NSRect) -> NSRect {
        let height = bandHeight(m, filtersVisible: filtersVisible)
        let top = visible.midY + bandHeight(m, filtersVisible: false) / 2
        return NSRect(x: visible.midX - m.bandWidth / 2, y: max(top - height, visible.minY + shadowMargin),
                      width: m.bandWidth, height: height)
    }

    /// Where the film lies when the clip at `position` is selected; `position` is fractional while the fingers
    /// follow. Index 0 is the newest (or best match) and sits at the left, older clips to its right. The film
    /// moves to keep the selection in the middle of the band, but stops with its first frame `dockInset` from
    /// the band's left end, so the selection then walks along the film instead. The right end stops the same
    /// way once `oldestIsLoaded`; before that more clips may follow, so the film goes on moving. An end fades
    /// when the film goes on beyond its dock, and the right end also fades while more clips may follow. A
    /// loaded film that fits between the docks is centred as a group. A negative `position` (-1) stands for a
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
        // Under half a point of overhang is not content that goes on, so it does not fade.
        return StripPlacement(
            firstOrigin: vanished ? slotOrigin + m.step : slotOrigin,
            fadesLeading: slotOrigin < m.dockInset - 0.5,
            fadesTrailing: !oldestIsLoaded || slotOrigin + filmWidth > m.bandWidth - m.dockInset + 0.5
        )
    }

    /// The left edge of each frame within the band, one step apart from index 0 at `placement.firstOrigin` on.
    static func frameOrigins(_ m: StripMetrics, count: Int, placement: StripPlacement) -> [CGFloat] {
        (0..<count).map { placement.firstOrigin + CGFloat($0) * m.step }
    }

    /// The card goes above the band, which stays where it is. Where the card has no room above it, the
    /// card and the band are centred vertically as one group, so the band moves down to make room; the
    /// group is centred as if without the filter row, which then again moves only what is below the search
    /// row. The card is at most `previewMaximum`; when the room is smaller it shrinks to fit, in height and
    /// in width.
    static func previewLayout(band: NSRect, filtersVisible: Bool,
                              in visible: NSRect) -> (preview: NSRect, band: NSRect) {
        let room = visible.insetBy(dx: sideMargin, dy: shadowMargin)
        let size = CGSize(width: min(previewMaximum.width, room.width),
                          height: min(previewMaximum.height, room.height - band.height - previewGap))
        var movedBand = band
        if band.maxY + previewGap + size.height > room.maxY {
            let filterRow = filtersVisible ? filterHeight : 0
            let groupHeight = size.height + previewGap + band.height - filterRow
            let top = room.midY - groupHeight / 2 + band.height - filterRow
            movedBand.origin.y = max(top - band.height, room.minY)
        }
        let preview = NSRect(x: band.midX - size.width / 2, y: movedBand.maxY + previewGap,
                             width: size.width, height: size.height)
        return (preview, movedBand)
    }

    /// The window around the band, and around the preview card when it is open.
    static func panelFrame(band: NSRect, preview: NSRect?) -> NSRect {
        let content = preview.map { band.union($0) } ?? band
        return content.insetBy(dx: -sideMargin, dy: -shadowMargin)
    }

    /// A frame's size, the heights of its colour band and its footer, and the side of the app icon in the band.
    static func cardDimensions(
        for size: CardSize
    ) -> (frame: CGSize, header: CGFloat, footer: CGFloat, icon: CGFloat) {
        switch size {
        case .small: (CGSize(width: 200, height: 220), 52, 28, 36)
        case .medium: (CGSize(width: 228, height: 250), 56, 30, 40)
        case .large: (CGSize(width: 260, height: 286), 60, 32, 44)
        }
    }
}
