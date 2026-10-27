import CoreData
import XCTest
@testable import Keeptide

final class StoredRecordsTests: XCTestCase {
    func testMissingTrailingRepresentationIsRecoveringAndReturnsNoPartialPayload() async throws {
        try await withController { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("plain".utf8)),
                 ("public.html", Data("<b>plain</b>".utf8))]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)

            try await controller.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
                request.predicate = NSPredicate(
                    format: "snapshotID == %@ AND representationIndex == 1",
                    capture.id as NSUUID
                )
                guard let representation = try context.fetch(request).first else {
                    throw TestFailure.missingFixture
                }
                context.delete(representation)
                try context.save()
                context.reset()
            }

            let resolved = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(resolved.integrity, .recovering)
            XCTAssertTrue(resolved.representations.isEmpty)
            XCTAssertFalse(resolved.isActionable)
        }
    }

    func testCorruptRepresentationBytesRejectTheWholeCapture() async throws {
        try await withController { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("plain".utf8)),
                 ("public.html", Data("<b>plain</b>".utf8))]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)

            try await controller.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
                request.predicate = NSPredicate(
                    format: "snapshotID == %@ AND representationIndex == 1",
                    capture.id as NSUUID
                )
                guard let representation = try context.fetch(request).first else {
                    throw TestFailure.missingFixture
                }
                representation.setValue(Data("wrong".utf8), forKey: "bytes")
                try context.save()
                context.reset()
            }

            let resolved = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(resolved.integrity, .corrupt)
            XCTAssertTrue(resolved.representations.isEmpty)
        }
    }

    func testBrokenRepresentationRelationshipIsCorrupt() async throws {
        try await withController { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("plain".utf8))]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)

            try await controller.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
                request.predicate = NSPredicate(format: "snapshotID == %@", capture.id as NSUUID)
                guard let representation = try context.fetch(request).first else {
                    throw TestFailure.missingFixture
                }
                representation.setValue(nil, forKey: "snapshot")
                try context.save()
                context.reset()
            }

            let resolved = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(resolved.integrity, .corrupt)
            XCTAssertTrue(resolved.representations.isEmpty)
        }
    }

    func testSeparateItemLocalReferenceIsAllOrNothingAcrossRemovalAndRestore() async throws {
        try await withController { controller in
            let portableBytes = Data("independent text item".utf8)
            let localBytes = Data("local file".utf8)
            let captureID = UUID()
            let representations = [
                RepresentationValue(
                    snapshotID: captureID,
                    itemIndex: 0,
                    representationIndex: 0,
                    typeIdentifier: "public.utf8-plain-text",
                    storage: .portable,
                    byteCount: Int64(portableBytes.count),
                    digest: ContentDigest.sha256(portableBytes),
                    bytes: portableBytes
                ),
                RepresentationValue(
                    snapshotID: captureID,
                    itemIndex: 1,
                    representationIndex: 0,
                    typeIdentifier: "public.file-url",
                    storage: .localReference,
                    byteCount: Int64(localBytes.count),
                    digest: ContentDigest.sha256(localBytes),
                    bytes: nil
                )
            ]
            let manifest = CaptureManifest(itemCount: 2, entries: representations.map(ManifestEntry.init))
            let capture = CaptureValue(
                id: captureID,
                manifest: manifest,
                digest: ContentDigest.sha256(try manifest.canonicalData()),
                representations: representations
            )
            let item = ContentStoreFixtures.item(capture)
            let localAccess = LocalFileAccess(
                id: representations[1].id,
                snapshotID: captureID,
                bytes: localBytes
            )
            let fileAccessStore = FileAccessStore(controller: controller)
            let identity = try await controller.identity()
            let maintenancePermit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            try await fileAccessStore.put(localAccess, expecting: identity)
            try await ContentStoreFixtures.insert(item, capture, into: controller)

            let ref = ContentStoreFixtures.ref(item, capture)
            let complete = try await ContentRepository(controller: controller).read(ref)
            XCTAssertEqual(complete.integrity, .complete)
            XCTAssertEqual(complete.representations.map(\.bytes), [portableBytes, localBytes])

            try await fileAccessStore.remove(
                representationID: representations[1].id,
                permit: maintenancePermit
            )
            let missing = try await ContentRepository(controller: controller).read(ref)
            XCTAssertEqual(missing.integrity, .requiresRelocation)
            XCTAssertTrue(missing.representations.isEmpty)
            XCTAssertFalse(missing.isActionable)

            try await fileAccessStore.put(localAccess, expecting: identity)
            let restored = try await ContentRepository(controller: controller).read(ref)
            XCTAssertEqual(restored.integrity, .complete)
            XCTAssertEqual(restored.representations.map(\.bytes), [portableBytes, localBytes])

            try await fileAccessStore.remove(
                representationID: representations[1].id,
                permit: maintenancePermit
            )
            let removedAgain = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(removedAgain.integrity, .requiresRelocation)
            XCTAssertTrue(removedAgain.representations.isEmpty)
        }
    }

    func testSameItemLocalReferenceAndPortableCompanionIsRejectedWithoutPartialRecords() async throws {
        try await withController { controller in
            let portableBytes = Data("file URL companion".utf8)
            let localBytes = Data("local file".utf8)
            let captureID = UUID()
            let representations = [
                RepresentationValue(
                    snapshotID: captureID,
                    itemIndex: 0,
                    representationIndex: 0,
                    typeIdentifier: "public.utf8-plain-text",
                    storage: .portable,
                    byteCount: Int64(portableBytes.count),
                    digest: ContentDigest.sha256(portableBytes),
                    bytes: portableBytes
                ),
                RepresentationValue(
                    snapshotID: captureID,
                    itemIndex: 0,
                    representationIndex: 1,
                    typeIdentifier: "public.file-url",
                    storage: .localReference,
                    byteCount: Int64(localBytes.count),
                    digest: ContentDigest.sha256(localBytes),
                    bytes: nil
                )
            ]
            let manifest = CaptureManifest(itemCount: 1, entries: representations.map(ManifestEntry.init))
            let capture = CaptureValue(
                id: captureID,
                manifest: manifest,
                digest: ContentDigest.sha256(try manifest.canonicalData()),
                representations: representations
            )
            let item = ContentStoreFixtures.item(capture)
            let transaction = StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.capture(capture)), .insert(.item(item))]
            )

            do {
                _ = try await WriteCoordinator(controller: controller).commit(transaction)
                XCTFail("A file-reference item's companion representations must stay local")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }

            let recordsRemain = try await controller.perform { context in
                let captureExists = try StoredRecords.object(.capture(captureID), in: context) != nil
                let itemExists = try StoredRecords.object(.item(item.id), in: context) != nil
                return captureExists || itemExists
            }
            XCTAssertFalse(recordsRemain)
        }
    }

    func testAuthoredPathTextIsPreservedAsPortableContent() async throws {
        try await withController { controller in
            let authored = Data("cp /Users/alice/Documents/report.pdf /tmp/archive.pdf".utf8)
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", authored)]
            ])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)

            let resolved = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(resolved.integrity, .complete)
            XCTAssertEqual(resolved.representations.map(\.bytes), [authored])
            XCTAssertEqual(resolved.representations.map(\.storage), [.portable])
        }
    }

    func testOwnedMemoOldReferenceBecomesStaleAfterAtomicBodyUpdate() async throws {
        try await withController { controller in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("history".utf8))]
            ])
            let itemID = ItemID()
            let memoID = UUID()
            let originalBody = Data("first".utf8)
            let originalMemo = MemoValue(
                id: memoID,
                itemID: itemID,
                bodyMode: .ownedPlainText,
                body: originalBody,
                version: ContentVersion(),
                digest: ContentDigest.sha256(originalBody)
            )
            let item = ItemValue(
                id: itemID,
                title: "memo",
                captureID: capture.id,
                memoID: memoID,
                historyEligible: true
            )
            let insert = StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.capture(capture)), .insert(.memo(originalMemo)), .insert(.item(item))]
            )
            _ = try await WriteCoordinator(controller: controller).commit(insert)

            let originalRef = try await controller.perform { context in
                guard let ref = try StoredRecords.currentRef(itemID: itemID, facet: .memo, in: context) else {
                    throw TestFailure.missingFixture
                }
                return ref
            }
            let fingerprint = try await controller.perform { context in
                try StoredRecords.fingerprint(.memo(memoID), in: context)
            }
            let updatedBody = Data("second".utf8)
            var updatedMemo = originalMemo
            updatedMemo.body = updatedBody
            updatedMemo.version = ContentVersion()
            updatedMemo.digest = ContentDigest.sha256(updatedBody)
            let update = StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.memo(memoID), fingerprint: fingerprint)],
                mutations: [.update(.memo(updatedMemo))]
            )
            _ = try await WriteCoordinator(controller: controller).commit(update)

            do {
                _ = try await ContentRepository(controller: controller).read(originalRef)
                XCTFail("The pre-update memo reference must not resolve")
            } catch {
                XCTAssertEqual(error as? StoreError, .staleReference)
            }
        }
    }

    func testIdenticalContentInDistinctItemsRetainsDistinctIdentity() async throws {
        try await withController { controller in
            let bytes = Data("same".utf8)
            let firstCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", bytes)]
            ])
            let secondCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", bytes)]
            ])
            let firstItem = ContentStoreFixtures.item(firstCapture)
            let secondItem = ContentStoreFixtures.item(secondCapture)
            XCTAssertNotEqual(firstCapture.id, secondCapture.id)
            XCTAssertEqual(firstCapture.digest, secondCapture.digest)

            let transaction = StoreTransaction(
                identity: try await controller.identity(),
                mutations: [
                    .insert(.capture(firstCapture)), .insert(.item(firstItem)),
                    .insert(.capture(secondCapture)), .insert(.item(secondItem))
                ]
            )
            _ = try await WriteCoordinator(controller: controller).commit(transaction)

            let summaries = try await ContentRepository(controller: controller).recent(limit: 10)
            let references = summaries.compactMap(\.history)
            XCTAssertEqual(Set(references.map(\.itemID)), Set([firstItem.id, secondItem.id]))
            XCTAssertEqual(Set(references.map(\.version.rawValue)), Set([firstCapture.id, secondCapture.id]))
            XCTAssertEqual(Set(references.map(\.digest)), Set([firstCapture.digest]))
        }
    }
}

private extension StoredRecordsTests {
    func withController<T: Sendable>(
        _ body: (PersistenceController) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoredRecordsTests-\(UUID().uuidString)", isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let result = try await body(controller)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private enum TestFailure: Error {
    case missingFixture
}
