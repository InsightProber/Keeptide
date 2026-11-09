import CoreGraphics
import XCTest
@testable import Keeptide

/// The source an engine that recognizes text all at once hands a job: what it sends, how it fails and how it stops.
@MainActor
final class TextRecognitionSourceTests: XCTestCase {
    private let info = GenerationInfo(engine: "On this Mac", model: "test")
    private let recognized = TextInImage(paragraphs: [
        TextInImage.Paragraph(
            lines: [TextInImage.Line(text: "Good morning,", bounds: CGRect(x: 0, y: 0.9, width: 0.5, height: 0.05)),
                    TextInImage.Line(text: "everyone.", bounds: CGRect(x: 0, y: 0.84, width: 0.3, height: 0.05))],
            transcript: "Good morning, everyone."),
    ])

    func testTheWholeTextArrivesAtOnceWhenRecognitionEnds() async throws {
        let recognized = recognized
        let source = TextRecognitionSource(info: info, keepingLineBreaks: true) { recognized }

        let events = try await collect(source)

        XCTAssertEqual(events, [.started(info), .delta("Good morning,\neveryone."), .finished(.completed)])
    }

    func testJoiningLinesSendsTheParagraphs() async throws {
        let recognized = recognized
        let source = TextRecognitionSource(info: info, keepingLineBreaks: false) { recognized }

        let events = try await collect(source)

        XCTAssertEqual(events, [.started(info), .delta("Good morning, everyone."), .finished(.completed)])
    }

    func testAnImageWithoutTextFinishesWithoutText() async throws {
        let source = TextRecognitionSource(info: info, keepingLineBreaks: true) { TextInImage(paragraphs: []) }

        let events = try await collect(source)

        XCTAssertEqual(events, [.started(info), .finished(.completed)])
    }

    func testAFailureSaysWhatWentWrong() async {
        let cases: [(any Error, GenerationError.Kind, String)] = [
            (StoreError.notFound, .contentUnavailable, "This item changed or is no longer available."),
            (StoreError.staleReference, .contentUnavailable, "This item changed or is no longer available."),
            (PreviewLoadError.couldNotDecodeImage, .contentUnavailable, "This image couldn't be read."),
            (PreviewLoadError.invalidImageDimensions, .contentUnavailable, "This image couldn't be read."),
            (PreviewLoadError.originalImageTooLarge, .inputTooLarge, "This image is too large to recognize text in."),
            (CocoaError(.featureUnsupported), .engineUnavailable, "Text couldn't be recognized in this image."),
        ]
        for (error, kind, message) in cases {
            let source = TextRecognitionSource(info: info, keepingLineBreaks: true) { throw error }
            do {
                _ = try await collect(source)
                XCTFail("\(error) should fail the stream")
            } catch let failure as GenerationError {
                XCTAssertEqual(failure.kind, kind, "\(error)")
                XCTAssertEqual(failure.message, message, "\(error)")
            } catch {
                XCTFail("\(error) should fail with a GenerationError, not \(error)")
            }
        }
        let own = GenerationError(kind: .network, message: "Can't reach the provider.")
        let source = TextRecognitionSource(info: info, keepingLineBreaks: true) { throw own }
        do {
            _ = try await collect(source)
            XCTFail("The stream should fail")
        } catch {
            XCTAssertEqual(error as? GenerationError, own, "A source's own error passes through")
        }
    }

    func testStoppingTheJobStopsTheRecognition() async {
        let started = expectation(description: "recognition started")
        let cancelled = expectation(description: "recognition cancelled")
        let source = TextRecognitionSource(info: info, keepingLineBreaks: true) {
            try await withTaskCancellationHandler {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                return TextInImage(paragraphs: [])
            } onCancel: {
                cancelled.fulfill()
            }
        }
        var options = GenerationJob.Options()
        options.publishInterval = .zero
        var final: GenerationSnapshot?
        let center = JobCenter()
        let job = center.start(GenerationKey(item: "image", action: "extractText"), lane: .onDevice, priority: .user,
                               options: options, source: source) { final = $0 }

        await fulfillment(of: [started], timeout: 5)
        job.stop()

        await fulfillment(of: [cancelled], timeout: 5)
        await waitUntil("the job ended") { final != nil }
        XCTAssertEqual(final?.phase, .stopped(.person))
        XCTAssertFalse(final?.hasText ?? true)
    }

    private func collect(_ source: TextRecognitionSource) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in source.events() { events.append(event) }
        return events
    }
}
