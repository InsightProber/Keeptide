import CoreGraphics
import XCTest
@testable import Keeptide

/// Reading a tall image in strips, against a page whose reader returns what an engine would: the lines wholly inside
/// a strip, a line cut by a strip's edge as a piece of itself, and a paragraph's own transcript only when all of it is
/// inside.
final class StripReadingTests: XCTestCase {
    func testOnlyTallImagesAreReadInStrips() {
        XCTAssertNil(StripReading.stripFraction(width: 2_880, height: 1_800), "A screenshot of a Mac's screen")
        XCTAssertNil(StripReading.stripFraction(width: 1_440, height: 900))
        XCTAssertNil(StripReading.stripFraction(width: 1_200, height: 1_500))
        XCTAssertEqual(StripReading.stripFraction(width: 1_170, height: 2_532), 1_200 / 2_532, "A phone's screenshot")
        XCTAssertEqual(StripReading.stripFraction(width: 1_200, height: 9_000), 1_200 / 9_000)
        XCTAssertEqual(StripReading.stripFraction(width: 4_000, height: 3_000), 1_800 / 3_000)
    }

    func testATallPageComesBackWholeWithEachParagraphFromTheStripThatHoldsItAll() async throws {
        let page = Page(paragraphs: 100, linesEach: 3)
        var reads = 0

        let found = try await StripReading.read(stripFraction: 1_200 / 9_000) { bottom, top in
            reads += 1
            return page.read(bottom: bottom, top: top)
        }

        XCTAssertEqual(found, page.paragraphs, "Every paragraph once, in order, with its own transcript")
        XCTAssertGreaterThan(reads, 7)
    }

    func testAParagraphTallerThanAStripKeepsEveryLineOnce() async throws {
        let page = Page(paragraphs: 1, linesEach: 360)

        let found = try await StripReading.read(stripFraction: 1_200 / 9_000) { bottom, top in
            page.read(bottom: bottom, top: top)
        }

        XCTAssertEqual(found.flatMap(\.lines), page.paragraphs[0].lines, "No line lost, repeated or cut")
        XCTAssertGreaterThan(found.count, 1)
    }

    func testCancellingStopsBeforeTheNextStrip() async {
        let page = Page(paragraphs: 100, linesEach: 3)
        let reads = ReadCount()
        let reading = Task {
            try await StripReading.read(stripFraction: 1_200 / 9_000) { bottom, top in
                reads.add()
                withUnsafeCurrentTask { $0?.cancel() }
                return page.read(bottom: bottom, top: top)
            }
        }

        do {
            _ = try await reading.value
            XCTFail("A cancelled reading should throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(reads.count, 1)
    }
}

/// A page 9,000 pixels tall, set in 16-pixel letters with a line and a half between lines and a letter's height more
/// between paragraphs, in normalized coordinates with the origin at the lower left.
private struct Page {
    let paragraphs: [TextInImage.Paragraph]

    init(paragraphs count: Int, linesEach: Int) {
        let size: CGFloat = 16 / 9_000
        var baseline: CGFloat = 0.998
        paragraphs = (0..<count).map { paragraph in
            let lines = (0..<linesEach).map { line -> TextInImage.Line in
                defer { baseline -= size * 1.5 }
                return TextInImage.Line(text: "\(paragraph).\(line)",
                                        bounds: CGRect(x: 0.03, y: baseline - size * 0.22, width: 0.6,
                                                       height: size * 0.97))
            }
            baseline -= size
            return TextInImage.Paragraph(lines: lines, transcript: lines.map(\.text).joined(separator: " "))
        }
    }

    func read(bottom: CGFloat, top: CGFloat) -> [TextInImage.Paragraph] {
        let strip = CGRect(x: 0, y: bottom, width: 1, height: top - bottom)
        return paragraphs.compactMap { paragraph in
            var whole = true
            let lines = paragraph.lines.compactMap { line -> TextInImage.Line? in
                if strip.contains(line.bounds) { return line }
                whole = false
                let piece = line.bounds.intersection(strip)
                guard !piece.isNull, piece.height > 0 else { return nil }
                return TextInImage.Line(text: "piece of \(line.text)", bounds: piece)
            }
            guard !lines.isEmpty else { return nil }
            return TextInImage.Paragraph(
                lines: lines, transcript: whole ? paragraph.transcript : lines.map(\.text).joined(separator: " "))
        }
    }
}

private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func add() {
        lock.withLock { value += 1 }
    }
}
