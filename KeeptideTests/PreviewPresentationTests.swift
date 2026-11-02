import CoreGraphics
import Foundation
import XCTest
@testable import Keeptide

final class PreviewPresentationTests: XCTestCase {
    func testActualImageSizeMapsDecodedPixelsToDisplayPixels() {
        XCTAssertEqual(
            ImagePreviewMetrics.actualPointSize(
                decodedPixelSize: CGSize(width: 2_000, height: 1_000),
                displayScale: 2
            ),
            CGSize(width: 1_000, height: 500)
        )
        XCTAssertEqual(
            ImagePreviewMetrics.actualPointSize(
                decodedPixelSize: CGSize(width: 200, height: 100),
                displayScale: 0
            ),
            CGSize(width: 200, height: 100)
        )
        XCTAssertEqual(
            ImagePreviewMetrics.actualPointSize(
                decodedPixelSize: CGSize(width: CGFloat.infinity, height: CGFloat.nan),
                displayScale: CGFloat.nan
            ),
            .zero
        )
    }

    func testDownsampledImageDescriptionDoesNotClaimOriginalResolution() {
        let decoded = CGSize(width: 2_000, height: 1_500)
        let source = CGSize(width: 4_000, height: 3_000)

        XCTAssertTrue(ImagePreviewMetrics.isDownsampled(
            decodedPixelSize: decoded, sourcePixelSize: source
        ))
        XCTAssertEqual(
            ImagePreviewMetrics.resolutionDescription(
                decodedPixelSize: decoded, sourcePixelSize: source
            ),
            "Scaled preview: 2000 × 1500 pixels; source reports 4000 × 3000 pixels"
        )
    }

    func testURLPreviewAllowsOnlyExplicitWebAddresses() throws {
        for source in ["https://example.com/a", "http://localhost:8080/path"] {
            let url = try XCTUnwrap(URL(string: source))
            XCTAssertEqual(URLPreviewPolicy.actionableURL(url), url)
        }

        for source in [
            "file:///private/tmp/a.pdf",
            "mailto:dev@example.com",
            "javascript:alert(1)",
            "notes/today",
            "https:path-only",
        ] {
            let url = try XCTUnwrap(URL(string: source))
            XCTAssertNil(URLPreviewPolicy.actionableURL(url), source)
        }
    }

    func testFilePreviewCleanupClosesQuickLookBeforeTheLease() {
        var events: [String] = []

        FilePreviewCleanup.run(
            clearPreviewItem: { events.append("clear-item") },
            closePreview: { events.append("close-quick-look") },
            removePreview: { events.append("remove-view") },
            closeLease: { events.append("close-scope") }
        )

        XCTAssertEqual(events, ["clear-item", "close-quick-look", "remove-view", "close-scope"])
    }
}
