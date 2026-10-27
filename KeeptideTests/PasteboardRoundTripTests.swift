import AppKit
import Darwin
import XCTest
@testable import Keeptide

@MainActor
final class PasteboardRoundTripTests: XCTestCase {
    func testIsolatedReaderMaterializesDeferredDataWithoutSharingTheReaderObject() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = ThreadCheckingDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        let result = try await SnapshotReader(pasteboard: board).readAsynchronously(sourceApp: "synthetic", expectedChangeCount: board.changeCount)
        XCTAssertEqual(result.items.first?.representations.first?.bytes, Data("deferred".utf8))
        XCTAssertTrue(provider.wasMainThread, "The owner fulfills its promise on its own executor; the helper owns the reader")
    }
    func testIsolatedReaderRejectsReplacedCopyBeforeMaterializingItsProvider() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let admittedCount = board.changeCount
        let provider = DeferredDataProvider()
        let replacement = NSPasteboardItem()
        replacement.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        XCTAssertTrue(board.writeObjects([replacement]))
        do {
            _ = try await SnapshotReader(pasteboard: board).readAsynchronously(
                sourceApp: "synthetic.allowed", expectedChangeCount: admittedCount)
            XCTFail("Replaced content was read")
        } catch {
            guard case .changedDuringRead = error as? SnapshotReaderError else {
                return XCTFail("Expected change-count rejection, got \(error)")
            }
        }
        XCTAssertTrue(provider.requestedTypes.isEmpty)
    }

    func testIsolatedReaderSurvivesConcurrentMainActorPasteboardWrites() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let reader = SnapshotReader(pasteboard: board)
        for index in 0..<20 {
            board.clearContents()
            board.setString(String(repeating: "synthetic", count: 32_768), forType: .string)
            let count = board.changeCount
            let read = Task { try await reader.readAsynchronously(sourceApp: nil, expectedChangeCount: count) }
            await Task.yield()
            board.clearContents()
            board.setString("replacement \(index)", forType: .string)
            do {
                let result = try await read.value
                XCTAssertEqual(result.changeCount, count)
            } catch {
                guard let failure = error as? SnapshotReaderError else { return XCTFail("Unexpected \(error)") }
                switch failure {
                case .changedDuringRead, .readerUnavailable, .incompleteRepresentation, .emptyPasteboard: break
                default: XCTFail("Unexpected \(failure)")
                }
            }
        }
        let result = try await reader.readAsynchronously(sourceApp: nil, expectedChangeCount: board.changeCount)
        XCTAssertEqual(result.items.first?.representations.first?.bytes, Data("replacement 19".utf8))
    }

    func testCancelledReaderNeverLaunchesAChild() throws {
        let operation = PasteboardReadOperation()
        operation.cancel()
        XCTAssertThrowsError(try operation.read(executable: URL(fileURLWithPath: "/nonexistent"),
            pasteboardName: "synthetic", expectedChangeCount: 1)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellingRunningReaderKillsAndReapsChild() throws {
        let fixture = try makeReaderFixture(mode: "stall")
        defer { removeReaderFixture(fixture) }
        let operation = PasteboardReadOperation(timeout: 10, environment: fixture.environment)
        let attempt = launchRead(operation: operation, executable: fixture.executable)
        defer { stopAndAwait(operation, attempt: attempt) }
        let processID = try waitForFixtureProcessID(fixture)

        operation.cancel()

        wait(for: [attempt.completion], timeout: 3)
        assertFailure(attempt.result.value, is: CancellationError.self)
        assertProcessDoesNotExist(processID)
    }

    func testReaderTimeoutKillsAndReapsChild() throws {
        let fixture = try makeReaderFixture(mode: "stall")
        defer { removeReaderFixture(fixture) }
        let operation = PasteboardReadOperation(timeout: 1, environment: fixture.environment)
        let attempt = launchRead(operation: operation, executable: fixture.executable)
        defer { stopAndAwait(operation, attempt: attempt) }
        let processID = try waitForFixtureProcessID(fixture)

        wait(for: [attempt.completion], timeout: 3)
        assertFailure(attempt.result.value, equals: .readTimedOut)
        assertProcessDoesNotExist(processID)
    }

    func testReaderRejectsOversizedProcessOutputAndReapsChild() throws {
        let fixture = try makeReaderFixture(mode: "oversized")
        defer { removeReaderFixture(fixture) }
        let operation = PasteboardReadOperation(timeout: 10, environment: fixture.environment)
        let attempt = launchRead(operation: operation, executable: fixture.executable)
        defer { stopAndAwait(operation, attempt: attempt) }
        let processID = try waitForFixtureProcessID(fixture)

        wait(for: [attempt.completion], timeout: 10)
        assertFailure(attempt.result.value, equals: .readerUnavailable)
        assertProcessDoesNotExist(processID)
    }

    func testReaderWireRejectsTruncatedFramesAndWrongProcessIdentity() throws {
        let snapshot = CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("wire fixture".utf8))
        ])], changeCount: 42, sourceApp: nil)
        let reply = CaptureReaderReply(protocolVersion: 1, processID: 123, snapshot: snapshot, failure: nil)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(reply)
        var frame = Data("KPTREAD1".utf8)
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        XCTAssertEqual(try PasteboardReadOperation.decodeReply(frame, processID: 123, expectedChangeCount: 42), snapshot)
        for invalid in [Data(frame.dropLast()), Data(frame.prefix(15)), Data("BADMAGIC".utf8) + frame.dropFirst(8)] {
            XCTAssertThrowsError(try PasteboardReadOperation.decodeReply(invalid, processID: 123, expectedChangeCount: 42))
        }
        XCTAssertThrowsError(try PasteboardReadOperation.decodeReply(frame, processID: 124, expectedChangeCount: 42))
        XCTAssertThrowsError(try PasteboardReadOperation.decodeReply(frame, processID: 123, expectedChangeCount: 43))
    }

    nonisolated(unsafe) private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards.removeAll()
        super.tearDown()
    }

    func testSnapshotReaderPreservesItemTypeAndByteOrderWithObservedSource() throws {
        let pasteboard = makePasteboard()
        let first = NSPasteboardItem()
        first.setData(Data("plain".utf8), forType: .string)
        first.setData(Data("<b>plain</b>".utf8), forType: .html)
        let second = NSPasteboardItem()
        second.setData(Data([0, 1, 2, 3]), forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let reader = SnapshotReader(pasteboard: pasteboard)
        let source = "untrusted.observed.bundle.identifier"
        let snapshot = try reader.read(sourceApp: source)

        XCTAssertEqual(snapshot.changeCount, pasteboard.changeCount)
        XCTAssertEqual(snapshot.sourceApp, source)
        XCTAssertEqual(snapshot.items, [
            CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                       bytes: Data("plain".utf8)),
                CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.html.rawValue,
                                       bytes: Data("<b>plain</b>".utf8))
            ]),
            CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.png.rawValue,
                                       bytes: Data([0, 1, 2, 3]))
            ])
        ])
    }

    func testSnapshotReaderRejectsAnEmptyPasteboard() {
        let pasteboard = makePasteboard()

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(error as? SnapshotReaderError, .emptyPasteboard)
        }
    }

    func testSnapshotReaderScansPrivacyTypesBeforeRequestingAnyBody() {
        let pasteboard = makePasteboard()
        let provider = DeferredDataProvider()
        let ordinary = NSPasteboardItem()
        ordinary.setDataProvider(provider, forTypes: [.string])
        let privateItem = NSPasteboardItem()
        privateItem.setData(Data(), forType: NSPasteboard.PasteboardType(CapturePolicy.concealedType))
        XCTAssertTrue(pasteboard.writeObjects([ordinary, privateItem]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(error as? SnapshotReaderError, .privacyRestricted)
        }
        XCTAssertEqual(provider.requestedTypes, [])
    }

    func testSnapshotReaderRejectsPromisedRepresentationThatProvidesNoData() {
        let pasteboard = makePasteboard()
        let provider = DeferredDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(
                error as? SnapshotReaderError,
                .incompleteRepresentation(itemIndex: 0, typeIdentifier: NSPasteboard.PasteboardType.string.rawValue)
            )
        }
        XCTAssertEqual(provider.requestedTypes, [.string])
    }

    func testSnapshotReaderRejectsMoreThanFiftyMiBWithoutTruncation() {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setData(
            Data(repeating: 0xA5, count: SnapshotReader.maximumPayloadBytes + 1),
            forType: NSPasteboard.PasteboardType("public.data")
        )
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(error as? SnapshotReaderError, .payloadTooLarge(maximumBytes: 50 * 1_024 * 1_024))
        }
    }

    func testSnapshotReaderRejectsAChangeCountMutationDuringBodyRead() {
        let pasteboard = makePasteboard()
        let provider = MutatingDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            guard case .changedDuringRead = error as? SnapshotReaderError else {
                return XCTFail("Expected changedDuringRead, got \(error)")
            }
        }
    }

    func testSnapshotReaderOmitsOwnWriteMarkerFromCapturedIdentity() throws {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setData(Data("body".utf8), forType: .string)
        item.setData(Data("marker".utf8), forType: NSPasteboard.PasteboardType(OwnWriteToken.typeIdentifier))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let snapshot = try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].representations.map(\.typeIdentifier), [
            NSPasteboard.PasteboardType.string.rawValue
        ])
    }

    func testCapturedRepresentationUsesTheSharedFileReferenceClassifier() {
        XCTAssertTrue(CapturedRepresentation(
            typeIdentifier: "public.file-url",
            bytes: Data("file:///Synthetic/report.txt".utf8)
        ).isLocalFileReference)
        XCTAssertTrue(CapturedRepresentation(
            typeIdentifier: "public.url",
            bytes: Data("file:///Synthetic/report.txt".utf8)
        ).isLocalFileReference)
        XCTAssertFalse(CapturedRepresentation(
            typeIdentifier: "public.url",
            bytes: Data("https://example.invalid/report".utf8)
        ).isLocalFileReference)
    }

    func testWriterPreservesEveryItemRepresentationAndByteInCoordinateOrder() throws {
        let pasteboard = makePasteboard()
        let content = resolvedContent([
            representation(item: 1, representation: 0, type: .png, bytes: Data([7, 8, 9])),
            representation(item: 0, representation: 1, type: .html, bytes: Data("<p>A</p>".utf8)),
            representation(item: 0, representation: 0, type: .string, bytes: Data("A".utf8))
        ])

        let token = try PasteboardWriter(pasteboard: pasteboard).write(PasteboardWriter.prepare(content))
        let items = try XCTUnwrap(pasteboard.pasteboardItems)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].types, [
            .string,
            .html,
            NSPasteboard.PasteboardType(OwnWriteToken.typeIdentifier)
        ])
        XCTAssertEqual(items[0].data(forType: .string), Data("A".utf8))
        XCTAssertEqual(items[0].data(forType: .html), Data("<p>A</p>".utf8))
        XCTAssertEqual(items[1].types, [.png])
        XCTAssertEqual(items[1].data(forType: .png), Data([7, 8, 9]))
        XCTAssertTrue(token.matches(pasteboard: pasteboard))
    }

    func testWriterPreservesFileURLRepresentationsAsBytes() throws {
        let pasteboard = makePasteboard()
        let bytes = Data("file:///Synthetic/report.txt".utf8)
        let content = resolvedContent([
            representation(item: 0, representation: 0,
                           type: NSPasteboard.PasteboardType("public.file-url"), bytes: bytes),
            representation(item: 0, representation: 1,
                           type: NSPasteboard.PasteboardType("public.url"), bytes: bytes)
        ])

        _ = try PasteboardWriter(pasteboard: pasteboard).write(PasteboardWriter.prepare(content))
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)

        XCTAssertEqual(item.data(forType: NSPasteboard.PasteboardType("public.file-url")), bytes)
        XCTAssertEqual(item.data(forType: NSPasteboard.PasteboardType("public.url")), bytes)
    }

    func testWriterRoundTripsResolvedLocalReferenceBytesWithoutChangingThem() throws {
        let pasteboard = makePasteboard()
        let bytes = Data("file:///Synthetic/report.txt".utf8)
        let content = resolvedContent([
            representation(
                item: 0,
                representation: 0,
                type: NSPasteboard.PasteboardType("public.file-url"),
                storage: .localReference,
                bytes: bytes
            )
        ])

        _ = try PasteboardWriter(pasteboard: pasteboard).write(PasteboardWriter.prepare(content))

        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(
                forType: NSPasteboard.PasteboardType("public.file-url")
            ),
            bytes
        )
    }

    func testWriterRejectsNonActionableContentBeforeClearingExistingPasteboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("keep me", forType: .string)
        let content = ResolvedContent(
            ref: contentRef(),
            integrity: .recovering,
            representations: []
        )

        XCTAssertThrowsError(try PasteboardWriter(pasteboard: pasteboard).write(PasteboardWriter.prepare(content))) { error in
            XCTAssertEqual(error as? PasteboardWriterError, .nonActionableContent)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testWriterRejectsMissingBytesBeforeClearingExistingPasteboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("keep me", forType: .string)
        let content = resolvedContent([
            representation(item: 0, representation: 0, type: .string, bytes: nil)
        ])

        XCTAssertThrowsError(try PasteboardWriter(pasteboard: pasteboard).write(PasteboardWriter.prepare(content))) { error in
            XCTAssertEqual(
                error as? PasteboardWriterError,
                .missingRepresentationBytes(itemIndex: 0, representationIndex: 0)
            )
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testOwnWriteTokenDoesNotSwallowTheNextExternalCopy() throws {
        let pasteboard = makePasteboard()
        let content = resolvedContent([
            representation(item: 0, representation: 0, type: .string, bytes: Data("ours".utf8))
        ])
        let token = try PasteboardWriter(pasteboard: pasteboard).write(PasteboardWriter.prepare(content))
        XCTAssertTrue(token.matches(pasteboard: pasteboard))
        XCTAssertFalse(
            OwnWriteToken(changeCount: token.changeCount, marker: "a different marker")
                .matches(pasteboard: pasteboard)
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external", forType: .string))

        XCTAssertFalse(token.matches(pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "external")
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func contentRef() -> ContentRef {
        ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 1, count: 32))
    }

    private func resolvedContent(_ representations: [RepresentationValue]) -> ResolvedContent {
        ResolvedContent(ref: contentRef(), integrity: .complete, representations: representations)
    }

    private func representation(
        item: Int,
        representation: Int,
        type: NSPasteboard.PasteboardType,
        storage: RepresentationStorage = .portable,
        bytes: Data?
    ) -> RepresentationValue {
        RepresentationValue(
            snapshotID: UUID(),
            itemIndex: item,
            representationIndex: representation,
            typeIdentifier: type.rawValue,
            storage: storage,
            byteCount: Int64(bytes?.count ?? 0),
            digest: bytes.map(ContentDigest.sha256) ?? Data(repeating: 0, count: 32),
            bytes: bytes
        )
    }

    private func makeReaderFixture(mode: String) throws -> ReaderProcessFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideReaderProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let marker = directory.appendingPathComponent("pid")
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeeptidePasteboardReader")
        var environment = ProcessInfo.processInfo.environment
        environment["KEEPTIDE_READER_FIXTURE"] = mode
        environment["KEEPTIDE_READER_FIXTURE_PID"] = marker.path
        return ReaderProcessFixture(directory: directory, executable: executable, marker: marker, environment: environment)
    }

    private func removeReaderFixture(_ fixture: ReaderProcessFixture) {
        do {
            try FileManager.default.removeItem(at: fixture.directory)
        } catch {
            XCTFail("Failed to remove reader fixture: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    private func launchRead(
        operation: PasteboardReadOperation,
        executable: URL
    ) -> (completion: XCTestExpectation, result: ReaderProcessResult) {
        let completion = expectation(description: "Reader process exits")
        let result = ReaderProcessResult()
        DispatchQueue.global(qos: .utility).async {
            do {
                result.store(.success(try operation.read(
                    executable: executable,
                    pasteboardName: "synthetic.fixture",
                    expectedChangeCount: 1
                )))
            } catch {
                result.store(.failure(error))
            }
            completion.fulfill()
        }
        return (completion, result)
    }

    private func waitForFixtureProcessID(
        _ fixture: ReaderProcessFixture,
        timeout: TimeInterval = 2
    ) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let data = try? Data(contentsOf: fixture.marker),
               let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let processID = Int32(value) {
                return processID
            }
            usleep(10_000)
        } while Date() < deadline
        XCTFail("Signed reader fixture did not start in the test sandbox")
        throw ReaderProcessFixtureError.didNotLaunch
    }

    private func stopAndAwait(
        _ operation: PasteboardReadOperation,
        attempt: (completion: XCTestExpectation, result: ReaderProcessResult)
    ) {
        operation.cancel()
        XCTAssertTrue(
            attempt.result.waitUntilStored(timeout: 2),
            "Reader operation did not return after cancellation"
        )
    }

    private func assertFailure<T, E: Error>(
        _ result: Result<T, Error>?,
        is expectedType: E.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("Expected \(expectedType), got \(String(describing: result))", file: file, line: line)
        }
        XCTAssertTrue(error is E, "Expected \(expectedType), got \(error)", file: file, line: line)
    }

    private func assertFailure<T>(
        _ result: Result<T, Error>?,
        equals expected: SnapshotReaderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("Expected \(expected), got \(String(describing: result))", file: file, line: line)
        }
        XCTAssertEqual(error as? SnapshotReaderError, expected, file: file, line: line)
    }

    private func assertProcessDoesNotExist(
        _ processID: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        errno = 0
        XCTAssertEqual(kill(processID, 0), -1, "Reader process \(processID) still exists", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, "Reader process \(processID) was not reaped", file: file, line: line)
    }
}

private struct ReaderProcessFixture {
    let directory: URL
    let executable: URL
    let marker: URL
    let environment: [String: String]
}

private enum ReaderProcessFixtureError: Error {
    case didNotLaunch
}

private final class ReaderProcessResult: @unchecked Sendable {
    private let lock = NSLock()
    private let storedSignal = DispatchSemaphore(value: 0)
    private var stored: Result<CaptureSnapshotValue, Error>?

    var value: Result<CaptureSnapshotValue, Error>? {
        lock.withLock { stored }
    }

    func store(_ result: Result<CaptureSnapshotValue, Error>) {
        lock.withLock { stored = result }
        storedSignal.signal()
    }

    func waitUntilStored(timeout: TimeInterval) -> Bool {
        if value != nil { return true }
        return storedSignal.wait(timeout: .now() + timeout) == .success
    }
}

private final class ThreadCheckingDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var mainThread = false
    var wasMainThread: Bool { lock.withLock { mainThread } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        lock.withLock { mainThread = Thread.isMainThread }
        item.setData(Data("deferred".utf8), forType: type)
    }
}

private final class DeferredDataProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var requestedTypes: [NSPasteboard.PasteboardType] = []

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestedTypes.append(type)
    }
}

private final class MutatingDataProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setData(Data("stale".utf8), forType: type)
        pasteboard?.clearContents()
        pasteboard?.setString("new value", forType: .string)
    }
}
