import Foundation

/// Point sizes inside a frame at one density. No text is set below 12 pt: a frame that cannot hold
/// its text truncates it instead of shrinking the type.
struct StripType: Equatable {
    /// Body text sizes from the shortest bucket to the longest; see `StripTypography.bodySize`.
    let tiers: [CGFloat]
    /// A link's host.
    let linkDomain: CGFloat
    /// The rest of a link's address.
    let linkPath: CGFloat
    /// The line with the character count, pixel size or file type.
    let info: CGFloat
    /// Space between a frame's edge and its content.
    let padding: CGFloat
    /// Side of the source app's icon.
    let icon: CGFloat
}

/// The strip's type table. Sizes follow the density alone and never the frame's width, so a narrow
/// screen keeps its text legible and shows less of it.
enum StripTypography {
    static func type(for density: StripDensity) -> StripType {
        switch density {
        case .seven: StripType(tiers: [22, 17, 14, 13], linkDomain: 15, linkPath: 12, info: 12, padding: 14, icon: 14)
        case .nine: StripType(tiers: [19, 15, 13, 12], linkDomain: 14, linkPath: 12, info: 12, padding: 11, icon: 12)
        case .eleven: StripType(tiers: [16, 13, 12, 12], linkDomain: 13, linkPath: 12, info: 12, padding: 9, icon: 12)
        }
    }

    /// Short text is set larger. The length is `String.count`, so an emoji sequence or a letter
    /// with a combining accent counts once, as the reader sees it.
    static func bodySize(for text: String, density: StripDensity) -> CGFloat {
        let tiers = type(for: density).tiers
        return switch text.count {
        case ...12: tiers[0]
        case ...40: tiers[1]
        case ...120: tiers[2]
        default: tiers[3]
        }
    }
}
