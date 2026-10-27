import CoreData
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class FileRelocationPrivacyTests: XCTestCase {
    func testV2LocalReferencePersistsOnlyOpaqueCloudDescriptorAndResolvesBoundLocalBytes() async throws {
        let store = try makeStore()
        let localBytes = Data("file:///Users/example/Documents/Quarterly Plan.pdf".utf8)
        let token = Data(repeating: 0xa7, count: 32)
        let fixture = try makeLocalReference(version: 2, localBytes: localBytes, cloudByteCount: 0, cloudDigest: token)
        let accessStore = FileAccessStore(controller: store)

        try await accessStore.put(
            LocalFileAccess(
                id: fixture.representation.id,
                snapshotID: fixture.capture.id,
                bytes: localBytes,
                bookmark: Data([0x01, 0x02]),
                localPath: "/Users/example/Documents/Quarterly Plan.pdf"
            ),
            expecting: store.identity()
        )
        try await ContentStoreFixtures.insert(fixture.item, fixture.capture, into: store)

        let cloudValues = try await cloudDescriptor(
            snapshotID: fixture.capture.id,
            representationID: fixture.representation.id,
            in: store
        )
        XCTAssertEqual(cloudValues.byteCount, 0)
        XCTAssertEqual(cloudValues.digest, token)
        XCTAssertNil(cloudValues.bytes)
        XCTAssertNotEqual(cloudValues.digest, ContentDigest.sha256(localBytes))
        XCTAssertNotEqual(cloudValues.byteCount, Int64(localBytes.count))

        let resolved = try await ContentRepository(controller: store).read(
            ContentStoreFixtures.ref(fixture.item, fixture.capture)
        )
        XCTAssertEqual(resolved.integrity, .complete)
        XCTAssertEqual(resolved.representations.first?.bytes, localBytes)
    }

    func testNewV1LocalReferenceWriteIsRejectedWithoutDeletingPreparedLocalAccess() async throws {
        let store = try makeStore()
        let localBytes = Data("file:///Synthetic/legacy-new-write.txt".utf8)
        let fixture = try makeLocalReference(
            version: 1,
            localBytes: localBytes,
            cloudByteCount: Int64(localBytes.count),
            cloudDigest: ContentDigest.sha256(localBytes)
        )
        let access = LocalFileAccess(
            id: fixture.representation.id,
            snapshotID: fixture.capture.id,
            bytes: localBytes,
            bookmark: nil,
            localPath: "/Synthetic/legacy-new-write.txt"
        )
        let accessStore = FileAccessStore(controller: store)
        try await accessStore.put(access, expecting: store.identity())

        do {
            try await ContentStoreFixtures.insert(fixture.item, fixture.capture, into: store)
            XCTFail("A new local reference used the path-derived v1 cloud descriptor")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidTransaction)
        }
        let storedAccess = try await accessStore.read(representationID: access.id)
        XCTAssertEqual(storedAccess, access)
    }

    func testLocalEnvelopeDetectsPostWriteCorruptionBeforeContentCommit() async throws {
        let store = try makeStore()
        let value = LocalFileAccess(
            id: UUID(),
            snapshotID: UUID(),
            bytes: Data("file:///Synthetic/envelope.txt".utf8),
            bookmark: Data([0x0a]),
            localPath: "/Synthetic/envelope.txt"
        )
        let accessStore = FileAccessStore(controller: store)
        try await accessStore.put(value, expecting: store.identity())

        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(format: "id == %@", value.id as NSUUID)
            let row = try XCTUnwrap(context.fetch(request).first)
            let persisted = try XCTUnwrap(row.value(forKey: "bytes") as? Data)
            var corrupted = [UInt8](persisted)
            corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0xff
            row.setValue(Data(corrupted), forKey: "bytes")
            try context.save()
            context.reset()
        }

        do {
            _ = try await accessStore.read(representationID: value.id)
            XCTFail("Corrupted LocalState bytes were returned as a valid file reference")
        } catch {
            XCTAssertEqual(error as? StoreError, .corruptStore)
        }
    }

    func testLocalEnvelopeRejectsRepresentationSwapAndSnapshotRebinding() async throws {
        let store = try makeStore()
        let accessStore = FileAccessStore(controller: store)
        let sharedSnapshotID = UUID()
        let first = LocalFileAccess(
            id: UUID(),
            snapshotID: sharedSnapshotID,
            bytes: Data("file:///Synthetic/first.txt".utf8)
        )
        let second = LocalFileAccess(
            id: UUID(),
            snapshotID: sharedSnapshotID,
            bytes: Data("file:///Synthetic/second.txt".utf8)
        )
        let rebound = LocalFileAccess(
            id: UUID(),
            snapshotID: UUID(),
            bytes: Data("file:///Synthetic/rebound.txt".utf8)
        )
        let identity = try await store.identity()
        try await accessStore.put(first, expecting: identity)
        try await accessStore.put(second, expecting: identity)
        try await accessStore.put(rebound, expecting: identity)

        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(
                format: "id IN %@",
                [first.id, second.id, rebound.id].map { $0 as NSUUID }
            )
            let rows = try context.fetch(request)
            let firstRow = try XCTUnwrap(rows.first { ($0.value(forKey: "id") as? UUID) == first.id })
            let secondRow = try XCTUnwrap(rows.first { ($0.value(forKey: "id") as? UUID) == second.id })
            let reboundRow = try XCTUnwrap(rows.first { ($0.value(forKey: "id") as? UUID) == rebound.id })
            let firstEnvelope = Data(try XCTUnwrap(firstRow.value(forKey: "bytes") as? Data))
            let secondEnvelope = Data(try XCTUnwrap(secondRow.value(forKey: "bytes") as? Data))
            firstRow.setValue(secondEnvelope, forKey: "bytes")
            secondRow.setValue(firstEnvelope, forKey: "bytes")
            reboundRow.setValue(UUID(), forKey: "snapshotID")
            try context.save()
            context.reset()
        }

        for representationID in [first.id, second.id, rebound.id] {
            do {
                _ = try await accessStore.read(representationID: representationID)
                XCTFail("A LocalState envelope was accepted under a different representation or snapshot binding")
            } catch {
                XCTAssertEqual(error as? StoreError, .corruptStore)
            }
        }
    }

    func testGenericPutCannotRebindArbitraryBytesToCommittedV2LocalReference() async throws {
        let store = try makeStore()
        let originalBytes = Data("file:///Synthetic/original-restored.txt".utf8)
        let fixture = try makeLocalReference(
            version: 2,
            localBytes: originalBytes,
            cloudByteCount: 0,
            cloudDigest: Data(repeating: 0x2d, count: 32)
        )
        try await insertCommittedCapture(fixture.capture, item: fixture.item, into: store)

        let accessStore = FileAccessStore(controller: store)
        do {
            try await accessStore.put(
                LocalFileAccess(
                    id: fixture.representation.id,
                    snapshotID: fixture.capture.id,
                    bytes: Data("file:///Synthetic/attacker-selected.txt".utf8)
                ),
                expecting: store.identity()
            )
            XCTFail("Generic put rebound arbitrary bytes to a restored v2 local reference")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let rebound = try await accessStore.read(representationID: fixture.representation.id)
        XCTAssertNil(rebound)
    }

    func testLegacyV1LocalReferenceReadsLocallyButArchiveRefusesGuessableDescriptor() async throws {
        let store = try makeStore()
        let localBytes = Data("file:///Users/example/Documents/Legacy Secret.pdf".utf8)
        let legacyDigest = ContentDigest.sha256(localBytes)
        let fixture = try makeLocalReference(
            version: 1,
            localBytes: localBytes,
            cloudByteCount: Int64(localBytes.count),
            cloudDigest: legacyDigest
        )
        try await insertLegacy(fixture.capture, item: fixture.item, localBytes: localBytes, into: store)

        let resolved = try await ContentRepository(controller: store).read(
            ContentStoreFixtures.ref(fixture.item, fixture.capture)
        )
        XCTAssertEqual(resolved.integrity, .complete)
        XCTAssertEqual(resolved.representations.first?.bytes, localBytes)

        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        do {
            _ = try await reader.begin(SnapshotRequest(permit: permit))
            XCTFail("A legacy path-derived descriptor entered a portable archive")
        } catch {
            XCTAssertEqual(error as? StoreError, .operationDenied)
        }
    }

    func testMissingV2LocalStateRequiresRelocationAndCloudDescriptorCannotConfirmCandidatePaths() async throws {
        let store = try makeStore()
        let localBytes = Data("file:///Users/example/Documents/Restored.pdf".utf8)
        let token = Data(repeating: 0x5c, count: 32)
        let fixture = try makeLocalReference(version: 2, localBytes: localBytes, cloudByteCount: 0, cloudDigest: token)
        let accessStore = FileAccessStore(controller: store)
        try await accessStore.put(
            LocalFileAccess(id: fixture.representation.id, snapshotID: fixture.capture.id, bytes: localBytes),
            expecting: store.identity()
        )
        try await ContentStoreFixtures.insert(fixture.item, fixture.capture, into: store)
        try await accessStore.remove(
            representationID: fixture.representation.id,
            permit: StoreSafetyGate(controller: store).permit(.maintenance)
        )

        let restored = try await ContentRepository(controller: store).read(
            ContentStoreFixtures.ref(fixture.item, fixture.capture)
        )
        XCTAssertEqual(restored.integrity, .requiresRelocation)
        XCTAssertTrue(restored.representations.isEmpty)

        let candidatePaths = [
            "file:///Users/example/Documents/Restored.pdf",
            "file:///Users/example/Desktop/Restored.pdf",
            "/Users/example/Documents/Restored.pdf"
        ].map { Data($0.utf8) }
        XCTAssertFalse(candidatePaths.contains { ContentDigest.sha256($0) == token })
        XCTAssertFalse(candidatePaths.contains { Int64($0.count) == fixture.representation.byteCount })
    }

    func testDiscardPreparedRemovesOnlyUncommittedRowsForTheExactSnapshot() async throws {
        let store = try makeStore()
        let accessStore = FileAccessStore(controller: store)
        let identity = try await store.identity()
        let committedBytes = Data("file:///Synthetic/committed.txt".utf8)
        let fixture = try makeLocalReference(
            version: 2,
            localBytes: committedBytes,
            cloudByteCount: 0,
            cloudDigest: Data(repeating: 0x19, count: 32)
        )
        let preparedID = UUID()
        let foreignID = UUID()
        let prepared = LocalFileAccess(id: preparedID, snapshotID: fixture.capture.id, bytes: Data("prepared".utf8))
        let foreign = LocalFileAccess(id: foreignID, snapshotID: UUID(), bytes: Data("foreign".utf8))
        try await accessStore.put(
            LocalFileAccess(
                id: fixture.representation.id,
                snapshotID: fixture.capture.id,
                bytes: committedBytes
            ),
            expecting: identity
        )
        try await accessStore.put(prepared, expecting: identity)
        try await accessStore.put(foreign, expecting: identity)
        try await ContentStoreFixtures.insert(fixture.item, fixture.capture, into: store)

        do {
            try await accessStore.discardPrepared(
                [fixture.representation.id, preparedID],
                snapshotID: fixture.capture.id,
                expecting: identity
            )
            XCTFail("Cleanup deleted or ignored a committed local reference")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let committedAfterMixedCleanup = try await accessStore.read(representationID: fixture.representation.id)
        let preparedAfterMixedCleanup = try await accessStore.read(representationID: preparedID)
        XCTAssertNotNil(committedAfterMixedCleanup)
        XCTAssertEqual(preparedAfterMixedCleanup, prepared)

        do {
            try await accessStore.discardPrepared(
                [foreignID],
                snapshotID: fixture.capture.id,
                expecting: identity
            )
            XCTFail("Cleanup removed a row belonging to another snapshot")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let foreignAfterRejectedCleanup = try await accessStore.read(representationID: foreignID)
        XCTAssertEqual(foreignAfterRejectedCleanup, foreign)

        try await accessStore.discardPrepared(
            [preparedID],
            snapshotID: fixture.capture.id,
            expecting: identity
        )
        let discarded = try await accessStore.read(representationID: preparedID)
        let committedAfterCleanup = try await accessStore.read(representationID: fixture.representation.id)
        XCTAssertNil(discarded)
        XCTAssertNotNil(committedAfterCleanup)
    }

    private func makeLocalReference(
        version: Int,
        localBytes: Data,
        cloudByteCount: Int64,
        cloudDigest: Data
    ) throws -> (capture: CaptureValue, item: ItemValue, representation: RepresentationValue) {
        let captureID = UUID()
        let representation = RepresentationValue(
            snapshotID: captureID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: cloudByteCount,
            digest: cloudDigest,
            bytes: nil
        )
        let manifest = CaptureManifest(
            version: version,
            itemCount: 1,
            entries: [ManifestEntry(representation)]
        )
        let capture = CaptureValue(
            id: captureID,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: [representation]
        )
        return (capture, ContentStoreFixtures.item(capture), representation)
    }

    private func insertLegacy(
        _ capture: CaptureValue,
        item: ItemValue,
        localBytes: Data,
        into store: PersistenceController
    ) async throws {
        try await store.perform { context in
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
            let local = NSEntityDescription.insertNewObject(forEntityName: "FileAccessRecord", into: context)
            local.setValue(capture.representations[0].id, forKey: "id")
            local.setValue(capture.id, forKey: "snapshotID")
            local.setValue(localBytes, forKey: "bytes")
            try context.save()
            context.reset()
        }
    }

    private func insertCommittedCapture(
        _ capture: CaptureValue,
        item: ItemValue,
        into store: PersistenceController
    ) async throws {
        try await store.perform { context in
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

    private func cloudDescriptor(
        snapshotID: UUID,
        representationID: UUID,
        in store: PersistenceController
    ) async throws -> (byteCount: Int64, digest: Data, bytes: Data?) {
        try await store.perform { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(
                format: "snapshotID == %@ AND id == %@",
                snapshotID as NSUUID,
                representationID as NSUUID
            )
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["byteCount", "digest", "bytes"]
            let row = try XCTUnwrap(context.fetch(request).first)
            return (
                try XCTUnwrap(row["byteCount"] as? Int64),
                try XCTUnwrap(row["digest"] as? Data),
                row["bytes"] as? Data
            )
        }
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-FileRelocationPrivacyTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock {
            try await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        return store
    }
}
