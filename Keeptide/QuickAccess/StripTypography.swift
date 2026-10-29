import Foundation

/// A point size and the distance from one line's baseline to the next.
struct StripTextStyle: Equatable {
    let size: CGFloat
    let lineHeight: CGFloat
}

/// The type inside a card. The values are a medium card's; a small or a large card scales them by its width, so a
/// card of any size looks the same, only larger or smaller. No text is set below 12 pt: a card that cannot hold its
/// text cuts it off instead of shrinking the type.
enum StripTypography {
    /// A medium card's width, which the other sizes are measured against.
    private static let mediumWidth: CGFloat = 228

    /// How much a card of this size scales a medium card's contents: its width over the medium width.
    static func scale(for cardSize: CardSize) -> CGFloat {
        StripLayout.cardDimensions(for: cardSize).frame.width / mediumWidth
    }

    /// Short text is set larger: up to 24 characters at 20/27, up to 60 at 18/26, up to 140 at 15/22, and longer at
    /// 14/21 on a medium card. The length is `String.count`, so an emoji sequence or a letter with a combining accent
    /// counts once, as the reader sees it.
    static func bodyStyle(for text: String, cardSize: CardSize) -> StripTextStyle {
        let medium = switch text.count {
        case ...24: StripTextStyle(size: 20, lineHeight: 27)
        case ...60: StripTextStyle(size: 18, lineHeight: 26)
        case ...140: StripTextStyle(size: 15, lineHeight: 22)
        default: StripTextStyle(size: 14, lineHeight: 21)
        }
        return scaled(medium, for: cardSize)
    }

    /// A link's title and a file's name: 14/19 on a medium card.
    static func titleStyle(cardSize: CardSize) -> StripTextStyle {
        scaled(StripTextStyle(size: 14, lineHeight: 19), for: cardSize)
    }

    /// A medium card's `style` at `cardSize`. A size that would fall below 12 pt is held at 12, and its lines stay
    /// as far apart for that size as the style sets them.
    static func scaled(_ style: StripTextStyle, for cardSize: CardSize) -> StripTextStyle {
        let size = max(12, style.size * scale(for: cardSize))
        return StripTextStyle(size: size, lineHeight: style.lineHeight * size / style.size)
    }
}
