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

    func testOpenDocksTheNewestAtTheLeftEnd() {
        // More clips may follow the 50, so only the right end fades.
        assertPlacement(count: 50, position: 0, origin: 24, fades: (false, true))
    }

    func testTheSelectionWalksToTheMiddleBeforeTheFilmMoves() {
        // The film rests while the selection walks right along it: the selected frame is at 24 + 3 · 176 = 552.
        assertPlacement(count: 50, position: 3, origin: 24, fades: (false, true))
        // One step further it would pass the middle, so the film moves instead and the selected frame stays centred.
        assertPlacement(count: 50, position: 4, origin: -106, fades: (true, true))
        let moved = StripLayout.placement(metrics, count: 50, position: 4, oldestIsLoaded: false)
        XCTAssertEqual(moved.firstOrigin + 4 * metrics.step + metrics.frameSize.width / 2, metrics.bandWidth / 2)
    }

    func testFingersMoveTheFilmOnlyPastTheDock() {
        // A fractional position is a selection under the fingers, between two clips. Short of the middle, which
        // it reaches at about 3.26, the film rests; past it the film follows.
        assertPlacement(count: 50, position: 3.2, origin: 24, fades: (false, true))
        assertPlacement(count: 50, position: 3.3, origin: 17.2, accuracy: 0.001, fades: (true, true))
        assertPlacement(count: 50, position: 3.5, origin: -18, fades: (true, true))
    }

    func testUnderHalfAPointOfOverhangDoesNotFade() {
        // The left end fades once the film is more than half a point past its dock at 24.
        assertPlacement(count: 50, position: 3.263, origin: 23.712, accuracy: 0.001, fades: (false, true))
        assertPlacement(count: 50, position: 3.266, origin: 23.184, accuracy: 0.001, fades: (true, true))
        // So does the right end of a loaded film, past its dock at 1336.
        assertPlacement(count: 50, position: 45.737, loaded: true, origin: -7451.712, accuracy: 0.001,
                        fades: (true, false))
        assertPlacement(count: 50, position: 45.73, loaded: true, origin: -7450.48, accuracy: 0.001,
                        fades: (true, true))
    }

    func testTheOldestEndDocksOnlyWhenLoaded() {
        // Loaded, the film follows the selection until the last frame's right edge would pass 1360 − 24 = 1336,
        // at about index 45.7. From there it stops and the selection walks on to the last clip.
        assertPlacement(count: 50, position: 45, loaded: true, origin: -7322, fades: (true, true))
        assertPlacement(count: 50, position: 46, loaded: true, origin: -7452, fades: (true, false))
        assertPlacement(count: 50, position: 49, loaded: true, origin: -7452, fades: (true, false))
        let docked = StripLayout.placement(metrics, count: 50, position: 49, oldestIsLoaded: true)
        let last = StripLayout.frameOrigins(metrics, count: 50, placement: docked)[49]
        XCTAssertEqual(last + metrics.frameSize.width, 1336)
        // While more may follow, the film keeps moving to the last clip and the right end keeps fading.
        assertPlacement(count: 50, position: 49, origin: -8026, fades: (true, true))
    }

    func testAShortLoadedFilmIsCentredAsAGroup() {
        // Three clips are 516 wide, which leaves 422 on each side whichever of them is selected.
        assertPlacement(count: 3, position: 0, loaded: true, origin: 422, fades: (false, false))
        assertPlacement(count: 3, position: 2, loaded: true, origin: 422, fades: (false, false))
        // Seven (1220) still fit between the docks (1312). Eight (1396) do not, so the film docks at the left end.
        assertPlacement(count: 7, position: 0, loaded: true, origin: 70, fades: (false, false))
        assertPlacement(count: 8, position: 0, loaded: true, origin: 24, fades: (false, true))
        // A single clip sits in the middle.
        assertPlacement(count: 1, position: 0, loaded: true, origin: 598, fades: (false, false))
        // Clips that more may follow are not centred.
        assertPlacement(count: 3, position: 0, origin: 24, fades: (false, true))
    }

    func testAVanishedSelectionKeepsAnEmptySlotAtTheDock() {
        // The empty slot takes the dock and index 0 stands one step to its right: 24 + 176.
        assertPlacement(count: 50, position: -1, origin: 200, fades: (false, true))
        // A short loaded film is centred with the slot in it: four frames are 692 wide, so index 0 is at 334 + 176.
        assertPlacement(count: 3, position: -1, loaded: true, origin: 510, fades: (false, false))
        // Six clips and the slot (1220) still fit between the docks; seven and the slot (1396) do not, so the
        // slot docks at the left end and the right end fades.
        assertPlacement(count: 6, position: -1, loaded: true, origin: 246, fades: (false, false))
        assertPlacement(count: 7, position: -1, loaded: true, origin: 200, fades: (false, true))
        // Fingers between the slot and index 0 do not move the film.
        assertPlacement(count: 50, position: -0.5, origin: 200, fades: (false, true))
    }

    func testFrameOriginsStepRightFromTheFirst() {
        let placement = StripPlacement(firstOrigin: 24, fadesLeading: false, fadesTrailing: true)
        XCTAssertEqual(StripLayout.frameOrigins(metrics, count: 3, placement: placement), [24, 200, 376])
    }

    func testPanelAndPreviewStayInsideOddVisibleFrames() {
        for visible in [NSRect(x: 0, y: 25, width: 1280, height: 760), NSRect(x: 0, y: 0, width: 1100, height: 680),
                        NSRect(x: -1800, y: 30, width: 1600, height: 1000), NSRect(x: 0, y: 900, width: 400, height: 640),
                        NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: 0, y: 0, width: 2560, height: 1415)] {
            let m = StripLayout.metrics(for: .medium, visibleWidth: visible.width)
            let plain = StripLayout.bandFrame(m, filtersVisible: false, in: visible)
            XCTAssertEqual(plain.midX, visible.midX, accuracy: 0.5); XCTAssertEqual(plain.midY, visible.midY, accuracy: 0.5)
            // The filter row goes in below the search row, which stays where it was.
            let band = StripLayout.bandFrame(m, filtersVisible: true, in: visible)
            XCTAssertEqual(band.midX, visible.midX, accuracy: 0.5); XCTAssertEqual(band.maxY, plain.maxY, accuracy: 0.5)
            XCTAssertEqual(band.height, plain.height + StripLayout.filterHeight, accuracy: 0.5)
            for (shown, filtersVisible) in [(plain, false), (band, true)] {
                XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: shown, preview: nil)), "\(visible)")
                let (preview, moved) = StripLayout.previewLayout(band: shown, filtersVisible: filtersVisible,
                                                                 in: visible)
                XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: moved, preview: preview)), "\(visible)")
                // The card sits above the band.
                XCTAssertGreaterThanOrEqual(preview.minY, moved.maxY + StripLayout.previewGap - 0.5)
            }
        }
    }

    func testOnAShortScreenTheFilterRowMovesTheBandUpJustEnough() {
        let short = NSRect(x: 0, y: 0, width: 1440, height: 480)
        let m = StripLayout.metrics(for: .medium, visibleWidth: short.width)
        let plain = StripLayout.bandFrame(m, filtersVisible: false, in: short)
        let band = StripLayout.bandFrame(m, filtersVisible: true, in: short)
        XCTAssertEqual(band.minY, short.minY + StripLayout.shadowMargin, accuracy: 0.5)
        XCTAssertGreaterThan(band.maxY, plain.maxY)
        XCTAssertTrue(short.contains(StripLayout.panelFrame(band: band, preview: nil)))
    }

    func testThePreviewGoesAboveTheBandAndMovesItOnlyWhenThereIsNoRoom() {
        // On a tall screen the card fits above the band, which stays where it is.
        let tall = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let tallMetrics = StripLayout.metrics(for: .medium, visibleWidth: tall.width)
        let band = StripLayout.bandFrame(tallMetrics, filtersVisible: false, in: tall)
        let above = StripLayout.previewLayout(band: band, filtersVisible: false, in: tall)
        XCTAssertEqual(above.band, band)
        XCTAssertEqual(above.preview.minY, band.maxY + StripLayout.previewGap, accuracy: 0.5)
        XCTAssertEqual(above.preview.size, StripLayout.previewMaximum)

        // On a lower screen it has no room there, so the card and the band are centred as one group and the band
        // moves down.
        let lower = NSRect(x: 0, y: 0, width: 1440, height: 1100)
        let m = StripLayout.metrics(for: .medium, visibleWidth: lower.width)
        let plain = StripLayout.bandFrame(m, filtersVisible: false, in: lower)
        let centred = StripLayout.previewLayout(band: plain, filtersVisible: false, in: lower)
        XCTAssertLessThan(centred.band.maxY, plain.maxY)
        XCTAssertEqual((centred.preview.maxY + centred.band.minY) / 2, lower.midY, accuracy: 0.5)
        // The filter row, shown with the card open, still leaves the search row and the card where they are.
        let filtered = StripLayout.previewLayout(band: StripLayout.bandFrame(m, filtersVisible: true, in: lower),
                                                 filtersVisible: true, in: lower)
        XCTAssertEqual(filtered.band.maxY, centred.band.maxY, accuracy: 0.5)
        XCTAssertEqual(filtered.preview, centred.preview)
    }

    /// The fades exactly, and the first origin exactly or within `accuracy` where the arithmetic is not exact.
    private func assertPlacement(count: Int, position: CGFloat, loaded: Bool = false, origin: CGFloat,
                                 accuracy: CGFloat = 0, fades: (leading: Bool, trailing: Bool),
                                 file: StaticString = #filePath, line: UInt = #line) {
        let placement = StripLayout.placement(metrics, count: count, position: position, oldestIsLoaded: loaded)
        XCTAssertEqual(placement.firstOrigin, origin, accuracy: accuracy, "origin", file: file, line: line)
        XCTAssertEqual(placement.fadesLeading, fades.leading, "leading fade", file: file, line: line)
        XCTAssertEqual(placement.fadesTrailing, fades.trailing, "trailing fade", file: file, line: line)
    }
}
