import CoreData
import SQLite3
import XCTest
@testable import Keeptide

/// The text recognized in an image is searched as the image's body: found once it is kept, as it changes, and after
/// the index was stopped or built afresh, under the search's own rules. Its saves leave no history the index reads, so
/// each pass compares what was recognized with what the index last projected.
@MainActor
final class RecognizedTextSearchTests: XCTestCase {
    func testAnImageIsFoundByTheTextRecognizedInIt() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (image, _) = try await insertImage(into: harness)
        try await harness.consumer.synchronize()
        let found1 = try await finds("Quarterly", image, in: harness)
        XCTAssertFalse(found1)

        try await keep("Quarterly plan* (Q4) 季度计划", of: image, in: harness)

        try await waitUntilFound("Quarterly", image, in: harness)
        let found2 = try await finds("季度", image, in: harness)
        XCTAssertTrue(found2, "A short Chinese query")
        let found3 = try await finds("plan*", image, in: harness)
        XCTAssertTrue(found3, "Taken as written")
        let found4 = try await finds("(Q4)", image, in: harness)
        XCTAssertTrue(found4)
        let hit = try await harness.search("Quarterly").results.first { $0.ref == image }
        XCTAssertEqual(hit?.matchedFields, [.body])
        XCTAssertEqual(hit?.kind, .image)
    }

    func testAChinesePhraseWrappedOntoTheNextLineOfTheImageIsFound() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (image, _) = try await insertImage(into: harness)

        try await keep("季度\n计划", of: image, in: harness)

        try await waitUntilFound("季度计划", image, in: harness)
    }

    func testAClipSavedAsASnippetIsFoundByTheTextRecognizedInTheSnippet() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (clip, snippet, _) = try await insertImageSavedAsSnippet(into: harness)

        try await keep("Quarterly plan", of: snippet, in: harness)

        // In All the clip stands for both, and the snippet is the same image.
        try await waitUntilFound("Quarterly", clip, in: harness)
        let snippets = try await harness.search("Quarterly", scope: .memo).results.map(\.ref)
        XCTAssertEqual(snippets, [snippet])
        let clips = try await harness.search("Quarterly", scope: .history).results.map(\.ref)
        XCTAssertEqual(clips, [clip])
    }

    func testAClipAndItsSnippetWithDifferentResultsAreFoundByEitherInAll() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (clip, snippet, _) = try await insertImageSavedAsSnippet(into: harness)

        // As when one was stopped partway, or made with the other line-break setting.
        try await keep("Quarterly", of: clip, in: harness)
        try await keep("Quarterly plan, annual budget", of: snippet, in: harness)

        try await waitUntilFound("budget", clip, in: harness)
    }

    func testASnippetEditedToItsOwnTextIsNoLongerFoundByItsImagesText() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (clip, snippet, memo) = try await insertImageSavedAsSnippet(into: harness)
        try await keep("Quarterly plan", of: snippet, in: harness)
        try await waitUntilFound("Quarterly", clip, in: harness)

        var edited = memo
        let body = Data("Edited note".utf8)
        edited.bodyMode = .ownedPlainText
        edited.body = body
        edited.version = ContentVersion()
        edited.digest = ContentDigest.sha256(body)
        try await harness.update(.memo(memo.id), to: .memo(edited))

        // The snippet is its own text now, and the clip has no result of its own.
        try await SearchTestSupport.waitUntil { try await !harness.search("Edited").results.isEmpty }
        let found = try await harness.search("Quarterly").results
        XCTAssertEqual(found.map(\.ref), [])
    }

    func testTheTextFoundFollowsWhatIsRecognizedAgainOrCleared() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (image, _) = try await insertImage(into: harness)
        try await keep("Quarterly plan", of: image, in: harness)
        try await waitUntilFound("Quarterly", image, in: harness)

        try await keep("Annual report", of: image, in: harness)
        try await waitUntilFound("Annual", image, in: harness)
        let found5 = try await finds("Quarterly", image, in: harness)
        XCTAssertFalse(found5, "The earlier text isn't found")

        try await DerivedTextStore(controller: harness.controller).clear(image, operation: .extractText)
        try await SearchTestSupport.waitUntil { try await !self.finds("Annual", image, in: harness) }
    }

    func testClearingEverySavedResultLeavesNoImageFoundByItsText() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (first, _) = try await insertImage(into: harness, seed: 1)
        let (second, _) = try await insertImage(into: harness, seed: 2)
        try await keep("Quarterly plan", of: first, in: harness)
        try await keep("Quarterly budget", of: second, in: harness)
        try await waitUntilFound("plan", first, in: harness)
        try await waitUntilFound("budget", second, in: harness)

        try await DerivedTextStore(controller: harness.controller).removeAll()

        try await SearchTestSupport.waitUntil { try await harness.search("Quarterly").results.isEmpty }
    }

    func testRecognizedTextFollowsItsClipIntoRecentlyDeletedAndBack() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (image, _) = try await insertImage(into: harness)
        try await keep("Quarterly plan", of: image, in: harness)
        try await waitUntilFound("Quarterly", image, in: harness)
        let maintenance = try await makeMaintenance(for: harness)

        let moved = await maintenance.moveToRecentlyDeleted(image)
        let target = try XCTUnwrap(moved)
        try await SearchTestSupport.waitUntil { try await !self.finds("Quarterly", image, in: harness) }
        // Still recorded while it waits there, so a later change to other results doesn't project it again.
        XCTAssertEqual(try harness.index.recognizedRows().keys.map(\.itemID), [image.itemID])
        let recovered = await maintenance.recover(target)
        XCTAssertTrue(recovered)

        try await waitUntilFound("Quarterly", image, in: harness)
    }

    func testTextRecognizedWhileTheIndexWasStoppedIsFoundOnceItRuns() async throws {
        let harness = try SearchHarness.make(in: self)
        let (image, _) = try await insertImage(into: harness)
        try await harness.consumer.synchronize()
        await harness.consumer.stopAndDrain()

        try await keep("Quarterly plan", of: image, in: harness)
        let resumed = HistoryConsumer(controller: harness.controller, index: harness.index, status: harness.status,
                                      debounce: .milliseconds(20))
        addTeardownBlock { await resumed.stopAndDrain() }
        try await resumed.synchronize()

        let found6 = try await finds("Quarterly", image, in: harness)
        XCTAssertTrue(found6)
    }

    func testTextRecognizedBeforeTheIndexIsBuiltIsInIt() async throws {
        let harness = try SearchHarness.make(in: self)
        let (image, _) = try await insertImage(into: harness)
        try await keep("Quarterly plan", of: image, in: harness)

        try await harness.consumer.synchronize()

        let found7 = try await finds("Quarterly", image, in: harness)
        XCTAssertTrue(found7)
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)
        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        // Recorded with its documents, so the next pass has nothing to project again.
        XCTAssertEqual(try harness.index.recognizedRows().keys.map(\.itemID), [image.itemID])
    }

    func testTextClearedAfterTheIndexWasBuiltAgainIsNoLongerFound() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        let (image, _) = try await insertImage(into: harness)
        try await keep("Quarterly plan", of: image, in: harness)
        try await waitUntilFound("Quarterly", image, in: harness)
        // A lost checkpoint: the next pass builds the index again.
        try execute(on: harness, "DELETE FROM meta WHERE key = 'checkpoint'")
        try await harness.consumer.synchronize()
        let rebuilt = try await finds("Quarterly", image, in: harness)
        XCTAssertTrue(rebuilt)

        try await DerivedTextStore(controller: harness.controller).clear(image, operation: .extractText)

        try await SearchTestSupport.waitUntil { try await !self.finds("Quarterly", image, in: harness) }
    }

    func testAResultWhoseTextCantBeReadIsRecordedButNotSearched() async throws {
        let harness = try SearchHarness.make(in: self)
        let (image, _) = try await insertImage(into: harness)
        try await keep("Quarterly plan", of: image, in: harness)
        // Its text unreadable, as when the file that holds it is lost.
        try await harness.controller.perform { context in
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DerivedText"))
                .forEach { $0.setValue(nil, forKey: "text") }
            try context.save()
        }

        try await harness.consumer.synchronize()

        let found = try await finds("Quarterly", image, in: harness)
        XCTAssertFalse(found)
        // Recorded with the image's documents all the same, so the next result saved anywhere doesn't project it again.
        XCTAssertEqual(try harness.index.recognizedRows().keys.map(\.itemID), [image.itemID])
    }

    func testOnlyTextMadeFromTheContentShownIsProjected() async throws {
        let harness = try SearchHarness.make(in: self)
        let (image, _) = try await insertImage(into: harness)
        try await keep("Quarterly plan", of: image, in: harness)
        let identity = try await harness.controller.identity()
        func projected() async throws -> SearchProjectionBatch {
            try await harness.controller.perform { context in
                context.reset()
                defer { context.reset() }
                return try StoredRecords.searchProjection(itemIDs: [image.itemID], maximumTextBytes: .max,
                                                          identity: identity, in: context)
            }
        }
        let made = try await projected()
        let row = try XCTUnwrap(made.inputs.first?.recognizedText)
        XCTAssertEqual(row.source, image)

        // Made from another version of the content: its text isn't shown, and the result is still recorded.
        try await harness.controller.perform { context in
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DerivedText"))
                .forEach { $0.setValue(UUID(), forKey: "sourceVersion") }
            try context.save()
        }
        let stale = try await projected()
        XCTAssertNil(stale.inputs.first?.recognizedText)
        XCTAssertEqual(stale.recognizedResults, [image.itemID: [.history: row.id]])
    }

    // MARK: Helpers

    /// A synthetic image clip, with no text of its own.
    private func insertImage(into harness: SearchHarness, seed: UInt8 = 5) async throws -> (ContentRef, ItemValue) {
        let capture = try ContentStoreFixtures.capture([[("public.png", Data([1, 2, 3, 4, seed]))]])
        let item = ContentStoreFixtures.item(capture)
        try await harness.commit([.insert(.capture(capture)), .insert(.item(item))])
        return (ContentStoreFixtures.ref(item, capture), item)
    }

    /// A synthetic image clip saved as a snippet that inherits it: the clip, the snippet, and the snippet's memo.
    private func insertImageSavedAsSnippet(into harness: SearchHarness) async throws
        -> (clip: ContentRef, snippet: ContentRef, memo: MemoValue) {
        let capture = try ContentStoreFixtures.capture([[("public.png", Data([1, 2, 3, 4, 6]))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        item.memoID = memo.id
        try await harness.commit([.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))])
        return (ContentStoreFixtures.ref(item, capture), ContentStoreFixtures.ref(item, capture, facet: .memo), memo)
    }

    private func keep(_ text: String, of image: ContentRef, in harness: SearchHarness) async throws {
        _ = try await DerivedTextStore(controller: harness.controller).save(
            GenerationSnapshot(phase: .finished(.completed), info: GenerationInfo(engine: "On this Mac"),
                               texts: [.main: text]),
            for: DerivedTextRequest(source: image, operation: .extractText, keepsLineBreaks: true)
        )
    }

    private func finds(_ query: String, _ image: ContentRef, in harness: SearchHarness) async throws -> Bool {
        try await harness.search(query).results.contains { $0.ref == image }
    }

    private func waitUntilFound(_ query: String, _ image: ContentRef, in harness: SearchHarness) async throws {
        try await SearchTestSupport.waitUntil { try await self.finds(query, image, in: harness) }
    }

    private func execute(on harness: SearchHarness, _ sql: String) throws {
        let path = harness.directory.appendingPathComponent("Search/\(SQLiteSearchIndex.fileName)").path
        let connection = try SQLiteConnection(path: path, flags: SQLITE_OPEN_READWRITE)
        defer { connection.close() }
        try connection.run(sql, [])
    }

    private func makeMaintenance(for harness: SearchHarness) async throws -> LibraryMaintenance {
        let suite = "Keeptide-RecognizedTextSearch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let maintenance = LibraryMaintenance(controller: harness.controller,
                                             identity: try await harness.controller.identity(),
                                             directory: harness.directory,
                                             preferences: LifecyclePreferences(defaults: defaults))
        addTeardownBlock {
            await maintenance.stopAndDrain()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return maintenance
    }
}
