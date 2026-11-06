import Foundation

/// A point size and the distance from one line's baseline to the next.
struct StripTextStyle: Equatable {
    let size: CGFloat
    let lineHeight: CGFloat
}

/// The type inside a card. A text body is set at one size for each card size, whatever its length, and a link's title
/// or a file's name a point under it. The room around them is a medium card's, scaled by the card's width, so a card of
/// any size looks the same, only larger or smaller. No text is set below 12 pt: a card that cannot hold its text cuts
/// it off instead of shrinking the type.
enum StripTypography {
    /// A medium card's width, which the other sizes are measured against.
    private static let mediumWidth: CGFloat = 196

    /// How much a card of this size scales a medium card's measures: its width over the medium width.
    static func scale(for cardSize: CardSize) -> CGFloat {
        StripLayout.cardDimensions(for: cardSize).frame.width / mediumWidth
    }

    /// A text body: 13/18 on a small card, 14/19 on a medium one and 15/20 on a large one.
    static func bodyStyle(cardSize: CardSize) -> StripTextStyle {
        switch cardSize {
        case .small: StripTextStyle(size: 13, lineHeight: 18)
        case .medium: StripTextStyle(size: 14, lineHeight: 19)
        case .large: StripTextStyle(size: 15, lineHeight: 20)
        }
    }

    /// A link's title and a file's name, a point under the body: 12/16, 13/17 and 14/18.
    static func titleStyle(cardSize: CardSize) -> StripTextStyle {
        let body = bodyStyle(cardSize: cardSize)
        return StripTextStyle(size: body.size - 1, lineHeight: body.lineHeight - 2)
    }

    /// The room beside a card's text, and around a picture shown whole: 13 pt on a medium card, scaled and rounded to
    /// whole points.
    static func padding(for cardSize: CardSize) -> CGFloat {
        (13 * scale(for: cardSize)).rounded()
    }

    /// The room above a text body, under the header, and below it, over the footer: 2 and 10 pt on a medium card,
    /// scaled and rounded to whole points.
    static func verticalPadding(for cardSize: CardSize) -> (top: CGFloat, bottom: CGFloat) {
        let scale = scale(for: cardSize)
        return ((2 * scale).rounded(), (10 * scale).rounded())
    }

    /// How many lines of `style` fit in `height`, at least one. Text is cut at the last line that fits, never set
    /// smaller.
    static func lines(in height: CGFloat, style: StripTextStyle) -> Int {
        max(1, Int((height / style.lineHeight + 0.001).rounded(.down)))
    }

    /// How many lines of a text body set in `style` a card shows: as many as its middle holds inside the room above
    /// and below the text, under the memo title's line when it has one.
    static func bodyLines(_ style: StripTextStyle, metrics: StripMetrics, hasMemoTitle: Bool) -> Int {
        let room = verticalPadding(for: metrics.cardSize)
        let height = metrics.contentSize.height - room.top - room.bottom - (hasMemoTitle ? style.lineHeight : 0)
        return lines(in: height, style: style)
    }
}
