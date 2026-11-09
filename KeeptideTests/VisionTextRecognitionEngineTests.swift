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

    func testACancelledRecognitionThrowsRatherThanReportingNoText() async throws {
        // A page that takes Vision about a third of a second here. Each line is its own: Vision finds nothing on a
        // page of identical lines.
        let words = ["review", "Thursday", "afternoon", "finance", "numbers", "agenda", "budget", "meeting", "room",
                     "slides", "region", "percent", "quarter", "report", "schedule", "project", "customer", "invoice",
                     "delivery", "update"]
        let lines = (0..<55).map { line in
            (0..<12).map { words[(line * 7 + $0 * 3) % words.count] }.joined(separator: " ")
        }
        let image = Self.render([lines], size: 40, width: 4000, height: 4000)
        let engine = engine
        let recognition = Task { try await engine.recognizedText(in: image) }

        try await Task.sleep(for: .milliseconds(20))
        recognition.cancel()

        do {
            let recognized = try await recognition.value
            XCTFail("A cancelled recognition returned \(recognized.paragraphs.count) paragraphs")
        } catch {
            // Vision stopped part way, so a stopped job is never taken for an image without text.
        }
    }

    // MARK: Helpers

    /// Draws each paragraph's lines in dark grey on white, with a blank line's space between paragraphs.
    nonisolated private static func render(_ paragraphs: [[String]], font: String = "Helvetica", size: CGFloat = 30,
                                           width: Int = 1400, height: Int = 700) -> CGImage {
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
                baseline -= size * 1.35
            }
            baseline -= size * 1.2
        }
        return context.makeImage()!
    }
}
