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

    func testAWholeResultWithoutTextLeavesNoResultForTheContentTheItemHas() async throws {
        let (controller, store) = try await makeStore()
        let source = try await insertClip("Screenshot", into: controller)
        let recognition = DerivedTextRequest(source: source, operation: .extractText)
        _ = try await store.save(snapshot("Made before"), for: recognition)
        _ = try await store.save(snapshot("Traduit"),
                                 for: DerivedTextRequest(source: source, operation: .translate, targetLanguage: "fr"))

        // Nothing found under another store generation, or for content the item no longer has, and nothing made by a
        // job that failed or was stopped: the text made before stays.
        let current = try await controller.identity()
        let earlier = StoreIdentity(storeID: current.storeID, generation: UUID())
        _ = try await store.save(snapshot(""), for: recognition, expecting: earlier)
        var stale = source
        stale.version = ContentVersion()
        _ = try await store.save(snapshot(""), for: DerivedTextRequest(source: stale, operation: .extractText))
        let clearedOtherGeneration = try await store.clear(source, operation: .extractText, expecting: earlier)
        let clearedStale = try await store.clear(stale, operation: .extractText)
        XCTAssertFalse(clearedOtherGeneration, "It says the store didn't take it")
        XCTAssertFalse(clearedStale)
        _ = try await store.save(snapshot("", phase: .failed(.interrupted)), for: recognition)
        _ = try await store.save(snapshot("", phase: .stopped(.person)), for: recognition)
        var kept = try await store.result(for: source, operation: .extractText)
        XCTAssertEqual(kept?.text, "Made before")

        // Nothing found for the content the item has: the item has no text now, and keeps its translation.
        let cleared = try await store.save(snapshot(""), for: recognition, expecting: current)

        XCTAssertNil(cleared)
        let clearedAgain = try await store.clear(source, operation: .extractText, expecting: current)
        XCTAssertTrue(clearedAgain, "Nothing left to clear is cleared all the same")
        kept = try await store.result(for: source, operation: .extractText)
        XCTAssertNil(kept)
        let translation = try await store.result(for: source, operation: .translate)
        XCTAssertEqual(translation?.text, "Traduit")
        let rows = try await rowCount(for: source.itemID, in: controller)
        XCTAssertEqual(rows, 1)
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

    func testWhatIsKeptOfManySourcesIsReadAtOnce() async throws {
        let (controller, store) = try await makeStore()
        let whole = try await insertClip("Whole", into: controller)
        let partial = try await insertClip("Partial", into: controller)
        let cutOff = try await insertClip("Cut off", into: controller)
        let none = try await insertClip("None", into: controller)
        let changed = try await insertClip("Changed", into: controller)
        let deleted = try await insertClip("Deleted", into: controller)
        let otherGeneration = try await insertClip("Other generation", into: controller)
        let unreadable = try await insertClip("Unreadable", into: controller)
        for (source, phase) in [(whole, GenerationSnapshot.Phase.finished(.completed)), (partial, .stopped(.person)),
                                (cutOff, .finished(.truncated)), (changed, .finished(.completed)),
                                (deleted, .finished(.completed)), (otherGeneration, .finished(.completed)),
                                (unreadable, .finished(.completed))] {
            _ = try await store.save(snapshot("Made of \(source.itemID)", phase: phase),
                                     for: DerivedTextRequest(source: source, operation: .translate,
                                                             targetLanguage: source == partial ? "ja" : "fr"))
        }
        var later = changed
        later.version = ContentVersion()
        let identity = try await controller.identity()
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        _ = try await LifecycleService(controller: controller).remove(ref: deleted, at: Date(), expecting: identity,
                                                                      permit: permit)
        let otherItemID = otherGeneration.itemID.rawValue
        let unreadableItemID = unreadable.itemID.rawValue
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedText")
            request.predicate = NSPredicate(format: "itemID == %@", otherItemID as NSUUID)
            try context.fetch(request).forEach { $0.setValue(UUID(), forKey: "storeGeneration") }
            // A row whose text no longer matches its digest can't be read.
            request.predicate = NSPredicate(format: "itemID == %@", unreadableItemID as NSUUID)
            try context.fetch(request).forEach { $0.setValue(Data(repeating: 0, count: 32), forKey: "textDigest") }
            try context.save()
            context.reset()
        }

        let found = try await store.summaries(of: [whole, partial, cutOff, none, later, deleted, otherGeneration,
                                                   unreadable], operation: .translate)

        // How whole each is, and the language it is in, for a card to say.
        XCTAssertEqual(found, [whole: DerivedTextSummary(status: .complete, targetLanguage: "fr"),
                               partial: DerivedTextSummary(status: .stopped, targetLanguage: "ja"),
                               cutOff: DerivedTextSummary(status: .truncated, targetLanguage: "fr")],
                       "Current, readable, and for exactly the content it was made from; one that isn't hides no other")
        let nothingAsked = try await store.summaries(of: [], operation: .translate)
        XCTAssertEqual(nothingAsked, [:])
        let otherOperation = try await store.summaries(of: [whole], operation: .extractText)
        XCTAssertEqual(otherOperation, [:])
    }

    // MARK: For the search index

    func testRecognizedTextsAreReadAsKeptForTheItemsAskedFor() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let stopped = try await insertClip("Diagram", into: controller)
        let translated = try await insertClip("Plan", into: controller)
        let other = try await insertClip("Other", into: controller)
        let saved = try await store.save(snapshot("Quarterly plan"),
                                         for: DerivedTextRequest(source: image, operation: .extractText))
        let partial = try await store.save(snapshot("Diagr", phase: .stopped(.person)),
                                           for: DerivedTextRequest(source: stopped, operation: .extractText))
        try await store.save(snapshot("Plan traduit"), for: DerivedTextRequest(source: translated, operation: .translate,
                                                                                targetLanguage: "fr"))
        try await store.save(snapshot("Not asked for"), for: DerivedTextRequest(source: other, operation: .extractText))
        let identity = try await controller.identity()

        let read = try await controller.perform { context in
            try DerivedTextStore.recognizedTexts(itemIDs: [image.itemID, stopped.itemID, translated.itemID],
                                                 identity: identity, in: context)
        }

        // As stored: where the text is searched, its digest is checked. A result stopped partway is read too.
        let (first, second) = (try XCTUnwrap(saved), try XCTUnwrap(partial))
        let expected = [(first, image, "Quarterly plan"), (second, stopped, "Diagr")]
            .map { RecognizedTextRow(id: $0.0.id, source: $0.1, bytes: Data($0.2.utf8),
                                     digest: ContentDigest.sha256(Data($0.2.utf8))) }
        XCTAssertEqual(Set(read.rows), Set(expected), "Only recognized text, of the items asked for")
        XCTAssertEqual(read.results, [RecognizedTextKey(itemID: image.itemID, facet: image.facet): first.id,
                                      RecognizedTextKey(itemID: stopped.itemID, facet: stopped.facet): second.id])
    }

    func testRecognizedTextsWrittenInAnotherStoreGenerationAreNotRead() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        try await store.save(snapshot("Quarterly plan"), for: DerivedTextRequest(source: image, operation: .extractText))
        let identity = try await controller.identity()
        let elsewhere = StoreIdentity(storeID: UUID(), generation: identity.generation)
        let later = StoreIdentity(storeID: identity.storeID, generation: UUID())

        let read = try await controller.perform { context in
            [try DerivedTextStore.recognizedTexts(itemIDs: [image.itemID], identity: elsewhere, in: context),
             try DerivedTextStore.recognizedTexts(itemIDs: [image.itemID], identity: later, in: context)]
                .map { $0.rows.count + $0.results.count }
        }
        let rows = try await controller.perform { context in
            [try DerivedTextStore.recognizedRows(identity: elsewhere, in: context),
             try DerivedTextStore.recognizedRows(identity: later, in: context)]
        }

        XCTAssertEqual(read, [0, 0])
        XCTAssertEqual(rows, [[:], [:]])
    }

    func testRecognizedTextRowsAreListedWithAFingerprintThatChangesWithEachSaveAndClear() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let note = try await insertClip("Note", into: controller)
        let identity = try await controller.identity()
        func rows() async throws -> ([RecognizedTextKey: UUID], RecognizedTextFingerprint) {
            try await controller.perform { context in
                (try DerivedTextStore.recognizedRows(identity: identity, in: context),
                 try DerivedTextStore.recognizedFingerprint(in: context))
            }
        }
        let (none, empty) = try await rows()
        XCTAssertEqual(none, [:])

        let saved1 = try await store.save(snapshot("Quarterly plan"),
                                          for: DerivedTextRequest(source: image, operation: .extractText),
                                          at: Date(timeIntervalSinceNow: -10))
        let first = try XCTUnwrap(saved1)
        let (_, beforeTranslation) = try await rows()
        try await store.save(snapshot("Note traduite"), for: DerivedTextRequest(source: note, operation: .translate,
                                                                                 targetLanguage: "fr"))
        let (saved, afterSave) = try await rows()
        XCTAssertEqual(saved, [RecognizedTextKey(itemID: image.itemID, facet: .history): first.id],
                       "Only recognized text")
        XCTAssertEqual(afterSave, beforeTranslation, "A translation changes nothing that is searched")
        XCTAssertNotEqual(afterSave, empty)

        let saved2 = try await store.save(snapshot("Annual plan"),
                                          for: DerivedTextRequest(source: image, operation: .extractText))
        let second = try XCTUnwrap(saved2)
        let (replaced, afterReplace) = try await rows()
        XCTAssertEqual(replaced, [RecognizedTextKey(itemID: image.itemID, facet: .history): second.id])
        XCTAssertNotEqual(afterReplace, afterSave)

        try await store.clear(image, operation: .extractText)
        let (cleared, afterClear) = try await rows()
        XCTAssertEqual(cleared, [:])
        XCTAssertNotEqual(afterClear, afterReplace)
    }

    func testTheFingerprintChangesWhenAResultIsReplacedAtAnEarlierTime() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let other = try await insertClip("Diagram", into: controller)
        let now = Date()
        try await store.save(snapshot("Quarterly plan"), for: DerivedTextRequest(source: image, operation: .extractText),
                             at: now)
        try await store.save(snapshot("Diagram text"), for: DerivedTextRequest(source: other, operation: .extractText),
                             at: now.addingTimeInterval(-10))
        let before = try await controller.perform { try DerivedTextStore.recognizedFingerprint(in: $0) }

        // As after the clock was set back: as many results are kept, and the latest is the same one.
        try await store.save(snapshot("Diagram notes"), for: DerivedTextRequest(source: other, operation: .extractText),
                             at: now.addingTimeInterval(-20))

        let after = try await controller.perform { try DerivedTextStore.recognizedFingerprint(in: $0) }
        XCTAssertNotEqual(after, before)
    }

    func testTheFingerprintCountsAResultMadeAtTheReferenceDate() async throws {
        let (controller, store) = try await makeStore()
        let image = try await insertClip("Screenshot", into: controller)
        let none = try await controller.perform { try DerivedTextStore.recognizedFingerprint(in: $0) }

        // Its time adds nothing to the sum.
        try await store.save(snapshot("Quarterly plan"), for: DerivedTextRequest(source: image, operation: .extractText),
                             at: Date(timeIntervalSinceReferenceDate: 0))

        let one = try await controller.perform { try DerivedTextStore.recognizedFingerprint(in: $0) }
        XCTAssertNotEqual(one, none)
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
