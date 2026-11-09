import CoreData
import XCTest
@testable import Keeptide

final class ModelCompatibilityTests: XCTestCase {
    private let cloudEntities: Set<String> = [
        "LibraryItem", "CaptureSnapshot", "CaptureRepresentation", "MemoDocument", "Collection",
        "ItemDeletionMarker", "FacetDeletionMarker"
    ]
    private let localEntities: Set<String> = [
        "StoreIdentity", "UsageSummary", "UsageExecutionDedup", "FileAccessRecord", "CleanupIntent", "RawRecoveryPlan"
    ]
    private let legacyLocalEntities: Set<String> = [
        "StoreIdentity", "UsageSummary", "UsageExecutionDedup", "FileAccessRecord"
    ]

    func testIndexUpgradeRequiresAnInferredMigrationFromTheFrozenV1Model() throws {
        let current = try loadModel()
        let directory = try XCTUnwrap(Bundle(for: PersistenceController.self)
            .url(forResource: "Keeptide", withExtension: "momd"))
        let original = try XCTUnwrap(NSManagedObjectModel(contentsOf:
            directory.appendingPathComponent("KeeptideV1.mom")))
        XCTAssertEqual(original.versionIdentifiers, ["1"])
        for entity in ["CaptureSnapshot", "LibraryItem"] {
            XCTAssertNotEqual(original.entityVersionHashesByName[entity], current.entityVersionHashesByName[entity])
        }
        for entity in legacyLocalEntities {
            XCTAssertEqual(original.entityVersionHashesByName[entity], current.entityVersionHashesByName[entity])
        }
        _ = try NSMappingModel.inferredMappingModel(forSourceModel: original, destinationModel: current)
    }

    func testCurrentModelHasExactConfigurationBoundariesAndVersionIdentifier() throws {
        let model = try loadModel()

        let customConfigurations = Set(model.configurations).subtracting(["PF_DEFAULT_CONFIGURATION_NAME"])
        XCTAssertEqual(customConfigurations, ["CloudContent", "LocalState"])
        XCTAssertEqual(Set(try XCTUnwrap(model.entities(forConfigurationName: "CloudContent")).compactMap(\.name)), cloudEntities)
        XCTAssertEqual(Set(try XCTUnwrap(model.entities(forConfigurationName: "LocalState")).compactMap(\.name)), localEntities)
        XCTAssertEqual(model.versionIdentifiers, ["5"])
    }

    func testCloudEntitiesExposeTheFrozenAttributes() throws {
        let model = try loadModel()

        assertAttributes(model, entity: "LibraryItem", expected: [
            "id": .UUIDAttributeType, "createdAt": .dateAttributeType, "sourceApp": .stringAttributeType,
            "title": .stringAttributeType, "captureID": .UUIDAttributeType, "memoID": .UUIDAttributeType,
            "collectionID": .UUIDAttributeType, "isFavorite": .booleanAttributeType,
            "historyEligible": .booleanAttributeType, "historyDeletedAt": .dateAttributeType,
            "historyPurgeAfter": .dateAttributeType, "deletedAt": .dateAttributeType,
            "lastCopiedAt": .dateAttributeType, "copyCount": .integer64AttributeType
        ])
        assertAttributes(model, entity: "CaptureSnapshot", expected: [
            "id": .UUIDAttributeType, "manifest": .binaryDataAttributeType, "digest": .binaryDataAttributeType
        ])
        assertAttributes(model, entity: "CaptureRepresentation", expected: [
            "id": .UUIDAttributeType, "snapshotID": .UUIDAttributeType, "itemIndex": .integer64AttributeType,
            "representationIndex": .integer64AttributeType, "typeIdentifier": .stringAttributeType,
            "storage": .stringAttributeType, "byteCount": .integer64AttributeType,
            "digest": .binaryDataAttributeType, "bytes": .binaryDataAttributeType
        ])
        assertAttributes(model, entity: "MemoDocument", expected: [
            "id": .UUIDAttributeType, "itemID": .UUIDAttributeType, "title": .stringAttributeType,
            "bodyMode": .stringAttributeType, "sourceRepresentationType": .stringAttributeType,
            "body": .binaryDataAttributeType, "version": .UUIDAttributeType, "digest": .binaryDataAttributeType,
            "languageHint": .stringAttributeType, "displayKind": .stringAttributeType, "note": .stringAttributeType,
            "deletedAt": .dateAttributeType, "purgeAfter": .dateAttributeType
        ])
        assertAttributes(model, entity: "Collection", expected: [
            "id": .UUIDAttributeType, "name": .stringAttributeType, "color": .stringAttributeType,
            "sortOrder": .doubleAttributeType, "deletedAt": .dateAttributeType
        ])
        assertAttributes(model, entity: "ItemDeletionMarker", expected: [
            "id": .UUIDAttributeType, "deletedAt": .dateAttributeType
        ])
        assertAttributes(model, entity: "FacetDeletionMarker", expected: [
            "id": .UUIDAttributeType, "itemID": .UUIDAttributeType, "facet": .stringAttributeType,
            "generationID": .UUIDAttributeType, "purgedAt": .dateAttributeType
        ])
    }

    func testLocalEntitiesExposeTheFrozenAttributes() throws {
        let model = try loadModel()

        assertAttributes(model, entity: "StoreIdentity", expected: [
            "id": .UUIDAttributeType, "generation": .UUIDAttributeType, "safetyState": .stringAttributeType
        ])
        assertAttributes(model, entity: "UsageSummary", expected: [
            "id": .UUIDAttributeType, "itemID": .UUIDAttributeType, "facet": .stringAttributeType,
            "lastUsedAt": .dateAttributeType, "useCount": .integer64AttributeType
        ])
        assertAttributes(model, entity: "UsageExecutionDedup", expected: [
            "id": .UUIDAttributeType, "recordedAt": .dateAttributeType
        ])
        assertAttributes(model, entity: "FileAccessRecord", expected: [
            "id": .UUIDAttributeType, "snapshotID": .UUIDAttributeType, "bytes": .binaryDataAttributeType,
            "bookmark": .binaryDataAttributeType, "localPath": .stringAttributeType
        ])
        for entity in ["CleanupIntent", "RawRecoveryPlan"] {
            assertAttributes(model, entity: entity, expected: [
                "id": .UUIDAttributeType, "schemaVersion": .integer64AttributeType,
                "storeID": .UUIDAttributeType, "generation": .UUIDAttributeType,
                "phase": .stringAttributeType, "payload": .binaryDataAttributeType,
                "createdAt": .dateAttributeType, "updatedAt": .dateAttributeType
            ])
        }
    }

    func testRelationshipsStayInsideCloudConfigurationAndHaveInverses() throws {
        let model = try loadModel()
        let expected: [String: [String: (destination: String, inverse: String, toMany: Bool)]] = [
            "LibraryItem": [
                "capture": ("CaptureSnapshot", "items", false),
                "memo": ("MemoDocument", "item", false),
                // V5: a snippet belongs to any number of collections.
                "collection": ("Collection", "items", true)
            ],
            "CaptureSnapshot": [
                "representations": ("CaptureRepresentation", "snapshot", true),
                "items": ("LibraryItem", "capture", true)
            ],
            "CaptureRepresentation": ["snapshot": ("CaptureSnapshot", "representations", false)],
            "MemoDocument": ["item": ("LibraryItem", "memo", false)],
            "Collection": ["items": ("LibraryItem", "collection", true)]
        ]

        for (entityName, relationships) in expected {
            let entity = try XCTUnwrap(model.entitiesByName[entityName])
            XCTAssertEqual(Set(entity.relationshipsByName.keys), Set(relationships.keys), entityName)
            for (name, expectation) in relationships {
                let relationship = try XCTUnwrap(entity.relationshipsByName[name])
                XCTAssertEqual(relationship.destinationEntity?.name, expectation.destination, "\(entityName).\(name)")
                XCTAssertEqual(relationship.inverseRelationship?.name, expectation.inverse, "\(entityName).\(name)")
                XCTAssertEqual(relationship.isToMany, expectation.toMany, "\(entityName).\(name)")
                XCTAssertFalse(relationship.isOrdered, "\(entityName).\(name)")
                XCTAssertNotEqual(relationship.deleteRule, .denyDeleteRule, "\(entityName).\(name)")
                XCTAssertTrue(relationship.isOptional, "\(entityName).\(name)")
            }
        }
        for name in localEntities {
            XCTAssertTrue(try XCTUnwrap(model.entitiesByName[name]).relationshipsByName.isEmpty, name)
        }
    }

    func testModelUsesManualManagedObjectsWithoutUniquenessConstraints() throws {
        let model = try loadModel()

        for entity in model.entities {
            XCTAssertEqual(entity.managedObjectClassName, "NSManagedObject", entity.name ?? "unnamed")
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty, entity.name ?? "unnamed")
            for property in entity.properties {
                XCTAssertFalse(property.isTransient, "\(entity.name ?? "unnamed").\(property.name)")
            }
        }
    }

    func testOptionalityDefaultsAndDeletionHistoryIdentifiersMatchCloudCompatibilityRules() throws {
        let model = try loadModel()
        let expectedBooleanDefaults: [String: Bool] = [
            "LibraryItem.isFavorite": false,
            "LibraryItem.historyEligible": false
        ]
        let expectedNumericDefaults: [String: Double] = [
            "LibraryItem.copyCount": 0,
            "CaptureRepresentation.itemIndex": 0,
            "CaptureRepresentation.representationIndex": 0,
            "CaptureRepresentation.byteCount": 0,
            "Collection.sortOrder": 0,
            "UsageSummary.useCount": 0
        ]

        for entity in model.entities {
            for attribute in entity.attributesByName.values {
                let key = "\(entity.name ?? "unnamed").\(attribute.name)"
                XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil, key)
                if let expected = expectedBooleanDefaults[key] {
                    XCTAssertEqual((attribute.defaultValue as? NSNumber)?.boolValue, expected, key)
                }
                if let expected = expectedNumericDefaults[key] {
                    XCTAssertEqual((attribute.defaultValue as? NSNumber)?.doubleValue, expected, key)
                }
            }
            let id = try XCTUnwrap(entity.attributesByName["id"], entity.name ?? "unnamed")
            XCTAssertTrue(id.preservesValueInHistoryOnDeletion, entity.name ?? "unnamed")
        }
    }

    func testOnlyPayloadAttributesUseExternalBinaryStorageAndCloudHasNoLocalSecrets() throws {
        let model = try loadModel()
        let externalAttributes = Set(model.entities.flatMap { entity in
            entity.attributesByName.values.compactMap { attribute in
                attribute.allowsExternalBinaryDataStorage ? "\(entity.name!).\(attribute.name)" : nil
            }
        })

        XCTAssertEqual(externalAttributes, [
            "CaptureRepresentation.bytes", "MemoDocument.body", "FileAccessRecord.bytes", "FileAccessRecord.bookmark",
            "CleanupIntent.payload", "RawRecoveryPlan.payload"
        ])

        let cloudAttributeNames = Set(try XCTUnwrap(model.entities(forConfigurationName: "CloudContent"))
            .flatMap { $0.attributesByName.keys })
        XCTAssertFalse(cloudAttributeNames.contains("bookmark"))
        XCTAssertFalse(cloudAttributeNames.contains("localPath"))
        XCTAssertFalse(cloudAttributeNames.contains("path"))
        XCTAssertFalse(cloudAttributeNames.contains("fileName"))
    }

    func testRequiredLookupIndexesArePresent() throws {
        let model = try loadModel()
        let expected: [String: Set<String>] = [
            "LibraryItem": ["id:ascending", "captureID:ascending", "memoID:ascending", "collectionID:ascending",
                            "lastCopiedAt:descending,id:ascending"],
            "CaptureSnapshot": ["id:ascending", "digest:ascending"],
            "CaptureRepresentation": [
                "id:ascending", "snapshotID:ascending,itemIndex:ascending,representationIndex:ascending"
            ],
            "MemoDocument": ["id:ascending", "itemID:ascending"],
            "Collection": ["id:ascending"],
            "ItemDeletionMarker": ["id:ascending"],
            "FacetDeletionMarker": ["id:ascending", "itemID:ascending,facet:ascending,generationID:ascending"],
            "StoreIdentity": ["id:ascending"],
            "UsageSummary": ["id:ascending", "itemID:ascending,facet:ascending"],
            "UsageExecutionDedup": ["id:ascending", "recordedAt:ascending,id:ascending"],
            "FileAccessRecord": ["id:ascending"],
            "CleanupIntent": ["id:ascending", "phase:ascending,updatedAt:ascending"],
            "RawRecoveryPlan": ["id:ascending", "phase:ascending,updatedAt:ascending"]
        ]

        for (entityName, requiredIndexes) in expected {
            let entity = try XCTUnwrap(model.entitiesByName[entityName])
            let actualIndexes = Set(entity.indexes.map { index in
                index.elements.map { element in
                    "\(element.propertyName ?? "missing"):\(element.isAscending ? "ascending" : "descending")"
                }.joined(separator: ",")
            })
            XCTAssertTrue(requiredIndexes.isSubset(of: actualIndexes),
                          "\(entityName) is missing \(requiredIndexes.subtracting(actualIndexes).sorted())")
        }
    }

    func testV5ChangesOnlyTheItemsCollectionsAndSupportsInferredMigrationFromEveryPriorModel() throws {
        let current = try loadModel()
        let directory = try XCTUnwrap(Bundle(for: PersistenceController.self)
            .url(forResource: "Keeptide", withExtension: "momd"))
        for version in 1...4 {
            let prior = try XCTUnwrap(NSManagedObjectModel(contentsOf:
                directory.appendingPathComponent("KeeptideV\(version).mom")))
            _ = try NSMappingModel.inferredMappingModel(forSourceModel: prior, destinationModel: current)
        }
        let v4 = try XCTUnwrap(NSManagedObjectModel(contentsOf:
            directory.appendingPathComponent("KeeptideV4.mom")))
        for entity in cloudEntities.union(localEntities) where entity != "LibraryItem" {
            XCTAssertEqual(v4.entityVersionHashesByName[entity], current.entityVersionHashesByName[entity],
                           "V5 changed entity \(entity)")
        }
        // LibraryItem changes only in its collection relationship, which becomes to-many. The collectionID scalar
        // and its index stay one more version, as the source of the membership backfill.
        let before = try XCTUnwrap(v4.entitiesByName["LibraryItem"])
        let after = try XCTUnwrap(current.entitiesByName["LibraryItem"])
        XCTAssertEqual(Set(before.attributesByName.keys), Set(after.attributesByName.keys))
        XCTAssertEqual(Set(before.relationshipsByName.keys), Set(after.relationshipsByName.keys))
        XCTAssertFalse(try XCTUnwrap(before.relationshipsByName["collection"]).isToMany)
        XCTAssertTrue(try XCTUnwrap(after.relationshipsByName["collection"]).isToMany)
        XCTAssertNotNil(after.attributesByName["collectionID"])
    }

    func testEveryPriorDiskStoreMigratesToV5AndReopensWithStableIdentity() async throws {
        let modelDirectory = try XCTUnwrap(Bundle(for: PersistenceController.self)
            .url(forResource: "Keeptide", withExtension: "momd"))
        for version in 1...4 {
            let prior = try XCTUnwrap(NSManagedObjectModel(contentsOf:
                modelDirectory.appendingPathComponent("KeeptideV\(version).mom")))
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Keeptide-V\(version)-to-V5-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let seed = NSPersistentContainer(name: "Keeptide", managedObjectModel: prior)
            let coordinator = seed.persistentStoreCoordinator
            let options: [AnyHashable: Any] = [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ]
            let content = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: "CloudContent",
                at: directory.appendingPathComponent("Content.sqlite"),
                options: options
            )
            let local = try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: "LocalState",
                at: directory.appendingPathComponent("Local.sqlite"),
                options: options
            )
            let expected = try seedMigrationFixture(
                version: version,
                contentStore: content,
                container: seed
            )
            try coordinator.remove(content)
            try coordinator.remove(local)

            let migrated = try PersistenceController(directory: directory)
            let identity = try await migrated.identity()
            XCTAssertEqual(identity, expected.identity, "V\(version) identity changed during migration")
            XCTAssertEqual(migrated.runtime.safety, expected.safety, "V\(version) safety state changed during migration")
            let migratedRecords = try await readMigrationFixture(from: migrated, expected: expected)
            XCTAssertEqual(migratedRecords, expected.records, "V\(version) records changed during migration")
            let lifecycleRows = try await insertLifecycleRows(into: migrated, version: version)
            try await migrated.close()

            let reopened = try PersistenceController(directory: directory)
            let reopenedIdentity = try await reopened.identity()
            XCTAssertEqual(reopenedIdentity, expected.identity, "V\(version) identity changed after reopen")
            XCTAssertEqual(reopened.runtime.safety, expected.safety, "V\(version) safety state changed after reopen")
            let reopenedRecords = try await readMigrationFixture(from: reopened, expected: expected)
            XCTAssertEqual(
                reopenedRecords,
                expected.records,
                "V\(version) records changed after reopen"
            )
            let reopenedLifecycleRows = try await readLifecycleRows(from: reopened)
            XCTAssertEqual(
                reopenedLifecycleRows,
                lifecycleRows,
                "V\(version) V4 lifecycle rows changed after reopen"
            )
            try await reopened.close()
        }
    }

    private func seedMigrationFixture(
        version: Int,
        contentStore: NSPersistentStore,
        container: NSPersistentContainer
    ) throws -> MigrationFixture {
        let storeID = try XCTUnwrap(UUID(uuidString: contentStore.identifier))
        let identity = StoreIdentity(storeID: storeID, generation: UUID())
        let safety = StoreSafetyState.active
        let records = MigrationRecords(
            collectionID: UUID(),
            collectionName: "V\(version) migration collection",
            collectionColor: "blue",
            collectionSortOrder: Double(version) + 0.5,
            usageID: UUID(),
            usageItemID: UUID(),
            usageFacet: ContentFacet.memo.rawValue,
            usageLastUsedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(version)),
            usageCount: Int64(40 + version)
        )
        let context = container.newBackgroundContext()
        try context.performAndWait {
            let identityObject = NSEntityDescription.insertNewObject(forEntityName: "StoreIdentity", into: context)
            identityObject.setValue(identity.storeID, forKey: "id")
            identityObject.setValue(identity.generation, forKey: "generation")
            identityObject.setValue(safety.rawValue, forKey: "safetyState")

            let collection = NSEntityDescription.insertNewObject(forEntityName: "Collection", into: context)
            collection.setValue(records.collectionID, forKey: "id")
            collection.setValue(records.collectionName, forKey: "name")
            collection.setValue(records.collectionColor, forKey: "color")
            collection.setValue(records.collectionSortOrder, forKey: "sortOrder")

            let usage = NSEntityDescription.insertNewObject(forEntityName: "UsageSummary", into: context)
            usage.setValue(records.usageID, forKey: "id")
            usage.setValue(records.usageItemID, forKey: "itemID")
            usage.setValue(records.usageFacet, forKey: "facet")
            usage.setValue(records.usageLastUsedAt, forKey: "lastUsedAt")
            usage.setValue(records.usageCount, forKey: "useCount")
            try context.save()
            context.reset()
        }
        return MigrationFixture(identity: identity, safety: safety, records: records)
    }

    private func readMigrationFixture(
        from controller: PersistenceController,
        expected: MigrationFixture
    ) async throws -> MigrationRecords {
        try await controller.perform { context in
            let collectionRequest = NSFetchRequest<NSManagedObject>(entityName: "Collection")
            collectionRequest.predicate = NSPredicate(format: "id == %@", expected.records.collectionID as NSUUID)
            collectionRequest.fetchLimit = 2
            let collections = try context.fetch(collectionRequest)
            guard collections.count == 1, let collection = collections.first else { throw StoreError.corruptStore }

            let usageRequest = NSFetchRequest<NSManagedObject>(entityName: "UsageSummary")
            usageRequest.predicate = NSPredicate(format: "id == %@", expected.records.usageID as NSUUID)
            usageRequest.fetchLimit = 2
            let usages = try context.fetch(usageRequest)
            guard usages.count == 1, let usage = usages.first,
                  let collectionID = collection.value(forKey: "id") as? UUID,
                  let collectionName = collection.value(forKey: "name") as? String,
                  let collectionColor = collection.value(forKey: "color") as? String,
                  let collectionSortOrder = collection.value(forKey: "sortOrder") as? Double,
                  let usageID = usage.value(forKey: "id") as? UUID,
                  let usageItemID = usage.value(forKey: "itemID") as? UUID,
                  let usageFacet = usage.value(forKey: "facet") as? String,
                  let usageLastUsedAt = usage.value(forKey: "lastUsedAt") as? Date,
                  let usageCount = usage.value(forKey: "useCount") as? Int64 else {
                throw StoreError.corruptStore
            }
            return MigrationRecords(
                collectionID: collectionID,
                collectionName: collectionName,
                collectionColor: collectionColor,
                collectionSortOrder: collectionSortOrder,
                usageID: usageID,
                usageItemID: usageItemID,
                usageFacet: usageFacet,
                usageLastUsedAt: usageLastUsedAt,
                usageCount: usageCount
            )
        }
    }

    private func insertLifecycleRows(
        into controller: PersistenceController,
        version: Int
    ) async throws -> [LifecycleRow] {
        let now = Date(timeIntervalSince1970: 1_800_100_000 + Double(version))
        let rows = [
            LifecycleRow(entity: "CleanupIntent", id: UUID(), schemaVersion: 1,
                         storeID: controller.runtime.identity.storeID, generation: controller.runtime.identity.generation,
                         phase: CleanupIntentPhase.prepared.rawValue,
                         payload: Data("cleanup-v\(version)".utf8), createdAt: now, updatedAt: now),
            LifecycleRow(entity: "RawRecoveryPlan", id: UUID(), schemaVersion: 1,
                         storeID: controller.runtime.identity.storeID, generation: controller.runtime.identity.generation,
                         phase: RawRecoveryPlanPhase.reconciling.rawValue,
                         payload: Data("recovery-v\(version)".utf8), createdAt: now, updatedAt: now)
        ]
        try await controller.perform { context in
            for row in rows {
                let object = NSEntityDescription.insertNewObject(forEntityName: row.entity, into: context)
                object.setValue(row.id, forKey: "id")
                object.setValue(row.schemaVersion, forKey: "schemaVersion")
                object.setValue(row.storeID, forKey: "storeID")
                object.setValue(row.generation, forKey: "generation")
                object.setValue(row.phase, forKey: "phase")
                object.setValue(row.payload, forKey: "payload")
                object.setValue(row.createdAt, forKey: "createdAt")
                object.setValue(row.updatedAt, forKey: "updatedAt")
            }
            try context.save()
            context.reset()
        }
        return rows
    }

    private func readLifecycleRows(from controller: PersistenceController) async throws -> [LifecycleRow] {
        try await controller.perform { context in
            try ["CleanupIntent", "RawRecoveryPlan"].map { entity in
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.fetchLimit = 2
                let matches = try context.fetch(request)
                guard matches.count == 1, let object = matches.first,
                      let id = object.value(forKey: "id") as? UUID,
                      let schemaVersion = object.value(forKey: "schemaVersion") as? Int64,
                      let storeID = object.value(forKey: "storeID") as? UUID,
                      let generation = object.value(forKey: "generation") as? UUID,
                      let phase = object.value(forKey: "phase") as? String,
                      let payload = object.value(forKey: "payload") as? Data,
                      let createdAt = object.value(forKey: "createdAt") as? Date,
                      let updatedAt = object.value(forKey: "updatedAt") as? Date else {
                    throw StoreError.corruptStore
                }
                return LifecycleRow(entity: entity, id: id, schemaVersion: schemaVersion,
                                    storeID: storeID, generation: generation, phase: phase,
                                    payload: payload, createdAt: createdAt, updatedAt: updatedAt)
            }
        }
    }

    private func loadModel() throws -> NSManagedObjectModel {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Keeptide", withExtension: "momd"))
        return try XCTUnwrap(NSManagedObjectModel(contentsOf: url))
    }

    private func assertAttributes(
        _ model: NSManagedObjectModel,
        entity name: String,
        expected: [String: NSAttributeType],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let entity = model.entitiesByName[name] else {
            XCTFail("Missing entity \(name)", file: file, line: line)
            return
        }
        XCTAssertEqual(Set(entity.attributesByName.keys), Set(expected.keys), name, file: file, line: line)
        for (attributeName, type) in expected {
            XCTAssertEqual(entity.attributesByName[attributeName]?.attributeType, type,
                           "\(name).\(attributeName)", file: file, line: line)
        }
    }
}

private struct MigrationFixture: Sendable {
    let identity: StoreIdentity
    let safety: StoreSafetyState
    let records: MigrationRecords
}

private struct MigrationRecords: Equatable, Sendable {
    let collectionID: UUID
    let collectionName: String
    let collectionColor: String
    let collectionSortOrder: Double
    let usageID: UUID
    let usageItemID: UUID
    let usageFacet: String
    let usageLastUsedAt: Date
    let usageCount: Int64
}

private struct LifecycleRow: Equatable, Sendable {
    let entity: String
    let id: UUID
    let schemaVersion: Int64
    let storeID: UUID
    let generation: UUID
    let phase: String
    let payload: Data
    let createdAt: Date
    let updatedAt: Date
}
