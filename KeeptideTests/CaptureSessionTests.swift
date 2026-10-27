import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class CaptureSessionTests: XCTestCase {
    func testMissingLocalStateKeepsEnabledTestSessionInRecoveryAndNotRecording() async throws {
        let configuration = CaptureTestConfiguration(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        defaults.set(true, forKey: "captureEnabled")
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: configuration.directory.path) {
                try FileManager.default.removeItem(at: configuration.directory)
            }
            defaults.removePersistentDomain(forName: configuration.preferencesSuite)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }

        let store = try PersistenceController(directory: configuration.directory)
        let capture = try ContentStoreFixtures.capture([[
            ("public.utf8-plain-text", Data("content survives local loss".utf8)),
        ]])
        try await ContentStoreFixtures.insert(ContentStoreFixtures.item(capture), capture, into: store)
        try await store.close()
        try removeLocalStoreFiles(in: configuration.directory)

        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)

        XCTAssertFalse(session.isReady)
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(session.preferences.isEnabled)
        XCTAssertEqual(session.status, "The library requires recovery before recording can resume.")

        await session.shutdown()
        let cleanup = CaptureSession()
        await cleanup.initialize(testSessionID: configuration.id, cleanupTestSession: true)
        XCTAssertEqual(cleanup.status, "Test session removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.directory.path))
        XCTAssertTrue(defaults.persistentDomain(forName: configuration.preferencesSuite)?.isEmpty ?? true)
    }

    func testCleanupInitializationRemovesOnlyItsSyntheticSessionAndDisablesRecording() async throws {
        let target = CaptureTestConfiguration(id: UUID())
        let sibling = CaptureTestConfiguration(id: UUID())
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: target.preferencesSuite))
        let siblingDefaults = try XCTUnwrap(UserDefaults(suiteName: sibling.preferencesSuite))
        targetDefaults.set(true, forKey: "captureEnabled")
        targetDefaults.set(["com.example.target"], forKey: "captureExcludedApplications")
        siblingDefaults.set(true, forKey: "captureEnabled")
        try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling.directory, withIntermediateDirectories: true)
        let targetMarker = target.directory.appendingPathComponent("target-marker")
        let siblingMarker = sibling.directory.appendingPathComponent("sibling-marker")
        XCTAssertTrue(FileManager.default.createFile(atPath: targetMarker.path, contents: Data("target".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: siblingMarker.path, contents: Data("sibling".utf8)))
        let targetBoard = NSPasteboard(name: .init(target.pasteboardName))
        let siblingBoard = NSPasteboard(name: .init(sibling.pasteboardName))
        targetBoard.clearContents()
        siblingBoard.clearContents()
        XCTAssertTrue(targetBoard.setString("target", forType: .string))
        XCTAssertTrue(siblingBoard.setString("sibling", forType: .string))
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: target.directory.path) {
                try FileManager.default.removeItem(at: target.directory)
            }
            if FileManager.default.fileExists(atPath: sibling.directory.path) {
                try FileManager.default.removeItem(at: sibling.directory)
            }
            targetDefaults.removePersistentDomain(forName: target.preferencesSuite)
            siblingDefaults.removePersistentDomain(forName: sibling.preferencesSuite)
            targetBoard.releaseGlobally()
            siblingBoard.releaseGlobally()
        }

        let cleanup = CaptureSession()
        await cleanup.initialize(testSessionID: target.id, cleanupTestSession: true)

        XCTAssertEqual(cleanup.status, "Test session removed")
        XCTAssertFalse(cleanup.isReady)
        XCTAssertFalse(cleanup.isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.directory.path))
        XCTAssertTrue(targetDefaults.persistentDomain(forName: target.preferencesSuite)?.isEmpty ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingMarker.path))
        XCTAssertTrue(siblingDefaults.bool(forKey: "captureEnabled"))
        XCTAssertEqual(siblingBoard.string(forType: .string), "sibling")
    }

    func testSelectionFailurePublishesVisibleErrorAndStopsLoading() async throws {
        let failed = try content("unavailable")
        let session = CaptureSession(readContent: { _ in throw SelectionTestError.unavailable })

        await session.select(failed.ref)

        XCTAssertNil(session.selectedContent)
        XCTAssertNil(session.selectedPreview)
        XCTAssertEqual(session.selectionError, "This clip is no longer available.")
        XCTAssertFalse(session.selectionIsLoading)
    }

    func testNewSelectionCancelsPreviousReadAndKeepsOnlyNewestResult() async throws {
        let first = try content("first")
        let second = try content("second")
        let firstStarted = expectation(description: "First selection started")
        let firstCancelled = expectation(description: "First selection cancelled")
        let probe = SleepingSelectionRead(started: firstStarted, cancelled: firstCancelled)
        let session = CaptureSession(readContent: { ref in
            if ref == first.ref { return try await probe.read(first) }
            return second
        })

        let oldSelection = Task { await session.select(first.ref) }
        await fulfillment(of: [firstStarted], timeout: 3)
        await session.select(second.ref)
        await fulfillment(of: [firstCancelled], timeout: 3)
        await oldSelection.value

        XCTAssertEqual(session.selectedContent, second)
        XCTAssertEqual(session.selectedPreview?.text, "second")
        XCTAssertNil(session.selectionError)
        XCTAssertFalse(session.selectionIsLoading)
    }

    func testNonActionableSelectionKeepsIntegrityAndCannotOverwritePasteboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.setString("existing", forType: .string))
        let complete = try content("must not be copied")
        let unavailable = ResolvedContent(
            ref: complete.ref,
            integrity: .requiresRelocation,
            representations: complete.representations
        )
        let session = CaptureSession(readContent: { _ in unavailable }, pasteboard: board)

        await session.select(unavailable.ref)
        XCTAssertEqual(session.selectedContent?.integrity, .requiresRelocation)
        XCTAssertFalse(try XCTUnwrap(session.selectedContent).isActionable)
        XCTAssertNil(session.selectedPreview)

        await session.copy(unavailable.ref)
        XCTAssertEqual(board.string(forType: .string), "existing")
        XCTAssertEqual(
            session.actionMessage,
            "This clip could not be copied. Its original formats must all be available."
        )
    }

    func testLargeTextSelectionPublishesOnlyABoundedPreview() async throws {
        let large = try content(String(repeating: "a", count: 1_000_000))
        let session = CaptureSession(readContent: { _ in large })

        await session.select(large.ref)

        let preview = try XCTUnwrap(session.selectedPreview)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.text.utf8.count, 8_192)
        XCTAssertEqual(session.selectedContent, large)
        XCTAssertFalse(session.selectionIsLoading)
    }

    func testShutdownCancelsInflightSelectionAndNeverPublishesItsLateResult() async throws {
        let late = try content("late")
        let started = expectation(description: "Selection started")
        let cancelled = expectation(description: "Selection cancelled")
        let probe = DelayedSelectionRead(content: late, started: started, cancelled: cancelled)
        let session = CaptureSession(readContent: { _ in await probe.read() })
        let selection = Task { await session.select(late.ref) }
        await fulfillment(of: [started], timeout: 3)

        await session.shutdown()
        await fulfillment(of: [cancelled], timeout: 3)
        await probe.finish()
        await selection.value

        XCTAssertNil(session.selectedContent)
        XCTAssertNil(session.selectedPreview)
        XCTAssertNil(session.selectionError)
        XCTAssertFalse(session.selectionIsLoading)
    }

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

    private func removeLocalStoreFiles(in directory: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent("Local.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

private enum SelectionTestError: Error {
    case unavailable
}

private actor SleepingSelectionRead {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started
        self.cancelled = cancelled
    }

    func read(_ content: ResolvedContent) async throws -> ResolvedContent {
        started.fulfill()
        do {
            try await Task.sleep(for: .seconds(30))
            return content
        } catch {
            cancelled.fulfill()
            throw error
        }
    }
}

private actor DelayedSelectionRead {
    let content: ResolvedContent
    let started: XCTestExpectation
    let cancelled: XCTestExpectation
    private var continuation: CheckedContinuation<ResolvedContent, Never>?

    init(content: ResolvedContent, started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.content = content
        self.started = started
        self.cancelled = cancelled
    }

    func read() async -> ResolvedContent {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        } onCancel: {
            cancelled.fulfill()
        }
    }

    func finish() {
        continuation?.resume(returning: content)
        continuation = nil
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
