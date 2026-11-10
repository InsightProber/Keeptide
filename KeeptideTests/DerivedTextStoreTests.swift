import CoreData
import XCTest
@testable import Keeptide

/// Text recognized in or translated from an item, saved beside it on this Mac, against real temporary stores.
final class DerivedTextStoreTests: XCTestCase {
    func testAWholeResultIsSavedBesideItsSourceAndReadAfterReopening() async throws {
        let directory = SearchTestSupport.directory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var controller = try PersistenceController(directory: directory)
        let source = try await insertClip("Good morning", into: controller)
        let request = DerivedTextRequest(source: source, operation: .translate, sourceLanguage: "en",
                                         targetLanguage: "fr")
        let requestID = UUID()

        let saved = try await DerivedTextStore(controller: controller).save(
            snapshot("Bonjour", requestID: requestID, usage: GenerationUsage(inputTokens: 12, outputTokens: 4)),
            for: request)

        let result = try XCTUnwrap(saved)
        XCTAssertEqual(result.source, source)
        XCTAssertEqual(result.operation, .translate)
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.text, "Bonjour")
        XCTAssertEqual(result.textDigest, ContentDigest.sha256(Data("Bonjour".utf8)))
        XCTAssertEqual(result.engine, "On this Mac")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertEqual(result.targetLanguage, "fr")
        XCTAssertEqual(result.usage, GenerationUsage(inputTokens: 12, outputTokens: 4))
        XCTAssertEqual(result.requestID, requestID)
        try await controller.close()

        controller = try PersistenceController(directory: directory)
        let reopened = DerivedTextStore(controller: controller)
        let read = try await reopened.result(for: source, operation: .translate)
        XCTAssertEqual(read, result)
        let other = try await reopened.result(for: source, operation: .extractText)
        XCTAssertNil(other, "Each operation has a result of its own")
        try await controller.close()
    }

    func testAWholeResultReplacesAnyEarlierOneAndAPartialOneOnlyWhenThereIsNoWholeOne() async throws {
        let (controller, store) = try await makeStore()
        let first = try await insertClip("First", into: controller)
        let request = DerivedTextRequest(source: first, operation: .translate, targetLanguage: "ja")

        _ = try await store.save(snapshot("A"), for: request)
        // A result a person stopped, or one cut off at the length limit, never replaces a whole one.
        let stopped = try await store.save(snapshot("B", phase: .stopped(.person)), for: request)
        XCTAssertNil(stopped)
        let truncated = try await store.save(snapshot("C", phase: .finished(.truncated)), for: request)
        XCTAssertNil(truncated)
        var current = try await store.result(for: first, operation: .translate)
        XCTAssertEqual(current?.text, "A")
        // A newer whole result replaces it, and the item keeps one.
        _ = try await store.save(snapshot("D"), for: request)
        current = try await store.result(for: first, operation: .translate)
        XCTAssertEqual(current?.text, "D")
        XCTAssertEqual(current?.status, .complete)
        let rows = try await rowCount(for: first.itemID, in: controller)
        XCTAssertEqual(rows, 1)

        // Without a whole result, a partial one is kept, marked as such, until another result replaces it.
        let second = try await insertClip("Second", into: controller)
        let partial = DerivedTextRequest(source: second, operation: .translate, targetLanguage: "ja")
        let kept = try await store.save(snapshot("E", phase: .stopped(.person)), for: partial)
        XCTAssertEqual(kept?.status, .stopped)
        let cut = try await store.save(snapshot("F", phase: .finished(.truncated)), for: partial)
        XCTAssertEqual(cut?.status, .truncated)
        XCTAssertEqual(cut?.text, "F")
        _ = try await store.save(snapshot("G"), for: partial)
        current = try await store.result(for: second, operation: .translate)
        XCTAssertEqual(current?.text, "G")
        let secondRows = try await rowCount(for: second.itemID, in: controller)
        XCTAssertEqual(secondRows, 1)

        // What failed, what the model refused and what a newer request replaced is not kept.
        let third = try await insertClip("Third", into: controller)
        let discarded = DerivedTextRequest(source: third, operation: .translate, targetLanguage: "ja")
        for phase: GenerationSnapshot.Phase in [.failed(.interrupted), .finished(.refused), .stopped(.superseded),
                                                .stopped(.shutdown)] {
            let saved = try await store.save(snapshot("H", phase: phase), for: discarded)
            XCTAssertNil(saved, "\(phase)")
        }
        let emptyText = try await store.save(snapshot(""), for: discarded)
        XCTAssertNil(emptyText)
        let thirdRows = try await rowCount(for: third.itemID, in: controller)
        XCTAssertEqual(thirdRows, 0)
    }

    func testTheRecognizedTextAndTheTranslationOfOneItemAreKeptApart() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Hello", into: controller)

        _ = try await store.save(snapshot("Hello", engine: "On this Mac"),
                                 for: DerivedTextRequest(source: source, operation: .extractText, keepsLineBreaks: true))
        _ = try await store.save(snapshot("你好"),
                                 for: DerivedTextRequest(source: source, operation: .translate,
                                                         targetLanguage: "zh-Hans"))

        let text = try await store.result(for: source, operation: .extractText)
        let translation = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(text?.text, "Hello")
        XCTAssertEqual(text?.keepsLineBreaks, true)
        XCTAssertEqual(translation?.text, "你好")
        XCTAssertEqual(translation?.targetLanguage, "zh-Hans")
        let rows = try await rowCount(for: source.itemID, in: controller)
        XCTAssertEqual(rows, 2)
    }

    func testAResultHidesWhileItsSourceIsInRecentlyDeletedAndComesBackWithIt() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Hide me", into: controller)
        _ = try await store.save(snapshot("Versteck mich"),
                                 for: DerivedTextRequest(source: source, operation: .translate, targetLanguage: "de"))
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)

        let moved = try await LifecycleService(controller: controller).remove(
            ref: source, at: Date(), expecting: identity, permit: permit)
        let hidden = try await store.result(for: source, operation: .translate)
        XCTAssertNil(hidden)

        _ = try await LifecycleService(controller: controller).restore(
            moved.target, policy: .permanent, at: Date(), expecting: identity, permit: permit)
        let back = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(back?.text, "Versteck mich")
    }

    func testPermanentlyDeletingTheSourceRemovesItsResultsAndNoOtherItemsResults() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Delete me", into: controller)
        let other = try await insertClip("Keep me", into: controller)
        _ = try await store.save(snapshot("Delete me"),
                                 for: DerivedTextRequest(source: source, operation: .extractText))
        _ = try await store.save(snapshot("Löschen"),
                                 for: DerivedTextRequest(source: source, operation: .translate, targetLanguage: "de"))
        _ = try await store.save(snapshot("Behalten"),
                                 for: DerivedTextRequest(source: other, operation: .translate, targetLanguage: "de"))
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        let moved = try await LifecycleService(controller: controller).remove(
            ref: source, at: Date(), expecting: identity, permit: permit)

        _ = try await LifecycleCleanupService(controller: controller).purgeFacet(
            moved.target, trigger: .explicitUserRequest, at: Date(), expecting: identity, permit: permit)

        let removedRows = try await rowCount(for: source.itemID, in: controller)
        XCTAssertEqual(removedRows, 0)
        let kept = try await store.result(for: other, operation: .translate)
        XCTAssertEqual(kept?.text, "Behalten")
    }

    func testAnEditedSnippetNoLongerShowsTheResultOfItsEarlierText() async throws {
        let (controller, store) = try await makeStore()
        let library = LibraryService(controller: controller)
        let before = try await library.create(MemoDraft(title: "Greeting", body: "Hello"))
        _ = try await store.save(snapshot("Hallo"),
                                 for: DerivedTextRequest(source: before, operation: .translate, targetLanguage: "de"))
        let editing = try await library.editingSnapshot(before)

        let after = try await library.commit(
            MemoEdit(title: "Greeting", body: "Hello again", expectedMemoFingerprint: editing.memoFingerprint),
            base: before).ref

        XCTAssertNotEqual(after.version, before.version)
        let stale = try await store.result(for: before, operation: .translate)
        XCTAssertNil(stale, "The translation was of the earlier text")
        let current = try await store.result(for: after, operation: .translate)
        XCTAssertNil(current)
    }

    func testAResultForASourceThatChangedOrWentMeanwhileIsNotSaved() async throws {
        let (controller, store) = try await makeStore()
        let library = LibraryService(controller: controller)
        let before = try await library.create(MemoDraft(title: "Note", body: "One"))
        let editing = try await library.editingSnapshot(before)
        _ = try await library.commit(
            MemoEdit(title: "Note", body: "Two", expectedMemoFingerprint: editing.memoFingerprint), base: before)

        let late = try await store.save(snapshot("Eins"),
                                        for: DerivedTextRequest(source: before, operation: .translate,
                                                                targetLanguage: "de"))
        XCTAssertNil(late, "A late result for an earlier version is dropped")

        let gone = try await insertClip("Gone", into: controller)
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        _ = try await LifecycleService(controller: controller).remove(
            ref: gone, at: Date(), expecting: identity, permit: permit)
        let afterDeletion = try await store.save(snapshot("Weg"),
                                                 for: DerivedTextRequest(source: gone, operation: .translate,
                                                                         targetLanguage: "de"))
        XCTAssertNil(afterDeletion)
        let rowsBefore = try await rowCount(for: before.itemID, in: controller)
        let rowsGone = try await rowCount(for: gone.itemID, in: controller)
        XCTAssertEqual(rowsBefore + rowsGone, 0)
    }

    func testResultsWrittenUnderAnotherStoreGenerationAreNotRead() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Generation", into: controller)
        _ = try await store.save(snapshot("Génération"),
                                 for: DerivedTextRequest(source: source, operation: .translate, targetLanguage: "fr"))

        try await controller.perform { context in
            let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DerivedText"))
            rows.forEach { $0.setValue(UUID(), forKey: "storeGeneration") }
            try context.save()
            context.reset()
        }

        let read = try await store.result(for: source, operation: .translate)
        XCTAssertNil(read)
    }

    func testClearingSavedResultsRemovesEveryResultAndLeavesTheItems() async throws {
        let (controller, store) = try await makeStore()
        let first = try await insertClip("One", into: controller)
        let second = try await insertClip("Two", into: controller)
        _ = try await store.save(snapshot("Un"),
                                 for: DerivedTextRequest(source: first, operation: .translate, targetLanguage: "fr"))
        _ = try await store.save(snapshot("Two"), for: DerivedTextRequest(source: second, operation: .extractText))

        let removed = try await store.removeAll()

        XCTAssertEqual(removed, 2)
        let firstResult = try await store.result(for: first, operation: .translate)
        let secondResult = try await store.result(for: second, operation: .extractText)
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)
        let content = try await ContentRepository(controller: controller).read(first)
        XCTAssertEqual(content.integrity, .complete)
    }

    func testAPartialResultIsKeptWhenTheOnlyWholeOneIsOfEarlierContent() async throws {
        let (controller, store) = try await makeStore()
        let library = LibraryService(controller: controller)
        let before = try await library.create(MemoDraft(title: "Note", body: "One"))
        _ = try await store.save(snapshot("Un"),
                                 for: DerivedTextRequest(source: before, operation: .translate, targetLanguage: "fr"))
        let editing = try await library.editingSnapshot(before)
        let after = try await library.commit(
            MemoEdit(title: "Note", body: "One and two", expectedMemoFingerprint: editing.memoFingerprint),
            base: before).ref

        let kept = try await store.save(snapshot("Un et", phase: .stopped(.person)),
                                        for: DerivedTextRequest(source: after, operation: .translate,
                                                                targetLanguage: "fr"))

        XCTAssertEqual(kept?.status, .stopped, "The whole translation was of the earlier text")
        let current = try await store.result(for: after, operation: .translate)
        XCTAssertEqual(current?.text, "Un et")
    }

    func testAnUnreadableRowIsNoResultAndTheNextResultReplacesIt() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Readable", into: controller)
        let request = DerivedTextRequest(source: source, operation: .translate, targetLanguage: "fr")
        _ = try await store.save(snapshot("Lisible"), for: request)
        let other = DerivedTextRequest(source: source, operation: .extractText)
        _ = try await store.save(snapshot("Readable"), for: other)
        // The translation's text no longer matches its digest.
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedText")
            request.predicate = NSPredicate(format: "operation == %@", DerivedTextOperation.translate.rawValue)
            try context.fetch(request).forEach { $0.setValue(Data("Altered".utf8), forKey: "text") }
            try context.save()
            context.reset()
        }

        let unreadable = try await store.result(for: source, operation: .translate)
        XCTAssertNil(unreadable)
        let readable = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(readable?.text, "Readable", "The item's other results stay readable")
        // An unreadable row is no whole result: a partial one takes its place.
        let replaced = try await store.save(snapshot("Lis", phase: .stopped(.person)), for: request)
        XCTAssertEqual(replaced?.text, "Lis")
        let rows = try await rowCount(for: source.itemID, in: controller)
        XCTAssertEqual(rows, 2)
    }

    func testPurgingASnippetRemovesItsResultsAndLeavesItsClipsResults() async throws {
        let (controller, store) = try await makeStore()
        let clip = try await insertClip("Both facets", into: controller)
        guard case .created(let snippet) = try await LibraryService(controller: controller).saveAsMemo(clip.itemID) else {
            return XCTFail("The clip was not saved as a snippet")
        }
        _ = try await store.save(snapshot("Clip"),
                                 for: DerivedTextRequest(source: clip, operation: .translate, targetLanguage: "fr"))
        _ = try await store.save(snapshot("Snippet"),
                                 for: DerivedTextRequest(source: snippet, operation: .translate, targetLanguage: "fr"))
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        let moved = try await LifecycleService(controller: controller).remove(
            ref: snippet, at: Date(), expecting: identity, permit: permit)

        _ = try await LifecycleCleanupService(controller: controller).purgeFacet(
            moved.target, trigger: .explicitUserRequest, at: Date(), expecting: identity, permit: permit)

        let clipResult = try await store.result(for: clip, operation: .translate)
        XCTAssertEqual(clipResult?.text, "Clip")
        let snippetRows = try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedText")
            request.predicate = NSPredicate(format: "facet == %@", ContentFacet.memo.rawValue)
            return try context.count(for: request)
        }
        XCTAssertEqual(snippetRows, 0)
    }

    func testAClipTheHistoryLetGoHasNoResult() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Old", into: controller, copiedAt: Date(timeIntervalSinceNow: -3 * 86_400))
        _ = try await store.save(snapshot("Vieux"),
                                 for: DerivedTextRequest(source: source, operation: .translate, targetLanguage: "fr"))
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)

        _ = try await LifecycleService(controller: controller).expireHistory(
            policy: .days(1), at: Date(), expecting: identity, permit: permit)

        let expired = try await store.result(for: source, operation: .translate)
        XCTAssertNil(expired)
    }

    func testASaveForContentReadInAnotherStoreGenerationIsDropped() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Generation", into: controller)
        let current = try await controller.identity()
        let earlier = StoreIdentity(storeID: current.storeID, generation: UUID())

        let dropped = try await store.save(snapshot("Génération"),
                                           for: DerivedTextRequest(source: source, operation: .translate,
                                                                   targetLanguage: "fr"),
                                           expecting: earlier)

        XCTAssertNil(dropped)
        let rows = try await rowCount(for: source.itemID, in: controller)
        XCTAssertEqual(rows, 0)
        let kept = try await store.save(snapshot("Génération"),
                                        for: DerivedTextRequest(source: source, operation: .translate,
                                                                targetLanguage: "fr"),
                                        expecting: current)
        XCTAssertNotNil(kept)
    }

    func testASavedResultReadsBackAsItWasSaved() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Usage", into: controller)

        let saved = try await store.save(snapshot("Utilisation", usage: GenerationUsage()),
                                         for: DerivedTextRequest(source: source, operation: .translate,
                                                                 targetLanguage: "fr"))

        XCTAssertNil(saved?.usage, "Usage with no count is no usage")
        let read = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(read, saved)
    }

    // MARK: Helpers

    private func makeStore() async throws -> (PersistenceController, DerivedTextStore) {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (controller, DerivedTextStore(controller: controller))
    }

    /// A synthetic text clip, copied a moment ago unless said otherwise.
    private func insertClip(_ text: String, into controller: PersistenceController,
                            copiedAt: Date = Date()) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let item = ItemValue(title: text, captureID: capture.id, historyEligible: true, lastCopiedAt: copiedAt,
                             copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    private func snapshot(_ text: String, phase: GenerationSnapshot.Phase = .finished(.completed),
                          engine: String = "On this Mac", requestID: UUID = UUID(),
                          usage: GenerationUsage? = nil) -> GenerationSnapshot {
        GenerationSnapshot(phase: phase, info: GenerationInfo(engine: engine, requestID: requestID),
                           texts: [.main: text], usage: usage)
    }

    private func rowCount(for itemID: ItemID, in controller: PersistenceController) async throws -> Int {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedText")
            request.predicate = NSPredicate(format: "itemID == %@", itemID.rawValue as NSUUID)
            return try context.count(for: request)
        }
    }
}
