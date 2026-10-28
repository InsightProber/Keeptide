import AppKit

/// Clips in a row, counting the half-hidden ones in the faded ends. Stored as the raw value.
enum StripDensity: Int, CaseIterable {
    case seven = 7, nine = 9, eleven = 11

    /// The next sparser level, which a narrow screen falls back to.
    var stepDown: StripDensity? {
        switch self {
        case .eleven: .nine
        case .nine: .seven
        case .seven: nil
        }
    }

    /// Stored values are not trusted: anything but 7, 9 or 11 gives the default.
    static func from(_ raw: Int) -> StripDensity {
        StripDensity(rawValue: raw) ?? .nine
    }
}

/// Frame sizes for one screen width. `scale` is the band width relative to its reference width.
struct StripMetrics: Equatable {
    let density: StripDensity
    let bandWidth: CGFloat
    let scale: CGFloat
    let frameSize: CGSize
    let gap: CGFloat
    let cornerRadius: CGFloat

    /// Distance between the left edges of neighbouring frames.
    var step: CGFloat { frameSize.width + gap }
}

/// Geometry of the quick access strip. The band is the glass bar holding the search row, the
/// frames and the caption; the panel is the window around it. All values are in points.
enum StripLayout {
    static let maximumBandWidth: CGFloat = 1360
    /// The share of the band's width that fades out at each end.
    static let fade: CGFloat = 0.14
    static let searchHeight: CGFloat = 70
    static let captionHeight: CGFloat = 60
    static let filterHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 30
    /// Panel room beside the band for the key-cap hint and the shadow.
    static let sideMargin: CGFloat = 40
    /// Panel room above and below the band for the shadow.
    static let shadowMargin: CGFloat = 24
    static let previewGap: CGFloat = 16
    static let previewMaximum = CGSize(width: 760, height: 470)

    /// Frames shrink with the band, rounded to whole points; their corners are 12 pt at full size
    /// and never below 8. Below 80% the frames would be too small for the 12 pt text floor, so that
    /// screen drops one density; the stored choice is untouched.
    static func metrics(for density: StripDensity, visibleWidth: CGFloat) -> StripMetrics {
        let bandWidth = min(visibleWidth - 2 * sideMargin, maximumBandWidth)
        let scale = bandWidth / maximumBandWidth
        let effective = scale < 0.8 ? (density.stepDown ?? density) : density
        let reference = referenceSizes(for: effective)
        return StripMetrics(
            density: effective, bandWidth: bandWidth, scale: scale,
            frameSize: CGSize(width: (reference.width * scale).rounded(), height: (reference.height * scale).rounded()),
            gap: (reference.gap * scale).rounded(), cornerRadius: max(8, 12 * scale)
        )
    }

    static func bandHeight(_ m: StripMetrics, filtersVisible: Bool) -> CGFloat {
        searchHeight + m.frameSize.height + captionHeight + (filtersVisible ? filterHeight : 0)
    }

    /// The band, centred in the screen's visible area.
    static func bandFrame(_ m: StripMetrics, filtersVisible: Bool, in visible: NSRect) -> NSRect {
        let size = CGSize(width: m.bandWidth, height: bandHeight(m, filtersVisible: filtersVisible))
        return NSRect(origin: NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2), size: size)
    }

    /// The left edge of each frame within the band. Index 0 is the newest (or best match) and
    /// sits rightmost; `centredIndex` lands in the middle of the band. Index -1 stands for a
    /// selection that vanished: the middle stays empty and every frame sits to its left.
    static func frameOrigins(_ m: StripMetrics, count: Int, centredIndex: Int) -> [CGFloat] {
        (0..<count).map { m.bandWidth / 2 + CGFloat(centredIndex - $0) * m.step - m.frameSize.width / 2 }
    }

    /// The card goes above the band and the pair is centred vertically as one group, so the band
    /// moves down to make room. The card is at most `previewMaximum`; when the room is smaller it
    /// shrinks to fit, in height and in width.
    static func previewLayout(band: NSRect, in visible: NSRect) -> (preview: NSRect, band: NSRect) {
        let room = visible.insetBy(dx: sideMargin, dy: shadowMargin)
        let size = CGSize(width: min(previewMaximum.width, room.width),
                          height: min(previewMaximum.height, room.height - band.height - previewGap))
        let groupHeight = size.height + previewGap + band.height
        let movedBand = NSRect(x: band.minX, y: room.midY - groupHeight / 2, width: band.width, height: band.height)
        let preview = NSRect(x: band.midX - size.width / 2, y: movedBand.maxY + previewGap,
                             width: size.width, height: size.height)
        return (preview, movedBand)
    }

    /// The window around the band, and around the preview card when it is open.
    static func panelFrame(band: NSRect, preview: NSRect?) -> NSRect {
        let content = preview.map { band.union($0) } ?? band
        return content.insetBy(dx: -sideMargin, dy: -shadowMargin)
    }

    /// Frame width, gap and height at the reference band width.
    private static func referenceSizes(for density: StripDensity) -> (width: CGFloat, gap: CGFloat, height: CGFloat) {
        switch density {
        case .seven: (200, 14, 133)
        case .nine: (164, 12, 109)
        case .eleven: (136, 10, 91)
        }
    }
}
