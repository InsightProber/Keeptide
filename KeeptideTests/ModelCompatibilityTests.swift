import CoreData
import XCTest
@testable import Keeptide

final class ModelCompatibilityTests: XCTestCase {
    private let cloudEntities: Set<String> = [
        "LibraryItem", "CaptureSnapshot", "CaptureRepresentation", "MemoDocument", "Collection",
        "ItemDeletionMarker", "FacetDeletionMarker"
    ]
    private let localEntities: Set<String> = [
        "StoreIdentity", "UsageSummary", "UsageExecutionDedup", "FileAccessRecord"
    ]

    func testV1ModelHasExactConfigurationBoundariesAndVersionIdentifier() throws {
        let model = try loadModel()

        let customConfigurations = Set(model.configurations).subtracting(["PF_DEFAULT_CONFIGURATION_NAME"])
        XCTAssertEqual(customConfigurations, ["CloudContent", "LocalState"])
        XCTAssertEqual(Set(try XCTUnwrap(model.entities(forConfigurationName: "CloudContent")).compactMap(\.name)), cloudEntities)
        XCTAssertEqual(Set(try XCTUnwrap(model.entities(forConfigurationName: "LocalState")).compactMap(\.name)), localEntities)
        XCTAssertEqual(model.versionIdentifiers, ["1"])
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
            "languageHint": .stringAttributeType, "note": .stringAttributeType,
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
    }

    func testRelationshipsStayInsideCloudConfigurationAndHaveInverses() throws {
        let model = try loadModel()
        let expected: [String: [String: (destination: String, inverse: String, toMany: Bool)]] = [
            "LibraryItem": [
                "capture": ("CaptureSnapshot", "items", false),
                "memo": ("MemoDocument", "item", false),
                "collection": ("Collection", "items", false)
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
            "CaptureRepresentation.bytes", "MemoDocument.body", "FileAccessRecord.bytes", "FileAccessRecord.bookmark"
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
            "LibraryItem": ["id:ascending", "captureID:ascending", "lastCopiedAt:descending,id:ascending"],
            "CaptureSnapshot": ["id:ascending"],
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
            "FileAccessRecord": ["id:ascending"]
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
