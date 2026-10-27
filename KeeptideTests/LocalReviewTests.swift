import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class LocalReviewTests: XCTestCase {
    func testCommittedLocalReferenceBytesCannotBeReplacedButAuthorizationCanBeRefreshed() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close() }
        let originalBytes = Data("file:///synthetic/original.txt".utf8)
        let fixture = try makeLocalReferenceFixture(bytes: originalBytes)
        let store = FileAccessStore(controller: controller)
        let original = LocalFileAccess(
            id: fixture.representation.id,
            snapshotID: fixture.capture.id,
            bytes: originalBytes,
            bookmark: Data([0x01]),
            localPath: "/Synthetic/original.txt"
        )
        let identity = try await controller.identity()
        try await store.put(original, expecting: identity)
        try await ContentStoreFixtures.insert(fixture.item, fixture.capture, into: controller)

        let refreshedAuthorization = LocalFileAccess(
            id: original.id,
            snapshotID: original.snapshotID,
            bytes: original.bytes,
            bookmark: Data([0x02, 0x03]),
            localPath: "/Synthetic/relocated.txt"
        )
        try await store.put(refreshedAuthorization, expecting: identity)
        let storedAfterAuthorizationRefresh = try await store.read(representationID: original.id)
        XCTAssertEqual(storedAfterAuthorizationRefresh, refreshedAuthorization)

        let replacement = LocalFileAccess(
            id: original.id,
            snapshotID: original.snapshotID,
            bytes: Data("file:///synthetic/replaced.txt".utf8),
            bookmark: Data([0x04]),
            localPath: "/Synthetic/replaced.txt"
        )
        do {
            try await store.put(replacement, expecting: identity)
            XCTFail("Committed original bytes were replaced")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let storedAfterRejectedReplacement = try await store.read(representationID: original.id)
        XCTAssertEqual(storedAfterRejectedReplacement, refreshedAuthorization)
    }

    func testLegacyCommittedLocalReferenceRejectsBytesThatDoNotMatchStoredIdentity() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close() }
        let committedBytes = Data("file:///synthetic/committed.txt".utf8)
        let fixture = try makeLocalReferenceFixture(bytes: committedBytes, version: 1)
        try await insertLegacy(fixture.capture, item: fixture.item, into: controller)
        let store = FileAccessStore(controller: controller)

        do {
            try await store.put(LocalFileAccess(
                id: fixture.representation.id,
                snapshotID: fixture.capture.id,
                bytes: Data("file:///synthetic/not-the-committed-file.txt".utf8),
                bookmark: nil,
                localPath: "/Synthetic/not-the-committed-file.txt"
            ), expecting: try await controller.identity())
            XCTFail("Bytes that disagree with the committed digest were accepted")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let storedAfterRejectedInitialWrite = try await store.read(representationID: fixture.representation.id)
        XCTAssertNil(storedAfterRejectedInitialWrite)
    }

    func testFileAccessRemovalIsDeniedWhileQuarantinedAndPreservesOriginal() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close() }
        let store = FileAccessStore(controller: controller)
        let value = LocalFileAccess(
            id: UUID(),
            snapshotID: UUID(),
            bytes: Data("synthetic local original".utf8),
            bookmark: nil,
            localPath: "/Synthetic/original"
        )
        let identity = try await controller.identity()
        try await store.put(value, expecting: identity)
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        try await StoreSafetyGate(controller: controller).transition(to: .quarantined, expecting: identity)

        do {
            try await store.remove(representationID: value.id, permit: permit)
            XCTFail("Quarantine allowed destructive local removal")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let storedAfterRejectedRemoval = try await store.read(representationID: value.id)
        XCTAssertEqual(storedAfterRejectedRemoval, value)
    }

    func testFileAccessReadMapsMalformedLocalRowsToCorruptStore() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close() }
        let representationID = UUID()
        try await controller.perform { context in
            let row = NSEntityDescription.insertNewObject(forEntityName: "FileAccessRecord", into: context)
            row.setValue(representationID, forKey: "id")
            row.setValue(Data("synthetic".utf8), forKey: "bytes")
            try context.save()
        }

        do {
            _ = try await FileAccessStore(controller: controller).read(representationID: representationID)
            XCTFail("Malformed local row was returned")
        } catch {
            XCTAssertEqual(error as? StoreError, .corruptStore)
        }
    }

    func testFileAccessRejectsNULInLocalPathWithoutPersistingTheRecord() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close() }
        let store = FileAccessStore(controller: controller)
        let value = LocalFileAccess(
            id: UUID(),
            snapshotID: UUID(),
            bytes: Data("synthetic local original".utf8),
            bookmark: nil,
            localPath: "/Synthetic/before\0after"
        )

        do {
            try await store.put(value, expecting: try await controller.identity())
            XCTFail("A local path that SQLite cannot round-trip was accepted")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidTransaction)
        }
        let stored = try await store.read(representationID: value.id)
        XCTAssertNil(stored)
        try await controller.close()
    }

    private func makeLocalReferenceFixture(
        bytes: Data,
        version: Int = LocalReferencePrivacy.manifestVersion
    ) throws -> (capture: CaptureValue, item: ItemValue, representation: RepresentationValue) {
        let snapshotID = UUID()
        let representation = RepresentationValue(
            snapshotID: snapshotID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: version == 1 ? Int64(bytes.count) : 0,
            digest: version == 1 ? ContentDigest.sha256(bytes) : Data(repeating: 0x47, count: 32),
            bytes: nil
        )
        let manifest = CaptureManifest(
            version: version,
            itemCount: 1,
            entries: [ManifestEntry(representation)]
        )
        let capture = CaptureValue(
            id: snapshotID,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: [representation]
        )
        return (capture, ContentStoreFixtures.item(capture), representation)
    }

    private func insertLegacy(
        _ capture: CaptureValue,
        item: ItemValue,
        into controller: PersistenceController
    ) async throws {
        try await controller.perform { context in
            let captureObject = NSEntityDescription.insertNewObject(
                forEntityName: RecordKey.capture(capture.id).entity,
                into: context
            )
            try StoredRecords.write(.capture(capture), to: captureObject, in: context)
            let itemObject = NSEntityDescription.insertNewObject(
                forEntityName: RecordKey.item(item.id).entity,
                into: context
            )
            try StoredRecords.write(.item(item), to: itemObject, in: context)
            try StoredRecords.link(item, in: context)
            try context.save()
            context.reset()
        }
    }

    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-LocalReviewTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
