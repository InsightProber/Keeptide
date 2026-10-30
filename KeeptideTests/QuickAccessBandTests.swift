import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

/// What the band stands on, as the band view sets it up from SwiftUI's environment: the material in each appearance,
/// and what Reduce Transparency and Increase Contrast make of it. And the strip's section icons below the cards,
/// measured by the ink SwiftUI draws for them.
@MainActor
final class QuickAccessBandTests: XCTestCase {
    func testTheBackdropTakesTheSwitchersMaterialInEachAppearance() throws {
        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false)
        // Dark: a HUD's material behind the window, with a hairline edge and no solid fill.
        window.appearance = NSAppearance(named: .darkAqua)
        settle(window)
        XCTAssertEqual(backdrop.material.material, .hudWindow)
        XCTAssertEqual(backdrop.material.blendingMode, .behindWindow)
        XCTAssertEqual(backdrop.material.state, .active)
        XCTAssertFalse(backdrop.material.isHidden)
        XCTAssertFalse(backdrop.surface.isSolid)
        XCTAssertEqual(backdrop.surface.edgeWidth, 0.5)
        XCTAssertNotNil(backdrop.material.maskImage, "The material is cut to the band's rounded shape")

        // A change of appearance restyles it: light takes a popover's light material.
        window.appearance = NSAppearance(named: .aqua)
        settle(window)
        XCTAssertEqual(backdrop.material.material, .popover)
        XCTAssertFalse(backdrop.material.isHidden)
    }

    func testReduceTransparencyMakesTheBandSolid() throws {
        let (window, backdrop) = try host(reducesTransparency: true, increasedContrast: false)
        window.appearance = NSAppearance(named: .darkAqua)
        settle(window)
        XCTAssertTrue(backdrop.material.isHidden)
        XCTAssertTrue(backdrop.surface.isSolid)
        XCTAssertEqual(backdrop.surface.edgeWidth, 0.5)
    }

    func testIncreaseContrastWidensTheEdge() throws {
        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: true)
        window.appearance = NSAppearance(named: .aqua)
        settle(window)
        XCTAssertEqual(backdrop.surface.edgeWidth, 1)
        XCTAssertFalse(backdrop.material.isHidden)
        XCTAssertFalse(backdrop.surface.isSolid)
    }

    // MARK: Section icons

    func testTheSectionIconsLieBelowTheCards() throws {
        // Without the frequent wing the band is 340 tall with 22 below the cards, as it always was; with it, 346 with
        // 28 below them. Either way the cards start 68 below the band's top edge, 20 below the toolbar's row.
        for (wing, room, height) in [(false, 22, 340), (true, 28, 346)] as [(Bool, CGFloat, CGFloat)] {
            let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: wing)
            let strip = QuickAccessStripView()
            let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, metrics: metrics,
                                              strip: strip)
            let rows = makeWing(frequent: wing ? 3 : 0, recent: 20)
            strip.show(rows, selection: rows[wing ? 3 : 0].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            settle(window)

            let band = backdrop.convert(backdrop.bandRect, to: nil)
            let card = try selectedCard(in: strip)
            XCTAssertEqual(band.height, height, "wing \(wing)")
            XCTAssertEqual(band.maxY - card.maxY, 68, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(card.minY - band.minY, room, accuracy: 0.5, "wing \(wing)")
            // The icons' view is as wide as the band, from the cards' bottom edge down to the band's.
            let icons = strip.sectionLabels.convert(strip.sectionLabels.bounds, to: nil)
            XCTAssertEqual(icons.minX, band.minX, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(icons.width, band.width, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(icons.maxY, card.minY, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(icons.minY, band.minY, accuracy: 0.5, "wing \(wing)")
            // It takes no clicks: just below the cards the pointer finds the strip beneath it.
            let belowTheCards = NSPoint(x: band.midX, y: card.minY - 4)
            XCTAssertTrue(icons.contains(belowTheCards), "wing \(wing)")
            XCTAssertTrue(window.contentView?.hitTest(belowTheCards) === strip, "wing \(wing)")
            guard wing else { continue }
            // A click on an icon goes where it would go without the icons: to the band beneath them.
            for identifier in ["QuickAccessFrequentLabel", "QuickAccessRecentLabel"] {
                let label = try sectionLabel(identifier, of: strip)
                XCTAssertFalse(label.isHidden, identifier)
                let frame = label.convert(label.bounds, to: nil)
                let middle = NSPoint(x: frame.midX, y: frame.midY)
                let hit = try XCTUnwrap(window.contentView?.hitTest(middle), identifier)
                XCTAssertFalse(hit.isDescendant(of: strip.sectionLabels), identifier)
                strip.sectionLabels.isHidden = true
                XCTAssertTrue(window.contentView?.hitTest(middle) === hit, identifier)
                strip.sectionLabels.isHidden = false
            }
        }
    }

    func testTheSectionIconsStandClearOfTheRingAndTheBandsBottomEdge() throws {
        // The ring around a selected card reaches 6 pt below it, and 7 with Increase Contrast. Each icon is centred
        // between the wider ring's lowest reach and the band's bottom edge, and the ink it draws, measured as SwiftUI
        // draws it, keeps at least 3 pt from both, the two gaps differing by less than a point. The icons are the same
        // with Increase Contrast or without.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: true)
        XCTAssertEqual(try ringReach(increasedContrast: false, below: true), 6, accuracy: 0.5)
        let reach = try ringReach(increasedContrast: true, below: true)
        XCTAssertEqual(reach, 7, accuracy: 0.5)
        for increasedContrast in [false, true] {
            let strip = QuickAccessStripView()
            strip.increasesContrast = { increasedContrast }
            let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: increasedContrast,
                                              metrics: metrics, strip: strip)
            let rows = makeWing(frequent: 3, recent: 20)
            strip.show(rows, selection: rows[3].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            settle(window)
            let band = backdrop.convert(backdrop.bandRect, to: nil)
            let ring = try selectedCard(in: strip).minY - reach
            for identifier in ["QuickAccessFrequentLabel", "QuickAccessRecentLabel"] {
                let name = "\(identifier), Increase Contrast \(increasedContrast)"
                let label = try sectionLabel(identifier, of: strip)
                XCTAssertFalse(label.isHidden, name)
                let frame = label.convert(label.bounds, to: nil)
                XCTAssertEqual(frame.midY, (ring + band.minY) / 2, accuracy: 0.5, name)
                let ink = try ink(of: label)
                XCTAssertGreaterThanOrEqual(ring - ink.maxY, 3, name)
                XCTAssertGreaterThanOrEqual(ink.minY - band.minY, 3, name)
                XCTAssertLessThan(abs((ring - ink.maxY) - (ink.minY - band.minY)), 1, name)
            }
        }
    }

    func testTheSectionIconsAreTwelvePointSemiboldSymbolsWithoutWords() throws {
        // Each icon draws the ink of its SF Symbol at 12 pt semibold, as SwiftUI draws the symbol alone, and nothing
        // else: one run of ink, no gap in it wider than 2 pt, as wide and as tall as the symbol's own, and as heavy. No
        // "Frequent" or "Recent" is drawn beside it. A point more or less makes the symbol at least 0.75 pt wider or
        // narrower, or taller or shorter, which is more than the 0.5 pt the comparison allows; medium or bold strokes
        // cover at least 8 percent less or more, against the 4 percent allowed.
        let strip = QuickAccessStripView()
        for (identifier, symbol) in [("QuickAccessFrequentLabel", "flame"), ("QuickAccessRecentLabel", "clock")] {
            let label = try sectionLabel(identifier, of: strip)
            let size = label.bounds.size
            let picture = try Picture(label.rootView.frame(width: size.width, height: size.height))
            let columns = picture.inkColumns
            XCTAssertFalse(columns.isEmpty, symbol)
            XCTAssertNil(zip(columns, columns.dropFirst()).first { $1 - $0 > Int(2 * Picture.scale) },
                         "\(symbol): something is drawn beside the symbol")
            let drawn = try XCTUnwrap(picture.ink(in: nil), symbol)
            let reference = try Picture(Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .fixedSize())
            let alone = try XCTUnwrap(reference.ink(in: nil), symbol)
            XCTAssertEqual(drawn.width, alone.width, accuracy: 0.5, symbol)
            XCTAssertEqual(drawn.height, alone.height, accuracy: 0.5, symbol)
            XCTAssertEqual(picture.inkArea, reference.inkArea, accuracy: reference.inkArea * 0.04, symbol)
        }
    }

    func testAPinnedIconKeepsEightPointsFromTheBandsRoundedCorner() throws {
        // Once the divider has gone off an end, the icon of the wing still on screen rests at that end, and its ink
        // keeps at least 8 pt from the band's rounded corner there: the outline as the band draws it, where it lies
        // within the corner's radius, 36 pt, of that end and of the bottom edge. Further along the outline runs within
        // 0.35 pt of the straight bottom edge, which the icons keep 3 pt from. Resting at the dock inset, 20 pt, the
        // ink came within 2 pt of the corner.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: true)
        // Three frequent clips and Row 10 selected: the divider is off the left end, and the clock rests there. Twenty
        // frequent clips and the most used one selected: the divider is off the right end, and the flame rests there.
        let cases = [(frequent: 3, selected: 13, pinned: "QuickAccessRecentLabel", gone: "QuickAccessFrequentLabel"),
                     (frequent: 20, selected: 0, pinned: "QuickAccessFrequentLabel", gone: "QuickAccessRecentLabel")]
        for (frequent, selected, pinned, gone) in cases {
            let strip = QuickAccessStripView()
            let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, metrics: metrics,
                                              strip: strip)
            let rows = makeWing(frequent: frequent, recent: 20)
            strip.show(rows, selection: rows[selected].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            settle(window)
            let band = backdrop.convert(backdrop.bandRect, to: nil)
            let label = try sectionLabel(pinned, of: strip)
            XCTAssertFalse(label.isHidden, pinned)
            XCTAssertTrue(try sectionLabel(gone, of: strip).isHidden, gone)
            let left = label.convert(label.bounds, to: nil).midX < band.midX
            let radius = StripLayout.cornerRadius
            let corner = outline(of: band).filter { point in
                point.y <= band.minY + radius && (left ? point.x <= band.minX + radius : point.x >= band.maxX - radius)
            }
            XCTAssertFalse(corner.isEmpty, pinned)
            let ink = try inkPixels(of: label)
            XCTAssertFalse(ink.isEmpty, pinned)
            let nearest = ink.map { pixel in
                corner.map { hypot($0.x - pixel.x, $0.y - pixel.y) }.min() ?? 0
            }.min() ?? 0
            // From the nearest pixel's edge rather than its middle.
            XCTAssertGreaterThanOrEqual(nearest - 0.5 / Picture.scale, 8, pinned)
        }
    }

    func testAFrequentCardDrawsHowOftenItWasUsedAsATimeIsDrawn() throws {
        // A frequent clip's card says "Used 1,234 times" where a recent clip's says how long ago it was copied, in the
        // same face, size and colour: it is the very picture of a card whose time read those words. The clip's own
        // recent card, with its time, is a different picture, so the comparison can tell them apart.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let icon = ApplicationNames().icon(for: nil)
        func picture(_ content: StripFrameContent) throws -> Picture {
            try Picture(StripFrameView(content: content, applicationIcon: icon, metrics: metrics, headerTint: nil,
                                       isSelected: false))
        }
        func same(_ one: Picture, _ other: Picture) -> Bool {
            one.width == other.width && one.height == other.height
                && !(0..<one.height).contains { one.differs(from: other, inRow: $0) }
        }
        var row = makeRow()
        row.frequentUses = 1_234
        let frequent = StripFrameContent.make(row: row, detail: nil, cardSize: .medium)
        var timed = frequent
        timed.time = try XCTUnwrap(frequent.uses)
        timed.uses = nil
        row.frequentUses = nil
        let recent = StripFrameContent.make(row: row, detail: nil, cardSize: .medium)

        XCTAssertTrue(same(try picture(frequent), try picture(timed)))
        XCTAssertFalse(same(try picture(frequent), try picture(recent)))
    }

    // MARK: Helpers

    /// The band view with `metrics`, medium cards unless given others, and nothing in its state, in a window that is
    /// never shown, with the two settings given through SwiftUI's environment as the system would give them; and the
    /// backdrop it made.
    private func host(
        reducesTransparency: Bool, increasedContrast: Bool,
        metrics: StripMetrics = StripLayout.metrics(for: .medium, visibleWidth: 1440),
        strip: QuickAccessStripView = QuickAccessStripView(),
        toolbar: QuickAccessToolbar = QuickAccessToolbar(field: QuickAccessSearchField())
    ) throws -> (NSWindow, QuickAccessBandBackdrop) {
        let band = QuickAccessBandView(
            layout: QuickAccessBandView.Layout(metrics: metrics, previewSize: nil,
                                               roomBelow: StripLayout.shadowRoom.below),
            state: QuickAccessState(services: { nil }), toolbar: toolbar,
            strip: strip, applicationNames: ApplicationNames(),
            actions: QuickAccessBandView.Actions(previewCommand: { _ in }, confirmCommand: {}, cancelCommandReview: {})
        )
        let root = band
            .environment(\._accessibilityReduceTransparency, reducesTransparency)
            .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard)
        let size = NSSize(width: metrics.bandWidth + 2 * StripLayout.sideMargin,
                          height: StripLayout.bandHeight(metrics) + StripLayout.shadowRoom.above
                              + StripLayout.shadowRoom.below)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
        settle(window)
        let backdrop = try XCTUnwrap(backdrops(in: hosting).first)
        return (window, backdrop)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func backdrops(in view: NSView) -> [QuickAccessBandBackdrop] {
        ((view as? QuickAccessBandBackdrop).map { [$0] } ?? []) + view.subviews.flatMap { backdrops(in: $0) }
    }

    /// `frequent` rows of the frequent wing, the most used first, then `recent` rows; every clip made up here.
    private func makeWing(frequent: Int, recent: Int) -> [QuickAccessRow] {
        (0..<frequent).map { index in
            var row = makeRow()
            row.frequentUses = Int64(100 - index)
            return row
        } + (0..<recent).map { _ in makeRow() }
    }

    private func makeRow() -> QuickAccessRow {
        QuickAccessRow(
            ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                            digest: Data(repeating: 7, count: 32)),
            title: "Synthetic clip", snippet: nil, kind: .text, sourceApp: nil,
            date: Date(timeIntervalSince1970: 1_000), savedAsMemo: false, isPartiallyIndexed: false,
            isTextUnavailable: false
        )
    }

    /// The selected clip's card, in window coordinates.
    private func selectedCard(in strip: QuickAccessStripView) throws -> NSRect {
        func drawings(in view: NSView) -> [NSHostingView<StripFrameView>] {
            view.subviews.flatMap { ($0 as? NSHostingView<StripFrameView>).map { [$0] } ?? drawings(in: $0) }
        }
        let card = try XCTUnwrap(drawings(in: strip).first { $0.rootView.isSelected }, "the selected card")
        return card.convert(card.bounds, to: nil)
    }

    /// One of the two section icons, found by its identifier.
    private func sectionLabel(_ identifier: String,
                              of strip: QuickAccessStripView) throws -> NSHostingView<StripSectionLabel> {
        let label = strip.sectionLabels.subviews.first { $0.accessibilityIdentifier() == identifier }
        return try XCTUnwrap(label as? NSHostingView<StripSectionLabel>, identifier)
    }

    /// The rectangle around the ink a section icon draws, as SwiftUI draws the icon's view in a frame as large as the
    /// icon, in window coordinates.
    private func ink(of label: NSHostingView<StripSectionLabel>) throws -> NSRect {
        let size = label.bounds.size
        let picture = try Picture(label.rootView.frame(width: size.width, height: size.height))
        let rect = try XCTUnwrap(picture.ink(in: nil), "no ink")
        // From the picture's top left corner to the icon's own coordinates, then to the window's.
        return label.convert(label.isFlipped ? rect : NSRect(x: rect.minX, y: size.height - rect.maxY,
                                                            width: rect.width, height: rect.height), to: nil)
    }

    /// The middle of each pixel a section icon inks, as SwiftUI draws the icon's view in a frame as large as the icon,
    /// in window coordinates.
    private func inkPixels(of label: NSHostingView<StripSectionLabel>) throws -> [NSPoint] {
        let size = label.bounds.size
        let picture = try Picture(label.rootView.frame(width: size.width, height: size.height))
        return picture.inkPixels.map { pixel in
            let x = (CGFloat(pixel.x) + 0.5) / Picture.scale, y = (CGFloat(pixel.y) + 0.5) / Picture.scale
            return label.convert(NSPoint(x: x, y: label.isFlipped ? y : size.height - y), to: nil)
        }
    }

    /// Points along the band's outline as the band draws it around `band`, its curves included, no more than a
    /// quarter point apart.
    private func outline(of band: NSRect) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero, start = CGPoint.zero
        func follow(to end: CGPoint, steps: Int, _ point: (CGFloat) -> CGPoint) {
            points += (1...steps).map { point(CGFloat($0) / CGFloat(steps)) }
            current = end
        }
        func line(to end: CGPoint) {
            let from = current
            follow(to: end, steps: max(1, Int((hypot(end.x - from.x, end.y - from.y) * 4).rounded(.up)))) { t in
                CGPoint(x: from.x + (end.x - from.x) * t, y: from.y + (end.y - from.y) * t)
            }
        }
        QuickAccessBandBackdrop.outline(in: band).applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                start = current
                points.append(current)
            case .addLineToPoint:
                line(to: element.points[0])
            case .addQuadCurveToPoint:
                let from = current, control = element.points[0], end = element.points[1]
                follow(to: end, steps: 256) { t in
                    let u = 1 - t
                    return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * end.x,
                                   y: u * u * from.y + 2 * u * t * control.y + t * t * end.y)
                }
            case .addCurveToPoint:
                let from = current, first = element.points[0], second = element.points[1], end = element.points[2]
                follow(to: end, steps: 256) { t in
                    let u = 1 - t
                    let (a, b, c, d) = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
                    return CGPoint(x: a * from.x + b * first.x + c * second.x + d * end.x,
                                   y: a * from.y + b * first.y + c * second.y + d * end.y)
                }
            case .closeSubpath:
                line(to: start)
            @unknown default:
                break
            }
        }
        return points
    }

    /// How far beyond a selected medium card its ring reaches, above it or `below` it, as SwiftUI draws the card with
    /// Increase Contrast or without: from the card's edge out to the outermost row in which the card's picture differs
    /// from the picture of the same card unselected. Its shadow is the same in both.
    private func ringReach(increasedContrast: Bool, below: Bool = false) throws -> CGFloat {
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let row = makeRow()
        let room: CGFloat = 20
        func picture(selected: Bool) throws -> Picture {
            try Picture(StripFrameView(content: StripFrameContent.make(row: row, detail: nil, cardSize: .medium),
                                       applicationIcon: ApplicationNames().icon(for: nil), metrics: metrics,
                                       headerTint: nil, isSelected: selected)
                .padding(room)
                .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard))
        }
        let plain = try picture(selected: false), ringed = try picture(selected: true)
        XCTAssertEqual([ringed.width, ringed.height], [plain.width, plain.height], "The ring changes no size")
        guard ringed.width == plain.width, ringed.height == plain.height else { return 0 }
        // Rows counted in from the picture's top edge, or from its bottom edge below the card.
        let outermost = try XCTUnwrap((0..<Int(room * Picture.scale)).first {
            ringed.differs(from: plain, inRow: below ? ringed.height - 1 - $0 : $0)
        }, "no ring \(below ? "below" : "above") the card")
        return room - CGFloat(outermost) / Picture.scale
    }
}

/// A picture SwiftUI draws of a view at four times its size, as rows of pixels from the top, each pixel's red, green,
/// blue and alpha in one byte each.
@MainActor
private struct Picture {
    static let scale: CGFloat = 4
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ content: some View) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.scale
        let image = try XCTUnwrap(renderer.cgImage, "SwiftUI drew no picture")
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "The picture could not be read")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Whether the pixel `x` from the left and `y` from the top holds any ink at all.
    func hasInk(_ x: Int, _ y: Int) -> Bool {
        bytes[(y * width + x) * 4 + 3] > 0
    }

    /// The columns, from the left, with ink in them.
    var inkColumns: [Int] {
        (0..<width).filter { x in (0..<height).contains { hasInk(x, $0) } }
    }

    /// Every pixel with ink in it, by its column from the left and its row from the top.
    var inkPixels: [(x: Int, y: Int)] {
        (0..<height).flatMap { y in (0..<width).filter { hasInk($0, y) }.map { (x: $0, y: y) } }
    }

    /// How much the ink covers, in square points, as if it were drawn opaque: each pixel's alpha over the strongest
    /// pixel's, so the colour it is drawn in does not count.
    var inkArea: CGFloat {
        var total = 0, peak: UInt8 = 0
        for index in stride(from: 3, to: bytes.count, by: 4) {
            total += Int(bytes[index])
            peak = max(peak, bytes[index])
        }
        return peak == 0 ? 0 : CGFloat(total) / CGFloat(peak) / (Self.scale * Self.scale)
    }

    /// The rectangle around the ink in `columns`, or in every column when it is nil, in points from the picture's top
    /// left corner; nil where there is none.
    func ink(in columns: ClosedRange<Int>?) -> NSRect? {
        let columns = columns ?? 0...(width - 1)
        let inked = columns.filter { x in (0..<height).contains { hasInk(x, $0) } }
        let rows = (0..<height).filter { y in columns.contains { hasInk($0, y) } }
        guard let left = inked.first, let right = inked.last, let top = rows.first, let bottom = rows.last else {
            return nil
        }
        return NSRect(x: CGFloat(left) / Self.scale, y: CGFloat(top) / Self.scale,
                      width: CGFloat(right + 1 - left) / Self.scale, height: CGFloat(bottom + 1 - top) / Self.scale)
    }

    /// Whether the row `y` from the top differs anywhere from the same row of `other`, a picture as large.
    func differs(from other: Picture, inRow y: Int) -> Bool {
        let range = (y * width * 4)..<((y + 1) * width * 4)
        return bytes[range] != other.bytes[range]
    }
}
