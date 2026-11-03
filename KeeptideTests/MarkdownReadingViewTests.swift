import XCTest
@testable import Keeptide

final class MarkdownReadingViewTests: XCTestCase {
    func testBeginningRequestDropsPreviouslyReadyDocument() {
        let first = MarkdownReadingRequest(documentID: UUID(), source: "# First")
        let second = MarkdownReadingRequest(documentID: UUID(), source: "# Second")
        var phase = MarkdownReadingPhase.ready(first, MarkdownRenderer.parse(first.source))

        phase.begin(second)

        XCTAssertEqual(phase, .loading(second))
        XCTAssertNil(phase.document(for: second))
    }

    func testCompletionAcceptsOnlyCurrentDocumentAndExactSource() {
        let documentID = UUID()
        let old = MarkdownReadingRequest(documentID: documentID, source: "old source")
        let current = MarkdownReadingRequest(documentID: documentID, source: "current source")
        let staleDocument = MarkdownRenderer.parse(old.source)
        let currentDocument = MarkdownRenderer.parse(current.source)
        var phase = MarkdownReadingPhase.loading(current)

        phase.complete(staleDocument, for: old, current: current)
        XCTAssertEqual(phase, .loading(current))

        phase.complete(currentDocument, for: current, current: current)
        XCTAssertEqual(phase.document(for: current), currentDocument)
        XCTAssertNil(phase.document(for: old))
    }
}
