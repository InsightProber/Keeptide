import XCTest
@testable import Keeptide

final class StripTypographyTests: XCTestCase {
    func testTiersPerCardSizeAndTheTwelvePointFloor() {
        XCTAssertEqual(StripTypography.bodySize(for: "#E2462A", cardSize: .large), 22)
        XCTAssertEqual(StripTypography.bodySize(for: String(repeating: "a", count: 41), cardSize: .medium), 13)
        for size in CardSize.allCases { let t = StripTypography.type(for: size)
            XCTAssertGreaterThanOrEqual((t.tiers + [t.linkDomain, t.linkPath, t.info]).min()!, 12) }
    }

    func testTierCountsGraphemesNotScalars() {
        XCTAssertEqual(StripTypography.bodySize(for: String(repeating: "👩‍👩‍👧", count: 12), cardSize: .large), 22)
    }

    func testInfoLineCopy() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ClipInfoFormatter.characters(1, locale: en), "1 character")
        XCTAssertEqual(ClipInfoFormatter.characters(1284, locale: en), "1,284 characters")
        XCTAssertEqual(ClipInfoFormatter.pixels(CGSize(width: 4032, height: 3024)), "4032 × 3024")
        XCTAssertEqual(ClipInfoFormatter.files(["Quick Access — Review.pdf"]), "PDF")
        XCTAssertEqual(ClipInfoFormatter.files(["a.pdf", "b.txt", "c"]), "3 files")
        XCTAssertEqual(ClipInfoFormatter.files(["README"]), "File")
        XCTAssertEqual(ClipInfoFormatter.items(2), "2 items")
    }
}
