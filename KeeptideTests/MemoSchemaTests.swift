import CoreData
import XCTest
@testable import Keeptide

final class MemoSchemaTests: XCTestCase {
    func testV2DiskStoreMigratesWithoutLosingCaptureOrMemoAndKeepsDisplayKindOnReopen() async throws {
        try await verifyDiskMigration(from: 2)
    }

    func testV1DiskStoreMigratesWithoutLosingCaptureOrMemoAndKeepsDisplayKindOnReopen() async throws {
        try await verifyDiskMigration(from: 1)
    }

    private func verifyDiskMigration(from version: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = try XCTUnwrap(Bundle(for: PersistenceController.self)
            .url(forResource: "Keeptide", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: models.appendingPathComponent("KeeptideV\(version).mom")))
        let old = try PersistenceController(directory: directory, model: oldModel)
        addTeardownBlock { try? await old.close(); try? FileManager.default.removeItem(at: directory) }
        let capture = try ContentStoreFixtures.capture([[ ("public.utf8-plain-text", Data("migration 中文 source".utf8)) ]])
        var item = ContentStoreFixtures.item(capture)
        let memo = MemoValue(itemID: item.id, title: "Before", bodyMode: .inheritedCapture)
        item.memoID = memo.id
        _ = try await WriteCoordinator(controller: old).commit(StoreTransaction(identity: old.identity(), mutations: [
            .insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))
        ]))
        try await old.close()

        let migrated = try PersistenceController(directory: directory)
        addTeardownBlock { try? await migrated.close() }
        let repository = ContentRepository(controller: migrated)
        let original = try await repository.read(ContentStoreFixtures.ref(item, capture))
        XCTAssertEqual(original.representations, capture.representations)
        let state = try await repository.recordState(.memo(memo.id))
        guard case .memo(var value) = state.value else { return XCTFail("Missing migrated memo") }
        XCTAssertNil(value.displayKind)
        value.displayKind = "prompt"
        _ = try await WriteCoordinator(controller: migrated).commit(StoreTransaction(identity: migrated.identity(),
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: state.fingerprint)], mutations: [.update(.memo(value))]))
        let after = try await repository.recordState(.memo(memo.id))
        XCTAssertNotEqual(after.fingerprint, state.fingerprint)
        try await migrated.close()

        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try? await reopened.close() }
        let final = try await ContentRepository(controller: reopened).recordState(.memo(memo.id))
        guard case .memo(let persisted) = final.value else { return XCTFail("Missing memo after reopen") }
        XCTAssertEqual(persisted.displayKind, "prompt")
        XCTAssertEqual(persisted.bodyMode, .inheritedCapture)
        XCTAssertEqual(persisted.title, "Before")
        try await reopened.close()
    }

    func testLegacyMemoEncodingWithoutDisplayKindStillDecodes() throws {
        let memo = MemoValue(itemID: ItemID(), bodyMode: .inheritedCapture)
        let encoded = try JSONEncoder().encode(memo)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["displayKind"])
        XCTAssertEqual(try JSONDecoder().decode(MemoValue.self, from: encoded), memo)
    }

    func testDisplayKindIsOptionalAndOldModelsRemainMigratable() throws {
        let current = try PersistenceController.loadModel()
        let field = try XCTUnwrap(current.entitiesByName["MemoDocument"]?.attributesByName["displayKind"])
        XCTAssertTrue(field.isOptional)
        XCTAssertEqual(field.attributeType, .stringAttributeType)
        XCTAssertEqual(current.versionIdentifiers, ["3"])
        let directory = try XCTUnwrap(Bundle(for: PersistenceController.self)
            .url(forResource: "Keeptide", withExtension: "momd"))
        for version in [1, 2] {
            let old = try XCTUnwrap(NSManagedObjectModel(contentsOf:
                directory.appendingPathComponent("KeeptideV\(version).mom")))
            XCTAssertNil(old.entitiesByName["MemoDocument"]?.attributesByName["displayKind"])
            _ = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: current)
        }
    }
}
