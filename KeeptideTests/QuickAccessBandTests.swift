import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

/// What the band stands on, as the band view sets it up from SwiftUI's environment: the material in each appearance,
/// and what Reduce Transparency and Increase Contrast make of it. And the strip's section labels in the gap between the
/// toolbar and the cards, measured by the ink SwiftUI draws for them.
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

    // MARK: Section labels

    func testTheSectionLabelsLieInTheGapBetweenTheToolbarAndTheCards() throws {
        // Without the frequent wing the gap is 20 and the band 340 tall, as they always were; with it, 30 and 350.
        for (wing, gap, height) in [(false, 20, 340), (true, 30, 350)] as [(Bool, CGFloat, CGFloat)] {
            let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: wing)
            let strip = QuickAccessStripView()
            let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, metrics: metrics,
                                              strip: strip)
            let rows = makeWing(frequent: wing ? 3 : 0, recent: 20)
            strip.show(rows, selection: rows[wing ? 3 : 0].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            settle(window)

            let band = backdrop.convert(backdrop.bandRect, to: nil)
            XCTAssertEqual(band.height, height, "wing \(wing)")
            // The labels' view is as wide as the band, from the toolbar's row down to the cards.
            let labels = strip.sectionLabels.convert(strip.sectionLabels.bounds, to: nil)
            let card = try selectedCard(in: strip)
            XCTAssertEqual(labels.minX, band.minX, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(labels.width, band.width, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(labels.height, gap, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(band.maxY - labels.maxY, StripLayout.toolbarTop + StripLayout.toolbarHeight, accuracy: 0.5,
                           "wing \(wing)")
            XCTAssertEqual(band.maxY - card.maxY, 48 + gap, accuracy: 0.5, "wing \(wing)")
            XCTAssertEqual(labels.minY, card.maxY, accuracy: 0.5, "wing \(wing)")
            // They take no clicks: just above the cards the pointer finds the strip beneath them.
            let aboveTheCards = NSPoint(x: band.midX, y: card.maxY + 4)
            XCTAssertTrue(labels.contains(aboveTheCards), "wing \(wing)")
            XCTAssertTrue(window.contentView?.hitTest(aboveTheCards) === strip, "wing \(wing)")
        }
    }

    func testTheSectionLabelsStandClearOfTheToolbarAboveAndTheRingBelow() throws {
        // The ink each label draws, its symbol's included, stays at least 8 pt above the cards and so above the ring
        // around a selected card, at least 6 pt below the toolbar's row, and at least 3 pt below the 3 pt ring around
        // the search, open or folded, while its field has the keys. The labels move with the cards, so either may pass
        // under the search: what counts is how far apart they are from top to bottom. All of it holds with Increase
        // Contrast, which draws the selection ring wider.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: true)
        for increasedContrast in [false, true] {
            let strip = QuickAccessStripView()
            strip.increasesContrast = { increasedContrast }
            let toolbar = QuickAccessToolbar(field: QuickAccessSearchField())
            let (window, _) = try host(reducesTransparency: false, increasedContrast: increasedContrast,
                                       metrics: metrics, strip: strip, toolbar: toolbar)
            let rows = makeWing(frequent: 3, recent: 20)
            strip.show(rows, selection: rows[3].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            settle(window)
            let card = try selectedCard(in: strip)
            let row = toolbar.convert(toolbar.rowFrame, to: nil)
            // The cards in the strip are drawn with the system's setting, so the ring is measured on a card drawn
            // with Increase Contrast given to it.
            let ring = try ringReach(increasedContrast: increasedContrast)
            XCTAssertEqual(ring, increasedContrast ? 7 : 6, accuracy: 0.5)

            var searchRings: [NSRect] = []
            for expanded in [false, true] {
                toolbar.setSearchExpanded(expanded)
                toolbar.ringsFoldedSearch = !expanded
                toolbar.showsSearchFocus = true
                toolbar.layoutSubtreeIfNeeded()
                XCTAssertFalse(toolbar.focusHalo.isHidden, "expanded \(expanded)")
                searchRings.append(toolbar.convert(toolbar.focusHalo.frame, to: nil))
            }
            for identifier in ["QuickAccessFrequentLabel", "QuickAccessRecentLabel"] {
                let name = "\(identifier), Increase Contrast \(increasedContrast)"
                let label = try sectionLabel(identifier, of: strip)
                XCTAssertFalse(label.isHidden, name)
                // The label's frame ends 8 pt above the cards.
                let frame = label.convert(label.bounds, to: nil)
                XCTAssertEqual(frame.minY - card.maxY, 8, accuracy: 0.01, name)
                let parts = try ink(of: label)
                let ink = parts.symbol.union(parts.title)
                XCTAssertGreaterThanOrEqual(ink.minY - card.maxY, 8, name)
                XCTAssertGreaterThan(ink.minY - card.maxY, ring, name)
                XCTAssertGreaterThanOrEqual(row.minY - ink.maxY, 6, name)
                for searchRing in searchRings {
                    XCTAssertGreaterThanOrEqual(searchRing.minY - ink.maxY, 3, name)
                }
            }
        }
    }

    func testTheSectionLabelsAreTwelvePointSemiboldWithElevenPointSymbols() throws {
        // Each label's title draws the ink 12 pt semibold system text draws, and its symbol the ink of the SF Symbol at
        // 11 pt semibold, as SwiftUI draws each alone. A point more or less makes either at least 0.75 pt wider or
        // narrower, or taller or shorter, which is more than the 0.5 pt the comparison allows.
        let strip = QuickAccessStripView()
        for (identifier, title, symbol) in [("QuickAccessFrequentLabel", "Frequent", "flame"),
                                            ("QuickAccessRecentLabel", "Recent", "clock")] {
            let drawn = try ink(of: try sectionLabel(identifier, of: strip))
            let text = try XCTUnwrap(try Picture(Text(title).font(.system(size: 12, weight: .semibold)).fixedSize())
                .ink(in: nil))
            let image = try XCTUnwrap(try Picture(Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .fixedSize()).ink(in: nil))
            XCTAssertEqual(drawn.title.width, text.width, accuracy: 0.5, title)
            XCTAssertEqual(drawn.title.height, text.height, accuracy: 0.5, title)
            XCTAssertEqual(drawn.symbol.width, image.width, accuracy: 0.5, symbol)
            XCTAssertEqual(drawn.symbol.height, image.height, accuracy: 0.5, symbol)
        }
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

    /// One of the two section labels, found by its identifier.
    private func sectionLabel(_ identifier: String,
                              of strip: QuickAccessStripView) throws -> NSHostingView<StripSectionLabel> {
        let label = strip.sectionLabels.subviews.first { $0.accessibilityIdentifier() == identifier }
        return try XCTUnwrap(label as? NSHostingView<StripSectionLabel>, identifier)
    }

    /// The ink a section label draws, as SwiftUI draws the label's view in a frame as large as the label: its symbol's,
    /// up to the first gap wider than 2 pt, and its title's, after it; each in window coordinates.
    private func ink(of label: NSHostingView<StripSectionLabel>) throws -> (symbol: NSRect, title: NSRect) {
        let size = label.bounds.size
        let picture = try Picture(label.rootView.frame(width: size.width, height: size.height))
        let columns = picture.inkColumns
        let first = try XCTUnwrap(columns.first, "no ink"), last = try XCTUnwrap(columns.last, "no ink")
        let gap = try XCTUnwrap(zip(columns, columns.dropFirst()).first { $1 - $0 > Int(2 * Picture.scale) },
                                "no gap between the symbol and the title")
        let symbol = try XCTUnwrap(picture.ink(in: first...gap.0))
        let title = try XCTUnwrap(picture.ink(in: gap.1...last))
        // From the picture's top left corner to the label's own coordinates, then to the window's.
        func inWindow(_ rect: NSRect) -> NSRect {
            label.convert(label.isFlipped ? rect : NSRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width,
                                                         height: rect.height), to: nil)
        }
        return (inWindow(symbol), inWindow(title))
    }

    /// How far above a selected medium card its ring reaches, as SwiftUI draws the card with Increase Contrast or
    /// without: from the card's top edge up to the highest row in which the card's picture differs from the picture of
    /// the same card unselected. Its shadow is the same in both.
    private func ringReach(increasedContrast: Bool) throws -> CGFloat {
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
        let top = try XCTUnwrap((0..<Int(room * Picture.scale)).first { ringed.differs(from: plain, inRow: $0) },
                                "no ring above the card")
        return room - CGFloat(top) / Picture.scale
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
