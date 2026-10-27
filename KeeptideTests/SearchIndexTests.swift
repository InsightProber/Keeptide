import CoreData
import Foundation
import XCTest
@testable import Keeptide

/// End-to-end: Core Data facts → persistent history → HistoryConsumer → index → SearchService.
final class SearchIndexTests: XCTestCase {
    func testCapturedTextBecomesSearchableAfterSynchronize() async throws {
        let harness = try await makeHarness()
        _ = try await CaptureService(controller: harness.controller).capture(snapshot("中文剪贴板历史", count: 1))

        try await harness.consumer.synchronize()
        let page = try await search(harness, "贴板")
        let recent = try await ContentRepository(controller: harness.controller).recent(limit: 1)

        XCTAssertEqual(page.results.map(\.ref), [try XCTUnwrap(recent.first?.history)])
        XCTAssertEqual(harness.status.state, .ready)
    }

    func testWriterSavesTriggerBackgroundCatchUp() async throws {
        let harness = try await makeHarness()
        await harness.consumer.start()
        try await waitUntil { harness.status.state == .ready }

        _ = try await CaptureService(controller: harness.controller).capture(snapshot("wake up 自动", count: 1))

        try await waitUntil { try await self.search(harness, "自动").totalMatches == 1 }
    }

    func testMemoEditReplacesOldVersion() async throws {
        let harness = try await makeHarness()
        let itemID = ItemID()
        let first = Data("alpha beta".utf8)
        let memo = MemoValue(itemID: itemID, title: "Prompt", bodyMode: .ownedPlainText, body: first,
                             version: ContentVersion(), digest: ContentDigest.sha256(first))
        try await commit(harness, [.insert(.memo(memo)), .insert(.item(ItemValue(id: itemID, title: "Prompt", memoID: memo.id)))])
        try await harness.consumer.synchronize()
        let original = try await search(harness, "alpha")
        let oldRef = try XCTUnwrap(original.results.first?.ref)

        var edited = memo
        let second = Data("gamma".utf8)
        edited.body = second
        edited.version = ContentVersion()
        edited.digest = ContentDigest.sha256(second)
        try await update(harness, .memo(memo.id), to: .memo(edited))
        try await harness.consumer.synchronize()

        let stale = try await search(harness, "alpha")
        let current = try await search(harness, "gamma")
        XCTAssertEqual(stale.totalMatches, 0)
        XCTAssertEqual(current.results.map(\.ref.version), [try XCTUnwrap(edited.version)])
        do {
            _ = try await ContentRepository(controller: harness.controller).read(oldRef)
            XCTFail("A stale search result resolved")
        } catch {
            XCTAssertEqual(error as? StoreError, .staleReference)
        }
    }

    func testDeletionsRemoveDocuments() async throws {
        let harness = try await makeHarness()
        let softDeleted = try await insertItemWithOwnedMemo(harness, text: "soft delete marker")
        let historyRemoved = try await insertItemWithOwnedMemo(harness, text: "history removal marker")
        let historyPurged = try await insertItemWithOwnedMemo(harness, text: "history purge marker")
        let wholeItem = try await insertItemWithOwnedMemo(harness, text: "whole item marker")
        try await harness.consumer.synchronize()

        var memo = softDeleted.memo
        memo.deletedAt = Date(timeIntervalSince1970: 500)
        try await update(harness, .memo(memo.id), to: .memo(memo))
        var removed = historyRemoved.item
        removed.historyDeletedAt = Date(timeIntervalSince1970: 600)
        try await update(harness, .item(removed.id), to: .item(removed))
        var purged = historyPurged.item
        purged.historyEligible = false
        let state = try await ContentRepository(controller: harness.controller).recordState(.item(purged.id))
        try await commit(harness, [
            .update(.item(purged)),
            .insert(.facetMarker(FacetDeletionMarkerValue(itemID: purged.id, facet: .history,
                                                          generationID: try XCTUnwrap(purged.captureID)))),
        ], preconditions: [.recordUnchanged(.item(purged.id), fingerprint: state.fingerprint)], maintenance: true)
        try await commit(harness, [.insert(.itemMarker(ItemDeletionMarkerValue(itemID: wholeItem.item.id)))],
                         maintenance: true)
        try await harness.consumer.synchronize()

        let facets = try harness.index.allDocuments().reduce(into: [UUID: Set<ContentFacet>]()) {
            $0[$1.ref.itemID.rawValue, default: []].insert($1.ref.facet)
        }
        XCTAssertEqual(facets[softDeleted.item.id.rawValue], [.history])
        XCTAssertEqual(facets[historyRemoved.item.id.rawValue], [.memo])
        XCTAssertEqual(facets[historyPurged.item.id.rawValue], [.memo])
        XCTAssertNil(facets[wholeItem.item.id.rawValue])
    }

    func testRelationshipOnlyTransactionDoesNotStallCatchUp() async throws {
        let harness = try await makeHarness()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("inverse page".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        let collections = [CollectionValue(name: "first"), CollectionValue(name: "second")]
        item.memoID = memo.id
        item.collectionID = collections[0].id
        try await commit(harness, [.insert(.capture(capture)), .insert(.memo(memo))]
                         + collections.map { .insert(.collection($0)) } + [.insert(.item(item))])
        try await harness.consumer.synchronize()
        let itemID = item.id
        let collectionIDs = collections.map(\.id)
        for index in 0..<128 {
            try await harness.controller.perform { context in
                context.reset()
                guard let object = try StoredRecords.object(.item(itemID), in: context),
                      let collection = try StoredRecords.object(.collection(collectionIDs[(index + 1) % 2]), in: context)
                else { throw CocoaError(.coderValueNotFound) }
                object.setValue(collection, forKey: "collection")
                try context.save()
                context.reset()
            }
        }
        _ = try await CaptureService(controller: harness.controller).capture(snapshot("after inverse pages", count: 2))

        try await harness.consumer.synchronize()
        let head = try await StoreChangeReader(controller: harness.controller).currentCheckpoint()

        let page = try await search(harness, "after inverse")
        XCTAssertEqual(page.totalMatches, 1)
        XCTAssertEqual(try harness.index.metadata()?.checkpoint, head)
        XCTAssertEqual(harness.status.state, .ready)
    }

    func testRealUsageReceiptsReorderSameTierAfterRestart() async throws {
        let directory = SearchTestSupport.directory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var harness: Harness? = try await makeHarness(directory: directory, cleanUp: false)
        let service = CaptureService(controller: try XCTUnwrap(harness?.controller))
        let rarely = try await service.capture(snapshot("deploy script A", count: 1))
        let often = try await service.capture(snapshot("deploy script B", count: 2))
        let exact = try await service.capture(snapshot("deploy", count: 3))
        let recent = try await ContentRepository(controller: try XCTUnwrap(harness?.controller)).recent(limit: 10)
        let oftenRef = try XCTUnwrap(recent.first { $0.itemID == often.itemID }?.history)
        let usage = LocalUsageStore(controller: try XCTUnwrap(harness?.controller))
        for _ in 0..<3 {
            try await usage.record(UseReceipt(ref: oftenRef, outcome: .success))
        }
        try await harness?.consumer.synchronize()
        let expected = [exact.itemID, often.itemID, rarely.itemID]
        let before = try await search(try XCTUnwrap(harness), "deploy").results.map(\.ref.itemID)
        try await harness?.close()
        harness = nil

        let reopened = try await makeHarness(directory: directory)
        try await reopened.consumer.synchronize()
        let after = try await search(reopened, "deploy").results.map(\.ref.itemID)

        XCTAssertEqual(before, expected)
        XCTAssertEqual(after, expected)
    }

    func testCaptureDuringRebuildIsIndexed() async throws {
        let harness = try await makeHarness()
        try await insertTextItems(harness, count: 2_000, prefix: "bulk")

        let consumer = harness.consumer
        let rebuild = Task { try await consumer.synchronize() }
        _ = try await CaptureService(controller: harness.controller).capture(snapshot("late arrival 迟到", count: 1))
        try await rebuild.value
        try await harness.consumer.synchronize()

        let late = try await search(harness, "迟到")
        let bulk = try await search(harness, "bulk", limit: 1)
        XCTAssertEqual(late.totalMatches, 1)
        XCTAssertEqual(bulk.totalMatches, 2_000)
    }

    func testNormalizationNeverAltersStoredContent() async throws {
        let harness = try await makeHarness()
        let original = Data("ＡＢＣ Café".utf8)
        _ = try await CaptureService(controller: harness.controller).capture(
            CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: original),
            ])], changeCount: 1, sourceApp: "test.source")
        )
        try await harness.consumer.synchronize()

        let page = try await search(harness, "abc cafe")
        let ref = try XCTUnwrap(page.results.first?.ref)
        let content = try await ContentRepository(controller: harness.controller).read(ref)

        XCTAssertEqual(content.representations.map(\.bytes), [original])
    }

    func testHugeTextCaptureIsPartiallyIndexed() async throws {
        let harness = try await makeHarness()
        let filler = String(repeating: "x", count: 1_048_576)
        let text = "needle-early " + filler + " needle-late " + filler
        _ = try await CaptureService(controller: harness.controller).capture(snapshot(text, count: 1))
        try await harness.consumer.synchronize()

        let early = try await search(harness, "needle-early")
        let late = try await search(harness, "needle-late")

        XCTAssertEqual(early.totalMatches, 1)
        XCTAssertEqual(early.results.first?.isPartiallyIndexed, true)
        XCTAssertEqual(late.totalMatches, 0)
    }

    func testGenerationChangeRebuildsForNewIdentity() async throws {
        let harness = try await makeHarness()
        try await insertTextItems(harness, count: 20, prefix: "generation")
        try await harness.consumer.synchronize()

        try await StoreSafetyGate(controller: harness.controller)
            .transition(to: .quarantined, expecting: try await harness.controller.identity())
        try await harness.consumer.synchronize()
        let fresh = try await freshDocuments(for: harness.controller)

        let identity = try await harness.controller.identity()
        XCTAssertEqual(try harness.index.metadata()?.identity, identity)
        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 20)
    }

    // MARK: - Helpers

    struct Harness {
        let directory: URL
        let controller: PersistenceController
        let index: SQLiteSearchIndex
        let status: SearchIndexStatus
        let consumer: HistoryConsumer
        let service: SearchService

        func close() async throws {
            await consumer.stopAndDrain()
            index.close()
            try await controller.close()
        }
    }

    func makeHarness(directory: URL? = nil, cleanUp: Bool = true) async throws -> Harness {
        let directory = directory ?? SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        let index = try SQLiteSearchIndex(directory: directory.appendingPathComponent("Search", isDirectory: true))
        let status = SearchIndexStatus()
        let consumer = HistoryConsumer(controller: controller, index: index, status: status,
                                       debounce: .milliseconds(20))
        let harness = Harness(directory: directory, controller: controller, index: index, status: status,
                              consumer: consumer, service: SearchService(index: index, status: status))
        if cleanUp {
            addTeardownBlock {
                try? await harness.close()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return harness
    }

    /// Documents a brand-new index builds from the same store, for recovery comparisons.
    func freshDocuments(for controller: PersistenceController) async throws -> [SearchDocument] {
        let directory = SearchTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteSearchIndex(directory: directory)
        defer { index.close() }
        let consumer = HistoryConsumer(controller: controller, index: index, status: SearchIndexStatus())
        try await consumer.synchronize()
        await consumer.stopAndDrain()
        return try index.allDocuments()
    }

    func search(_ harness: Harness, _ query: String, scope: SearchScope = .all, limit: Int = 200) async throws -> SearchPage {
        var last: SearchPage?
        for try await page in harness.service.search(SearchRequest(query: query, scope: scope, generation: 1, limit: limit)) {
            last = page
        }
        return try XCTUnwrap(last)
    }

    func snapshot(_ text: String, count: Int) -> CaptureSnapshotValue {
        CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)),
        ])], changeCount: count, sourceApp: "test.source")
    }

    func commit(
        _ harness: Harness, _ mutations: [StoreMutation], preconditions: [StorePrecondition] = [],
        maintenance: Bool = false
    ) async throws {
        let permit = maintenance ? try await StoreSafetyGate(controller: harness.controller).permit(.maintenance) : nil
        _ = try await WriteCoordinator(controller: harness.controller).commit(StoreTransaction(
            identity: try await harness.controller.identity(), preconditions: preconditions,
            mutations: mutations, permit: permit
        ))
    }

    func update(_ harness: Harness, _ key: RecordKey, to value: RecordValue) async throws {
        let state = try await ContentRepository(controller: harness.controller).recordState(key)
        try await commit(harness, [.update(value)],
                         preconditions: [.recordUnchanged(key, fingerprint: state.fingerprint)])
    }

    func insertItemWithOwnedMemo(_ harness: Harness, text: String) async throws -> (item: ItemValue, memo: MemoValue) {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let itemID = ItemID()
        let body = Data("memo \(text)".utf8)
        let memo = MemoValue(itemID: itemID, title: "Memo", bodyMode: .ownedPlainText, body: body,
                             version: ContentVersion(), digest: ContentDigest.sha256(body))
        let item = ItemValue(id: itemID, title: text, captureID: capture.id, memoID: memo.id,
                             historyEligible: true, copyCount: 1)
        try await commit(harness, [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))])
        return (item, memo)
    }

    func insertTextItems(_ harness: Harness, count: Int, prefix: String) async throws {
        for start in stride(from: 0, to: count, by: 100) {
            var mutations: [StoreMutation] = []
            for index in start..<min(start + 100, count) {
                let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("\(prefix) \(index)".utf8))]])
                mutations += [.insert(.capture(capture)), .insert(.item(ContentStoreFixtures.item(capture)))]
            }
            try await commit(harness, mutations)
        }
    }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition not met within \(timeout)")
    }
}
