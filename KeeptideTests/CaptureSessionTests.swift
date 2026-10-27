import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class CaptureSessionTests: XCTestCase {
    func testLateCopyCannotOverwriteNewSelectionAndNewerCopy() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let a = try content("first")
        let b = try content("second")
        let started = expectation(description: "First copy waiting on storage")
        let gate = DelayedCaptureRead(content: a, started: started)
        let session = CaptureSession(readContent: { ref in
            if ref == a.ref { return await gate.read() }
            return b
        }, pasteboard: board)
        let oldCopy = Task { await session.copy(a.ref) }
        await fulfillment(of: [started], timeout: 3)
        await session.select(b.ref)
        await session.copy(b.ref)
        XCTAssertEqual(board.string(forType: .string), "second")
        await gate.finish()
        await oldCopy.value
        XCTAssertEqual(board.string(forType: .string), "second")
        XCTAssertEqual(session.actionMessage, "Copied")
        await session.select(nil)
        XCTAssertNil(session.actionMessage)
    }

    private func content(_ text: String) throws -> ResolvedContent {
        let capture = try ContentStoreFixtures.capture([[ ("public.utf8-plain-text", Data(text.utf8)) ]])
        let item = ContentStoreFixtures.item(capture)
        return ResolvedContent(ref: ContentStoreFixtures.ref(item, capture), integrity: .complete,
                               representations: capture.representations)
    }
}

private actor DelayedCaptureRead {
    let content: ResolvedContent
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<ResolvedContent, Never>?

    init(content: ResolvedContent, started: XCTestExpectation) {
        self.content = content
        self.started = started
    }

    func read() async -> ResolvedContent {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish() { continuation?.resume(returning: content); continuation = nil }
}
