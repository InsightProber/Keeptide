import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class CaptureSessionTests: XCTestCase {
    func testInitializedTestSessionBuildsSearchIndex() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)
        let service = try XCTUnwrap(session.searchService)
        let indexFile = configuration.directory.appendingPathComponent("Search/\(SQLiteSearchIndex.fileName)")

        try await SearchTestSupport.waitUntil {
            guard FileManager.default.fileExists(atPath: indexFile.path) else { return false }
            return try await lastSearchPage(service, "").indexState == .ready
        }
        await session.shutdown()

        XCTAssertNil(session.searchService)
        let reopened = try SQLiteSearchIndex(directory: configuration.directory.appendingPathComponent("Search"))
        defer { reopened.close() }
        XCTAssertEqual(try reopened.metadata()?.state, .ready)
    }

    func testSearchIndexFailureDoesNotPreventRecording() async throws {
        let configuration = try makeIsolatedSession()
        try FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: configuration.directory.appendingPathComponent("Search"))
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)

        let page = try await lastSearchPage(try XCTUnwrap(session.searchService), "anything")

        XCTAssertTrue(session.isReady)
        XCTAssertEqual(page.indexState, .unavailable)
        XCTAssertEqual(page.results, [])
        await session.shutdown()
    }

    func testInitializedSessionProvidesPasteServicesUntilShutdown() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        let changes = CallCounter()
        session.onServicesChanged = { changes.count += 1 }
        await session.initialize(testSessionID: configuration.id)

        XCTAssertNotNil(session.pasteService)
        XCTAssertNotNil(session.previewService)
        XCTAssertNotNil(session.contentRepository)
        XCTAssertNotNil(session.usageStore)
        XCTAssertEqual(changes.count, 1)

        await session.shutdown()
        XCTAssertNil(session.pasteService)
        XCTAssertNil(session.previewService)
        XCTAssertNil(session.contentRepository)
        XCTAssertNil(session.usageStore)
        XCTAssertEqual(changes.count, 2)
    }

    func testSyntheticSeedListsClipsNewestFirst() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id, seedSyntheticClips: true)

        XCTAssertEqual(session.recent.map(\.title), [
            "Synthetic alpha note", "echo synthetic-beta", "set -e", "合成中文剪贴板条目，用于快捷面板测试",
            "https://example.com/synthetic", "Synthetic rich text", "Copied content",
        ])
        XCTAssertEqual(session.recent.map(\.kind), [.text, .text, .text, .text, .url, .text, .image])
        await session.shutdown()
    }

    func testLibraryCopyRecordsAUseReceipt() async throws {
        let configuration = try makeIsolatedSession()
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id, seedSyntheticClips: true)
        let ref = try XCTUnwrap(session.recent.first?.history)

        await session.select(ref)
        await session.copy(ref)

        XCTAssertEqual(session.actionMessage, "Copied")
        let board = NSPasteboard(name: .init(configuration.pasteboardName))
        XCTAssertEqual(board.string(forType: .string), "Synthetic alpha note")
        let usage = try XCTUnwrap(session.usageStore)
        // The receipt is stored after the copy reports success, without delaying it.
        try await SearchTestSupport.waitUntil { try await usage.summaries(for: [ref]).map(\.useCount) == [1] }
        await session.shutdown()
    }

    func testTestSessionsPasteOnlyIntoTheSystemTestHost() async throws {
        let configuration = try makeIsolatedSession()
        let system = FakeDirectPasteSystem()
        let session = CaptureSession(directPaste: system.system)
        await session.initialize(testSessionID: configuration.id)
        let paste = try XCTUnwrap(session.pasteService)

        // TextEdit would paste from the general clipboard, not from the session's.
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .copy(.testSessionTarget))
        system.front = .testHost
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .paste(.testHost))
        await session.shutdown()
    }

    func testLibraryCopiesNeverPasteEvenWithATerminalInFront() async throws {
        let configuration = try makeIsolatedSession()
        let system = FakeDirectPasteSystem()
        system.front = .terminal
        let session = CaptureSession(directPaste: system.system)
        await session.initialize(testSessionID: configuration.id, seedSyntheticClips: true)
        let ref = try XCTUnwrap(session.recent.first { $0.title == "set -e" }?.history)

        await session.select(ref)
        await session.copy(ref)

        // The clip is copied as captured: it is not made a command for the terminal, which would hold it for a
        // review and drop its trailing newline.
        XCTAssertEqual(session.actionMessage, "Copied")
        let board = NSPasteboard(name: .init(configuration.pasteboardName))
        XCTAssertEqual(board.string(forType: .string), "set -e\necho synthetic-gamma\n")
        XCTAssertEqual(system.sent, [])
        // The front window is never read for the library.
        XCTAssertEqual(system.probes, 0)
        await session.shutdown()
    }

    func testManualPasteQASeedsAreHarmlessAndCoverTheChecklist() throws {
        let clips = ManualPasteQASession.clips()
        XCTAssertEqual(clips.count, 6)
        let texts = try clips.map { clip in
            String(decoding: try XCTUnwrap(clip.first { $0.0 == "public.utf8-plain-text" }).1, as: UTF8.self)
        }

        // Harmless in a terminal: the commands, the clips of ASCII plain text alone, only echo, and no clip's text
        // has anything else a shell acts on.
        let commands = texts.indices.filter { clips[$0].count == 1 && texts[$0].allSatisfy(\.isASCII) }
            .map { texts[$0] }
        XCTAssertEqual(commands.count, 3)
        for line in commands.flatMap({ $0.split(whereSeparator: \.isNewline) }) {
            XCTAssertTrue(line.drop { $0 == "\t" }.hasPrefix("echo "), String(line))
        }
        for text in texts {
            XCTAssertFalse(text.contains { ";|&$`<>()\\".contains($0) }, text)
        }

        // The checklist. The newest clip, which the panel opens on, is a single line.
        XCTAssertEqual(texts.last, commands.last)
        XCTAssertFalse(try XCTUnwrap(commands.last).contains(where: \.isNewline))
        XCTAssertTrue(commands.contains { $0.hasSuffix("\n") && !$0.dropLast().contains(where: \.isNewline) })
        XCTAssertTrue(commands.contains { $0.dropLast().contains(where: \.isNewline) && $0.contains("\t") })
        XCTAssertTrue(texts.contains { text in
            text.count >= 200 && text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        })
        XCTAssertTrue(clips.contains { $0.map { $0.0 } == ["public.rtf", "public.utf8-plain-text"] })
        let link = try XCTUnwrap(clips.first { $0.first?.0 == "public.url" })
        XCTAssertEqual(link.map { $0.0 }, ["public.url", "public.utf8-plain-text"])
        XCTAssertEqual(link.first?.1, link.last?.1)
        XCTAssertEqual(URL(string: String(decoding: link[0].1, as: UTF8.self))?.host(), "example.com")
    }

    func testManualPasteQASeedsGoIntoALibraryNewestFirst() async throws {
        let fixture = try PasteFixture(self)

        try await SyntheticClipSeeder.seed(ManualPasteQASession.clips(), into: fixture.controller)

        let recent = try await ContentRepository(controller: fixture.controller).recent(limit: 10)
            .filter { $0.history != nil }
        // The panel opens on the newest clip: the single-line command.
        XCTAssertEqual(recent.first?.title, "echo keeptide-qa-single")
        XCTAssertEqual(recent.map(\.kind), [.text, .text, .text, .text, .text, .url])
    }

    func testManualPasteQASessionRemovesItsLibraryAndPreferences() throws {
        let qa = ManualPasteQASession(id: UUID())
        let other = ManualPasteQASession(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: qa.preferencesSuite))
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: other.preferencesSuite))
        addTeardownBlock {
            for session in [qa, other] where FileManager.default.fileExists(atPath: session.directory.path) {
                try FileManager.default.removeItem(at: session.directory)
            }
            defaults.removePersistentDomain(forName: qa.preferencesSuite)
            otherDefaults.removePersistentDomain(forName: other.preferencesSuite)
        }
        // Each session's library is a throwaway folder of its own, never the user's.
        XCTAssertTrue(qa.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertNotEqual(qa.directory, other.directory)
        XCTAssertNotEqual(qa.preferencesSuite, other.preferencesSuite)
        for (session, sessionDefaults) in [(qa, defaults), (other, otherDefaults)] {
            try FileManager.default.createDirectory(at: session.directory, withIntermediateDirectories: true)
            let marker = session.directory.appendingPathComponent("marker")
            XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data("qa".utf8)))
            sessionDefaults.set(true, forKey: "captureEnabled")
        }

        qa.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: qa.directory.path))
        XCTAssertTrue(defaults.persistentDomain(forName: qa.preferencesSuite)?.isEmpty ?? true)
        // Another session's library and preferences stay.
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.directory.appendingPathComponent("marker").path))
        XCTAssertTrue(otherDefaults.bool(forKey: "captureEnabled"))
    }

    private func makeIsolatedSession() throws -> CaptureTestConfiguration {
        let configuration = CaptureTestConfiguration(id: UUID())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: configuration.preferencesSuite))
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: configuration.directory.path) {
                try FileManager.default.removeItem(at: configuration.directory)
            }
            defaults.removePersistentDomain(forName: configuration.preferencesSuite)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }
        return configuration
    }

    private func lastSearchPage(_ service: SearchService, _ query: String) async throws -> SearchPage {
        var last: SearchPage?
        for try await page in service.search(SearchRequest(query: query, generation: 1)) { last = page }
        return try XCTUnwrap(last)
    }

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

@MainActor
private final class CallCounter {
    var count = 0
}
