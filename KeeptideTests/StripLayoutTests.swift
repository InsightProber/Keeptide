import XCTest
@testable import Keeptide

final class StripLayoutTests: XCTestCase {
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
                let (preview, moved) = StripLayout.previewLayout(band: shown, filtersVisible: filtersVisible, in: visible)
                XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: moved, preview: preview)), "\(visible)")
                XCTAssertGreaterThanOrEqual(preview.minY, moved.maxY + StripLayout.previewGap - 0.5)  // the card sits above the band
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
}
