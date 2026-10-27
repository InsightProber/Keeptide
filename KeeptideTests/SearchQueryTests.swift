import XCTest
@testable import Keeptide

final class SearchQueryTests: XCTestCase {
    func testNormalizationFoldsCaseWidthAndDiacriticsButKeepsCJK() {
        XCTAssertEqual(SearchNormalizer.normalize("ＡＢＣ Café NAÏVE"), "abc cafe naive")
        XCTAssertEqual(SearchNormalizer.normalize("：8080"), ":8080")
        XCTAssertEqual(SearchNormalizer.normalize("中文剪贴板"), "中文剪贴板")
        XCTAssertEqual(SearchNormalizer.normalize("a\u{0}b"), "ab")
        // Pins the current Foundation folding so a behavior change is noticed.
        XCTAssertEqual(SearchNormalizer.normalize("Straße"), "strasse")
    }

    func testParsingSplitsOnUnicodeWhitespaceIncludingIdeographicSpace() {
        XCTAssertEqual(ParsedQuery("git\u{3000}status\n log").terms, ["git", "status", "log"])
    }

    func testTermsAreDedupedAndClassifiedByScalarCount() {
        let query = ParsedQuery("贴板 剪贴板 😀 👨‍👩‍👧 贴板 剪贴板")

        XCTAssertEqual(query.terms, ["贴板", "剪贴板", "😀", "👨‍👩‍👧"])
        XCTAssertEqual(query.shortTerms, ["贴板", "😀"])
        XCTAssertEqual(query.longTerms, ["剪贴板", "👨‍👩‍👧"])
        XCTAssertEqual(query.phrase, "贴板 剪贴板 😀 👨‍👩‍👧")
    }

    func testFTSExpressionQuotesEveryLongTermLiterally() {
        XCTAssertEqual(ParsedQuery(#"say "hi" NEAR(x) OR -y"#).ftsExpression, #""say" """hi""" "near(x)""#)
        XCTAssertNil(ParsedQuery("贴板").ftsExpression)
    }

    func testOverlongQueryIsTruncatedAndFlagged() {
        let query = ParsedQuery(String(repeating: "a", count: 5_000))

        XCTAssertTrue(query.wasTruncated)
        XCTAssertEqual(query.terms.first?.unicodeScalars.count, 4_096)
        XCTAssertFalse(ParsedQuery("short").wasTruncated)
    }

    func testTermCountIsCappedAndFlagged() {
        let query = ParsedQuery((0..<2_000).map(String.init).joined(separator: " "))

        XCTAssertEqual(query.terms.count, 64)
        XCTAssertEqual(query.terms.first, "0")
        XCTAssertEqual(query.terms.last, "63")
        XCTAssertTrue(query.wasTruncated)
        XCTAssertFalse(ParsedQuery(Array(repeating: "same", count: 200).joined(separator: " ")).wasTruncated)
    }

    func testWhitespaceOnlyQueryIsEmpty() {
        let query = ParsedQuery(" \u{3000}\n\t")

        XCTAssertTrue(query.isEmpty)
        XCTAssertNil(query.ftsExpression)
        XCTAssertEqual(query.phrase, "")
    }
}
