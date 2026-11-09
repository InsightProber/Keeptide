import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

/// What the band stands on, as the band view sets it up from SwiftUI's environment: the tray, its edge and its
/// highlight in each appearance, and what Increase Contrast makes of them. The light behind the selected card: its
/// colour, place and strength, and how one light gives way to the next. And the strip's section icons below the
/// cards, measured by the ink SwiftUI draws for them.
@MainActor
final class QuickAccessBandTests: XCTestCase {
    func testTheBandIsAnOpaqueTrayWithAHairlineEdgeAndAHighlightAlongItsTop() throws {
        // The tray is #121316 in dark mode and #F3F3F1 in light mode, with nothing behind the window showing through:
        // no material. Inside its edge a 1 pt hairline, white at 7 percent in dark mode and black at 6 in light mode;
        // along its top, under the hairline, a 1 pt highlight, white at 9 percent in dark mode and white in light mode.
        // So the top edge reads lighter than the sides in either appearance.
        let darkTray = rgb(0x121316), lightTray = rgb(0xF3F3F1), white: [CGFloat] = [1, 1, 1]
        let darkTop = over(over(darkTray, 1, alpha: 0.09), 1, alpha: 0.07)
        let cases: [(dark: Bool, tray: [CGFloat], side: [CGFloat], top: [CGFloat])] = [
            (true, darkTray, over(darkTray, 1, alpha: 0.07), darkTop),
            (false, lightTray, over(lightTray, 0, alpha: 0.06), over(white, 0, alpha: 0.06)),
        ]
        for (dark, tray, side, top) in cases {
            let name = dark ? "dark" : "light"
            let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            settle(window)
            XCTAssertFalse(views(NSVisualEffectView.self, in: window.contentView).contains { !$0.isHidden }, name)
            let pixel = try surfacePixels(of: backdrop)
            let band = backdrop.surface.bounds
            assertColor(pixel(NSPoint(x: band.midX, y: band.midY)), tray, name + " tray")
            assertColor(pixel(NSPoint(x: band.minX + 0.25, y: band.midY)), side, name + " left edge")
            assertColor(pixel(NSPoint(x: band.maxX - 0.25, y: band.midY)), side, name + " right edge")
            assertColor(pixel(NSPoint(x: band.midX, y: band.minY + 0.25)), side, name + " bottom edge")
            assertColor(pixel(NSPoint(x: band.midX, y: band.maxY - 0.25)), top, name + " top edge")
            // Just inside the edge the tray is plain again.
            assertColor(pixel(NSPoint(x: band.midX, y: band.maxY - 1.25)), tray, name + " under the top edge")
        }
    }

    func testReduceTransparencyChangesNothingAndIncreaseContrastStrengthensTheEdge() throws {
        // The tray is opaque, so Reduce Transparency leaves every pixel as it was. Increase Contrast draws the hairline
        // in white at 20 percent in dark mode and black at 18 in light mode, and leaves the tray itself alone.
        for dark in [true, false] {
            let name = dark ? "dark" : "light"
            func pixels(reducesTransparency: Bool, increasedContrast: Bool) throws -> (NSPoint) -> [CGFloat] {
                let (window, backdrop) = try host(reducesTransparency: reducesTransparency,
                                                  increasedContrast: increasedContrast)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                settle(window)
                XCTAssertEqual(backdrop.increasesContrast, increasedContrast, name)
                return try surfacePixels(of: backdrop)
            }
            let plain = try pixels(reducesTransparency: false, increasedContrast: false)
            let reduced = try pixels(reducesTransparency: true, increasedContrast: false)
            let contrast = try pixels(reducesTransparency: false, increasedContrast: true)
            let size = StripLayout.metrics(for: .medium, visibleWidth: 1440)
            let middle = NSPoint(x: size.bandWidth / 2, y: StripLayout.bandHeight(size) / 2)
            let edge = NSPoint(x: 0.25, y: StripLayout.bandHeight(size) / 2)
            for point in [middle, edge, NSPoint(x: size.bandWidth / 2, y: StripLayout.bandHeight(size) - 0.25)] {
                assertColor(reduced(point), plain(point), "\(name) Reduce Transparency at \(point)", accuracy: 0.001)
            }
            assertColor(contrast(middle), plain(middle), "\(name) tray with Increase Contrast", accuracy: 0.001)
            let tray = plain(middle)
            let stronger = dark ? over(tray, 1, alpha: 0.2) : over(tray, 0, alpha: 0.18)
            assertColor(contrast(edge), stronger, "\(name) edge with Increase Contrast")
        }
        XCTAssertEqual(QuickAccessBandSurface.edge(dark: true, increasedContrast: false).alphaComponent, 0.07, accuracy: 0.001)
        XCTAssertEqual(QuickAccessBandSurface.edge(dark: false, increasedContrast: false).alphaComponent, 0.06, accuracy: 0.001)
        XCTAssertEqual(QuickAccessBandSurface.edge(dark: true, increasedContrast: true).alphaComponent, 0.2, accuracy: 0.001)
        XCTAssertEqual(QuickAccessBandSurface.edge(dark: false, increasedContrast: true).alphaComponent, 0.18, accuracy: 0.001)
    }

    // MARK: The light behind the selected card

    func testACardsAccentIsItsCollectionsColourThenItsAppsThenNone() {
        // One colour per card washes its header and lights the band behind it, so the two always match.
        let prompts = CollectionID(), archive = CollectionID()
        let colors = [prompts: "yellow", archive: "gray"]
        let blue = HeaderTint(background: HeaderTint.RGB(hex: 0x1F5FBF), usesDarkText: false)
        let grey = HeaderTint.neutral(dark: true)
        var filed = makeRow()
        filed.collectionIDs = [prompts]
        var gone = makeRow()
        gone.collectionIDs = [CollectionID()]
        var greyCollection = makeRow()
        greyCollection.collectionIDs = [archive]
        let cases: [(String, QuickAccessRow, HeaderTint?, CardAccent?)] = [
            // A snippet in a collection takes the collection's colour, whatever its app gives.
            ("filed", filed, blue, .collection("yellow")),
            ("filed, no app", filed, nil, .collection("yellow")),
            // A collection the person coloured grey glows grey: that is the colour they chose.
            ("grey collection", greyCollection, nil, .collection("gray")),
            // A collection that is no longer listed gives no colour, and the app's is taken instead.
            ("collection gone", gone, blue, .app(blue.background)),
            // An unfiled snippet, or a clip, takes the colour its app's icon gives.
            ("clip", makeRow(), blue, .app(blue.background)),
            // An icon with no colour to speak of gives the grey band, which gives no light; nor does a clip without an
            // app.
            ("grey icon", makeRow(), grey, nil),
            ("no app", makeRow(), nil, nil),
        ]
        for (name, row, tint, expected) in cases {
            XCTAssertEqual(CardAccent(row: row, collectionColors: colors, tint: tint), expected, name)
        }
        XCTAssertTrue(HeaderTint.neutral(dark: false).isNeutral)
        XCTAssertFalse(blue.isNeutral)
    }

    func testTheLightSitsBehindTheSelectedCardAndGrowsWithIt() throws {
        // Its middle is the card's: as far into the band as the card rests, and halfway down the cards, 67 + 112 =
        // 179 pt below the band's top edge with medium cards at the standard enlargement. It is 460 by 500 behind a
        // medium card, and as much smaller or larger as the card is.
        let row = makeRow()
        let tint = HeaderTint(background: HeaderTint.RGB(hex: 0x1F5FBF), usesDarkText: false)
        let medium = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let glow = try XCTUnwrap(QuickAccessGlow.make(row: row, accent: .app(tint.background), cardMidX: 500,
                                                       metrics: medium))
        XCTAssertEqual(glow.row, row.id)
        XCTAssertEqual(glow.accent, .app(tint.background))
        XCTAssertEqual(glow.center, CGPoint(x: 500, y: 179))
        XCTAssertEqual(glow.size, CGSize(width: 460, height: 500))
        for (size, expected) in [(CardSize.small, CGSize(width: 413, height: 449)),
                                 (.large, CGSize(width: 516, height: 561))] {
            let metrics = StripLayout.metrics(for: size, visibleWidth: 1440)
            let sized = try XCTUnwrap(QuickAccessGlow.make(row: row, accent: .app(tint.background), cardMidX: 500,
                                                            metrics: metrics))
            XCTAssertEqual(sized.size, expected, "\(size)")
            XCTAssertEqual(sized.center.y, StripLayout.cardTop(metrics) + metrics.frameSize.height / 2, "\(size)")
        }
        // A card without an accent has no light behind it.
        XCTAssertNil(QuickAccessGlow.make(row: row, accent: nil, cardMidX: 500, metrics: medium))
    }

    func testTheLightsStrengthFollowsItsColourAndAppearance() {
        // At its middle: 0.40 to 0.46 in dark mode, the most for a deep colour; 0.24 to 0.34 in light mode, the most for
        // a light one, which the light tray would otherwise swallow. Increase Contrast halves it.
        let colours: [(String, HeaderTint.RGB, dark: Bool, CGFloat)] = [
            ("blue", .init(hex: 0x0A84FF), true, 0.454), ("yellow", .init(hex: 0xFFD60A), true, 0.40),
            ("green", .init(hex: 0x30D158), true, 0.42),
            ("blue", .init(hex: 0x007AFF), false, 0.243), ("yellow", .init(hex: 0xFFCC00), false, 0.34),
        ]
        for (name, colour, dark, expected) in colours {
            let label = "\(name) \(dark ? "dark" : "light")"
            let peak = QuickAccessGlow.peakOpacity(of: colour, dark: dark, increasedContrast: false)
            XCTAssertEqual(peak, expected, accuracy: 0.005, label)
            let allowed: ClosedRange<CGFloat> = dark ? 0.40...0.46 : 0.24...0.34
            XCTAssertTrue(allowed.contains(peak), label)
            XCTAssertEqual(QuickAccessGlow.peakOpacity(of: colour, dark: dark, increasedContrast: true), peak / 2,
                           accuracy: 0.0001, label)
        }
        // Level at the middle, nothing at the edge, half of it halfway, and never stronger further out.
        XCTAssertEqual(QuickAccessGlow.falloff(0), 1)
        XCTAssertEqual(QuickAccessGlow.falloff(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(QuickAccessGlow.falloff(1), 0, accuracy: 0.0001)
        let steps = (0...20).map { QuickAccessGlow.falloff(CGFloat($0) / 20) }
        XCTAssertTrue(zip(steps, steps.dropFirst()).allSatisfy { $0 >= $1 })
    }

    func testTheGlowViewCrossfadesToAnotherCardAndMovesWithTheSameOne() throws {
        let tint = HeaderTint(background: HeaderTint.RGB(hex: 0x1F5FBF), usesDarkText: false)
        let medium = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let (first, second) = (makeRow(), makeRow())
        func glow(_ row: QuickAccessRow, at x: CGFloat) throws -> QuickAccessGlow {
            try XCTUnwrap(QuickAccessGlow.make(row: row, accent: .app(tint.background), cardMidX: x, metrics: medium))
        }
        let size = NSSize(width: medium.bandWidth, height: StripLayout.bandHeight(medium))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        addTeardownBlock { window.close() }
        let view = QuickAccessGlowView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        // It takes no clicks, VoiceOver reads none of it, and nothing of it lies beyond the band.
        XCTAssertNil(view.hitTest(NSPoint(x: size.width / 2, y: size.height / 2)))
        XCTAssertFalse(view.isAccessibilityElement())
        XCTAssertTrue(view.clipsToBounds)
        let mask = try XCTUnwrap(view.layer?.mask as? CAShapeLayer)
        XCTAssertEqual(mask.path, QuickAccessBandBackdrop.outline(in: view.bounds))
        XCTAssertNil(view.shownLight)

        // Shown behind the first card: its middle at the card's, 179 below the band's top, coloured from the middle out.
        view.show(try glow(first, at: 300))
        let light = try XCTUnwrap(view.shownLight)
        XCTAssertFalse(light.isHidden)
        XCTAssertEqual(light.frame, NSRect(x: 300 - 230, y: size.height - 179 - 250, width: 460, height: 500))
        let peak = QuickAccessGlow.peakOpacity(of: tint.background, dark: true, increasedContrast: false)
        XCTAssertEqual(light.colors.first?.alpha ?? 0, peak, accuracy: 0.0001)
        XCTAssertEqual(light.colors.last?.alpha ?? 1, 0, accuracy: 0.0001)
        // The same card resting elsewhere: the same light moves there.
        view.show(try glow(first, at: 620))
        XCTAssertTrue(view.shownLight === light)
        XCTAssertEqual(light.frame.midX, 620)
        // Another card: another light, and the first goes. In a window that is not shown nothing fades.
        view.show(try glow(second, at: 620))
        let next = try XCTUnwrap(view.shownLight)
        XCTAssertFalse(next === light)
        XCTAssertFalse(next.isHidden)
        XCTAssertTrue(light.isHidden)
        XCTAssertNil(next.layer?.animation(forKey: "glow.fade"))
        // No selection, or none with a colour: no light at all.
        view.show(nil)
        XCTAssertNil(view.shownLight)
        XCTAssertTrue(next.isHidden && light.isHidden)

        // On screen, one light fades in as the other fades out over a fifth of a second; with Reduce Motion, at once.
        window.orderFront(nil)
        view.reducesMotion = { false }
        view.show(try glow(first, at: 300))
        // Halfway into its fade, the next card is chosen: the light goes from where it is drawn then.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: QuickAccessGlowView.fadeDuration / 2))
        view.show(try glow(second, at: 620))
        let fading = [light, next].compactMap { $0.layer?.animation(forKey: "glow.fade") as? CABasicAnimation }
        XCTAssertEqual(fading.count, 2)
        XCTAssertTrue(fading.allSatisfy { $0.duration == QuickAccessGlowView.fadeDuration })
        view.reducesMotion = { true }
        view.show(try glow(first, at: 300))
        XCTAssertTrue([light, next].allSatisfy { $0.layer?.animation(forKey: "glow.fade") == nil })
        XCTAssertEqual(view.shownLight?.isHidden, false)
        XCTAssertEqual([light, next].filter(\.isHidden).count, 1)
        window.orderOut(nil)

        // Increase Contrast halves it.
        view.increasesContrast = { true }
        view.show(nil)
        view.show(try glow(second, at: 300))
        XCTAssertEqual(view.shownLight?.colors.first?.alpha ?? 0, peak / 2, accuracy: 0.0001)
    }

    func testTheAccentWashesInFromTheCardsTopAndACardWithoutOneStaysNeutral() throws {
        // Behind the header, the card's accent at 30 percent at its top in dark mode and 22 in light mode, fading to
        // nothing 70 pt down a medium card; below that, and on a card without an accent, the card's own colour. The
        // header's text is the card's usual text, never white on colour. With Increase Contrast the wash is a third
        // weaker, and a line runs under the header.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        XCTAssertEqual(StripFrameView.washHeight(metrics), 70)
        XCTAssertEqual(StripFrameView.washHeight(StripLayout.metrics(for: .small, visibleWidth: 1440)), 63)
        XCTAssertEqual(StripFrameView.washHeight(StripLayout.metrics(for: .large, visibleWidth: 1440)), 79)
        let blue = HeaderTint.RGB(hex: 0x1F5FBF)
        let content = StripFrameContent.make(row: makeRow(), detail: nil, cardSize: .medium)
        let icon = ApplicationNames().icon(for: nil)
        func picture(_ accent: CardAccent?, dark: Bool, contrast: ColorSchemeContrast = .standard) throws -> Picture {
            try Picture(StripFrameView(content: content, applicationIcon: icon, metrics: metrics, accent: accent,
                                       isSelected: false)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\._colorSchemeContrast, contrast))
        }
        for dark in [true, false] {
            let name = dark ? "dark" : "light"
            let paper: [CGFloat] = dark ? rgb(0x1D1E22) : [1, 1, 1]
            let (top, middle) = StripFrameView.washOpacity(dark: dark, increasedContrast: false)
            XCTAssertEqual(top, dark ? 0.30 : 0.22, accuracy: 0.0001, name)
            XCTAssertEqual(middle, dark ? 0.13 : 0.09, accuracy: 0.0001, name)
            let washed = try picture(.app(blue), dark: dark)
            let plain = try picture(nil, dark: dark)
            // 3 pt below the card's top, beside the header's text: the accent laid over the card, at the strength the
            // gradient has 3 pt into its first 40.6 pt, 96 percent of the top's.
            let strength = CGFloat(top) * 0.957
            let expected = zip(paper, rgb(0x1F5FBF)).map { over([$0], $1, alpha: strength)[0] }
            assertColor(washed.color(at: CGPoint(x: 100, y: 3)), expected, "\(name) washed", accuracy: 0.02)
            assertColor(plain.color(at: CGPoint(x: 100, y: 3)), paper, "\(name) neutral", accuracy: 0.01)
            // Past the wash, at 80 pt, the card's own colour on both.
            assertColor(washed.color(at: CGPoint(x: 100, y: 80)), paper, "\(name) below the wash", accuracy: 0.01)
            // With Increase Contrast the wash is a third weaker, and a line lies under the header.
            let weaker = StripFrameView.washOpacity(dark: dark, increasedContrast: true)
            XCTAssertEqual(weaker.top, top * 2 / 3, accuracy: 0.0001, name)
            XCTAssertEqual(weaker.middle, middle * 2 / 3, accuracy: 0.0001, name)
            let contrasted = try picture(.app(blue), dark: dark, contrast: .increased)
            // How far a pixel lies from the card's own colour.
            let departure = { (pixel: [CGFloat]) in zip(pixel, paper).map { abs($0 - $1) }.max() ?? 0 }
            XCTAssertLessThan(departure(contrasted.color(at: CGPoint(x: 100, y: 3))),
                              departure(washed.color(at: CGPoint(x: 100, y: 3))), name)
            let line = contrasted.color(at: CGPoint(x: 100, y: metrics.headerHeight - 0.5))
            let noLine = washed.color(at: CGPoint(x: 100, y: metrics.headerHeight - 0.5))
            XCTAssertGreaterThan(zip(line, noLine).map { abs($0 - $1) }.max() ?? 0, 0.05, "\(name) line")
        }
    }

    func testTheBandHostsTheLightOverItsWholeShape() throws {
        // The band gives the light the band's own size and place, under the toolbar and the strip.
        let glow = QuickAccessGlowView()
        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, glow: glow)
        settle(window)
        let band = backdrop.convert(backdrop.bandRect, to: nil)
        let hosted = glow.convert(glow.bounds, to: nil)
        XCTAssertEqual(hosted.minX, band.minX, accuracy: 0.5)
        XCTAssertEqual(hosted.minY, band.minY, accuracy: 0.5)
        XCTAssertEqual(hosted.width, band.width, accuracy: 0.5)
        XCTAssertEqual(hosted.height, band.height, accuracy: 0.5)
        XCTAssertFalse(window.contentView?.hitTest(NSPoint(x: band.midX, y: band.midY)) === glow)
    }

    // MARK: Room for the enlarged card

    func testTheBandGivesTheEnlargedCardRoomAboveAndBelow() throws {
        // Medium cards at each enlargement, without the frequent wing and with it. The band is as tall as the toolbar,
        // the cards and the room around them. The selected card's unscaled layout frame starts 60 pt
        // below the band's top edge and the growth further down, the distance the enlarged card reaches past it, and
        // the room below it is the metrics' own. The strip reaches the growth and 8 pt more for the ring above the
        // cards and below them, and the section icons' view fills the room below the cards.
        let cases: [(scale: CGFloat, wing: Bool, height: CGFloat)] = [
            (1, false, 302), (1, true, 311), (1.06, false, 316), (1.06, true, 325), (1.25, false, 358),
            (1.25, true, 367),
        ]
        for (scale, wing, height) in cases {
            let name = "\(scale), wing \(wing)"
            let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: wing,
                                              style: StripStyle(selectedScale: scale))
            let growth = metrics.selectionGrowth
            let strip = QuickAccessStripView()
            let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, metrics: metrics,
                                              strip: strip)
            // With the wing, three frequent rows and the newest clip selected beside them; without it, the newest.
            let rows = makeWing(frequent: wing ? 3 : 0, recent: 20)
            strip.show(rows, selection: rows[wing ? 3 : 0].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            settle(window)

            let band = backdrop.convert(backdrop.bandRect, to: nil)
            let card = try selectedCard(in: strip)
            XCTAssertEqual(band.height, height, name)
            XCTAssertEqual(band.maxY - card.maxY, 60 + growth, accuracy: 0.5, name)
            XCTAssertEqual(card.minY - band.minY, metrics.bottomPadding, accuracy: 0.5, name)
            // The strip as the band hosts it.
            let hosted = strip.convert(strip.bounds, to: nil)
            XCTAssertEqual(hosted.maxY - card.maxY, growth + 8, accuracy: 0.5, name)
            XCTAssertEqual(card.minY - hosted.minY, growth + 8, accuracy: 0.5, name)
            let icons = strip.sectionLabels.convert(strip.sectionLabels.bounds, to: nil)
            XCTAssertEqual(icons.height, metrics.bottomPadding, accuracy: 0.5, name)
            XCTAssertEqual(icons.minY, band.minY, accuracy: 0.5, name)
        }
    }

    func testTheEnlargedCardAndItsRingFitInTheBand() throws {
        for size in CardSize.allCases {
            for scale in [1.0, 1.06, 1.25] {
                for wing in [false, true] {
                    for contrast in [false, true] {
                        let metrics = StripLayout.metrics(for: size, visibleWidth: 1440, showsFrequentClips: wing,
                                                          style: StripStyle(selectedScale: scale))
                        let strip = QuickAccessStripView()
                        strip.increasesContrast = { contrast }
                        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: contrast,
                                                          metrics: metrics, strip: strip)
                        let rows = makeWing(frequent: wing ? 3 : 0, recent: 20)
                        strip.show(rows, selection: rows[wing ? 3 : 0].id, details: [:], metrics: metrics,
                                   applicationNames: ApplicationNames())
                        settle(window)
                        let ringView = try XCTUnwrap(strip.subviews.first?.subviews.first {
                            $0.accessibilityIdentifier() == "QuickAccessSelectionRing"
                        })
                        let ring = ringView.convert(ringView.bounds, to: nil)
                        let card = try drawnSelectedCard(in: strip)
                        let hosted = strip.convert(strip.bounds, to: nil)
                        let band = backdrop.convert(backdrop.bandRect, to: nil)
                        XCTAssertTrue(hosted.contains(ring))
                        XCTAssertTrue(hosted.contains(card))
                        // The toolbar's row ends 44 below the band's top edge, and the ring keeps 9 pt from it, 10
                        // without Increase Contrast; below the cards it keeps 11 from the band's bottom edge, or 20
                        // with the frequent wing's room for its icons.
                        XCTAssertGreaterThanOrEqual(band.maxY - 44 - ring.maxY, 9)
                        XCTAssertGreaterThanOrEqual(ring.minY - band.minY, wing ? 20 : 11)
                        let outline = QuickAccessBandBackdrop.outline(in: band)
                        let radius = try XCTUnwrap(ringView.layer).cornerRadius
                        let ringPath = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: ring).cgPath
                        let edge = self.outline(of: ringPath)
                        for sample in 0..<64 {
                            XCTAssertTrue(outline.contains(edge[sample * edge.count / 64]))
                        }
                    }
                }
            }
        }
    }

    // MARK: Shadow

    /// The design's soft shadow reaches farther than the room the panel leaves it. Cut short where the window ends, it
    /// showed as a faint band with a hard edge above and below the band; so it fades out before any edge of the window,
    /// whether the panel leaves it its whole room or a low screen leaves it 10 points below the band.
    func testTheShadowFadesOutBeforeTheWindowEnds() throws {
        for dark in [true, false] {
            for roomBelow in [StripLayout.shadowRoom.below, 10] as [CGFloat] {
                let name = "\(dark ? "dark" : "light"), \(roomBelow) below"
                let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false,
                                                  roomBelow: roomBelow)
                backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let content = try XCTUnwrap(window.contentView)
                let shown = backdrop.bounds.intersection(backdrop.convert(content.bounds, from: content))
                let alpha = try shadowAlpha(of: backdrop)
                var edge: CGFloat = 0
                for step in 0...64 {
                    let x = shown.minX + shown.width * CGFloat(step) / 64
                    let y = shown.minY + shown.height * CGFloat(step) / 64
                    edge = max(edge, alpha(NSPoint(x: x, y: shown.maxY - 0.25)), alpha(NSPoint(x: x, y: shown.minY + 0.25)),
                               alpha(NSPoint(x: shown.minX + 0.25, y: y)), alpha(NSPoint(x: shown.maxX - 0.25, y: y)))
                }
                XCTAssertLessThanOrEqual(edge, 1.0 / 255, name)
                // Beside the band, well inside the window, the shadow is still there.
                let band = backdrop.bandRect
                let beside = max(alpha(NSPoint(x: band.midX, y: band.maxY + 10)),
                                 alpha(NSPoint(x: band.midX, y: band.minY - 10)),
                                 alpha(NSPoint(x: band.minX - 10, y: band.midY)))
                XCTAssertGreaterThan(beside, dark ? 0.15 : 0.06, name)
            }
        }
    }

    /// The panel moves around the band as the preview or a command's review opens and closes: the band moves down in
    /// the window and the window grows, while the backdrop keeps its size, so AppKit does not lay it out again. On a
    /// low screen the window then leaves less room below the band, and the shadow drawn for the old window ran on to
    /// the new one's bottom edge and was cut short there. So the backdrop is drawn again when the band's layout
    /// changes, and when its window's size does. SwiftUI hosts it in a layer: AppKit passes a request to draw it again
    /// on to the layer, and the view's own `needsDisplay` stays false. A window that changes size marks that layer as
    /// well, without drawing the view, so there the drawing itself tells whether the view was drawn again.
    func testTheShadowIsDrawnAgainAsThePanelMovesAroundTheBand() throws {
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, metrics: metrics)
        let layout = QuickAccessBandView.Layout(metrics: metrics, previewSize: nil,
                                                roomBelow: StripLayout.shadowRoom.below)
        XCTAssertEqual(backdrop.panelLayout, layout, "The band hands the backdrop its layout")
        let layer = try XCTUnwrap(backdrop.layer)
        layer.displayIfNeeded()
        XCTAssertFalse(layer.needsDisplay())

        var moved = layout
        moved.roomBelow = 30
        backdrop.panelLayout = moved
        XCTAssertTrue(layer.needsDisplay(), "A new layout")
        layer.displayIfNeeded()

        // The window loses 70 points at its bottom edge and keeps its top edge.
        let drawn = backdrop.drawnShadowArea
        XCTAssertEqual(drawn, backdrop.shadowArea)
        var frame = window.frame
        frame.origin.y += 70
        frame.size.height -= 70
        window.setFrame(frame, display: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertNotEqual(backdrop.shadowArea, drawn, "The window ends elsewhere in the backdrop")
        XCTAssertEqual(backdrop.drawnShadowArea, backdrop.shadowArea, "Drawn again for a window of another size")

        // Drawn again, the shadow fades out before the window's new bottom edge.
        let content = try XCTUnwrap(window.contentView)
        let shown = backdrop.bounds.intersection(backdrop.convert(content.bounds, from: content))
        let alpha = try shadowAlpha(of: backdrop)
        var edge: CGFloat = 0
        for step in 0...64 {
            edge = max(edge, alpha(NSPoint(x: shown.minX + shown.width * CGFloat(step) / 64, y: shown.minY + 0.25)))
        }
        XCTAssertLessThanOrEqual(edge, 1.0 / 255)
    }

    // MARK: Section icons

    func testTheSectionIconsLieBelowTheCards() throws {
        // With the standard enlargement and without the frequent wing the band is 316 tall with 25 below the cards;
        // with the wing, 325 with 34 below them. Either way the cards start 67 below the band's top edge: 16 below the
        // toolbar's row, and 7 more for the selected card enlarged.
        for (wing, room, height) in [(false, 25, 316), (true, 34, 325)] as [(Bool, CGFloat, CGFloat)] {
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
            XCTAssertEqual(band.maxY - card.maxY, 67, accuracy: 0.5, "wing \(wing)")
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
        // The ring around a selected card reaches 6 pt below it, and 7 with Increase Contrast. The selected card
        // enlarged by the standard 1.06 reaches 7 pt below the others' bottom edges, and its ring that much lower.
        // Each icon is centred between the wider ring's lowest reach and the band's bottom edge, and the ink it draws,
        // measured as SwiftUI draws it, keeps at least 3 pt from both, the two gaps differing by less than a point. The
        // icons are the same with Increase Contrast or without.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: true)
        XCTAssertEqual(metrics.selectionGrowth, 7)
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
            // The selected card's unscaled frame, then the enlarged card's growth and its ring's reach below it.
            let ring = try selectedCard(in: strip).minY - metrics.selectionGrowth - reach
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

    func testTheSectionIconsAreElevenPointSemiboldSymbolsWithoutWords() throws {
        // Each icon draws the ink of its SF Symbol at 11 pt semibold, as SwiftUI draws the symbol alone, and nothing
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
            let reference = try Picture(Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
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
        // within the corner's radius, 28 pt, of that end and of the bottom edge. Further along the outline runs close
        // to the straight bottom edge, which the icons keep 3 pt from.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: true)
        // Three frequent clips and Row 10 selected: the divider is off the left end, and the clock rests there. Twenty
        // frequent clips and the least used one selected, at the wing's left end: the divider is off the right end, and
        // the flame rests there.
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

    func testEveryIconAtRestKeepsEightPointsFromTheBandsRoundedCorners() throws {
        // Where the film came to rest with the divider 34 to 66 pt from an end of the band, the icon beside the
        // divider stood in the band's rounded corner. An icon now follows the divider until it is 42 pt from the end,
        // stays there, and goes once the divider passes it. Every place the film rests in, with twenty frequent clips
        // and thirty recent ones: each icon shown keeps 8 pt from the corner, measured by its ink as in the test above,
        // 42 pt or more from either end, and on its own wing's side of the divider, so the two never meet. It does so
        // at every enlargement of the selected card: at the slider's two ends and the standard one between them. With
        // the selected card not enlarged, the film rests with the divider that close to an end on the `near` screens,
        // with medium cards on one 1280 wide and small ones on one 1200 wide; the others are where it happened when
        // the band and its cards were larger.
        let near: [(width: CGFloat, size: CardSize)] = [(1280, .medium), (1200, .small)]
        let earlier: [(width: CGFloat, size: CardSize)] = [(1440, .medium), (1920, .medium), (1280, .small),
                                                           (1600, .large), (1710, .small), (2560, .small),
                                                           (1600, .medium), (1710, .medium)]
        let cases = (near + earlier).flatMap { screen in
            ([1, 1.06, 1.25] as [CGFloat]).map { (width: screen.width, size: screen.size, scale: $0) }
        }
        for (width, size, scale) in cases {
            let name = "\(Int(width)) \(size) \(scale)"
            let metrics = StripLayout.metrics(for: size, visibleWidth: width, showsFrequentClips: true,
                                              style: StripStyle(selectedScale: scale))
            let strip = QuickAccessStripView()
            let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, metrics: metrics,
                                              strip: strip)
            settle(window)
            let band = backdrop.convert(backdrop.bandRect, to: nil)
            let radius = StripLayout.cornerRadius
            let lowCorners = outline(of: band).filter { $0.y <= band.minY + radius }
            let corners = (left: lowCorners.filter { $0.x <= band.minX + radius },
                           right: lowCorners.filter { $0.x >= band.maxX - radius })
            XCTAssertFalse(corners.left.isEmpty || corners.right.isEmpty, name)
            let icons = try ["QuickAccessFrequentLabel", "QuickAccessRecentLabel"].map {
                try sectionLabel($0, of: strip)
            }
            // Each icon's ink, in its own coordinates; it is the same wherever the icon stands. Only the ink's edge can
            // be nearest a corner: from a pixel with ink all round it, a neighbour lies closer to anything outside.
            let inks = try icons.map { try inkEdgePoints(of: $0) }
            let divider = try XCTUnwrap(dividerView(in: strip), name)
            let rows = makeWing(frequent: 20, recent: 30)
            var nearAnEnd = 0
            for index in rows.indices {
                strip.show(rows, selection: rows[index].id, details: [:], metrics: metrics,
                           applicationNames: ApplicationNames())
                let rest = "\(name), row \(index)"
                let line = divider.convert(divider.bounds, to: nil).midX
                if [line - band.minX, band.maxX - line].contains(where: { (34...66).contains($0) }) { nearAnEnd += 1 }
                var shown: [NSRect] = []
                for (icon, ink) in zip(icons, inks) where !icon.isHidden {
                    let frame = icon.convert(icon.bounds, to: nil)
                    shown.append(frame)
                    XCTAssertGreaterThanOrEqual(frame.minX - band.minX, StripLayout.sectionLabelPinInset - 0.5, rest)
                    XCTAssertGreaterThanOrEqual(band.maxX - frame.maxX, StripLayout.sectionLabelPinInset - 0.5, rest)
                    if icon === icons[0] {
                        XCTAssertLessThanOrEqual(frame.maxX, line + 0.5, rest)
                    } else {
                        XCTAssertGreaterThanOrEqual(frame.minX, line - 0.5, rest)
                    }
                    // Only an icon this close to an end comes anywhere near its corner.
                    let corner = frame.midX < band.midX ? corners.left : corners.right
                    guard frame.minX - band.minX < 70 || band.maxX - frame.maxX < 70 else { continue }
                    // Three conversions give the icon's place in the window, which then places every pixel of its ink.
                    let origin = icon.convert(NSPoint.zero, to: nil)
                    let across = icon.convert(NSPoint(x: 1, y: 0), to: nil)
                    let up = icon.convert(NSPoint(x: 0, y: 1), to: nil)
                    var nearestSquared = CGFloat.infinity
                    for point in ink {
                        let x = origin.x + point.x * (across.x - origin.x) + point.y * (up.x - origin.x)
                        let y = origin.y + point.x * (across.y - origin.y) + point.y * (up.y - origin.y)
                        for outline in corner {
                            let dx = outline.x - x, dy = outline.y - y
                            nearestSquared = min(nearestSquared, dx * dx + dy * dy)
                        }
                    }
                    let nearest = nearestSquared.isFinite ? nearestSquared.squareRoot() : 0
                    // From the nearest pixel's edge rather than its middle.
                    XCTAssertGreaterThanOrEqual(nearest - 0.5 / Picture.scale, 8, rest)
                }
                XCTAssertFalse(shown.isEmpty, rest)
                if shown.count == 2 { XCTAssertFalse(shown[0].intersects(shown[1]), rest) }
            }
            // Where it happened, the film does rest with the divider that close to an end.
            if scale == 1, near.contains(where: { $0.width == width && $0.size == size }) {
                XCTAssertGreaterThan(nearAnEnd, 0, name)
            }
        }
    }

    func testAFrequentCardDrawsHowOftenItWasUsedAsATimeIsDrawn() throws {
        // A frequent clip's card says "Used 1,234 times" where a recent clip's says how long ago it was copied, in the
        // same face, size and colour: it is the very picture of a card whose time read those words. The clip's own
        // recent card, with its time, is a different picture, so the comparison can tell them apart.
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let icon = ApplicationNames().icon(for: nil)
        func picture(_ content: StripFrameContent) throws -> Picture {
            try Picture(StripFrameView(content: content, applicationIcon: icon, metrics: metrics, accent: nil,
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

    // MARK: Text in an image

    func testTheTextColumnSaysWhyWhenARecognitionEndsWithoutText() throws {
        var announced: [String] = []
        let image = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data())
        let failure = GenerationError(kind: .contentUnavailable, message: "This image couldn't be read.")
        func split(_ column: TextColumn, justMade: Bool, ref: ContentRef = image) -> QuickAccessSplitPreview {
            QuickAccessSplitPreview(preview: nil, applicationName: nil, column: column, ref: ref, isJustMade: justMade,
                                    onCommand: { _ in }, announce: { announced.append($0) })
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let hosting = NSHostingView(rootView: split(.loading, justMade: false))
        window.contentView = hosting
        settle(window)

        // A recognition that fails at once, before it was seen under way, says why as it ends.
        hosting.rootView = split(.failed(failure), justMade: true)
        settle(window)
        XCTAssertEqual(announced, [failure.message])

        // Text that was made, then couldn't be kept, says why too.
        hosting.rootView = split(.text("Synthetic", keepsLineBreaks: true, status: .complete), justMade: true)
        settle(window)
        hosting.rootView = split(.failed(.contentUnavailable), justMade: true)
        settle(window)
        XCTAssertEqual(announced, [failure.message, GenerationError.contentUnavailable.message])

        // An ending from before, shown for another image, says nothing again.
        let other = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data())
        hosting.rootView = split(.noText, justMade: true, ref: other)
        settle(window)
        XCTAssertEqual(announced.count, 2)
    }

    // MARK: Helpers

    /// The band view with `metrics`, medium cards unless given others, and nothing in its state, in a window that is
    /// never shown, with the two settings given through SwiftUI's environment as the system would give them; and the
    /// backdrop it made.
    private func host(
        reducesTransparency: Bool, increasedContrast: Bool,
        metrics: StripMetrics = StripLayout.metrics(for: .medium, visibleWidth: 1440),
        strip: QuickAccessStripView = QuickAccessStripView(),
        toolbar: QuickAccessToolbar = QuickAccessToolbar(field: QuickAccessSearchField()),
        glow: QuickAccessGlowView = QuickAccessGlowView(),
        roomBelow: CGFloat = StripLayout.shadowRoom.below
    ) throws -> (NSWindow, QuickAccessBandBackdrop) {
        let band = QuickAccessBandView(
            layout: QuickAccessBandView.Layout(metrics: metrics, previewSize: nil, roomBelow: roomBelow),
            state: QuickAccessState(services: { nil }), toolbar: toolbar,
            strip: strip, glow: glow, applicationNames: ApplicationNames(),
            actions: QuickAccessBandView.Actions(previewCommand: { _ in }, confirmCommand: {}, cancelCommandReview: {},
                                                 announce: { _ in })
        )
        let root = band
            .environment(\._accessibilityReduceTransparency, reducesTransparency)
            .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard)
        let size = NSSize(width: metrics.bandWidth + 2 * StripLayout.sideMargin,
                          height: StripLayout.bandHeight(metrics) + StripLayout.shadowRoom.above + roomBelow)
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

    /// What the backdrop draws itself, its shadow, rendered at twice its size: the alpha at a point in its coordinates.
    private func shadowAlpha(of backdrop: QuickAccessBandBackdrop) throws -> (NSPoint) -> CGFloat {
        let size = backdrop.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        backdrop.draw(backdrop.bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertFalse(backdrop.isFlipped, "The readings below count rows from the top of an unflipped view")
        return { point in
            let x = min(max(Int(point.x * 2), 0), rep.pixelsWide - 1)
            let y = min(max(Int((size.height - point.y) * 2), 0), rep.pixelsHigh - 1)
            return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }
    }

    /// What the band's surface draws, the tray, its edge and its highlight, drawn in sRGB at twice its size: the colour
    /// at a point in its coordinates, as red, green and blue.
    private func surfacePixels(of backdrop: QuickAccessBandBackdrop) throws -> (NSPoint) -> [CGFloat] {
        let surface = backdrop.surface
        let size = surface.bounds.size
        let (width, height) = (Int(size.width * 2), Int(size.height * 2))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        surface.draw(surface.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
        XCTAssertFalse(surface.isFlipped, "The readings below count rows from the top of an unflipped view")
        return { point in
            let x = min(max(Int(point.x * 2), 0), width - 1)
            let y = min(max(Int((size.height - point.y) * 2), 0), height - 1)
            let pixel = (y * width + x) * 4
            return (0..<3).map { CGFloat(bytes[pixel + $0]) / 255 }
        }
    }

    /// A colour written as 0xRRGGBB, as red, green and blue from 0 to 1.
    private func rgb(_ hex: UInt32) -> [CGFloat] {
        let red = CGFloat((hex >> 16) & 0xFF), green = CGFloat((hex >> 8) & 0xFF), blue = CGFloat(hex & 0xFF)
        return [red / 255, green / 255, blue / 255]
    }

    /// `base` with a grey `value` laid over it at `alpha`, as each component blends.
    private func over(_ base: [CGFloat], _ value: CGFloat, alpha: CGFloat) -> [CGFloat] {
        base.map { component in component * (1 - alpha) + value * alpha }
    }

    private func assertColor(_ actual: [CGFloat], _ expected: [CGFloat], _ name: String, accuracy: CGFloat = 0.012,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, 3, name, file: file, line: line)
        for (component, (value, wanted)) in zip(["red", "green", "blue"], zip(actual, expected)) {
            XCTAssertEqual(value, wanted, accuracy: accuracy, "\(name), \(component)", file: file, line: line)
        }
    }

    private func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func backdrops(in view: NSView) -> [QuickAccessBandBackdrop] {
        ((view as? QuickAccessBandBackdrop).map { [$0] } ?? []) + view.subviews.flatMap { backdrops(in: $0) }
    }

    /// `frequent` rows of the frequent wing, then `recent` rows; every clip made up here. As the state lists the wing,
    /// the least used comes first and the most used stands last, beside the newest clip.
    private func makeWing(frequent: Int, recent: Int) -> [QuickAccessRow] {
        (0..<frequent).map { index in
            var row = makeRow()
            row.frequentUses = Int64(2 + index)
            return row
        } + (0..<recent).map { _ in makeRow() }
    }

    /// The line between the wings, found by its identifier.
    private func dividerView(in view: NSView) -> NSView? {
        view.accessibilityIdentifier() == "QuickAccessDivider" ? view
            : view.subviews.lazy.compactMap { self.dividerView(in: $0) }.first
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

    /// The selected clip's unscaled layout frame, in window coordinates; growth is added separately by callers.
    private func selectedCard(in strip: QuickAccessStripView) throws -> NSRect {
        func drawings(in view: NSView) -> [NSHostingView<StripFrameView>] {
            view.subviews.flatMap { ($0 as? NSHostingView<StripFrameView>).map { [$0] } ?? drawings(in: $0) }
        }
        let card = try XCTUnwrap(drawings(in: strip).first { $0.rootView.isSelected }, "the selected card")
        return card.convert(card.bounds, to: nil)
    }

    private func drawnSelectedCard(in strip: QuickAccessStripView) throws -> NSRect {
        func selected(in view: NSView) -> NSView? {
            if let drawing = view as? NSHostingView<StripFrameView>, drawing.rootView.isSelected { return drawing.superview }
            return view.subviews.lazy.compactMap { selected(in: $0) }.first
        }
        let host = try XCTUnwrap(selected(in: strip))
        let film = try XCTUnwrap(host.superview), layer = try XCTUnwrap(host.layer)
        let shift = (film.layer?.presentation()?.position.x ?? film.layer?.position.x ?? 0) - (film.layer?.position.x ?? 0)
        return film.convert((layer.presentation() ?? layer).frame.offsetBy(dx: shift, dy: 0), to: nil)
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

    /// The middle of each pixel on the edge of a section icon's ink, as SwiftUI draws the icon's view in a frame as large
    /// as the icon, in the icon's own coordinates.
    private func inkEdgePoints(of label: NSHostingView<StripSectionLabel>) throws -> [NSPoint] {
        let size = label.bounds.size
        let picture = try Picture(label.rootView.frame(width: size.width, height: size.height))
        return picture.inkEdgePixels.map { pixel in
            let x = (CGFloat(pixel.x) + 0.5) / Picture.scale, y = (CGFloat(pixel.y) + 0.5) / Picture.scale
            return NSPoint(x: x, y: label.isFlipped ? y : size.height - y)
        }
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
        outline(of: QuickAccessBandBackdrop.outline(in: band))
    }

    private func outline(of path: CGPath) -> [CGPoint] {
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
        path.applyWithBlock { pointer in
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

    /// How far the strip's ring reaches past the selected medium card's drawn edge, above it or `below` it,
    /// with Increase Contrast or without. Measure the separate AppKit ring rather than the card's SwiftUI drawing.
    private func ringReach(increasedContrast: Bool, below: Bool = false) throws -> CGFloat {
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let strip = QuickAccessStripView()
        strip.increasesContrast = { increasedContrast }
        let (window, _) = try host(reducesTransparency: false, increasedContrast: increasedContrast,
                                  metrics: metrics, strip: strip)
        let rows = makeWing(frequent: 0, recent: 20)
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        settle(window)
        let ring = try XCTUnwrap(strip.subviews.first?.subviews.first {
            $0.accessibilityIdentifier() == "QuickAccessSelectionRing"
        })
        let frame = ring.convert(ring.bounds, to: nil)
        let card = try drawnSelectedCard(in: strip)
        return below ? card.minY - frame.minY : frame.maxY - card.maxY
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
            // In sRGB, as the colours read from it are given: the display's own space would shift them.
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "The picture could not be read")
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// The colour at the point `point` points from the picture's left and top, as red, green and blue from 0 to 1, as if
    /// over black: the pictures here are opaque where they are read.
    func color(at point: CGPoint) -> [CGFloat] {
        let x = min(max(Int(point.x * Self.scale), 0), width - 1)
        let y = min(max(Int(point.y * Self.scale), 0), height - 1)
        let index = (y * width + x) * 4
        return (0..<3).map { CGFloat(bytes[index + $0]) / 255 }
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

    /// The pixels of `inkPixels` with no ink in at least one of their eight neighbours, or on the picture's border.
    var inkEdgePixels: [(x: Int, y: Int)] {
        inkPixels.filter { pixel in
            (-1...1).contains { dy in
                (-1...1).contains { dx in
                    let x = pixel.x + dx, y = pixel.y + dy
                    return !(0..<width).contains(x) || !(0..<height).contains(y) || !hasInk(x, y)
                }
            }
        }
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
