import XCTest
@testable import Keeptide

final class StripTypographyTests: XCTestCase {
    func testEachCardSizeSetsItsTextAtOneSizeWhateverItsLength() {
        // A body is 13/18 on a small card, 14/19 on a medium one and 15/20 on a large one. Short text is not set
        // larger: the style depends on the card size alone. A link's title and a file's name are a point under it.
        let cases: [(CardSize, StripTextStyle, StripTextStyle)] = [
            (.small, StripTextStyle(size: 13, lineHeight: 18), StripTextStyle(size: 12, lineHeight: 16)),
            (.medium, StripTextStyle(size: 14, lineHeight: 19), StripTextStyle(size: 13, lineHeight: 17)),
            (.large, StripTextStyle(size: 15, lineHeight: 20), StripTextStyle(size: 14, lineHeight: 18)),
        ]
        for (cardSize, body, title) in cases {
            XCTAssertEqual(StripTypography.bodyStyle(cardSize: cardSize), body, "\(cardSize)")
            XCTAssertEqual(StripTypography.titleStyle(cardSize: cardSize), title, "\(cardSize)")
            // Nothing is set under 12 pt.
            XCTAssertGreaterThanOrEqual(title.size, 12, "\(cardSize)")
        }
    }

    func testCardMeasuresScaleWithTheCardsWidth() {
        // Small and large cards scale a medium card's measures by their width: 176 and 220 against 196.
        XCTAssertEqual(StripTypography.scale(for: .small), 176 / 196, accuracy: 0.0001)
        XCTAssertEqual(StripTypography.scale(for: .medium), 1)
        XCTAssertEqual(StripTypography.scale(for: .large), 220 / 196, accuracy: 0.0001)
        // The room beside the text, and above and below it, in whole points: 13, 2 and 10 on a medium card.
        XCTAssertEqual(CardSize.allCases.map { StripTypography.padding(for: $0) }, [12, 13, 15])
        XCTAssertEqual(CardSize.allCases.map { StripTypography.verticalPadding(for: $0).top }, [2, 2, 2])
        XCTAssertEqual(CardSize.allCases.map { StripTypography.verticalPadding(for: $0).bottom }, [9, 10, 11])
    }

    func testTheLinesATextShowsFillTheMiddleWithoutRunningPastIt() {
        // On every card size, with a memo title's line above or without: the lines the card shows fit between the room
        // above and below the text, and one more would not. A medium card shows seven lines, six under a memo title.
        for cardSize in CardSize.allCases {
            let metrics = StripLayout.metrics(for: cardSize, visibleWidth: 1440)
            let padding = StripTypography.verticalPadding(for: cardSize)
            let room = metrics.contentSize.height - padding.top - padding.bottom
            let style = StripTypography.bodyStyle(cardSize: cardSize)
            for hasMemoTitle in [false, true] {
                let lines = StripTypography.bodyLines(style, metrics: metrics, hasMemoTitle: hasMemoTitle)
                let used = CGFloat(lines + (hasMemoTitle ? 1 : 0)) * style.lineHeight
                let label = "\(cardSize), memo title \(hasMemoTitle): \(lines) lines"
                XCTAssertLessThanOrEqual(used, room + 0.05, label)
                XCTAssertGreaterThan(used + style.lineHeight, room, label)
            }
        }
        let medium = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let body = StripTypography.bodyStyle(cardSize: .medium)
        XCTAssertEqual(StripTypography.bodyLines(body, metrics: medium, hasMemoTitle: false), 7)
        XCTAssertEqual(StripTypography.bodyLines(body, metrics: medium, hasMemoTitle: true), 6)
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
