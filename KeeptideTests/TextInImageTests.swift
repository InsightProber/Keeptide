import CoreGraphics
import XCTest
@testable import Keeptide

/// How recognized text is laid out: line by line as in the image, or with each paragraph's lines joined.
final class TextInImageTests: XCTestCase {
    func testKeepingLineBreaksPutsEachLineOnItsOwnLineAndABlankLineWhereTheImageHasSpace() {
        let recognized = TextInImage(paragraphs: [
            paragraph("The quarterly report is due Friday. Finance needs the numbers by noon.",
                      line("The quarterly report is due Friday. Finance needs the", top: 0.95),
                      line("numbers by noon.", top: 0.89)),
            paragraph("Please send your comments by Thursday.",
                      line("Please send your comments by Thursday.", top: 0.76)),
        ])

        XCTAssertEqual(recognized.text(keepingLineBreaks: true), """
            The quarterly report is due Friday. Finance needs the
            numbers by noon.

            Please send your comments by Thursday.
            """)
    }

    func testJoiningLinesGivesEachParagraphAsVisionJoinedItWithABlankLineBetweenParagraphs() {
        let recognized = TextInImage(paragraphs: [
            paragraph("The committee agreed that the international schedule should move to May.",
                      line("The committee agreed that the inter-", top: 0.95),
                      line("national schedule should move to May.", top: 0.89)),
            paragraph("季度报告周五截止。财务需要在中午前拿到数据。",
                      line("季度报告周五截止。财务需要在中午前拿到", top: 0.76),
                      line("数据。", top: 0.70)),
        ])

        XCTAssertEqual(recognized.text(keepingLineBreaks: false), """
            The committee agreed that the international schedule should move to May.

            季度报告周五截止。财务需要在中午前拿到数据。
            """)
    }

    func testParagraphsThatFollowWithoutSpaceAreOnlyALineBreakApart() {
        // Vision makes the first item of a list, or the second line of a short paragraph, a paragraph of its own.
        let recognized = TextInImage(paragraphs: [
            paragraph("Milk", line("Milk", top: 0.95)),
            paragraph("Eggs\nBread", line("Eggs", top: 0.89), line("Bread", top: 0.83)),
            paragraph("Morgan，并抄送财务部门。", line("Morgan，并抄送财务部门。", top: 0.77)),
        ])

        XCTAssertEqual(recognized.text(keepingLineBreaks: true), "Milk\nEggs\nBread\nMorgan，并抄送财务部门。")
        XCTAssertEqual(recognized.text(keepingLineBreaks: false), "Milk\nEggs\nBread\nMorgan，并抄送财务部门。")
    }

    func testTheCellsOfATableRowAreLinesOfOneBlockAndEachRowIsABlock() {
        let recognized = TextInImage(paragraphs: [
            paragraph("Region", line("Region", x: 0.03, top: 0.70, height: 0.03)),
            paragraph("Revenue", line("Revenue", x: 0.33, top: 0.70, height: 0.03)),
            paragraph("Owner", line("Owner", x: 0.63, top: 0.70, height: 0.03)),
            paragraph("North", line("North", x: 0.03, top: 0.64, height: 0.03)),
            paragraph("1,200", line("1,200", x: 0.33, top: 0.64, height: 0.03)),
        ])

        XCTAssertEqual(recognized.text(keepingLineBreaks: true), "Region\nRevenue\nOwner\n\nNorth\n1,200")
        XCTAssertEqual(recognized.text(keepingLineBreaks: false), "Region\nRevenue\nOwner\n\nNorth\n1,200")
    }

    func testTextInAnotherColumnStartsABlock() {
        let recognized = TextInImage(paragraphs: [
            paragraph("Left column first line left column second line",
                      line("Left column first line", x: 0.05, top: 0.90, width: 0.4),
                      line("left column second line", x: 0.05, top: 0.84, width: 0.4)),
            paragraph("Right column", line("Right column", x: 0.55, top: 0.90, width: 0.4)),
        ])

        XCTAssertEqual(recognized.text(keepingLineBreaks: true),
                       "Left column first line\nleft column second line\n\nRight column")
    }

    func testLinesOfOneParagraphStayTogetherEvenWhenSpacedApart() {
        // Double-spaced lines: Vision puts them in one paragraph, and that holds over the space between them.
        let recognized = TextInImage(paragraphs: [
            paragraph("First line second line", line("First line", top: 0.90), line("second line", top: 0.78)),
        ])

        XCTAssertEqual(recognized.text(keepingLineBreaks: true), "First line\nsecond line")
    }

    func testBlankLinesAndParagraphsLeaveNoTrace() {
        let recognized = TextInImage(paragraphs: [
            paragraph("  ", line("   ", top: 0.95)),
            paragraph(" Hello ", line(" Hello ", top: 0.89), line(" ", top: 0.83)),
            paragraph("", line("Only lines", top: 0.83)),
            TextInImage.Paragraph(lines: [], transcript: "No lines"),
        ])

        XCTAssertEqual(recognized.text(keepingLineBreaks: true), "Hello\nOnly lines")
        XCTAssertEqual(recognized.text(keepingLineBreaks: false), "Hello")
        XCTAssertEqual(TextInImage(paragraphs: []).text(keepingLineBreaks: true), "")
        XCTAssertEqual(TextInImage(paragraphs: []).text(keepingLineBreaks: false), "")
    }

    // MARK: Helpers

    private func paragraph(_ transcript: String, _ lines: TextInImage.Line...) -> TextInImage.Paragraph {
        TextInImage.Paragraph(lines: lines, transcript: transcript)
    }

    /// A line whose top edge is `top`, in Vision's coordinates: normalized to the image, with the origin at the lower
    /// left.
    private func line(_ text: String, x: CGFloat = 0.03, top: CGFloat, width: CGFloat = 0.6,
                      height: CGFloat = 0.05) -> TextInImage.Line {
        TextInImage.Line(text: text, bounds: CGRect(x: x, y: top - height, width: width, height: height))
    }
}
