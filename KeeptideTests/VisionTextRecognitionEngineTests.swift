import AppKit
import CoreText
import XCTest
@testable import Keeptide

/// Text recognition with Vision on this Mac, on images drawn in the test with Core Text. Recognition is not exact, so
/// these check words and layout, not every character.
@MainActor
final class VisionTextRecognitionEngineTests: XCTestCase {
    private let engine = VisionTextRecognitionEngine()

    func testParagraphsAreRecognizedLineByLineOrJoined() async throws {
        let image = Self.render([
            ["The quarterly report is due Friday. Finance needs the", "numbers by noon so the board pack can go out."],
            ["Please send your comments by Thursday and flag any", "figures that might change before then."],
        ])

        let recognized = try await engine.recognizedText(in: image)

        let kept = recognized.text(keepingLineBreaks: true)
        let keptParagraphs = kept.components(separatedBy: "\n\n")
        XCTAssertEqual(keptParagraphs.count, 2, kept)
        XCTAssertEqual(keptParagraphs.first?.components(separatedBy: "\n").count, 2, kept)
        XCTAssertTrue(kept.contains("quarterly report"), kept)
        let joined = recognized.text(keepingLineBreaks: false)
        let joinedParagraphs = joined.components(separatedBy: "\n\n")
        XCTAssertEqual(joinedParagraphs.count, 2, joined)
        XCTAssertTrue(joinedParagraphs.first?.contains("needs the numbers") == true, joined)
        XCTAssertFalse(joinedParagraphs.first?.contains("\n") == true, joined)
    }

    func testAWordHyphenatedAcrossTwoLinesIsWholeWhenTheLinesAreJoined() async throws {
        let image = Self.render([["The committee agreed that the inter-", "national schedule should move to May."]])

        let recognized = try await engine.recognizedText(in: image)

        XCTAssertTrue(recognized.text(keepingLineBreaks: true).contains("inter-\nnational"),
                      recognized.text(keepingLineBreaks: true))
        XCTAssertTrue(recognized.text(keepingLineBreaks: false).contains("international schedule"),
                      recognized.text(keepingLineBreaks: false))
    }

    func testChineseIsRecognizedAndItsLinesJoinWithoutASpace() async throws {
        let image = Self.render([["季度报告周五截止。财务需要在中午前拿到", "数据，以便按时发出董事会材料。"]],
                                font: "PingFang SC")

        let recognized = try await engine.recognizedText(in: image)

        let joined = recognized.text(keepingLineBreaks: false)
        XCTAssertTrue(joined.contains("报告周五截止"), joined)
        XCTAssertTrue(joined.contains("董事会"), joined)
        XCTAssertTrue(joined.contains("拿到数据"), joined)
    }

    func testAnImageWithoutTextHasNone() async throws {
        let recognized = try await engine.recognizedText(in: Self.render([]))

        XCTAssertEqual(recognized.text(keepingLineBreaks: true), "")
        XCTAssertEqual(recognized.text(keepingLineBreaks: false), "")
    }

    func testTheEngineRunsOnThisMacAndNamesItsRevision() async throws {
        XCTAssertEqual(engine.tier, .onThisMac)
        let source = engine.recognizeText(in: { Self.render([["Good morning"]]) }, keepingLineBreaks: true)

        var events: [GenerationEvent] = []
        for try await event in source.events() { events.append(event) }

        guard case .started(let info)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(info.engine, "On this Mac")
        XCTAssertEqual(info.model, "RecognizeDocumentsRequest.revision1")
        XCTAssertEqual(events.last, .finished(.completed))
        guard case .delta(let text, _)? = events.dropFirst().first else { return XCTFail("\(events)") }
        XCTAssertTrue(text.contains("Good morning"), text)
    }

    func testACancelledRecognitionThrowsCancellationRatherThanReportingNoText() async throws {
        // A page that takes Vision about a third of a second here.
        let image = Self.render([Self.lines(55, words: 12)], size: 40, width: 4000, height: 4000)
        let engine = engine
        let recognition = Task { try await engine.recognizedText(in: image) }

        try await Task.sleep(for: .milliseconds(20))
        recognition.cancel()

        do {
            let recognized = try await recognition.value
            XCTFail("A cancelled recognition returned \(recognized.paragraphs.count) paragraphs")
        } catch {
            // Never taken for an image without text, and said the way every cancelled task says it.
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testAListWithOrdinaryLeadingHasNoBlankLines() async throws {
        let items = ["• Milk and eggs", "• Rice", "• Honey from the market", "• Yogurt", "• Bread", "• Cheese",
                     "• Coffee beans", "• Apples"]
        let image = Self.render([items], leading: 1.5)

        let kept = try await engine.recognizedText(in: image).text(keepingLineBreaks: true)

        XCTAssertFalse(kept.contains("\n\n"), kept)
        XCTAssertEqual(kept.components(separatedBy: "\n").count, items.count, kept)
    }

    func testALongScreenshotIsReadWholeOnce() async throws {
        // 1,200 by 9,000 pixels in 16-pixel letters: read in one pass, Vision finds none of it.
        let paragraphs = (0..<100).map { paragraph in
            Self.lines(3, words: 6, from: paragraph * 3).enumerated().map { "\(paragraph).\($0) \($1)" }
        }
        let image = Self.render(paragraphs, size: 16, width: 1200, height: 9000)

        let lines = try await engine.recognizedText(in: image).text(keepingLineBreaks: true)
            .components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertGreaterThanOrEqual(lines.count, 285, "\(lines.count) of 300 lines")
        XCTAssertLessThanOrEqual(lines.count, 300, "\(lines.count) of 300 lines")
        XCTAssertEqual(Set(lines).count, lines.count, "No line is read twice")
        XCTAssertTrue(lines.contains { $0.hasPrefix("0.0") && $0.contains("review") }, lines.prefix(3).description)
        XCTAssertTrue(lines.contains { $0.hasPrefix("99.") }, lines.suffix(3).description)
    }

    // MARK: Helpers

    /// `count` lines of `words` words each, every line its own: Vision finds nothing on a page of identical lines.
    nonisolated private static func lines(_ count: Int, words: Int, from first: Int = 0) -> [String] {
        let vocabulary = ["review", "Thursday", "afternoon", "finance", "numbers", "agenda", "budget", "meeting",
                          "room", "slides", "region", "percent", "quarter", "report", "schedule", "project",
                          "customer", "invoice", "delivery", "update"]
        return (first..<first + count).map { line in
            (0..<words).map { vocabulary[(line * 7 + $0 * 3) % vocabulary.count] }.joined(separator: " ")
        }
    }

    /// Draws each paragraph's lines in dark grey on white, `leading` times the letters' size apart, with a little more
    /// than a line's space between paragraphs.
    nonisolated private static func render(_ paragraphs: [[String]], font: String = "Helvetica", size: CGFloat = 30,
                                           leading: CGFloat = 1.35, width: Int = 1400,
                                           height: Int = 700) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName(font as CFString, size, nil)
        var baseline = CGFloat(height) - size * 2
        for paragraph in paragraphs {
            for line in paragraph {
                let text = NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
                ])
                context.textPosition = CGPoint(x: 40, y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
                baseline -= size * leading
            }
            baseline -= size * 1.2
        }
        return context.makeImage()!
    }
}
