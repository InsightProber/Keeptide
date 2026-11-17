import XCTest
@testable import Keeptide

/// What a row in the Library says of what was made of its item: the text in an image, and a translation.
@MainActor
final class LibraryResultMarksTests: XCTestCase {
    private let info = GenerationInfo(engine: "On this Mac", model: "test")

    func testRowsShowWhatWasKeptOnceTheStoreHasSaid() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let note = try await insertClip("Note", into: controller)
        let link = try await insertClip("Link", into: controller)
        let coordinator = try await makeCoordinator(controller, store)
        try await keep("Kept plan", .extractText, of: image, in: store)
        try await keep("Note gardée", .translate, of: note, in: store, into: "fr")
        let marks = LibraryResultMarks(derivedText: { coordinator })
        let rows = [entry(image, .image), entry(note, .text), entry(link, .url)]
        XCTAssertNil(marks.textMark(for: rows[0]), "Nothing until the store has said")

        marks.read(for: rows)

        await waitUntil("the store has said") {
            marks.textMark(for: rows[0]) == .hasText && marks.translationMark(for: rows[1]) == .translated(into: "fr")
        }
        XCTAssertNil(marks.textMark(for: rows[1]), "A text has no text in an image")
        XCTAssertNil(marks.translationMark(for: rows[2]), "A link isn't translated")
        XCTAssertNil(marks.translationMark(for: rows[0]), "Nothing was translated of the image")
    }

    func testAFailureIsShownOnceTheStoreHasSaidItKeptNothing() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let recognizer = ScriptedRecognizer()
        let coordinator = try await makeCoordinator(controller, store, recognizer)
        let marks = LibraryResultMarks(derivedText: { coordinator })
        let row = entry(image, .image)
        coordinator.extractText(from: image, keepingLineBreaks: true)
        await waitUntil("it waits or runs") { marks.textMark(for: row) != nil }
        try await started(recognizer, 0).end(throwing: GenerationError(kind: .engineUnavailable,
                                                                       message: "Synthetic failure."))
        await waitUntil("it failed") {
            if case .failed? = coordinator.outcome(for: image, operation: .extractText) { return true }
            return false
        }
        XCTAssertNil(marks.textMark(for: row), "Unasked, the store may have kept text from before")

        marks.read(for: [row])

        await waitUntil("the store has said") { marks.textMark(for: row) == .failed("Synthetic failure.") }
    }

    func testForgettingReadsWhatWasKeptAgain() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let coordinator = try await makeCoordinator(controller, store)
        try await keep("Kept plan", .extractText, of: image, in: store)
        let marks = LibraryResultMarks(derivedText: { coordinator })
        let row = entry(image, .image)
        marks.read(for: [row])
        await waitUntil("the store has said") { marks.textMark(for: row) == .hasText }

        marks.forget()

        XCTAssertNil(marks.textMark(for: row))
        marks.read(for: [row])
        await waitUntil("read again") { marks.textMark(for: row) == .hasText }
    }

    func testAnItemIsAskedAboutOnceUntilTheMarksAreForgotten() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let first = entry(try await insertClip("First screenshot", into: controller), .image)
        let next = entry(try await insertClip("Next screenshot", into: controller), .image)
        let coordinator = try await makeCoordinator(controller, store)
        try await keep("Kept plan", .extractText, of: first.ref, in: store)
        try await keep("Kept plan", .extractText, of: next.ref, in: store)
        let marks = LibraryResultMarks(derivedText: { coordinator })
        let row = entry(image, .image)
        // A read is seen to end by a row read with it that has text kept: they are asked about together.
        marks.read(for: [row, first])
        await waitUntil("the first read ended") { marks.textMark(for: first) == .hasText }
        // Kept after the store was asked, as by another surface: asked again as more rows load, it isn't read again.
        try await keep("Kept plan", .extractText, of: image, in: store)
        marks.read(for: [row, next])
        await waitUntil("the next read ended") { marks.textMark(for: next) == .hasText }
        XCTAssertNil(marks.textMark(for: row))

        marks.forget()
        marks.read(for: [row])

        await waitUntil("read again") { marks.textMark(for: row) == .hasText }
    }

    func testALongListIsReadWholeAPartAtATime() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let coordinator = try await makeCoordinator(controller, store)
        try await keep("Kept plan", .extractText, of: image, in: store)
        let marks = LibraryResultMarks(derivedText: { coordinator })
        // Rows the store has nothing for fill the first part; the image is in the next.
        let others = (0..<LibraryResultMarks.readSize).map { _ in
            entry(ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                             digest: Data(repeating: 1, count: 32)), .image)
        }
        let row = entry(image, .image)

        marks.read(for: others + [row])

        await waitUntil("the last part was read") { marks.textMark(for: row) == .hasText }
    }

    // MARK: Helpers

    private func entry(_ ref: ContentRef, _ kind: ContentKind) -> LibraryEntry {
        LibraryEntry(id: ref.itemID, ref: ref, title: "Synthetic", snippet: nil, lastCopiedAt: Date(), kind: kind,
                     isMemo: false)
    }

    private func keep(_ text: String, _ operation: DerivedTextOperation, of source: ContentRef,
                      in store: DerivedTextStore, into language: String? = nil) async throws {
        let request = operation == .translate
            ? DerivedTextRequest(source: source, operation: .translate, targetLanguage: language ?? "fr")
            : DerivedTextRequest(source: source, operation: .extractText, keepsLineBreaks: true)
        _ = try await store.save(GenerationSnapshot(phase: .finished(.completed), info: info, texts: [.main: text]),
                                 for: request)
    }

    private func makeStore() async throws -> (PersistenceController, DerivedTextStore) {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (controller, DerivedTextStore(controller: controller))
    }

    private func makeCoordinator(_ controller: PersistenceController, _ store: DerivedTextStore,
                                 _ recognizer: ScriptedRecognizer = ScriptedRecognizer()) async throws
        -> DerivedTextCoordinator {
        let identity = try await controller.identity()
        let coordinator = DerivedTextCoordinator(store: store, identity: identity, recognizer: recognizer,
                                                 translator: ScriptedTranslator(), preferredLanguages: { ["en-US"] },
                                                 image: { _ in throw PreviewLoadError.couldNotDecodeImage },
                                                 text: { _ in "Synthetic text" })
        addTeardownBlock { await coordinator.stopAndDrain() }
        return coordinator
    }

    /// A synthetic clip copied a moment ago. The store keeps results for any current item, so a text clip stands in
    /// for an image here.
    private func insertClip(_ text: String, into controller: PersistenceController) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let item = ItemValue(title: text, captureID: capture.id, historyEligible: true, lastCopiedAt: Date(),
                             copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    /// The recognizer's `index`th source, once its job has started reading it.
    private func started(_ recognizer: ScriptedRecognizer, _ index: Int) async throws -> ControlledSource {
        await waitUntil("source \(index) is read") { (recognizer.source(index)?.startCount ?? 0) > 0 }
        return try XCTUnwrap(recognizer.source(index))
    }
}
