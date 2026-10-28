import CoreData
import Foundation
import XCTest
@testable import Keeptide

final class SearchProjectionTests: XCTestCase {
    func testProjectionMatchesRecentVisibilityRules() async throws {
        let controller = try makeStore()
        let fixtures = try await insertVisibilityFixtures(into: controller)
        let ids = fixtures.all

        let recent = try await ContentRepository(controller: controller).recent(limit: 100)
        let inputs = try await project(ids, in: controller)
        let recentByItem = Dictionary(uniqueKeysWithValues: recent.map { ($0.itemID.rawValue, $0) })

        XCTAssertEqual(Set(inputs.map(\.itemID.rawValue)), Set(recentByItem.keys))
        for input in inputs {
            let summary = try XCTUnwrap(recentByItem[input.itemID.rawValue])
            XCTAssertEqual(input.history, summary.history)
            XCTAssertEqual(input.memo?.ref, summary.memo)
        }
        let byItem = Dictionary(uniqueKeysWithValues: inputs.map { ($0.itemID.rawValue, $0) })
        XCTAssertEqual(byItem[fixtures.inherited.rawValue]?.memo?.isInherited, true)
        XCTAssertEqual(byItem[fixtures.inherited.rawValue]?.memo?.title, "Saved")
        XCTAssertEqual(byItem[fixtures.owned.rawValue]?.memo?.body, Data("owned body".utf8))
        XCTAssertEqual(byItem[fixtures.owned.rawValue]?.memo?.isInherited, false)
        XCTAssertNil(byItem[fixtures.softDeletedMemo.rawValue]?.memo)
        XCTAssertNotNil(byItem[fixtures.softDeletedMemo.rawValue]?.history)
        XCTAssertNil(byItem[fixtures.historyRemoved.rawValue])
        XCTAssertNil(byItem[fixtures.markedForDeletion.rawValue])
        XCTAssertEqual(byItem[fixtures.historyOnly.rawValue]?.textRepresentations.map(\.bytes),
                       [Data("history only".utf8)])
        XCTAssertEqual(byItem[fixtures.historyOnly.rawValue]?.sourceApp, "test.source")
    }

    func testProjectionReturnsOnlyPortableTextBytes() async throws {
        let controller = try makeStore()
        let image = Data(repeating: 0xAB, count: 1_048_576)
        let capture = try ContentStoreFixtures.capture([[
            ("public.png", image),
            ("public.utf8-plain-text", Data("caption".utf8)),
        ]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: controller)

        let projected = try await project([item.id], in: controller)
        let input = try XCTUnwrap(projected.first)

        XCTAssertEqual(input.textRepresentations.map(\.typeIdentifier), ["public.utf8-plain-text"])
        XCTAssertEqual(input.textRepresentations.map(\.bytes), [Data("caption".utf8)])
        XCTAssertEqual(input.representationTypes, ["public.png", "public.utf8-plain-text"])
        XCTAssertFalse(input.hasLocalReference)
        XCTAssertEqual(input.captureID, capture.id)
    }

    func testTextByteBudgetSplitsLargeBatchesButAlwaysProgresses() async throws {
        let controller = try makeStore()
        var ids: [ItemID] = []
        for index in 0..<3 {
            let capture = try ContentStoreFixtures.capture([[
                ("public.utf8-plain-text", Data(repeating: UInt8(ascii: "a") + UInt8(index), count: 2_000_000)),
            ]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            ids.append(item.id)
        }
        let requested = ids

        let small = try await controller.perform { context in
            try StoredRecords.searchProjection(itemIDs: requested, maximumTextBytes: 1_000_000, in: context)
        }
        let medium = try await controller.perform { context in
            try StoredRecords.searchProjection(itemIDs: requested, maximumTextBytes: 5_000_000, in: context)
        }

        XCTAssertEqual(small.processed, 1)
        XCTAssertEqual(small.inputs.map(\.itemID), [ids[0]])
        XCTAssertEqual(medium.processed, 2)
        XCTAssertEqual(medium.inputs.map(\.itemID), [ids[0], ids[1]])
    }

    func testAllItemIDsListsEveryItem() async throws {
        let controller = try makeStore()
        var inserted: Set<UUID> = []
        for index in 0..<3 {
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("item \(index)".utf8))]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            inserted.insert(item.id.rawValue)
        }

        let ids = try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            return try StoredRecords.searchAllItemIDs(in: context)
        }

        XCTAssertEqual(Set(ids.map(\.rawValue)), inserted)
    }

    func testChangesMapCaptureMemoAndMarkerToItems() async throws {
        let controller = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("mapped".utf8))]])
        let captureItem = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(captureItem, capture, into: controller)
        let memoItemID = ItemID()
        let body = Data("memo".utf8)
        let memo = MemoValue(itemID: memoItemID, bodyMode: .ownedPlainText, body: body,
                             version: ContentVersion(), digest: ContentDigest.sha256(body))
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(ItemValue(id: memoItemID, title: "memo", memoID: memo.id)))]
        ))
        // A purge revokes history eligibility in the same transaction as its marker.
        let marker = FacetDeletionMarkerValue(itemID: captureItem.id, facet: .history, generationID: capture.id)
        var purged = captureItem
        purged.historyEligible = false
        let state = try await ContentRepository(controller: controller).recordState(.item(captureItem.id))
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(),
            preconditions: [.recordUnchanged(.item(captureItem.id), fingerprint: state.fingerprint)],
            mutations: [.update(.item(purged)), .insert(.facetMarker(marker))],
            permit: try await StoreSafetyGate(controller: controller).permit(.maintenance)
        ))
        let deletedItem = UUID()
        let changes = [
            StoreChange(entity: "CaptureSnapshot", id: capture.id, deleted: false),
            StoreChange(entity: "CaptureRepresentation", id: try XCTUnwrap(capture.representations.first).id, deleted: false),
            StoreChange(entity: "MemoDocument", id: memo.id, deleted: false),
            StoreChange(entity: "FacetDeletionMarker", id: marker.id, deleted: false),
            StoreChange(entity: "LibraryItem", id: deletedItem, deleted: true),
            StoreChange(entity: "MemoDocument", id: UUID(), deleted: true),
            StoreChange(entity: "Collection", id: UUID(), deleted: false),
            StoreChange(entity: "Unknown", id: UUID(), deleted: false),
        ]

        let ids = try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            return try StoredRecords.searchItemIDs(for: changes, in: context)
        }

        XCTAssertEqual(Set(ids.map(\.rawValue)), [captureItem.id.rawValue, memoItemID.rawValue, deletedItem])
    }

    // MARK: - Helpers

    private struct VisibilityFixtures {
        let historyOnly: ItemID
        let inherited: ItemID
        let owned: ItemID
        let softDeletedMemo: ItemID
        let historyRemoved: ItemID
        let markedForDeletion: ItemID

        var all: [ItemID] { [historyOnly, inherited, owned, softDeletedMemo, historyRemoved, markedForDeletion] }
    }

    private func insertVisibilityFixtures(into controller: PersistenceController) async throws -> VisibilityFixtures {
        let writer = WriteCoordinator(controller: controller)
        func commit(_ mutations: [StoreMutation], permit: StorePermit? = nil) async throws {
            _ = try await writer.commit(StoreTransaction(
                identity: try await controller.identity(), mutations: mutations, permit: permit
            ))
        }
        func capture(_ text: String) throws -> CaptureValue {
            try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        }
        func item(_ id: ItemID, _ capture: CaptureValue, memoID: UUID? = nil, historyDeletedAt: Date? = nil) -> ItemValue {
            ItemValue(id: id, sourceApp: "test.source", title: "item", captureID: capture.id, memoID: memoID,
                      historyEligible: true, historyDeletedAt: historyDeletedAt, copyCount: 1)
        }

        let historyOnly = ItemID()
        let historyCapture = try capture("history only")
        try await commit([.insert(.capture(historyCapture)), .insert(.item(item(historyOnly, historyCapture)))])

        let inherited = ItemID()
        let inheritedCapture = try capture("inherited")
        let inheritedMemo = MemoValue(itemID: inherited, title: "Saved", bodyMode: .inheritedCapture)
        try await commit([
            .insert(.capture(inheritedCapture)), .insert(.memo(inheritedMemo)),
            .insert(.item(item(inherited, inheritedCapture, memoID: inheritedMemo.id))),
        ])

        let owned = ItemID()
        let ownedCapture = try capture("owned source")
        let ownedBody = Data("owned body".utf8)
        let ownedMemo = MemoValue(itemID: owned, title: "Owned", bodyMode: .ownedPlainText, body: ownedBody,
                                  version: ContentVersion(), digest: ContentDigest.sha256(ownedBody))
        try await commit([
            .insert(.capture(ownedCapture)), .insert(.memo(ownedMemo)),
            .insert(.item(item(owned, ownedCapture, memoID: ownedMemo.id))),
        ])

        let softDeleted = ItemID()
        let softCapture = try capture("soft deleted memo")
        let softBody = Data("deleted memo body".utf8)
        let softMemo = MemoValue(itemID: softDeleted, bodyMode: .ownedPlainText, body: softBody,
                                 version: ContentVersion(), digest: ContentDigest.sha256(softBody),
                                 deletedAt: Date(timeIntervalSince1970: 500))
        try await commit([
            .insert(.capture(softCapture)), .insert(.memo(softMemo)),
            .insert(.item(item(softDeleted, softCapture, memoID: softMemo.id))),
        ])

        let removed = ItemID()
        let removedCapture = try capture("history removed")
        try await commit([
            .insert(.capture(removedCapture)),
            .insert(.item(item(removed, removedCapture, historyDeletedAt: Date(timeIntervalSince1970: 600)))),
        ])

        let marked = ItemID()
        let markedCapture = try capture("marked for deletion")
        try await commit([.insert(.capture(markedCapture)), .insert(.item(item(marked, markedCapture)))])
        try await commit([.insert(.itemMarker(ItemDeletionMarkerValue(itemID: marked)))],
                         permit: try await StoreSafetyGate(controller: controller).permit(.maintenance))

        return VisibilityFixtures(historyOnly: historyOnly, inherited: inherited, owned: owned,
                                  softDeletedMemo: softDeleted, historyRemoved: removed, markedForDeletion: marked)
    }

    private func project(_ ids: [ItemID], in controller: PersistenceController) async throws -> [SearchProjectionInput] {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            return try StoredRecords.searchProjection(itemIDs: ids, in: context)
        }
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideSearchProjection-\(UUID().uuidString)", isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return controller
    }
}
