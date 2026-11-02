import XCTest
@testable import Keeptide

final class StripTypographyTests: XCTestCase {
    func testTextSizesFollowTheLengthSteps() {
        func style(_ length: Int) -> StripTextStyle {
            StripTypography.bodyStyle(for: String(repeating: "a", count: length), cardSize: .medium)
        }
        XCTAssertEqual(style(1), StripTextStyle(size: 20, lineHeight: 27))
        XCTAssertEqual(style(24), StripTextStyle(size: 20, lineHeight: 27))
        XCTAssertEqual(style(25), StripTextStyle(size: 18, lineHeight: 26))
        XCTAssertEqual(style(60), StripTextStyle(size: 18, lineHeight: 26))
        XCTAssertEqual(style(61), StripTextStyle(size: 15, lineHeight: 22))
        XCTAssertEqual(style(140), StripTextStyle(size: 15, lineHeight: 22))
        XCTAssertEqual(style(141), StripTextStyle(size: 14, lineHeight: 21))
        XCTAssertEqual(style(5_000), StripTextStyle(size: 14, lineHeight: 21))

        // Length is what a reader counts: a family emoji is one character, and so is each Chinese character.
        XCTAssertEqual(StripTypography.bodyStyle(for: String(repeating: "👩‍👩‍👧", count: 24), cardSize: .medium).size, 20)
        XCTAssertEqual(StripTypography.bodyStyle(for: "下周三前把设计定稿，周四上午和产品一起过一遍交互细节。", cardSize: .medium),
                       StripTextStyle(size: 18, lineHeight: 26))
        // A link's or a file's name.
        XCTAssertEqual(StripTypography.titleStyle(cardSize: .medium), StripTextStyle(size: 14, lineHeight: 19))
    }

    func testSmallAndLargeCardsScaleButNeverGoUnderTwelve() {
        // Small and large cards scale the medium sizes by their width: 200 and 260 against 228.
        XCTAssertEqual(StripTypography.scale(for: .small), 200 / 228, accuracy: 0.0001)
        XCTAssertEqual(StripTypography.scale(for: .medium), 1)
        XCTAssertEqual(StripTypography.scale(for: .large), 260 / 228, accuracy: 0.0001)
        let small = StripTypography.bodyStyle(for: "Short", cardSize: .small)
        XCTAssertEqual(small.size, 20 * 200 / 228, accuracy: 0.001)
        XCTAssertEqual(small.lineHeight, 27 * 200 / 228, accuracy: 0.001)
        let large = StripTypography.bodyStyle(for: String(repeating: "a", count: 200), cardSize: .large)
        XCTAssertEqual(large.size, 14 * 260 / 228, accuracy: 0.001)
        XCTAssertEqual(large.lineHeight, 21 * 260 / 228, accuracy: 0.001)

        // Nothing goes under 12 pt; a size that would is held at 12, with its lines as far apart as before for its size.
        let floored = StripTypography.scaled(StripTextStyle(size: 12.5, lineHeight: 17), for: .small)
        XCTAssertEqual(floored.size, 12)
        XCTAssertEqual(floored.lineHeight, 17 * 12 / 12.5, accuracy: 0.001)
        for cardSize in CardSize.allCases {
            for length in [1, 25, 61, 141, 10_000] {
                let style = StripTypography.bodyStyle(for: String(repeating: "a", count: length), cardSize: cardSize)
                XCTAssertGreaterThanOrEqual(style.size, 12, "\(cardSize) \(length)")
                XCTAssertGreaterThan(style.lineHeight, style.size, "\(cardSize) \(length)")
            }
            XCTAssertGreaterThanOrEqual(StripTypography.titleStyle(cardSize: cardSize).size, 12, "\(cardSize)")
        }
    }

    func testTheLinesATextShowsFillTheMiddleWithoutRunningPastIt() {
        // Every body style, from the shortest text's to the longest's, on every card size, with a memo title's line
        // above or without: the lines the card shows fit inside the middle's padding, and one more would not.
        for cardSize in CardSize.allCases {
            let metrics = StripLayout.metrics(for: cardSize, visibleWidth: 1440)
            let room = metrics.contentSize.height - 2 * StripTypography.padding(for: cardSize)
            for length in [1, 25, 61, 141, 5_000] {
                let style = StripTypography.bodyStyle(for: String(repeating: "a", count: length), cardSize: cardSize)
                for hasMemoTitle in [false, true] {
                    let lines = StripTypography.bodyLines(style, metrics: metrics, hasMemoTitle: hasMemoTitle)
                    let used = CGFloat(lines + (hasMemoTitle ? 1 : 0)) * style.lineHeight
                    let label = "\(cardSize), \(length) characters, memo title \(hasMemoTitle): \(lines) lines"
                    XCTAssertLessThanOrEqual(used, room + 0.05, label)
                    XCTAssertGreaterThan(used + style.lineHeight, room, label)
                }
            }
        }
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
        // VoiceOver says the size of a picture in words.
        XCTAssertEqual(ClipInfoFormatter.spoken("2880 × 1800"), "2880 by 1800")
        XCTAssertEqual(ClipInfoFormatter.spoken("22 characters"), "22 characters")
    }

    func testUsesAreCountedWithGroupedDigits() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ClipInfoFormatter.uses(2, locale: en), "Used 2 times")
        XCTAssertEqual(ClipInfoFormatter.uses(1_234, locale: en), "Used 1,234 times")
        XCTAssertEqual(ClipInfoFormatter.uses(12_345_678, locale: en), "Used 12,345,678 times")
        // Spoken, it follows the kind after a comma, so it starts in lower case.
        XCTAssertEqual(ClipInfoFormatter.uses(1_234, spoken: true, locale: en), "used 1,234 times")
        // Only the grouping of digits follows the user's region; the words are the interface's English.
        XCTAssertEqual(ClipInfoFormatter.uses(1_234, locale: Locale(identifier: "de_DE")), "Used 1.234 times")
        // The wing lists no clip used only once, but one use would still read in the singular.
        XCTAssertEqual(ClipInfoFormatter.uses(1, locale: en), "Used 1 time")
        XCTAssertEqual(ClipInfoFormatter.uses(1, spoken: true, locale: en), "used 1 time")
    }

    func testRelativeTimeOnTheCardAndSpoken() {
        let en = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func time(_ secondsAgo: TimeInterval, spoken: Bool = false) -> String {
            QuickAccessRowContent.time(of: now.addingTimeInterval(-secondsAgo), relativeTo: now, spoken: spoken, locale: en)
        }
        // Under a minute a clip is new; a clip from a clock set ahead is new as well.
        XCTAssertEqual(time(0), "Just now")
        XCTAssertEqual(time(59), "Just now")
        XCTAssertEqual(time(-30), "Just now")
        XCTAssertEqual(time(120), "2 min. ago")
        XCTAssertEqual(time(3 * 3_600), "3 hr. ago")
        XCTAssertEqual(time(26 * 3_600), "Yesterday")
        // Spoken, the units are whole words.
        XCTAssertEqual(time(120, spoken: true), "2 minutes ago")
        XCTAssertEqual(time(10, spoken: true), "Just now")
    }
}
