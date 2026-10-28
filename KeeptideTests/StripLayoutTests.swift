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
                        NSRect(x: -1800, y: 30, width: 1600, height: 1000), NSRect(x: 0, y: 900, width: 400, height: 300)] {
            let m = StripLayout.metrics(for: .nine, visibleWidth: visible.width)
            let band = StripLayout.bandFrame(m, filtersVisible: true, in: visible)
            XCTAssertEqual(band.midX, visible.midX, accuracy: 0.5); XCTAssertEqual(band.midY, visible.midY, accuracy: 0.5)
            XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: band, preview: nil)))
            let (preview, moved) = StripLayout.previewLayout(band: band, in: visible)
            XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: moved, preview: preview)))
            XCTAssertGreaterThanOrEqual(preview.minY, moved.maxY + StripLayout.previewGap - 0.5)  // the card sits above the band
        }
    }
}
