import CoreData
import Foundation
import XCTest
@testable import Keeptide

/// Synthetic stores only. A V4 store keeps a snippet's collection in `LibraryItem.collectionID`, and V4 also pointed
/// the to-one `collection` relationship at it; V5 keeps every membership in the to-many relationship alone.
final class CollectionMembershipBackfillTests: XCTestCase {
    func testAV4StoreReadsTheSameCollectionsBeforeDuringAndAfterTheBackfill() async throws {
        let directory = try temporaryDirectory()
        let fixture = try seedV4Store(at: directory)

        var controller = try PersistenceController(directory: directory)
        let before = try await states(fixture.items, in: controller)
        XCTAssertEqual(before[fixture.filed]?.collectionIDs, [fixture.active])
        XCTAssertEqual(before[fixture.attributeOnly]?.collectionIDs, [fixture.active])
        XCTAssertEqual(before[fixture.inDeleted]?.collectionIDs, [fixture.deleted])
        XCTAssertEqual(before[fixture.unfiled]?.collectionIDs, [])
        let members = try await ContentRepository(controller: controller).collectionMembershipSnapshot(fixture.active)
        XCTAssertEqual(Set(members.members.map(\.value.key)), [.item(fixture.filed), .item(fixture.attributeOnly)])

        let backfill = CollectionMembershipBackfill(controller: controller)
        let needed = try await backfill.isNeeded()
        XCTAssertTrue(needed)
        let outcome = try await backfill.run()
        XCTAssertEqual(outcome, .init(moved: 3, dropped: 1, skipped: 0))

        let after = try await states(fixture.items, in: controller)
        // Moving a membership leaves the item's value, and so its fingerprint, as it was.
        for id in [fixture.filed, fixture.attributeOnly, fixture.unfiled] {
            XCTAssertEqual(after[id]?.value, before[id]?.value)
            XCTAssertEqual(after[id]?.fingerprint, before[id]?.fingerprint)
        }
        // A collection that was deleted keeps no members.
        XCTAssertEqual(after[fixture.inDeleted]?.collectionIDs, [])
        let stored = try await storedMemberships(in: controller)
        XCTAssertEqual(stored.legacy, [:])
        XCTAssertEqual(stored.related[fixture.filed.rawValue], [fixture.active.rawValue])
        XCTAssertEqual(stored.related[fixture.attributeOnly.rawValue], [fixture.active.rawValue])
        XCTAssertEqual(stored.related[fixture.inDeleted.rawValue], [])

        let neededAgain = try await backfill.isNeeded()
        XCTAssertFalse(neededAgain)
        let again = try await backfill.run()
        XCTAssertEqual(again, .init())

        try await controller.close()
        controller = try PersistenceController(directory: directory)
        let reopened = try await states(fixture.items, in: controller)
        XCTAssertEqual(reopened.mapValues(\.value), after.mapValues(\.value))
        try await controller.close()
    }

    func testEachBatchCommitsOnItsOwnAndARunResumesWhereAnotherStopped() async throws {
        let count = ProcessInfo.processInfo.environment["KEEPTIDE_BACKFILL_ITEM_COUNT"].flatMap(Int.init) ?? 450
        try await withStore { controller in
            let (collection, ids) = try await seedSnippets(count, in: controller)
            try await keepCollectionsTheV4Way(ids, collection: collection, in: controller)
            // A run that stopped after some items: those are in the relationship already.
            let resumedFrom = ids.prefix(Int(Double(count) * 0.1))
            try await moveToRelationship(Array(resumedFrom), collection: collection, in: controller)
            let reader = StoreChangeReader(controller: controller)
            let start = try await reader.currentCheckpoint()

            let clock = ContinuousClock()
            var outcome = CollectionMembershipBackfill.Outcome()
            let elapsed = try await clock.measure {
                outcome = try await CollectionMembershipBackfill(controller: controller).run()
            }

            print("Backfilling \(count - resumedFrom.count) of \(count) snippets took \(elapsed)")
            let remaining = count - resumedFrom.count
            XCTAssertEqual(outcome, .init(moved: remaining, dropped: 0, skipped: 0))
            let commits = try await itemCommits(after: start, in: reader)
            XCTAssertEqual(commits, (0..<(remaining + 199) / 200).map { min(200, remaining - $0 * 200) })
            let stored = try await storedMemberships(in: controller)
            XCTAssertEqual(stored.legacy, [:])
            XCTAssertEqual(stored.related.count, count)
            XCTAssertTrue(stored.related.values.allSatisfy { $0 == [collection.rawValue] })
        }
    }

    func testAnItemTheStoreRefusesIsLeftAsItWasAndTheRestStillMove() async throws {
        try await withStore { controller in
            let (collection, ids) = try await seedSnippets(5, in: controller)
            try await keepCollectionsTheV4Way(ids, collection: collection, in: controller)
            // An item on its way out of the library takes no ordinary writes.
            let refused = ids[2]
            try await controller.perform { context in
                let marker = NSEntityDescription.insertNewObject(forEntityName: "ItemDeletionMarker", into: context)
                marker.setValue(refused.rawValue, forKey: "id")
                marker.setValue(Date(), forKey: "deletedAt")
                try context.save()
                context.reset()
            }

            let outcome = try await CollectionMembershipBackfill(controller: controller).run()

            XCTAssertEqual(outcome, .init(moved: 4, dropped: 0, skipped: 1))
            let stored = try await storedMemberships(in: controller)
            XCTAssertEqual(stored.legacy, [refused.rawValue: collection.rawValue])
            let left = try await states([refused], in: controller)
            XCTAssertEqual(left[refused]?.collectionIDs, [collection])
        }
    }

    func testCollectionsReadWhileTheBackfillIsDueAreIndexedAndCounted() async throws {
        let harness = try SearchHarness.make(in: self)
        let (collection, ids) = try await seedSnippets(3, in: harness.controller)
        try await keepCollectionsTheV4Way(Array(ids.prefix(2)), collection: collection, in: harness.controller)
        try await harness.consumer.synchronize()

        var filed: SearchPage?
        let request = SearchRequest(query: "", scope: .memo, collection: .collection(collection), generation: 1)
        for try await page in harness.service.search(request) { filed = page }
        let counts = await harness.service.counts()

        XCTAssertEqual(Set(try XCTUnwrap(filed).results.map(\.ref.itemID)), Set(ids))
        XCTAssertEqual(counts?.collections[collection], 3)
        XCTAssertEqual(counts?.unfiled, 0)
    }

    /// Fingerprints, and every cleanup intent that stored an item, are digests of this encoding: an item in at most
    /// one collection must encode as it did when it could be in only one.
    func testAnItemInOneCollectionOrNoneEncodesAsItAlwaysDid() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for collection in [nil, CollectionID()] as [CollectionID?] {
            let legacy = V4ItemValue(
                id: ItemID(), createdAt: Date(timeIntervalSince1970: 100), sourceApp: "test.source", title: "Snippet",
                captureID: UUID(), memoID: UUID(), collectionID: collection, isFavorite: true, historyEligible: true,
                historyDeletedAt: nil, historyPurgeAfter: nil, deletedAt: nil,
                lastCopiedAt: Date(timeIntervalSince1970: 200), copyCount: 3
            )
            let current = ItemValue(
                id: legacy.id, createdAt: legacy.createdAt, sourceApp: legacy.sourceApp, title: legacy.title,
                captureID: legacy.captureID, memoID: legacy.memoID, collectionIDs: collection.map { [$0] } ?? [],
                isFavorite: true, historyEligible: true, lastCopiedAt: legacy.lastCopiedAt, copyCount: 3
            )
            XCTAssertEqual(try encoder.encode(current), try encoder.encode(legacy))
            XCTAssertEqual(try StoredRecords.canonicalDigest(RecordValue.item(current)),
                           try StoredRecords.canonicalDigest(RecordValue.item(try JSONDecoder().decode(
                               ItemValue.self, from: try encoder.encode(legacy)))))
        }
        var several = ItemValue(title: "In three", memoID: UUID())
        let ids = [CollectionID(), CollectionID(), CollectionID()]
        several.collectionIDs = ids + [ids[0]]
        XCTAssertEqual(several.collectionIDs, CollectionID.sorted(ids))
        XCTAssertEqual(try JSONDecoder().decode(ItemValue.self, from: try encoder.encode(several)), several)
    }
}

// MARK: - Fixtures

/// `ItemValue` as V4 declared it.
private struct V4ItemValue: Codable {
    var id: ItemID
    var createdAt: Date
    var sourceApp: String?
    var title: String
    var captureID: UUID?
    var memoID: UUID?
    var collectionID: CollectionID?
    var isFavorite: Bool
    var historyEligible: Bool
    var historyDeletedAt: Date?
    var historyPurgeAfter: Date?
    var deletedAt: Date?
    var lastCopiedAt: Date
    var copyCount: Int64
}

private struct V4Fixture {
    let active: CollectionID
    let deleted: CollectionID
    let filed: ItemID
    let attributeOnly: ItemID
    let inDeleted: ItemID
    let unfiled: ItemID
    var items: [ItemID] { [filed, attributeOnly, inDeleted, unfiled] }
}

private struct ItemRead {
    let value: ItemValue
    let fingerprint: Data
    var collectionIDs: [CollectionID] { value.collectionIDs }
}

private extension CollectionMembershipBackfillTests {
    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideBackfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func withStore(_ body: (PersistenceController) async throws -> Void) async throws {
        let controller = try PersistenceController(directory: try temporaryDirectory())
        do {
            try await body(controller)
            try await controller.close()
        } catch {
            try? await controller.close()
            throw error
        }
    }

    /// A V4 store written with the V4 model, as V4 wrote it: one snippet in an active collection both ways, one with
    /// only the attribute, one in a collection deleted since, and one in none.
    func seedV4Store(at directory: URL) throws -> V4Fixture {
        let models = try XCTUnwrap(Bundle(for: PersistenceController.self).url(forResource: "Keeptide", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: models.appendingPathComponent("KeeptideV4.mom")))
        let container = NSPersistentContainer(name: "Keeptide", managedObjectModel: model)
        let coordinator = container.persistentStoreCoordinator
        let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true]
        let content = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: "CloudContent",
            at: directory.appendingPathComponent("Content.sqlite"), options: options
        )
        let local = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: "LocalState",
            at: directory.appendingPathComponent("Local.sqlite"), options: [:]
        )
        let fixture = V4Fixture(active: CollectionID(), deleted: CollectionID(), filed: ItemID(),
                                attributeOnly: ItemID(), inDeleted: ItemID(), unfiled: ItemID())
        let context = container.newBackgroundContext()
        try context.performAndWait {
            let identity = NSEntityDescription.insertNewObject(forEntityName: "StoreIdentity", into: context)
            identity.setValue(UUID(uuidString: content.identifier), forKey: "id")
            identity.setValue(UUID(), forKey: "generation")
            identity.setValue(StoreSafetyState.active.rawValue, forKey: "safetyState")
            let active = collection(fixture.active, name: "Prompts", deletedAt: nil, in: context)
            let deleted = collection(fixture.deleted, name: "Old", deletedAt: Date(timeIntervalSince1970: 50), in: context)
            snippet(fixture.filed, attribute: fixture.active, relationship: active, in: context)
            snippet(fixture.attributeOnly, attribute: fixture.active, relationship: nil, in: context)
            snippet(fixture.inDeleted, attribute: fixture.deleted, relationship: deleted, in: context)
            snippet(fixture.unfiled, attribute: nil, relationship: nil, in: context)
            try context.save()
            context.reset()
        }
        try coordinator.remove(content)
        try coordinator.remove(local)
        return fixture
    }

    func collection(_ id: CollectionID, name: String, deletedAt: Date?,
                    in context: NSManagedObjectContext) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: "Collection", into: context)
        object.setValue(id.rawValue, forKey: "id")
        object.setValue(name, forKey: "name")
        object.setValue("blue", forKey: "color")
        object.setValue(1.0, forKey: "sortOrder")
        object.setValue(deletedAt, forKey: "deletedAt")
        return object
    }

    func snippet(_ id: ItemID, attribute: CollectionID?, relationship: NSManagedObject?,
                 in context: NSManagedObjectContext) {
        let body = Data("synthetic snippet".utf8)
        let memo = NSEntityDescription.insertNewObject(forEntityName: "MemoDocument", into: context)
        let memoID = UUID()
        memo.setValue(memoID, forKey: "id")
        memo.setValue(id.rawValue, forKey: "itemID")
        memo.setValue("Snippet", forKey: "title")
        memo.setValue(MemoBodyMode.ownedPlainText.rawValue, forKey: "bodyMode")
        memo.setValue(body, forKey: "body")
        memo.setValue(UUID(), forKey: "version")
        memo.setValue(ContentDigest.sha256(body), forKey: "digest")
        memo.setValue("", forKey: "note")
        memo.setValue(MemoKind.plainText.rawValue, forKey: "displayKind")
        let item = NSEntityDescription.insertNewObject(forEntityName: "LibraryItem", into: context)
        item.setValue(id.rawValue, forKey: "id")
        item.setValue(Date(timeIntervalSince1970: 100), forKey: "createdAt")
        item.setValue("Snippet", forKey: "title")
        item.setValue(memoID, forKey: "memoID")
        item.setValue(attribute?.rawValue, forKey: "collectionID")
        item.setValue(false, forKey: "isFavorite")
        item.setValue(false, forKey: "historyEligible")
        item.setValue(Date(timeIntervalSince1970: 200), forKey: "lastCopiedAt")
        item.setValue(Int64(0), forKey: "copyCount")
        item.setValue(memo, forKey: "memo")
        item.setValue(relationship, forKey: "collection")
    }

    /// `count` owned snippets in one new collection, as V5 writes them.
    func seedSnippets(_ count: Int, in controller: PersistenceController) async throws -> (CollectionID, [ItemID]) {
        let collection = CollectionValue(name: "Synthetic", color: "blue")
        var mutations: [StoreMutation] = [.insert(.collection(collection))]
        var ids: [ItemID] = []
        for index in 0..<count {
            let itemID = ItemID()
            let body = Data("synthetic snippet \(index)".utf8)
            let memo = MemoValue(itemID: itemID, title: "Snippet \(index)", bodyMode: .ownedPlainText, body: body,
                                 version: ContentVersion(), digest: ContentDigest.sha256(body))
            let item = ItemValue(id: itemID, title: "Snippet \(index)", memoID: memo.id, collectionIDs: [collection.id])
            mutations += [.insert(.memo(memo)), .insert(.item(item))]
            ids.append(itemID)
        }
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(), mutations: mutations
        ))
        return (collection.id, ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
    }

    /// Puts these items' collection where V4 kept it, in the attribute alone.
    func keepCollectionsTheV4Way(_ ids: [ItemID], collection: CollectionID,
                                 in controller: PersistenceController) async throws {
        try await rewrite(ids, in: controller) { object in
            object.setValue(collection.rawValue, forKey: "collectionID")
            object.setValue(NSSet(), forKey: "collection")
        }
    }

    /// As a run that stopped would have left these items.
    func moveToRelationship(_ ids: [ItemID], collection: CollectionID,
                            in controller: PersistenceController) async throws {
        try await controller.perform { context in
            guard let target = try StoredRecords.object(.collection(collection), in: context) else {
                throw StoreError.notFound
            }
            for id in ids {
                guard let object = try StoredRecords.object(.item(id), in: context) else { throw StoreError.notFound }
                object.setValue(nil, forKey: "collectionID")
                object.setValue(NSSet(object: target), forKey: "collection")
            }
            try context.save()
            context.reset()
        }
    }

    func rewrite(_ ids: [ItemID], in controller: PersistenceController,
                 _ change: @escaping @Sendable (NSManagedObject) -> Void) async throws {
        try await controller.perform { context in
            for id in ids {
                guard let object = try StoredRecords.object(.item(id), in: context) else { throw StoreError.notFound }
                change(object)
            }
            try context.save()
            context.reset()
        }
    }

    func states(_ ids: [ItemID], in controller: PersistenceController) async throws -> [ItemID: ItemRead] {
        var result: [ItemID: ItemRead] = [:]
        for id in ids {
            let state = try await ContentRepository(controller: controller).recordState(.item(id))
            guard case .item(let value) = state.value else { throw StoreError.corruptStore }
            result[id] = ItemRead(value: value, fingerprint: state.fingerprint)
        }
        return result
    }

    /// What the store holds, apart from how it is read: the attribute V4 used, and the relationship.
    func storedMemberships(in controller: PersistenceController) async throws
        -> (legacy: [UUID: UUID], related: [UUID: Set<UUID>]) {
        try await controller.perform { context in
            context.reset(); defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
            var legacy: [UUID: UUID] = [:]
            var related: [UUID: Set<UUID>] = [:]
            for object in try context.fetch(request) {
                guard let id = object.value(forKey: "id") as? UUID else { throw StoreError.corruptStore }
                legacy[id] = object.value(forKey: "collectionID") as? UUID
                let collections = object.value(forKey: "collection") as? Set<NSManagedObject> ?? []
                related[id] = Set(collections.compactMap { $0.value(forKey: "id") as? UUID })
            }
            return (legacy, related)
        }
    }

    /// The number of items each commit after `start` wrote.
    func itemCommits(after start: Data?, in reader: StoreChangeReader) async throws -> [Int] {
        var token = start
        var commits: [Int] = []
        while true {
            let batch = try await reader.read(after: token)
            for transaction in batch.transactions {
                let items = transaction.changes.filter { $0.entity == "LibraryItem" }.count
                if items > 0 { commits.append(items) }
            }
            guard batch.token != token else { return commits }
            token = batch.token
        }
    }
}
