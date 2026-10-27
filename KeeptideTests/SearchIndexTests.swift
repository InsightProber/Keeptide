import CoreData
import Foundation
import XCTest
@testable import Keeptide

/// End-to-end: Core Data facts → persistent history → HistoryConsumer → index → SearchService.
final class SearchIndexTests: XCTestCase {
    func testCapturedTextBecomesSearchableAfterSynchronize() async throws {
        let harness = try SearchHarness.make(in: self)
        _ = try await CaptureService(controller: harness.controller).capture(SearchTestSupport.snapshot("中文剪贴板历史", count: 1))

        try await harness.consumer.synchronize()
        let page = try await harness.search("贴板")
        let recent = try await ContentRepository(controller: harness.controller).recent(limit: 1)

        XCTAssertEqual(page.results.map(\.ref), [try XCTUnwrap(recent.first?.history)])
        XCTAssertEqual(harness.status.state, .ready)
    }

    func testWriterSavesTriggerBackgroundCatchUp() async throws {
        let harness = try SearchHarness.make(in: self)
        await harness.consumer.start()
        try await SearchTestSupport.waitUntil { harness.status.state == .ready }

        _ = try await CaptureService(controller: harness.controller).capture(SearchTestSupport.snapshot("wake up 自动", count: 1))

        try await SearchTestSupport.waitUntil { try await harness.search("自动").totalMatches == 1 }
    }

    func testMemoEditReplacesOldVersion() async throws {
        let harness = try SearchHarness.make(in: self)
        let itemID = ItemID()
        let first = Data("alpha beta".utf8)
        let memo = MemoValue(itemID: itemID, title: "Prompt", bodyMode: .ownedPlainText, body: first,
                             version: ContentVersion(), digest: ContentDigest.sha256(first))
        try await harness.commit([.insert(.memo(memo)), .insert(.item(ItemValue(id: itemID, title: "Prompt", memoID: memo.id)))])
        try await harness.consumer.synchronize()
        let original = try await harness.search("alpha")
        let oldRef = try XCTUnwrap(original.results.first?.ref)

        var edited = memo
        let second = Data("gamma".utf8)
        edited.body = second
        edited.version = ContentVersion()
        edited.digest = ContentDigest.sha256(second)
        try await harness.update(.memo(memo.id), to: .memo(edited))
        try await harness.consumer.synchronize()

        let stale = try await harness.search("alpha")
        let current = try await harness.search("gamma")
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
        let harness = try SearchHarness.make(in: self)
        let softDeleted = try await harness.insertItemWithOwnedMemo(text: "soft delete marker")
        let historyRemoved = try await harness.insertItemWithOwnedMemo(text: "history removal marker")
        let historyPurged = try await harness.insertItemWithOwnedMemo(text: "history purge marker")
        let wholeItem = try await harness.insertItemWithOwnedMemo(text: "whole item marker")
        try await harness.consumer.synchronize()

        var memo = softDeleted.memo
        memo.deletedAt = Date(timeIntervalSince1970: 500)
        try await harness.update(.memo(memo.id), to: .memo(memo))
        var removed = historyRemoved.item
        removed.historyDeletedAt = Date(timeIntervalSince1970: 600)
        try await harness.update(.item(removed.id), to: .item(removed))
        var purged = historyPurged.item
        purged.historyEligible = false
        let state = try await ContentRepository(controller: harness.controller).recordState(.item(purged.id))
        try await harness.commit([
            .update(.item(purged)),
            .insert(.facetMarker(FacetDeletionMarkerValue(itemID: purged.id, facet: .history,
                                                          generationID: try XCTUnwrap(purged.captureID)))),
        ], preconditions: [.recordUnchanged(.item(purged.id), fingerprint: state.fingerprint)], maintenance: true)
        try await harness.commit([.insert(.itemMarker(ItemDeletionMarkerValue(itemID: wholeItem.item.id)))],
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
        let harness = try SearchHarness.make(in: self)
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("inverse page".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, bodyMode: .inheritedCapture)
        let collections = [CollectionValue(name: "first"), CollectionValue(name: "second")]
        item.memoID = memo.id
        item.collectionID = collections[0].id
        try await harness.commit([.insert(.capture(capture)), .insert(.memo(memo))]
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
        _ = try await CaptureService(controller: harness.controller).capture(SearchTestSupport.snapshot("after inverse pages", count: 2))

        try await harness.consumer.synchronize()
        let head = try await StoreChangeReader(controller: harness.controller).currentCheckpoint()

        let page = try await harness.search("after inverse")
        XCTAssertEqual(page.totalMatches, 1)
        // Checkpoints are JSON; compare the transaction they point at, not their bytes.
        let indexed = try XCTUnwrap(try harness.index.metadata()?.checkpoint)
        XCTAssertEqual(try StoreChangeReader.sequence(of: indexed), try StoreChangeReader.sequence(of: try XCTUnwrap(head)))
        XCTAssertEqual(harness.status.state, .ready)
    }

    func testRealUsageReceiptsReorderSameTierAfterRestart() async throws {
        let directory = SearchTestSupport.directory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var harness: SearchHarness? = try SearchHarness.make(in: self, directory: directory, cleanUp: false)
        let service = CaptureService(controller: try XCTUnwrap(harness?.controller))
        let rarely = try await service.capture(SearchTestSupport.snapshot("deploy script A", count: 1))
        let often = try await service.capture(SearchTestSupport.snapshot("deploy script B", count: 2))
        let exact = try await service.capture(SearchTestSupport.snapshot("deploy", count: 3))
        let recent = try await ContentRepository(controller: try XCTUnwrap(harness?.controller)).recent(limit: 10)
        let oftenRef = try XCTUnwrap(recent.first { $0.itemID == often.itemID }?.history)
        let usage = LocalUsageStore(controller: try XCTUnwrap(harness?.controller))
        for _ in 0..<3 {
            try await usage.record(UseReceipt(ref: oftenRef, outcome: .success))
        }
        try await harness?.consumer.synchronize()
        let expected = [exact.itemID, often.itemID, rarely.itemID]
        let before = try await try XCTUnwrap(harness).search("deploy").results.map(\.ref.itemID)
        try await harness?.close()
        harness = nil

        let reopened = try SearchHarness.make(in: self, directory: directory)
        try await reopened.consumer.synchronize()
        let after = try await reopened.search("deploy").results.map(\.ref.itemID)

        XCTAssertEqual(before, expected)
        XCTAssertEqual(after, expected)
    }

    func testCaptureDuringRebuildIsIndexed() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 2_000, prefix: "bulk")

        let consumer = harness.consumer
        let rebuild = Task { try await consumer.synchronize() }
        _ = try await CaptureService(controller: harness.controller).capture(SearchTestSupport.snapshot("late arrival 迟到", count: 1))
        try await rebuild.value
        try await harness.consumer.synchronize()

        let late = try await harness.search("迟到")
        let bulk = try await harness.search("bulk", limit: 1)
        XCTAssertEqual(late.totalMatches, 1)
        XCTAssertEqual(bulk.totalMatches, 2_000)
    }

    func testNormalizationNeverAltersStoredContent() async throws {
        let harness = try SearchHarness.make(in: self)
        let original = Data("ＡＢＣ Café".utf8)
        _ = try await CaptureService(controller: harness.controller).capture(
            CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: original),
            ])], changeCount: 1, sourceApp: "test.source")
        )
        try await harness.consumer.synchronize()

        let page = try await harness.search("abc cafe")
        let ref = try XCTUnwrap(page.results.first?.ref)
        let content = try await ContentRepository(controller: harness.controller).read(ref)

        XCTAssertEqual(content.representations.map(\.bytes), [original])
    }

    func testHugeTextCaptureIsPartiallyIndexed() async throws {
        let harness = try SearchHarness.make(in: self)
        let filler = String(repeating: "x", count: 1_048_576)
        let text = "needle-early " + filler + " needle-late " + filler
        _ = try await CaptureService(controller: harness.controller).capture(SearchTestSupport.snapshot(text, count: 1))
        try await harness.consumer.synchronize()

        let early = try await harness.search("needle-early")
        let late = try await harness.search("needle-late")

        XCTAssertEqual(early.totalMatches, 1)
        XCTAssertEqual(early.results.first?.isPartiallyIndexed, true)
        XCTAssertEqual(late.totalMatches, 0)
    }

    func testGenerationChangeRebuildsForNewIdentity() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 20, prefix: "generation")
        try await harness.consumer.synchronize()

        try await StoreSafetyGate(controller: harness.controller)
            .transition(to: .quarantined, expecting: try await harness.controller.identity())
        try await harness.consumer.synchronize()
        let fresh = try await SearchHarness.freshDocuments(for: harness.controller)

        let identity = try await harness.controller.identity()
        XCTAssertEqual(try harness.index.metadata()?.identity, identity)
        XCTAssertEqual(try harness.index.allDocuments(), fresh)
        XCTAssertEqual(fresh.count, 20)
    }
}
