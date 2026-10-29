import XCTest
@testable import Keeptide

final class StripLayoutTests: XCTestCase {
    /// Nine clips in a row on a 1440 pt screen: the band is 1360 pt wide, the frames 164 pt wide and 176 pt apart,
    /// and the dock inset is 24 pt.
    private var metrics: StripMetrics { StripLayout.metrics(for: .nine, visibleWidth: 1440) }

    func testReferenceSizesAtFullWidthAndOnVeryWideScreens() {
        let m = StripLayout.metrics(for: .nine, visibleWidth: 2560)
        XCTAssertEqual(m.bandWidth, 1360); XCTAssertEqual(m.scale, 1); XCTAssertEqual(m.cornerRadius, 12)
        XCTAssertEqual(m.frameSize, CGSize(width: 164, height: 109)); XCTAssertEqual(m.gap, 12)
        XCTAssertEqual(StripLayout.metrics(for: .seven, visibleWidth: 1600).frameSize, CGSize(width: 200, height: 133))
        XCTAssertEqual(StripLayout.metrics(for: .eleven, visibleWidth: 1600).frameSize, CGSize(width: 136, height: 91))
    }

    func testNarrowScreensScaleAndStepDownOneDensity() {
        let m = StripLayout.metrics(for: .eleven, visibleWidth: 1280)                        // band 1200, s ≈ 0.882
        XCTAssertEqual(m.density, .eleven); XCTAssertEqual(m.bandWidth, 1200)
        XCTAssertEqual(StripLayout.metrics(for: .eleven, visibleWidth: 1100).density, .nine)  // band 1020, s = 0.75
        let tiny = StripLayout.metrics(for: .seven, visibleWidth: 400)
        XCTAssertEqual(tiny.density, .seven); XCTAssertEqual(tiny.cornerRadius, 8)
    }

    func testInvalidStoredDensityFallsBackToNine() { XCTAssertEqual(StripDensity.from(8), .nine) }

    func testSelectedFrameIsCentredAndNewerFramesSitRight() {
        let m = StripLayout.metrics(for: .nine, visibleWidth: 1600)
        let xs = StripLayout.frameOrigins(m, count: 5, centredIndex: 2)
        XCTAssertEqual(xs[2] + m.frameSize.width / 2, m.bandWidth / 2, accuracy: 0.5)
        XCTAssertEqual(xs[1] - xs[2], m.step, accuracy: 0.5)                                   // index 1 is newer, so it sits right
        let lost = StripLayout.frameOrigins(m, count: 3, centredIndex: -1)
        XCTAssertEqual(lost[0] + m.frameSize.width / 2, m.bandWidth / 2 - m.step, accuracy: 0.5)
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
        assertPlacement(count: 50, position: 3.5, origin: -18, fades: (true, true))
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
        // Clips that more may follow are not centred.
        assertPlacement(count: 3, position: 0, origin: 24, fades: (false, true))
    }

    func testAVanishedSelectionKeepsAnEmptySlotAtTheDock() {
        // The empty slot takes the dock and index 0 stands one step to its right: 24 + 176.
        assertPlacement(count: 50, position: -1, origin: 200, fades: (false, true))
        // A short loaded film is centred with the slot in it: four frames are 692 wide, so index 0 is at 334 + 176.
        assertPlacement(count: 3, position: -1, loaded: true, origin: 510, fades: (false, false))
        // Fingers between the slot and index 0 do not move the film.
        assertPlacement(count: 50, position: -0.5, origin: 200, fades: (false, true))
    }

    func testDockInsetScalesWithTheBand() {
        XCTAssertEqual(metrics.dockInset, 24)
        let narrow = StripLayout.metrics(for: .nine, visibleWidth: 1168)
        XCTAssertEqual(narrow.scale, 0.8, accuracy: 0.001)
        XCTAssertEqual(narrow.dockInset, 19)
        // The film docks at the scaled inset.
        XCTAssertEqual(StripLayout.placement(narrow, count: 50, position: 0, oldestIsLoaded: false).firstOrigin, 19)
    }

    func testFrameOriginsStepRightFromTheFirst() {
        let placement = StripPlacement(firstOrigin: 24, fadesLeading: false, fadesTrailing: true)
        XCTAssertEqual(StripLayout.frameOrigins(metrics, count: 3, placement: placement), [24, 200, 376])
    }

    func testPanelAndPreviewStayInsideOddVisibleFrames() {
        for visible in [NSRect(x: 0, y: 25, width: 1280, height: 760), NSRect(x: 0, y: 0, width: 1100, height: 680),
                        NSRect(x: -1800, y: 30, width: 1600, height: 1000), NSRect(x: 0, y: 900, width: 400, height: 300),
                        NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: 0, y: 0, width: 2560, height: 1415)] {
            let m = StripLayout.metrics(for: .nine, visibleWidth: visible.width)
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
        let short = NSRect(x: 0, y: 0, width: 1440, height: 360)
        let m = StripLayout.metrics(for: .nine, visibleWidth: short.width)
        let plain = StripLayout.bandFrame(m, filtersVisible: false, in: short)
        let band = StripLayout.bandFrame(m, filtersVisible: true, in: short)
        XCTAssertEqual(band.minY, short.minY + StripLayout.shadowMargin, accuracy: 0.5)
        XCTAssertGreaterThan(band.maxY, plain.maxY)
        XCTAssertTrue(short.contains(StripLayout.panelFrame(band: band, preview: nil)))
    }

    func testThePreviewGoesAboveTheBandAndMovesItOnlyWhenThereIsNoRoom() {
        // On a tall screen the card fits above the band, which stays where it is.
        let tall = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let tallMetrics = StripLayout.metrics(for: .nine, visibleWidth: tall.width)
        let band = StripLayout.bandFrame(tallMetrics, filtersVisible: false, in: tall)
        let above = StripLayout.previewLayout(band: band, filtersVisible: false, in: tall)
        XCTAssertEqual(above.band, band)
        XCTAssertEqual(above.preview.minY, band.maxY + StripLayout.previewGap, accuracy: 0.5)
        XCTAssertEqual(above.preview.size, StripLayout.previewMaximum)

        // On a laptop it has no room there, so the card and the band are centred as one group and the band moves down.
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let m = StripLayout.metrics(for: .nine, visibleWidth: laptop.width)
        let plain = StripLayout.bandFrame(m, filtersVisible: false, in: laptop)
        let centred = StripLayout.previewLayout(band: plain, filtersVisible: false, in: laptop)
        XCTAssertLessThan(centred.band.maxY, plain.maxY)
        XCTAssertEqual((centred.preview.maxY + centred.band.minY) / 2, laptop.midY, accuracy: 0.5)
        // The filter row, shown with the card open, still leaves the search row and the card where they are.
        let filtered = StripLayout.previewLayout(band: StripLayout.bandFrame(m, filtersVisible: true, in: laptop),
                                                 filtersVisible: true, in: laptop)
        XCTAssertEqual(filtered.band.maxY, centred.band.maxY, accuracy: 0.5)
        XCTAssertEqual(filtered.preview, centred.preview)
    }

    private func assertPlacement(count: Int, position: CGFloat, loaded: Bool = false, origin: CGFloat,
                                 fades: (leading: Bool, trailing: Bool), file: StaticString = #filePath,
                                 line: UInt = #line) {
        let placement = StripLayout.placement(metrics, count: count, position: position, oldestIsLoaded: loaded)
        XCTAssertEqual(placement, StripPlacement(firstOrigin: origin, fadesLeading: fades.leading,
                                                 fadesTrailing: fades.trailing), file: file, line: line)
    }
}
