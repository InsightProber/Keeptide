import CoreData
import XCTest
@testable import Keeptide

final class ReadReviewTests: XCTestCase {
    func testRecentLimitCountsOnlyVisibleItems() async throws {
        try await withController { controller, _ in
            let olderCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("older".utf8))]
            ])
            var older = ContentStoreFixtures.item(olderCapture)
            older.title = "visible older"
            older.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 100)

            let newerCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("newer".utf8))]
            ])
            var newer = ContentStoreFixtures.item(newerCapture)
            newer.title = "hidden newer"
            newer.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 200)
            newer.historyDeletedAt = Date(timeIntervalSinceReferenceDate: 201)

            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [
                    .insert(.capture(olderCapture)), .insert(.item(older)),
                    .insert(.capture(newerCapture)), .insert(.item(newer))
                ]
            ))

            let summaries = try await ContentRepository(controller: controller).recent(limit: 1)

            XCTAssertEqual(summaries.map(\.itemID), [older.id])
            XCTAssertEqual(summaries.first?.title, "visible older")
        }
    }

    func testRecentStopsBeforeUnrelatedCorruptMetadataOutsideRequiredBatch() async throws {
        try await withController { controller, _ in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("visible".utf8))]
            ])
            var visible = ContentStoreFixtures.item(capture)
            visible.title = "newest visible"
            visible.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 1_000)
            try await ContentStoreFixtures.insert(visible, capture, into: controller)

            let corruptCaptureID = UUID()
            try await controller.perform { context in
                for index in 0..<128 {
                    var hidden = ContentStoreFixtures.item(capture)
                    hidden.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 999 - Double(index))
                    hidden.historyDeletedAt = hidden.lastCopiedAt
                    let object = NSEntityDescription.insertNewObject(
                        forEntityName: "LibraryItem",
                        into: context
                    )
                    try StoredRecords.write(.item(hidden), to: object, in: context)
                }

                var unrelated = ContentStoreFixtures.item(capture)
                unrelated.captureID = corruptCaptureID
                unrelated.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 870)
                let unrelatedObject = NSEntityDescription.insertNewObject(
                    forEntityName: "LibraryItem",
                    into: context
                )
                try StoredRecords.write(.item(unrelated), to: unrelatedObject, in: context)

                for _ in 0..<2 {
                    let duplicate = NSEntityDescription.insertNewObject(
                        forEntityName: "CaptureSnapshot",
                        into: context
                    )
                    duplicate.setValue(corruptCaptureID, forKey: "id")
                    duplicate.setValue(Data("duplicate".utf8), forKey: "digest")
                }
                try context.save()
                context.reset()
            }

            let summaries = try await ContentRepository(controller: controller).recent(limit: 1)

            XCTAssertEqual(summaries.map(\.itemID), [visible.id])
        }
    }

    func testRecentContinuesPastAFullBatchOfHiddenItemsToFillLimit() async throws {
        try await withController { controller, _ in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("shared".utf8))]
            ])
            let anchor = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(anchor, capture, into: controller)
            try await controller.perform { context in
                guard let anchorObject = try StoredRecords.object(.item(anchor.id), in: context) else {
                    throw ReadReviewFailure.missingFixture
                }
                context.delete(anchorObject)

                for index in 0..<129 {
                    var hidden = ContentStoreFixtures.item(capture)
                    hidden.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 1_000 - Double(index))
                    hidden.historyDeletedAt = hidden.lastCopiedAt
                    let object = NSEntityDescription.insertNewObject(
                        forEntityName: "LibraryItem",
                        into: context
                    )
                    try StoredRecords.write(.item(hidden), to: object, in: context)
                }

                for (index, title) in ["first visible", "second visible"].enumerated() {
                    var visible = ContentStoreFixtures.item(capture)
                    visible.title = title
                    visible.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 100 - Double(index))
                    let object = NSEntityDescription.insertNewObject(
                        forEntityName: "LibraryItem",
                        into: context
                    )
                    try StoredRecords.write(.item(visible), to: object, in: context)
                }
                try context.save()
                context.reset()
            }

            let summaries = try await ContentRepository(controller: controller).recent(limit: 2)

            XCTAssertEqual(summaries.map(\.title), ["first visible", "second visible"])
        }
    }

    func testRecentOmitsDuplicateLogicalItemsWithinAndAcrossBatchBoundaries() async throws {
        try await withController { controller, _ in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("shared".utf8))]
            ])
            let anchor = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(anchor, capture, into: controller)
            let expectedID = try await controller.perform { context -> ItemID in
                guard let anchorObject = try StoredRecords.object(.item(anchor.id), in: context) else {
                    throw ReadReviewFailure.missingFixture
                }
                context.delete(anchorObject)

                let withinBatchID = ItemID()
                for timestamp in [1_000.0, 999.0] {
                    var duplicate = ContentStoreFixtures.item(capture, id: withinBatchID)
                    duplicate.lastCopiedAt = Date(timeIntervalSinceReferenceDate: timestamp)
                    let object = NSEntityDescription.insertNewObject(
                        forEntityName: "LibraryItem",
                        into: context
                    )
                    try StoredRecords.write(.item(duplicate), to: object, in: context)
                }

                for index in 0..<125 {
                    var hidden = ContentStoreFixtures.item(capture)
                    hidden.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 998 - Double(index))
                    hidden.historyDeletedAt = hidden.lastCopiedAt
                    let object = NSEntityDescription.insertNewObject(
                        forEntityName: "LibraryItem",
                        into: context
                    )
                    try StoredRecords.write(.item(hidden), to: object, in: context)
                }

                let acrossBatchID = ItemID()
                for timestamp in [873.0, 872.0] {
                    var duplicate = ContentStoreFixtures.item(capture, id: acrossBatchID)
                    duplicate.lastCopiedAt = Date(timeIntervalSinceReferenceDate: timestamp)
                    let object = NSEntityDescription.insertNewObject(
                        forEntityName: "LibraryItem",
                        into: context
                    )
                    try StoredRecords.write(.item(duplicate), to: object, in: context)
                }

                var expected = ContentStoreFixtures.item(capture)
                expected.title = "older valid item"
                expected.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 871)
                let expectedObject = NSEntityDescription.insertNewObject(
                    forEntityName: "LibraryItem",
                    into: context
                )
                try StoredRecords.write(.item(expected), to: expectedObject, in: context)
                try context.save()
                context.reset()
                return expected.id
            }

            let summaries = try await ContentRepository(controller: controller).recent(limit: 1)

            XCTAssertEqual(summaries.map(\.itemID), [expectedID])
        }
    }

    func testItemDeletionMarkerDoesNotConsumeRecentLimit() async throws {
        try await withController { controller, _ in
            let olderCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("older".utf8))]
            ])
            var older = ContentStoreFixtures.item(olderCapture)
            older.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 100)

            let newerCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("newer".utf8))]
            ])
            var newer = ContentStoreFixtures.item(newerCapture)
            newer.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 200)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [
                    .insert(.capture(olderCapture)), .insert(.item(older)),
                    .insert(.capture(newerCapture)), .insert(.item(newer))
                ]
            ))
            let newerID = newer.id
            try await controller.perform { context in
                let marker = NSEntityDescription.insertNewObject(forEntityName: "ItemDeletionMarker", into: context)
                marker.setValue(newerID.rawValue, forKey: "id")
                marker.setValue(Date(timeIntervalSinceReferenceDate: 201), forKey: "deletedAt")
                try context.save()
            }

            let summaries = try await ContentRepository(controller: controller).recent(limit: 1)

            XCTAssertEqual(summaries.map(\.itemID), [older.id])
        }
    }

    func testInheritedMemoWithOwnedFieldsIsCorruptAndReturnsNoCaptureBytes() async throws {
        try await withController { controller, _ in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("original capture".utf8))]
            ])
            let itemID = ItemID()
            let memo = MemoValue(itemID: itemID, bodyMode: .inheritedCapture)
            let item = ItemValue(
                id: itemID,
                captureID: capture.id,
                memoID: memo.id,
                historyEligible: true
            )
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
            ))
            try await controller.perform { context in
                guard let object = try StoredRecords.object(.memo(memo.id), in: context) else {
                    throw ReadReviewFailure.missingFixture
                }
                let edited = Data("user edit".utf8)
                object.setValue(edited, forKey: "body")
                object.setValue(UUID(), forKey: "version")
                object.setValue(ContentDigest.sha256(edited), forKey: "digest")
                try context.save()
            }
            let ref = ContentStoreFixtures.ref(item, capture, facet: .memo)

            let resolved = try await ContentRepository(controller: controller).read(ref)

            XCTAssertEqual(resolved.integrity, .corrupt)
            XCTAssertTrue(resolved.representations.isEmpty)
            XCTAssertFalse(resolved.isActionable)
        }
    }

    func testDuplicateLogicalItemMarkersConvergeToTheLatestDeletion() async throws {
        try await withController { controller, _ in
            let itemID = ItemID()
            let early = Date(timeIntervalSinceReferenceDate: 100)
            let late = Date(timeIntervalSinceReferenceDate: 200)
            try await controller.perform { context in
                for deletedAt in [early, late] {
                    let marker = NSEntityDescription.insertNewObject(
                        forEntityName: "ItemDeletionMarker",
                        into: context
                    )
                    marker.setValue(itemID.rawValue, forKey: "id")
                    marker.setValue(deletedAt, forKey: "deletedAt")
                }
                try context.save()
                context.reset()
            }

            let value = try await controller.perform { context in
                try StoredRecords.value(.itemMarker(itemID), in: context)
            }

            guard case .itemMarker(let marker)? = value else {
                return XCTFail("Duplicate logical markers must remain readable as one deletion")
            }
            XCTAssertEqual(marker.itemID, itemID)
            XCTAssertEqual(marker.deletedAt, late)
        }
    }

    func testMalformedNewerItemDoesNotPreventBrowsingHealthyRecentItems() async throws {
        try await withController { controller, _ in
            let olderCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("older".utf8))]
            ])
            var older = ContentStoreFixtures.item(olderCapture)
            older.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 100)
            let newerCapture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("newer".utf8))]
            ])
            var malformed = ContentStoreFixtures.item(newerCapture)
            malformed.lastCopiedAt = Date(timeIntervalSinceReferenceDate: 200)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [
                    .insert(.capture(olderCapture)), .insert(.item(older)),
                    .insert(.capture(newerCapture)), .insert(.item(malformed))
                ]
            ))
            let malformedID = malformed.id
            try await controller.perform { context in
                guard let object = try StoredRecords.object(.item(malformedID), in: context) else {
                    throw ReadReviewFailure.missingFixture
                }
                object.setValue(nil, forKey: "title")
                try context.save()
            }

            let summaries = try await ContentRepository(controller: controller).recent(limit: 1)

            XCTAssertEqual(summaries.map(\.itemID), [older.id])
        }
    }

    func testPortableDamageTakesPrecedenceOverMissingLocalAccess() async throws {
        try await withController { controller, _ in
            let portable = Data("portable".utf8)
            let local = Data("local-only".utf8)
            let capture = try mixedCapture(portable: portable, local: local)
            let item = ContentStoreFixtures.item(capture)
            let accessStore = FileAccessStore(controller: controller)
            try await accessStore.put(
                LocalFileAccess(
                    id: capture.representations[1].id,
                    snapshotID: capture.id,
                    bytes: local
                ),
                expecting: controller.identity()
            )
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            try await accessStore.remove(
                representationID: capture.representations[1].id,
                permit: StoreSafetyGate(controller: controller).permit(.maintenance)
            )
            let portableID = capture.representations[0].id
            try await setRepresentationBytes(Data("damaged!".utf8), id: portableID, controller: controller)

            let corrupt = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(corrupt.integrity, .corrupt)
            XCTAssertTrue(corrupt.representations.isEmpty)

            try await setRepresentationBytes(nil, id: portableID, controller: controller)
            let recovering = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            XCTAssertEqual(recovering.integrity, .recovering)
            XCTAssertTrue(recovering.representations.isEmpty)
        }
    }

    func testArchiveUsesTheSameCaptureRelationshipValidationAsRead() async throws {
        try await withController { controller, _ in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("history".utf8))]
            ])
            let itemID = ItemID()
            let body = Data("owned memo".utf8)
            let memo = MemoValue(
                itemID: itemID,
                bodyMode: .ownedPlainText,
                body: body,
                version: ContentVersion(),
                digest: ContentDigest.sha256(body)
            )
            let item = ItemValue(
                id: itemID,
                captureID: capture.id,
                memoID: memo.id,
                historyEligible: true
            )
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
            ))
            try await controller.perform { context in
                let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
                request.predicate = NSPredicate(format: "snapshotID == %@", capture.id as NSUUID)
                guard let representation = try context.fetch(request).first else {
                    throw ReadReviewFailure.missingFixture
                }
                representation.setValue(nil, forKey: "snapshot")
                try context.save()
            }

            let ref = ContentStoreFixtures.ref(item, capture)
            let read = try await ContentRepository(controller: controller).read(ref)
            XCTAssertEqual(read.integrity, .corrupt)

            try await controller.perform { context in
                guard let object = try StoredRecords.object(.item(item.id), in: context) else {
                    throw ReadReviewFailure.missingFixture
                }
                object.setValue(Date(timeIntervalSinceReferenceDate: 300), forKey: "historyDeletedAt")
                try context.save()
            }

            let reader = ContentSnapshotReader(controller: controller)
            let permit = try await StoreSafetyGate(controller: controller).permit(.completeArchive)
            let lease = try await reader.begin(SnapshotRequest(permit: permit))
            do {
                _ = try await reader.page(lease, after: nil)
                XCTFail("Archive must reject the same broken capture graph as ordinary reads")
            } catch {
                XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
            }
        }
    }

    func testAdjacentStoredDatesProduceDifferentRecordFingerprints() async throws {
        try await withController { controller, _ in
            let capture = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("payload".utf8))]
            ])
            var item = ContentStoreFixtures.item(capture)
            let timestamp = 1_000_000.0
            item.lastCopiedAt = Date(timeIntervalSinceReferenceDate: timestamp)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let first = try await ContentRepository(controller: controller).recordState(.item(item.id)).fingerprint
            let itemID = item.id
            try await controller.perform { context in
                guard let object = try StoredRecords.object(.item(itemID), in: context) else {
                    throw ReadReviewFailure.missingFixture
                }
                object.setValue(Date(timeIntervalSinceReferenceDate: timestamp.nextUp), forKey: "lastCopiedAt")
                try context.save()
                context.reset()
            }

            let second = try await ContentRepository(controller: controller).recordState(.item(item.id)).fingerprint

            XCTAssertNotEqual(first, second)
        }
    }

    func testCandidateFingerprintIsScopedToTheRequestedDigest() async throws {
        try await withController { controller, _ in
            let first = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("candidate".utf8))]
            ])
            let firstItem = ContentStoreFixtures.item(first)
            try await ContentStoreFixtures.insert(firstItem, first, into: controller)
            let repository = ContentRepository(controller: controller)
            let original = try await repository.candidateFingerprint(digest: first.digest)

            let unrelated = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("unrelated".utf8))]
            ])
            let unrelatedItem = ContentStoreFixtures.item(unrelated)
            try await ContentStoreFixtures.insert(unrelatedItem, unrelated, into: controller)
            let afterUnrelated = try await repository.candidateFingerprint(digest: first.digest)

            let matching = try ContentStoreFixtures.capture([
                [("public.utf8-plain-text", Data("candidate".utf8))]
            ])
            let matchingItem = ContentStoreFixtures.item(matching)
            try await ContentStoreFixtures.insert(matchingItem, matching, into: controller)
            let afterMatching = try await repository.candidateFingerprint(digest: first.digest)

            XCTAssertEqual(afterUnrelated, original)
            XCTAssertNotEqual(afterMatching, original)
        }
    }

    func testCaptureFingerprintRejectsCloudBytesOnLocalReference() async throws {
        try await withController { controller, _ in
            let capture = try mixedCapture(
                portable: Data("portable".utf8),
                local: Data("local-only".utf8)
            )
            let item = ContentStoreFixtures.item(capture)
            try await FileAccessStore(controller: controller).put(
                LocalFileAccess(
                    id: capture.representations[1].id,
                    snapshotID: capture.id,
                    bytes: Data("local-only".utf8)
                ),
                expecting: controller.identity()
            )
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let localReferenceID = capture.representations[1].id
            try await setRepresentationBytes(
                Data("must not be cloud portable".utf8),
                id: localReferenceID,
                controller: controller
            )

            do {
                _ = try await ContentRepository(controller: controller).recordState(.capture(capture.id))
                XCTFail("A local reference with cloud bytes must not produce a valid CAS fingerprint")
            } catch {
                XCTAssertEqual(error as? StoreError, .corruptStore)
            }
        }
    }

    func testMetadataReadsDoNotDependOnExternalPayloadFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadReviewTests-\(UUID().uuidString)", isDirectory: true)
        var controller: PersistenceController? = try PersistenceController(directory: directory)
        do {
            let bytes = syntheticPayload(count: 21 * 1024 * 1024)
            let memoBody = Data(repeating: 0x41, count: 21 * 1024 * 1024)
            let capture = try ContentStoreFixtures.capture([
                [("public.data", bytes)]
            ])
            let itemID = ItemID()
            let memo = MemoValue(
                itemID: itemID,
                bodyMode: .ownedPlainText,
                body: memoBody,
                version: ContentVersion(),
                digest: ContentDigest.sha256(memoBody)
            )
            let item = ItemValue(
                id: itemID,
                title: "metadata remains available",
                captureID: capture.id,
                memoID: memo.id,
                historyEligible: true
            )
            let active = try XCTUnwrap(controller)
            _ = try await WriteCoordinator(controller: active).commit(StoreTransaction(
                identity: try await active.identity(),
                mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
            ))
            let captureFingerprint = try await ContentRepository(controller: active)
                .recordState(.capture(capture.id)).fingerprint
            let memoFingerprint = try await ContentRepository(controller: active)
                .recordState(.memo(memo.id)).fingerprint
            try await active.close()
            controller = nil
            try removeExternalPayloadFiles(in: directory)

            let reopened = try PersistenceController(directory: directory)
            controller = reopened
            let summaries = try await ContentRepository(controller: reopened).recent(limit: 1)
            XCTAssertEqual(summaries.map(\.itemID), [item.id])
            XCTAssertEqual(summaries.first?.title, item.title)
            let reopenedCaptureFingerprint = try await ContentRepository(controller: reopened)
                .recordState(.capture(capture.id)).fingerprint
            let reopenedMemoFingerprint = try await ContentRepository(controller: reopened)
                .recordState(.memo(memo.id)).fingerprint
            XCTAssertEqual(
                reopenedCaptureFingerprint,
                captureFingerprint
            )
            XCTAssertEqual(
                reopenedMemoFingerprint,
                memoFingerprint
            )
            try await reopened.close()
            controller = nil
            try FileManager.default.removeItem(at: directory)
        } catch {
            if let controller { try? await controller.close() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private extension ReadReviewTests {
    func withController<T: Sendable>(
        _ body: (PersistenceController, URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadReviewTests-\(UUID().uuidString)", isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let result = try await body(controller, directory)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func mixedCapture(portable: Data, local: Data) throws -> CaptureValue {
        let id = UUID()
        let representations = [
            RepresentationValue(
                snapshotID: id,
                itemIndex: 0,
                representationIndex: 0,
                typeIdentifier: "public.utf8-plain-text",
                storage: .portable,
                byteCount: Int64(portable.count),
                digest: ContentDigest.sha256(portable),
                bytes: portable
            ),
            RepresentationValue(
                snapshotID: id,
                itemIndex: 1,
                representationIndex: 0,
                typeIdentifier: "public.file-url",
                storage: .localReference,
                byteCount: 0,
                digest: Data(repeating: 0x84, count: 32),
                bytes: nil
            )
        ]
        let manifest = CaptureManifest(
            version: LocalReferencePrivacy.manifestVersion,
            itemCount: 2,
            entries: representations.map(ManifestEntry.init)
        )
        return CaptureValue(
            id: id,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: representations
        )
    }

    func setRepresentationBytes(
        _ bytes: Data?,
        id: UUID,
        controller: PersistenceController
    ) async throws {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            guard let object = try context.fetch(request).first else {
                throw ReadReviewFailure.missingFixture
            }
            object.setValue(bytes, forKey: "bytes")
            try context.save()
            context.reset()
        }
    }

    func removeExternalPayloadFiles(in directory: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw ReadReviewFailure.missingFixture
        }
        let payloads = try enumerator.compactMap { element -> URL? in
            guard let url = element as? URL,
                  url.path.contains("_EXTERNAL_DATA"),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return url
        }
        guard !payloads.isEmpty else { throw ReadReviewFailure.missingFixture }
        for payload in payloads {
            try FileManager.default.removeItem(at: payload)
        }
    }

    func syntheticPayload(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var state: UInt32 = 0x1254_3678
            for index in bytes.indices {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                bytes[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        return data
    }
}

private enum ReadReviewFailure: Error {
    case missingFixture
}
