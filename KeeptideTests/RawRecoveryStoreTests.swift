import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class RawRecoveryStoreTests: XCTestCase {
    func testEvidencePersistsAcrossReopenAndOnlyPermitBoundPhasesAdvance() async throws {
        let directory = try makeDirectory()
        var controller = try PersistenceController(directory: directory)
        do {
            let identity = try await controller.identity()
            let evidence = Data("synthetic raw attributes and relationship ids".utf8)
            let store = RawRecoveryStore(controller: controller)
            let permit = try await store.record(evidence: evidence, expecting: identity)
            let prepared = try await store.load(permit)
            XCTAssertEqual(prepared.evidence, evidence)
            let reconciling = try await store.transition(permit, to: .reconciling)
            XCTAssertEqual(reconciling.phase, .reconciling)

            try await controller.close()
            controller = try PersistenceController(directory: directory)
            let reopened = RawRecoveryStore(controller: controller)
            let reopenedRecord = try await reopened.load(permit)
            XCTAssertEqual(reopenedRecord.evidence, evidence)
            let completed = try await reopened.transition(permit, to: .completed)
            XCTAssertEqual(completed.phase, .completed)
            do {
                _ = try await reopened.transition(permit, to: .reconciling)
                XCTFail("A completed raw recovery plan was reopened")
            } catch {
                XCTAssertEqual(error as? RawRecoveryError, .invalidTransition)
            }
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func testUnknownSchemaBlocksButPreservesOpaqueEvidence() async throws {
        let directory = try makeDirectory()
        let controller = try PersistenceController(directory: directory)
        do {
            let identity = try await controller.identity()
            let planID = UUID()
            let evidence = Data([0xde, 0xad, 0xbe, 0xef])
            try await controller.perform { context in
                let row = NSEntityDescription.insertNewObject(forEntityName: "RawRecoveryPlan", into: context)
                row.setValue(planID, forKey: "id")
                row.setValue(Int64(7), forKey: "schemaVersion")
                row.setValue(identity.storeID, forKey: "storeID")
                row.setValue(identity.generation, forKey: "generation")
                row.setValue("future", forKey: "phase")
                row.setValue(evidence, forKey: "payload")
                row.setValue(Date(timeIntervalSince1970: 1), forKey: "createdAt")
                row.setValue(Date(timeIntervalSince1970: 1), forKey: "updatedAt")
                try context.save()
                context.reset()
            }
            let permit = RecoveryPermit(planID: planID, identity: identity)
            do {
                _ = try await RawRecoveryStore(controller: controller).load(permit)
                XCTFail("Unknown raw recovery schema decoded as supported")
            } catch {
                XCTAssertEqual(error as? RawRecoveryError, .unsupportedPlan)
            }
            let persisted = try await controller.perform { context -> (String?, Data?, Int64) in
                let request = NSFetchRequest<NSManagedObject>(entityName: "RawRecoveryPlan")
                request.predicate = NSPredicate(format: "id == %@", planID as NSUUID)
                let row = try XCTUnwrap(context.fetch(request).first)
                return (
                    row.value(forKey: "phase") as? String,
                    row.value(forKey: "payload") as? Data,
                    (row.value(forKey: "schemaVersion") as? NSNumber)?.int64Value ?? -1
                )
            }
            XCTAssertEqual(persisted.0, RawRecoveryPlanPhase.blocked.rawValue)
            XCTAssertEqual(persisted.1, evidence)
            XCTAssertEqual(persisted.2, 7)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func testOversizedEvidenceIsRejectedBeforeAnyPlanIsWritten() async throws {
        let directory = try makeDirectory()
        let controller = try PersistenceController(directory: directory)
        do {
            let identity = try await controller.identity()
            do {
                _ = try await RawRecoveryStore(controller: controller).record(
                    evidence: Data(repeating: 0x7f, count: RawRecoveryStore.maximumEvidenceByteCount + 1),
                    expecting: identity
                )
                XCTFail("Unbounded raw evidence was persisted")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
            let count = try await controller.perform { context in
                try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "RawRecoveryPlan"))
            }
            XCTAssertEqual(count, 0)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawRecoveryStoreTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
