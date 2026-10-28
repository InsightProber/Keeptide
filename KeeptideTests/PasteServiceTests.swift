import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class PasteServiceTests: XCTestCase {
    private let rtf = Data("{\\rtf1\\ansi Synthetic}".utf8)
    private let text = Data("Synthetic".utf8)

    func testOriginalCopyWritesEveryRepresentationInOrder() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.rtf", rtf), ("public.utf8-plain-text", text)]], into: controller)
        let paste = service(controller, board)
        let session = paste.beginSession()

        let outcome = await paste.execute(request(ref, session, .original))

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        // The pasteboard also reports types it derives from RTF; only the written ones are ours.
        let written = ["public.rtf", "public.utf8-plain-text"]
        XCTAssertEqual(contentTypes(item).filter(written.contains), written)
        XCTAssertEqual(item.data(forType: .init("public.rtf")), rtf)
        XCTAssertEqual(item.data(forType: .init("public.utf8-plain-text")), text)
    }

    func testPlainTextCopyWritesOnlyUTF8Text() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.rtf", rtf), ("public.utf8-plain-text", text)]], into: controller)
        let paste = service(controller, board)
        let session = paste.beginSession()

        let outcome = await paste.execute(request(ref, session, .plainText))

        XCTAssertEqual(outcome, .copied)
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(contentTypes(item), ["public.utf8-plain-text"])
        XCTAssertEqual(item.string(forType: .init("public.utf8-plain-text")), "Synthetic")
    }

    func testPlainTextRefusedWithoutText() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.png", Data([0x89, 0x50, 0x4E, 0x47]))]], into: controller)
        let paste = service(controller, board)
        let session = paste.beginSession()
        let before = board.changeCount

        let outcome = await paste.execute(request(ref, session, .plainText))

        XCTAssertEqual(outcome, .refused(.noPlainText))
        XCTAssertEqual(board.changeCount, before)
        let usage = try await LocalUsageStore(controller: controller).summaries(for: [ref])
        XCTAssertEqual(usage, [])
    }

    func testStaleGenerationIsRefusedWithoutWritingOrReceipt() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.utf8-plain-text", text)]], into: controller)
        let paste = service(controller, board)
        let session = paste.beginSession()
        let stale = request(ref, session, .original)
        session.advanceQueryGeneration()
        let before = board.changeCount

        let outcome = await paste.execute(stale)

        XCTAssertEqual(outcome, .refused(.stale))
        XCTAssertEqual(board.changeCount, before)
        let usage = try await LocalUsageStore(controller: controller).summaries(for: [ref])
        XCTAssertEqual(usage, [])
    }

    func testGenerationChangeDuringReadDoesNotWrite() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.utf8-plain-text", text)]], into: controller)
        let repository = ContentRepository(controller: controller)
        let gate = ReadGate()
        let started = expectation(description: "Read started")
        let paste = service(controller, board, read: { ref in
            started.fulfill()
            await gate.wait()
            return try await repository.read(ref)
        })
        let session = paste.beginSession()
        let before = board.changeCount

        let copy = Task { await paste.execute(self.request(ref, session, .original)) }
        await fulfillment(of: [started], timeout: 3)
        session.advanceQueryGeneration()
        await gate.open()

        let outcome = await copy.value
        XCTAssertEqual(outcome, .refused(.stale))
        XCTAssertEqual(board.changeCount, before)
    }

    func testEndedSessionIsRefused() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.utf8-plain-text", text)]], into: controller)
        let paste = service(controller, board)
        let session = paste.beginSession()
        let pending = request(ref, session, .original)
        session.end()
        let before = board.changeCount

        let outcome = await paste.execute(pending)

        XCTAssertEqual(outcome, .refused(.stale))
        XCTAssertEqual(board.changeCount, before)
    }

    func testRemovedOrChangedContentIsRefused() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.utf8-plain-text", text)]], into: controller)
        let changed = ContentRef(itemID: ref.itemID, facet: ref.facet, version: ref.version,
                                 digest: Data(repeating: 1, count: 32))
        let paste = service(controller, board)
        let session = paste.beginSession()
        let before = board.changeCount

        let outcome = await paste.execute(request(changed, session, .original))

        XCTAssertEqual(outcome, .refused(.contentUnavailable))
        XCTAssertEqual(board.changeCount, before)
    }

    func testEachSuccessfulCopyRecordsOneReceipt() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.utf8-plain-text", text)]], into: controller)
        let paste = service(controller, board)
        let session = paste.beginSession()

        _ = await paste.execute(request(ref, session, .original))
        _ = await paste.execute(request(ref, session, .plainText))
        let stale = request(ref, session, .original)
        session.advanceQueryGeneration()
        _ = await paste.execute(stale)

        let usage = try await LocalUsageStore(controller: controller).summaries(for: [ref])
        XCTAssertEqual(usage.map(\.useCount), [2])
    }

    func testReceiptFailureStillReportsCopied() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.utf8-plain-text", text)]], into: controller)
        let paste = service(controller, board, recordUse: { _ in throw StoreError.invalidTransaction })
        let session = paste.beginSession()

        let outcome = await paste.execute(request(ref, session, .original))

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(board.string(forType: .string), "Synthetic")
    }

    func testDidWriteTokenMatchesTheBoard() async throws {
        let controller = try makeStore()
        let board = makeBoard()
        let ref = try await insert([[("public.utf8-plain-text", text)]], into: controller)
        let written = TokenBox()
        let paste = service(controller, board, didWrite: { written.token = $0 })
        let session = paste.beginSession()

        _ = await paste.execute(request(ref, session, .original))

        XCTAssertEqual(try XCTUnwrap(written.token).matches(pasteboard: board), true)
    }

    private func request(_ ref: ContentRef, _ session: PasteSession, _ mode: PasteMode) -> PasteRequest {
        PasteRequest(ref: ref, queryGeneration: session.queryGeneration, mode: mode, session: session)
    }

    private func contentTypes(_ item: NSPasteboardItem) -> [String] {
        item.types.map(\.rawValue).filter { $0 != OwnWriteToken.typeIdentifier }
    }

    private func service(
        _ controller: PersistenceController, _ board: NSPasteboard,
        read: (@Sendable (ContentRef) async throws -> ResolvedContent)? = nil,
        recordUse: (@Sendable (UseReceipt) async throws -> Void)? = nil,
        didWrite: @escaping @MainActor (OwnWriteToken) -> Void = { _ in }
    ) -> PasteService {
        let repository = ContentRepository(controller: controller)
        let usage = LocalUsageStore(controller: controller)
        return PasteService(pasteboard: board, read: read ?? { try await repository.read($0) },
                            recordUse: recordUse ?? { try await usage.record($0) }, didWrite: didWrite)
    }

    private func insert(_ items: [[(String, Data)]], into controller: PersistenceController) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture(items)
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    private func makeStore() throws -> PersistenceController {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return controller
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        return board
    }
}

@MainActor
private final class TokenBox {
    var token: OwnWriteToken?
}

private actor ReadGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
