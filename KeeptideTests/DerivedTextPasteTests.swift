import AppKit
import XCTest
@testable import Keeptide

/// A saved result pasted or copied in its item's place, through the same checks as the item itself, against a real
/// temporary store.
@MainActor
final class DerivedTextPasteTests: XCTestCase {
    private let rtf = Data("{\\rtf1\\ansi Good morning}".utf8)

    func testAWholeResultIsCopiedAsPlainTextMarkedAsKeeptidesOwnAndCountsNoUseOfItsItem() async throws {
        let (controller, store) = try makeStore()
        let board = makeBoard()
        let source = try await insert([[("public.rtf", rtf), ("public.utf8-plain-text", Data("Good morning".utf8))]],
                                      into: controller)
        let result = try await save("Bonjour", for: source, in: store)
        let written = TokenBox()
        let paste = service(controller, board, store: store, didWrite: { written.token = $0 },
                            recordUse: { _ in XCTFail("Taking a result does not raise its item among the frequent clips") })
        let session = paste.beginSession()

        let outcome = await paste.execute(request(source, session, .original, result: result))

        XCTAssertEqual(outcome, .copied)
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(contentTypes(item), ["public.utf8-plain-text"], "A result is plain text, whatever its item was")
        XCTAssertEqual(item.string(forType: .init("public.utf8-plain-text")), "Bonjour")
        // Keeptide's own write: capture skips it, so the result never enters the history.
        XCTAssertEqual(written.token?.matches(pasteboard: board), true)
    }

    func testAResultThatCannotBeReadIsRefused() async throws {
        let (controller, store) = try makeStore()
        let board = makeBoard()
        let source = try await insert([[("public.utf8-plain-text", Data("Read".utf8))]], into: controller)
        let result = try await save("Lire", for: source, in: store)
        let repository = ContentRepository(controller: controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) }, recordUse: { _ in },
                                 didWrite: { _ in }, readDerivedText: { _, _ in throw StoreError.corruptStore })
        let session = paste.beginSession()
        let before = board.changeCount

        let outcome = await paste.execute(request(source, session, .original, result: result))

        XCTAssertEqual(outcome, .refused(.contentUnavailable))
        XCTAssertEqual(board.changeCount, before)
    }

    func testCopyAsIsOfAResultInATerminalCopiesItWholeWithoutAReview() async throws {
        let (controller, store) = try makeStore()
        let board = makeBoard()
        let source = try await insert([[("public.utf8-plain-text", Data("Lines".utf8))]], into: controller)
        let result = try await save("echo one\necho two\n", for: source, in: store)
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let paste = service(controller, board, store: store, system: fake.system)
        let session = paste.beginSession()
        var asIs = request(source, session, .asIs, result: result)
        asIs.delivery = .paste

        let outcome = await paste.execute(asIs)

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(board.string(forType: .string), "echo one\necho two\n", "As-is keeps the trailing line break")
        XCTAssertEqual(fake.sent, [], "Copy As-Is never pastes")
    }

    func testAReviewOfAnItemsOwnTextNeverLetsItsResultThroughNorTheOtherWayRound() async throws {
        let (controller, store) = try makeStore()
        let board = makeBoard()
        let source = try await insert([[("public.utf8-plain-text", Data("echo a\necho b".utf8))]], into: controller)
        let result = try await save("echo c\necho d", for: source, in: store)
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let paste = service(controller, board, store: store, system: fake.system)
        let session = paste.beginSession()
        let ownText = PasteRequest(ref: source, queryGeneration: session.queryGeneration, mode: .original,
                                   session: session)
        guard case .needsConfirmation(let itemReview) = await paste.execute(ownText) else {
            return XCTFail("The item's own text is a multi-line command")
        }

        var resultWithItemsReview = request(source, session, .original, result: result)
        resultWithItemsReview.confirmation = itemReview.confirmation
        guard case .needsConfirmation(let resultReview) = await paste.execute(resultWithItemsReview) else {
            return XCTFail("The item's review does not confirm its result")
        }
        XCTAssertTrue(resultReview.isRenewal)
        XCTAssertEqual(resultReview.command.text, "echo c\necho d")

        var itemWithResultsReview = ownText
        itemWithResultsReview.confirmation = resultReview.confirmation
        guard case .needsConfirmation(let renewed) = await paste.execute(itemWithResultsReview) else {
            return XCTFail("The result's review does not confirm its item")
        }
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertEqual(board.string(forType: .string), nil, "Nothing was written")
    }

    func testAResultThatWasReplacedIsPartialOrWhoseItemWentIsNotPasted() async throws {
        let (controller, store) = try makeStore()
        let board = makeBoard()
        let paste = service(controller, board, store: store)
        let session = paste.beginSession()
        let before = board.changeCount

        // A newer translation replaced the one the column showed.
        let replacedSource = try await insert([[("public.utf8-plain-text", Data("One".utf8))]], into: controller)
        let earlier = try await save("Un", for: replacedSource, in: store)
        _ = try await save("Une", for: replacedSource, in: store)
        let replaced = await paste.execute(request(replacedSource, session, .original, result: earlier))
        XCTAssertEqual(replaced, .refused(.contentUnavailable))

        // A stopped result can be read and copied from its text, never pasted whole.
        let stoppedSource = try await insert([[("public.utf8-plain-text", Data("Two".utf8))]], into: controller)
        let stopped = try await save("Deu", for: stoppedSource, in: store, phase: .stopped(.person))
        XCTAssertEqual(stopped.status, .stopped)
        let partial = await paste.execute(request(stoppedSource, session, .original, result: stopped))
        XCTAssertEqual(partial, .refused(.contentUnavailable))

        // The item went to Recently Deleted.
        let goneSource = try await insert([[("public.utf8-plain-text", Data("Three".utf8))]], into: controller)
        let gone = try await save("Trois", for: goneSource, in: store)
        _ = try await LifecycleService(controller: controller).remove(
            ref: goneSource, at: Date(), expecting: try await controller.identity(),
            permit: try await StoreSafetyGate(controller: controller).permit(.maintenance))
        let deleted = await paste.execute(request(goneSource, session, .original, result: gone))
        XCTAssertEqual(deleted, .refused(.contentUnavailable))

        XCTAssertEqual(board.changeCount, before, "Nothing was written")
    }

    func testAResultForAnOlderQueryIsRefused() async throws {
        let (controller, store) = try makeStore()
        let board = makeBoard()
        let source = try await insert([[("public.utf8-plain-text", Data("Old".utf8))]], into: controller)
        let result = try await save("Vieux", for: source, in: store)
        let paste = service(controller, board, store: store)
        let session = paste.beginSession()
        let stale = request(source, session, .original, result: result)
        session.advanceQueryGeneration()

        let outcome = await paste.execute(stale)

        XCTAssertEqual(outcome, .refused(.stale))
    }

    func testAMultiLineResultForATerminalIsReviewedAndItsReviewHoldsOnlyForThatResult() async throws {
        let (controller, store) = try makeStore()
        let board = makeBoard()
        let source = try await insert([[("public.png", Data([0x89, 0x50, 0x4E, 0x47]))]], into: controller)
        let first = try await save("echo one\necho two\n", for: source, in: store, operation: .extractText)
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let paste = service(controller, board, store: store, system: fake.system)
        let session = paste.beginSession()

        // The item is an image, but its recognized text is what goes: a command, reviewed for its line break, and
        // without its trailing one.
        guard case .needsConfirmation(let review) = await paste.execute(
            request(source, session, .original, result: first, operation: .extractText)) else {
            return XCTFail("A multi-line command needs a review")
        }
        XCTAssertEqual(review.command.text, "echo one\necho two")
        XCTAssertEqual(review.confirmation.subject,
                       .derivedText(id: first.id, source: source, textDigest: first.textDigest))

        // The text is recognized again meanwhile: the review was of the earlier result, so it holds no more.
        let second = try await save("echo one\necho three", for: source, in: store, operation: .extractText)
        var again = request(source, session, .original, result: second, operation: .extractText)
        again.confirmation = review.confirmation
        guard case .needsConfirmation(let renewed) = await paste.execute(again) else {
            return XCTFail("A review holds only for the result it showed")
        }
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertEqual(board.string(forType: .string), nil, "Nothing is written before the review is confirmed")

        // Confirmed, the reviewed result is copied: the panel has no permission to paste here.
        again.confirmation = renewed.confirmation
        let confirmed = await paste.execute(again)
        XCTAssertEqual(confirmed, .copied)
        XCTAssertEqual(board.string(forType: .string), "echo one\necho three")
        XCTAssertEqual(fake.sent, [])
    }

    // MARK: Helpers

    private func request(_ source: ContentRef, _ session: PasteSession, _ mode: PasteMode, result: DerivedText,
                         operation: DerivedTextOperation = .translate) -> PasteRequest {
        PasteRequest(ref: source, queryGeneration: session.queryGeneration, mode: mode, session: session,
                     derivedText: DerivedTextPaste(id: result.id, operation: operation,
                                                   textDigest: result.textDigest))
    }

    private func save(_ text: String, for source: ContentRef, in store: DerivedTextStore,
                      phase: GenerationSnapshot.Phase = .finished(.completed),
                      operation: DerivedTextOperation = .translate) async throws -> DerivedText {
        let snapshot = GenerationSnapshot(phase: phase, info: GenerationInfo(engine: "On this Mac"),
                                          texts: [.main: text])
        let saved = try await store.save(snapshot, for: DerivedTextRequest(source: source, operation: operation,
                                                                           targetLanguage: "fr"))
        return try XCTUnwrap(saved)
    }

    private func service(_ controller: PersistenceController, _ board: NSPasteboard, store: DerivedTextStore,
                         system: DirectPasteSystem = .unavailable,
                         didWrite: @escaping @MainActor (OwnWriteToken) -> Void = { _ in },
                         recordUse: (@Sendable (UseReceipt) async throws -> Void)? = nil) -> PasteService {
        let repository = ContentRepository(controller: controller)
        let usage = LocalUsageStore(controller: controller)
        return PasteService(pasteboard: board, read: { try await repository.read($0) },
                            recordUse: recordUse ?? { try await usage.record($0) }, didWrite: didWrite, system: system,
                            readDerivedText: { try await store.result(for: $0, operation: $1) })
    }

    private func contentTypes(_ item: NSPasteboardItem) -> [String] {
        item.types.map(\.rawValue).filter { $0 != OwnWriteToken.typeIdentifier }
    }

    private func insert(_ items: [[(String, Data)]], into controller: PersistenceController) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture(items)
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    private func makeStore() throws -> (PersistenceController, DerivedTextStore) {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (controller, DerivedTextStore(controller: controller))
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
