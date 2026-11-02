import XCTest
@testable import Keeptide

final class StripLayoutTests: XCTestCase {
    /// A band 1360 pt wide with frames 164 pt wide and 176 pt apart, docked 24 pt in from its ends: the geometry
    /// the placement numbers below were worked out for. It is no card size's own.
    private var metrics: StripMetrics {
        StripMetrics(cardSize: .medium, bandWidth: 1360, frameSize: CGSize(width: 164, height: 109), gap: 12,
                     cornerRadius: 12, dockInset: 24, headerHeight: 56, footerHeight: 30, iconSize: 40)
    }

    func testCardSizesMatchTheSpec() {
        let sizes: [(size: CardSize, card: CGSize, header: CGFloat, icon: CGFloat, footer: CGFloat, radius: CGFloat)] = [
            (.small, CGSize(width: 200, height: 220), 52, 36, 28, 18),
            (.medium, CGSize(width: 228, height: 250), 56, 40, 30, 20),
            (.large, CGSize(width: 260, height: 286), 60, 44, 32, 22),
        ]
        for (size, card, header, icon, footer, radius) in sizes {
            let m = StripLayout.metrics(for: size, visibleWidth: 1440)
            XCTAssertEqual(m.cardSize, size)
            XCTAssertEqual(m.frameSize, card, "\(size)")
            XCTAssertEqual(m.headerHeight, header, "\(size)")
            XCTAssertEqual(m.iconSize, icon, "\(size)")
            XCTAssertEqual(m.footerHeight, footer, "\(size)")
            // Larger cards have rounder corners.
            XCTAssertEqual(m.cornerRadius, radius, "\(size)")
            // Gap and dock inset are the same at every size.
            XCTAssertEqual(m.gap, 14, "\(size)")
            XCTAssertEqual(m.dockInset, 20, "\(size)")
            XCTAssertEqual(m.step, card.width + 14, "\(size)")
        }
    }

    func testBandIsTheVisibleWidthLessSixtyFour() {
        for (visible, band) in [(1440, 1376), (2560, 2496), (1024, 960)] as [(CGFloat, CGFloat)] {
            XCTAssertEqual(StripLayout.metrics(for: .medium, visibleWidth: visible).bandWidth, band, "\(visible)")
        }
    }

    func testANarrowScreenKeepsTheCardSizeAndShowsFewerCards() {
        for size in CardSize.allCases {
            let wide = StripLayout.metrics(for: size, visibleWidth: 2560)
            let narrow = StripLayout.metrics(for: size, visibleWidth: 1024)
            XCTAssertEqual(narrow.cardSize, size)
            XCTAssertEqual(narrow.frameSize, wide.frameSize, "\(size)")
            XCTAssertEqual(narrow.gap, wide.gap, "\(size)")
            XCTAssertEqual(narrow.cornerRadius, wide.cornerRadius, "\(size)")
            XCTAssertEqual(narrow.dockInset, wide.dockInset, "\(size)")
        }
        // The film docks the same 20 pt in from the band's left end.
        let narrow = StripLayout.metrics(for: .large, visibleWidth: 1024)
        XCTAssertEqual(StripLayout.placement(narrow, count: 50, position: 0, oldestIsLoaded: false).firstOrigin, 20)
    }

    func testTheBandIsTheToolbarTheCardsAndTheirPadding() {
        // 16 above the toolbar, the toolbar's 32, 20 down to the cards, the cards, and 22 below them.
        for (size, height) in [(CardSize.small, 310), (.medium, 340), (.large, 376)] as [(CardSize, CGFloat)] {
            let m = StripLayout.metrics(for: size, visibleWidth: 1440)
            XCTAssertEqual(StripLayout.bandHeight(m), height, "\(size)")
            XCTAssertEqual(StripLayout.cardTop, 68)
            XCTAssertEqual(StripLayout.bandHeight(m) - StripLayout.cardTop - m.frameSize.height, 22, "\(size)")
        }
        // Its corners are rounder than the cards'.
        XCTAssertEqual(StripLayout.cornerRadius, 36)
    }

    func testOpenDocksTheNewestAtTheLeftEnd() {
        assertPlacement(count: 50, position: 0, origin: 24)
    }

    func testTheSelectionWalksToTheMiddleBeforeTheFilmMoves() {
        // The film rests while the selection walks right along it: the selected frame is at 24 + 3 · 176 = 552.
        assertPlacement(count: 50, position: 3, origin: 24)
        // One step further it would pass the middle, so the film moves instead and the selected frame stays centred.
        assertPlacement(count: 50, position: 4, origin: -106)
        let moved = StripLayout.placement(metrics, count: 50, position: 4, oldestIsLoaded: false)
        XCTAssertEqual(moved.firstOrigin + 4 * metrics.step + metrics.frameSize.width / 2, metrics.bandWidth / 2)
    }

    func testFingersMoveTheFilmOnlyPastTheDock() {
        // A fractional position is a selection under the fingers, between two clips. Short of the middle, which
        // it reaches at about 3.26, the film rests; past it the film follows.
        assertPlacement(count: 50, position: 3.2, origin: 24)
        assertPlacement(count: 50, position: 3.3, origin: 17.2, accuracy: 0.001)
        assertPlacement(count: 50, position: 3.5, origin: -18)
    }

    func testTheOldestEndDocksOnlyWhenLoaded() {
        // Loaded, the film follows the selection until the last frame's right edge would pass 1360 − 24 = 1336,
        // at about index 45.7. From there it stops and the selection walks on to the last clip.
        assertPlacement(count: 50, position: 45, loaded: true, origin: -7322)
        assertPlacement(count: 50, position: 46, loaded: true, origin: -7452)
        assertPlacement(count: 50, position: 49, loaded: true, origin: -7452)
        let docked = StripLayout.placement(metrics, count: 50, position: 49, oldestIsLoaded: true)
        let last = StripLayout.frameOrigins(metrics, count: 50, placement: docked)[49]
        XCTAssertEqual(last + metrics.frameSize.width, 1336)
        // While more may follow, the film keeps moving to the last clip.
        assertPlacement(count: 50, position: 49, origin: -8026)
    }

    func testAShortLoadedFilmIsCentredAsAGroup() {
        // Three clips are 516 wide, which leaves 422 on each side whichever of them is selected.
        assertPlacement(count: 3, position: 0, loaded: true, origin: 422)
        assertPlacement(count: 3, position: 2, loaded: true, origin: 422)
        // Seven (1220) still fit between the docks (1312). Eight (1396) do not, so the film docks at the left end.
        assertPlacement(count: 7, position: 0, loaded: true, origin: 70)
        assertPlacement(count: 8, position: 0, loaded: true, origin: 24)
        // A single clip sits in the middle.
        assertPlacement(count: 1, position: 0, loaded: true, origin: 598)
        // Clips that more may follow are not centred.
        assertPlacement(count: 3, position: 0, origin: 24)
    }

    func testAVanishedSelectionKeepsAnEmptySlotAtTheDock() {
        // The empty slot takes the dock and index 0 stands one step to its right: 24 + 176.
        assertPlacement(count: 50, position: -1, origin: 200)
        // A short loaded film is centred with the slot in it: four frames are 692 wide, so index 0 is at 334 + 176.
        assertPlacement(count: 3, position: -1, loaded: true, origin: 510)
        // Six clips and the slot (1220) still fit between the docks; seven and the slot (1396) do not, so the
        // slot docks at the left end.
        assertPlacement(count: 6, position: -1, loaded: true, origin: 246)
        assertPlacement(count: 7, position: -1, loaded: true, origin: 200)
        // Fingers between the slot and index 0 do not move the film.
        assertPlacement(count: 50, position: -0.5, origin: 200)
    }

    func testFrameOriginsStepRightFromTheFirst() {
        let placement = StripPlacement(firstOrigin: 24)
        XCTAssertEqual(StripLayout.frameOrigins(metrics, count: 3, placement: placement), [24, 200, 376])
    }

    func testPanelAndPreviewStayInsideOddVisibleFrames() {
        for visible in [NSRect(x: 0, y: 25, width: 1280, height: 760), NSRect(x: 0, y: 0, width: 1100, height: 680),
                        NSRect(x: -1800, y: 30, width: 1600, height: 1000), NSRect(x: 0, y: 900, width: 400, height: 640),
                        NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: 0, y: 0, width: 2560, height: 1415)] {
            for size in CardSize.allCases {
                let m = StripLayout.metrics(for: size, visibleWidth: visible.width)
                let band = StripLayout.bandFrame(m, in: visible)
                XCTAssertEqual(band.midX, visible.midX, accuracy: 0.5, "\(size) \(visible)")
                XCTAssertEqual(band.midY, visible.midY, accuracy: 0.5, "\(size) \(visible)")
                XCTAssertEqual(band.size, NSSize(width: m.bandWidth, height: StripLayout.bandHeight(m)))
                XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: band, preview: nil, in: visible)),
                              "\(size) \(visible)")
                let (preview, moved) = StripLayout.previewLayout(band: band, in: visible)
                XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: moved, preview: preview, in: visible)),
                              "\(size) \(visible)")
                // The card sits above the band.
                XCTAssertGreaterThanOrEqual(preview.minY, moved.maxY + StripLayout.previewGap - 0.5, "\(size) \(visible)")
            }
        }
    }

    func testALaptopScreenHoldsTheWholePreviewCard() {
        // 1440 × 875 is what a 1440 × 900 laptop screen leaves under the menu bar. With small and medium cards the
        // preview card keeps its full 760 × 470 above the band, the two centred together.
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875)
        for size in [CardSize.small, .medium] {
            let m = StripLayout.metrics(for: size, visibleWidth: laptop.width)
            let band = StripLayout.bandFrame(m, in: laptop)
            let (preview, moved) = StripLayout.previewLayout(band: band, in: laptop)
            XCTAssertEqual(preview.size, StripLayout.previewMaximum, "\(size)")
            XCTAssertEqual(preview.minY, moved.maxY + StripLayout.previewGap, accuracy: 0.5, "\(size)")
            XCTAssertEqual((preview.maxY + moved.minY) / 2, laptop.midY, accuracy: 0.5, "\(size)")
            XCTAssertTrue(laptop.contains(StripLayout.panelFrame(band: moved, preview: preview, in: laptop)), "\(size)")
        }
    }

    func testThePanelGivesTheShadowWhatRoomTheScreenHas() {
        // On a tall screen the panel reaches 32 beside the band, 40 above it and 100 below, where the shadow falls.
        let tall = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let m = StripLayout.metrics(for: .medium, visibleWidth: tall.width)
        let band = StripLayout.bandFrame(m, in: tall)
        let panel = StripLayout.panelFrame(band: band, preview: nil, in: tall)
        XCTAssertEqual(band.minX - panel.minX, 32)
        XCTAssertEqual(panel.maxX - band.maxX, 32)
        XCTAssertEqual(panel.maxY - band.maxY, 40)
        XCTAssertEqual(band.minY - panel.minY, 100)

        // Where the screen is shorter the panel stops at its edges, and the band stays in the middle.
        let short = NSRect(x: 0, y: 40, width: 1440, height: 480)
        let shortBand = StripLayout.bandFrame(m, in: short)
        let shortPanel = StripLayout.panelFrame(band: shortBand, preview: nil, in: short)
        XCTAssertEqual(shortBand.midY, short.midY, accuracy: 0.5)
        XCTAssertEqual(shortPanel.minY, short.minY, accuracy: 0.5)
        XCTAssertEqual(shortPanel.maxY, shortBand.maxY + 40, accuracy: 0.5)
        XCTAssertEqual(shortBand.minY - shortPanel.minY, 70, accuracy: 0.5)

        // The preview card above the band takes the room above in the same way.
        let (preview, moved) = StripLayout.previewLayout(band: band, in: tall)
        let withCard = StripLayout.panelFrame(band: moved, preview: preview, in: tall)
        XCTAssertEqual(withCard.maxY, min(tall.maxY, preview.maxY + 40), accuracy: 0.5)
        XCTAssertEqual(withCard.minY, max(tall.minY, moved.minY - 100), accuracy: 0.5)
    }

    func testThePreviewGoesAboveTheBandAndMovesItOnlyWhenThereIsNoRoom() {
        // On a tall screen the card fits above the band, which stays where it is.
        let tall = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let tallMetrics = StripLayout.metrics(for: .medium, visibleWidth: tall.width)
        let band = StripLayout.bandFrame(tallMetrics, in: tall)
        let above = StripLayout.previewLayout(band: band, in: tall)
        XCTAssertEqual(above.band, band)
        XCTAssertEqual(above.preview.minY, band.maxY + StripLayout.previewGap, accuracy: 0.5)
        XCTAssertEqual(above.preview.size, StripLayout.previewMaximum)

        // On a lower screen it has no room there, so the card and the band are centred as one group and the band
        // moves down.
        let lower = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let m = StripLayout.metrics(for: .medium, visibleWidth: lower.width)
        let plain = StripLayout.bandFrame(m, in: lower)
        let centred = StripLayout.previewLayout(band: plain, in: lower)
        XCTAssertLessThan(centred.band.maxY, plain.maxY)
        XCTAssertEqual((centred.preview.maxY + centred.band.minY) / 2, lower.midY, accuracy: 0.5)
        XCTAssertEqual(centred.preview.size, StripLayout.previewMaximum)
    }

    func testALowScreenKeepsThePreviewCardAtLeast160High() {
        // 1024 × 520, as a small laptop at a larger text size leaves under the menu bar and above the Dock: the room
        // above the band would leave the card 116 high with medium cards, and less than nothing on a lower screen. The
        // card is never under 160, and it stays on the screen with the band.
        let low = NSRect(x: 0, y: 0, width: 1024, height: 520)
        for size in CardSize.allCases {
            let m = StripLayout.metrics(for: size, visibleWidth: low.width)
            let band = StripLayout.bandFrame(m, in: low)
            let (preview, moved) = StripLayout.previewLayout(band: band, in: low)
            XCTAssertGreaterThanOrEqual(preview.height, 160, "\(size)")
            XCTAssertEqual(preview.width, StripLayout.previewMaximum.width, "\(size)")
            XCTAssertTrue(low.contains(preview), "\(size): \(preview)")
            XCTAssertTrue(low.contains(moved), "\(size): \(moved)")
            XCTAssertEqual(moved.size, band.size, "\(size)")
            XCTAssertTrue(low.contains(StripLayout.panelFrame(band: moved, preview: preview, in: low)), "\(size)")
        }

        // With medium cards the card still fits above the band once the two take the screen's whole height.
        let m = StripLayout.metrics(for: .medium, visibleWidth: low.width)
        let (preview, moved) = StripLayout.previewLayout(band: StripLayout.bandFrame(m, in: low), in: low)
        XCTAssertEqual(preview.minY, moved.maxY + StripLayout.previewGap, accuracy: 0.5)

        // On a screen lower still there is no room for it above the band at all: it is drawn over the band's top edge
        // rather than be cut down further or leave the screen.
        let lower = NSRect(x: 0, y: 30, width: 1024, height: 440)
        for size in CardSize.allCases {
            let m = StripLayout.metrics(for: size, visibleWidth: lower.width)
            let (preview, moved) = StripLayout.previewLayout(band: StripLayout.bandFrame(m, in: lower), in: lower)
            XCTAssertEqual(preview.height, 160, "\(size)")
            XCTAssertTrue(lower.contains(preview), "\(size): \(preview)")
            XCTAssertEqual(moved.minY, lower.minY, accuracy: 0.5, "\(size)")
            XCTAssertLessThan(preview.minY, moved.maxY, "\(size): over the band")
            XCTAssertTrue(lower.contains(StripLayout.panelFrame(band: moved, preview: preview, in: lower)), "\(size)")
        }
    }

    /// The first origin exactly, or within `accuracy` where the arithmetic is not exact.
    private func assertPlacement(count: Int, position: CGFloat, loaded: Bool = false, origin: CGFloat,
                                 accuracy: CGFloat = 0, file: StaticString = #filePath, line: UInt = #line) {
        let placement = StripLayout.placement(metrics, count: count, position: position, oldestIsLoaded: loaded)
        XCTAssertEqual(placement.firstOrigin, origin, accuracy: accuracy, "origin", file: file, line: line)
    }
}
