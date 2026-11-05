import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class CleanupIntentStoreTests: XCTestCase {
    func testUnknownSchemaRemainsPreparedAndFencesWritesWithoutChangingRawPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupIntentStoreTests-" + UUID().uuidString, isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let identity = try await controller.identity()
            let intentID = UUID()
            let raw = Data([0x00, 0xff, 0x42, 0x19])
            try await controller.perform { context in
                let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
                row.setValue(intentID, forKey: "id")
                row.setValue(Int64(99), forKey: "schemaVersion")
                row.setValue(identity.storeID, forKey: "storeID")
                row.setValue(identity.generation, forKey: "generation")
                row.setValue(CleanupIntentPhase.prepared.rawValue, forKey: "phase")
                row.setValue(raw, forKey: "payload")
                row.setValue(Date(timeIntervalSince1970: 1), forKey: "createdAt")
                row.setValue(Date(timeIntervalSince1970: 1), forKey: "updatedAt")
                try context.save()
                context.reset()
            }

            let maintenance = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let pendingBeforeLoad = try await CleanupIntentStore(controller: controller).pendingIDs(
                expecting: identity,
                permit: maintenance
            )
            XCTAssertEqual(pendingBeforeLoad, [intentID])

            do {
                _ = try await CleanupIntentStore(controller: controller).load(intentID, expecting: identity)
                XCTFail("Unknown cleanup schema decoded as a supported intent")
            } catch {
                XCTAssertEqual(error as? CleanupError, .unsupportedIntent)
            }
            let persisted = try await controller.perform { context -> (String?, Data?, Int64) in
                let request = NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")
                request.predicate = NSPredicate(format: "id == %@", intentID as NSUUID)
                let row = try XCTUnwrap(context.fetch(request).first)
                return (
                    row.value(forKey: "phase") as? String,
                    row.value(forKey: "payload") as? Data,
                    (row.value(forKey: "schemaVersion") as? NSNumber)?.int64Value ?? -1
                )
            }
            XCTAssertEqual(persisted.0, CleanupIntentPhase.prepared.rawValue)
            XCTAssertEqual(persisted.1, raw)
            XCTAssertEqual(persisted.2, 99)
            let pendingAfterLoad = try await CleanupIntentStore(controller: controller).pendingIDs(
                expecting: identity,
                permit: maintenance
            )
            XCTAssertEqual(pendingAfterLoad, [intentID])
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: identity,
                    mutations: [.insert(.collection(CollectionValue(name: "must remain fenced")))]
                ))
                XCTFail("Unknown prepared cleanup intent released the write fence")
            } catch {
                XCTAssertEqual(error as? StoreError, .operationDenied)
            }
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func testFutureAndNilPhasesArePagedAndPermanentlyFenceUntilExplicitBlock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupIntentUnknownPhaseTests-" + UUID().uuidString, isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let identity = try await controller.identity()
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let ids = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            ]
            let raw = Data("future cleanup payload".utf8)
            try await controller.perform { context in
                for (index, id) in ids.enumerated() {
                    let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
                    row.setValue(id, forKey: "id")
                    row.setValue(CleanupIntentStore.schemaVersion, forKey: "schemaVersion")
                    row.setValue(identity.storeID, forKey: "storeID")
                    row.setValue(identity.generation, forKey: "generation")
                    if index == 0 { row.setValue("futurePhase", forKey: "phase") }
                    row.setValue(raw, forKey: "payload")
                    row.setValue(Date(timeIntervalSince1970: 2), forKey: "createdAt")
                    row.setValue(Date(timeIntervalSince1970: 2), forKey: "updatedAt")
                }
                try context.save()
            }

            let store = CleanupIntentStore(controller: controller)
            let pending = try await store.pendingIDs(expecting: identity, permit: permit)
            XCTAssertEqual(pending, ids)
            for id in ids {
                do {
                    _ = try await store.load(id, expecting: identity)
                    XCTFail("Unknown cleanup phase decoded as supported")
                } catch {
                    XCTAssertEqual(error as? CleanupError, .unsupportedIntent)
                }
            }
            let rawStates = try await controller.perform { context -> [(String?, Data?)] in
                let request = NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                return try context.fetch(request).map {
                    ($0.value(forKey: "phase") as? String, $0.value(forKey: "payload") as? Data)
                }
            }
            XCTAssertEqual(rawStates.map(\.0), ["futurePhase", nil])
            XCTAssertEqual(rawStates.map(\.1), [raw, raw])

            let collection = CollectionValue(name: "released only by explicit block")
            do {
                _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                    identity: identity,
                    mutations: [.insert(.collection(collection))]
                ))
                XCTFail("Unknown cleanup phase released the write fence")
            } catch {
                XCTAssertEqual(error as? StoreError, .operationDenied)
            }

            for id in ids {
                try await store.block(id, expecting: identity, permit: permit, at: Date(timeIntervalSince1970: 3))
            }
            let afterBlock = try await store.pendingIDs(expecting: identity, permit: permit)
            XCTAssertTrue(afterBlock.isEmpty)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: identity,
                mutations: [.insert(.collection(collection))]
            ))
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }


    func testPendingIDsAreCurrentGenerationStableAndBounded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupIntentPagingTests-" + UUID().uuidString, isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let identity = try await controller.identity()
            let ids = [
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            ]
            try await controller.perform { context in
                for (index, id) in ids.enumerated() {
                    let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
                    row.setValue(id, forKey: "id")
                    row.setValue(CleanupIntentStore.schemaVersion, forKey: "schemaVersion")
                    row.setValue(identity.storeID, forKey: "storeID")
                    row.setValue(identity.generation, forKey: "generation")
                    row.setValue(
                        index == 1
                            ? CleanupIntentPhase.cloudCommitted.rawValue
                            : CleanupIntentPhase.prepared.rawValue,
                        forKey: "phase"
                    )
                    row.setValue(Data("synthetic".utf8), forKey: "payload")
                    row.setValue(Date(timeIntervalSince1970: 1), forKey: "createdAt")
                    row.setValue(Date(timeIntervalSince1970: 1), forKey: "updatedAt")
                }
                let foreign = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
                foreign.setValue(UUID(), forKey: "id")
                foreign.setValue(Int64(99), forKey: "schemaVersion")
                foreign.setValue(identity.storeID, forKey: "storeID")
                foreign.setValue(UUID(), forKey: "generation")
                foreign.setValue(CleanupIntentPhase.prepared.rawValue, forKey: "phase")
                foreign.setValue(Data("foreign generation".utf8), forKey: "payload")
                foreign.setValue(Date(timeIntervalSince1970: 1), forKey: "createdAt")
                foreign.setValue(Date(timeIntervalSince1970: 1), forKey: "updatedAt")
                try context.save()
                context.reset()
            }
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let store = CleanupIntentStore(controller: controller)
            let first = try await store.pendingIDs(expecting: identity, permit: permit, limit: 2)
            let second = try await store.pendingIDs(
                expecting: identity,
                permit: permit,
                afterID: try XCTUnwrap(first.last),
                limit: 2
            )
            XCTAssertEqual(first + second, ids)
            do {
                _ = try await store.pendingIDs(expecting: identity, permit: permit, limit: 129)
                XCTFail("Unbounded cleanup-intent replay was accepted")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func testBlockedIntentQueryFindsOnlyThisGenerationsBlockedIntents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupIntentBlockedTests-" + UUID().uuidString, isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let identity = try await controller.identity()
            let pendingID = UUID()
            try await controller.perform { context in
                // A completed and a pending intent of this generation, and a blocked one of another.
                let rows: [(UUID, UUID, CleanupIntentPhase)] = [
                    (UUID(), identity.generation, .completed),
                    (pendingID, identity.generation, .prepared),
                    (UUID(), UUID(), .blocked),
                ]
                for (id, generation, phase) in rows {
                    let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
                    row.setValue(id, forKey: "id")
                    row.setValue(CleanupIntentStore.schemaVersion, forKey: "schemaVersion")
                    row.setValue(identity.storeID, forKey: "storeID")
                    row.setValue(generation, forKey: "generation")
                    row.setValue(phase.rawValue, forKey: "phase")
                    row.setValue(Data("synthetic".utf8), forKey: "payload")
                    row.setValue(Date(timeIntervalSince1970: 1), forKey: "createdAt")
                    row.setValue(Date(timeIntervalSince1970: 1), forKey: "updatedAt")
                }
                try context.save()
                context.reset()
            }
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            let store = CleanupIntentStore(controller: controller)
            let before = try await store.hasBlockedIntent(expecting: identity, permit: permit)
            XCTAssertFalse(before)

            try await store.block(pendingID, expecting: identity, permit: permit, at: Date(timeIntervalSince1970: 2))
            let after = try await store.hasBlockedIntent(expecting: identity, permit: permit)
            XCTAssertTrue(after)
            do {
                let other = StoreIdentity(storeID: identity.storeID, generation: UUID())
                _ = try await store.hasBlockedIntent(expecting: other, permit: permit)
                XCTFail("Another generation's blocked intents were read")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
