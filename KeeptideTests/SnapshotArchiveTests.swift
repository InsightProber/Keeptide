import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class SnapshotArchiveTests: XCTestCase {
    func testArchiveNeverExportsLocalReferenceBytesOrPartialExecutableContent() async throws {
        let store = try makeStore()
        let fixture = try makeMixedStorageCapture()
        let item = ContentStoreFixtures.item(fixture.capture)
        let accessStore = FileAccessStore(controller: store)
        try await accessStore.put(LocalFileAccess(
            id: fixture.localRepresentation.id,
            snapshotID: fixture.capture.id,
            bytes: fixture.localBytes
        ))
        try await ContentStoreFixtures.insert(item, fixture.capture, into: store)

        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(permit: permit))
        let page = try await reader.page(lease, after: nil)

        XCTAssertEqual(page.contents.count, 1)
        XCTAssertEqual(page.contents.first?.integrity, .requiresRelocation)
        XCTAssertTrue(page.contents.first?.representations.isEmpty == true)
        XCTAssertFalse(page.contents.first?.isActionable == true)

        let archivedCapture = try XCTUnwrap(page.portableRecords.compactMap { record -> CaptureValue? in
            guard case .capture(let capture) = record, capture.id == fixture.capture.id else { return nil }
            return capture
        }.first)
        XCTAssertEqual(archivedCapture.manifest, fixture.capture.manifest)
        XCTAssertEqual(archivedCapture.representations.count, 2)
        XCTAssertEqual(archivedCapture.representations[0].bytes, fixture.portableBytes)
        XCTAssertEqual(archivedCapture.representations[1].storage, .localReference)
        XCTAssertNil(archivedCapture.representations[1].bytes)
        XCTAssertFalse(page.portableRecords.contains { record in
            guard case .capture(let capture) = record else { return false }
            return capture.representations.contains { $0.bytes == fixture.localBytes }
        })
        XCTAssertTrue(page.portableRecords.contains(.item(item)))
        await reader.end(lease)
    }

    func testBeginRejectsVisibleHistoryWhoseCaptureMetadataIsMissing() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("missing capture".utf8))]
        ])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        try await removeCapture(capture.id, from: store)

        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        do {
            _ = try await reader.begin(SnapshotRequest(permit: permit))
            XCTFail("A visibly eligible history facet was silently omitted")
        } catch {
            XCTAssertEqual(error as? StoreError, .corruptStore)
        }
    }

    func testBeginRejectsVisibleMemoWhoseDocumentMetadataIsMissing() async throws {
        let store = try makeStore()
        let itemID = ItemID()
        let body = Data("memo body".utf8)
        let memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        let item = ItemValue(id: itemID, title: "memo", memoID: memo.id)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(item))]
        ))
        try await store.perform { context in
            guard let object = try StoredRecords.object(.memo(memo.id), in: context) else {
                throw SnapshotArchiveTestFailure.missingFixture
            }
            context.delete(object)
            try context.save()
            context.reset()
        }

        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        do {
            _ = try await reader.begin(SnapshotRequest(permit: permit))
            XCTFail("A visible memo facet was silently omitted")
        } catch {
            XCTAssertEqual(error as? StoreError, .corruptStore)
        }
    }

    func testRecoveringFacetFailsWholeArchivePageInsteadOfReturningPartialPage() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("plain".utf8)),
             ("public.html", Data("<b>plain</b>".utf8))]
        ])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(
                format: "snapshotID == %@ AND representationIndex == 1",
                capture.id as NSUUID
            )
            guard let representation = try context.fetch(request).first else {
                throw SnapshotArchiveTestFailure.missingFixture
            }
            context.delete(representation)
            try context.save()
            context.reset()
        }

        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(permit: permit))
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A recovering facet was emitted as an archive page")
        } catch {
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
        }
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A failed snapshot lease was reusable")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }
    }

    func testCorruptFacetFailsWholeArchivePage() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("original".utf8))]
        ])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
            request.predicate = NSPredicate(format: "snapshotID == %@", capture.id as NSUUID)
            guard let representation = try context.fetch(request).first else {
                throw SnapshotArchiveTestFailure.missingFixture
            }
            representation.setValue(Data("corrupt".utf8), forKey: "bytes")
            try context.save()
            context.reset()
        }

        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(permit: permit))
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A corrupt facet was emitted as an archive page")
        } catch {
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
        }
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A failed snapshot lease was reusable")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }
    }

    func testSoftDeletedHistoryWithMissingCaptureIsExcludedRatherThanBlockingArchive() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("deleted".utf8))]
        ])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        try await store.perform { context in
            guard let object = try StoredRecords.object(.item(item.id), in: context) else {
                throw SnapshotArchiveTestFailure.missingFixture
            }
            var deletedItem = item
            deletedItem.historyDeletedAt = Date()
            try StoredRecords.write(.item(deletedItem), to: object, in: context)
            guard let captureObject = try StoredRecords.object(.capture(capture.id), in: context) else {
                throw SnapshotArchiveTestFailure.missingFixture
            }
            let children = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
            children.predicate = NSPredicate(format: "snapshotID == %@", capture.id as NSUUID)
            try context.fetch(children).forEach(context.delete)
            context.delete(captureObject)
            try context.save()
            context.reset()
        }

        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(permit: permit))
        let page = try await reader.page(lease, after: nil)
        XCTAssertTrue(page.contents.isEmpty)
        XCTAssertTrue(page.portableRecords.isEmpty)
        await reader.end(lease)
    }

    func testTamperedAndReopenedLeasesCannotReadPinnedArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotArchiveTests-\(UUID().uuidString)", isDirectory: true)
        let store = try PersistenceController(directory: directory)
        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(permit: permit))
        let tampered = SnapshotLease(
            leaseID: lease.leaseID,
            identity: lease.identity,
            boundary: Data("tampered".utf8)
        )
        do {
            _ = try await reader.page(tampered, after: nil)
            XCTFail("A tampered lease boundary was accepted")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }

        try await store.close()
        let reopened = try PersistenceController(directory: directory)
        do {
            _ = try await ContentSnapshotReader(controller: reopened).page(lease, after: nil)
            XCTFail("A process-local pinned lease survived reopen")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }
        try await reopened.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testOldMemoGenerationMarkerDoesNotHideReplacementFromReadOrArchive() async throws {
        let store = try makeStore()
        let itemID = ItemID()
        let oldMemoID = UUID()
        let body = Data("replacement memo".utf8)
        let currentMemo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        let item = ItemValue(id: itemID, title: "replacement", memoID: currentMemo.id)
        let marker = FacetDeletionMarkerValue(
            itemID: itemID,
            facet: .memo,
            generationID: oldMemoID
        )
        let gate = StoreSafetyGate(controller: store)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.memo(currentMemo)), .insert(.item(item))]
        ))
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.facetMarker(marker))],
            permit: try await gate.permit(.maintenance)
        ))

        let ref = ContentRef(
            itemID: itemID,
            facet: .memo,
            version: try XCTUnwrap(currentMemo.version),
            digest: try XCTUnwrap(currentMemo.digest)
        )
        let current = try await ContentRepository(controller: store).read(ref)
        XCTAssertEqual(current.integrity, .complete)
        XCTAssertEqual(current.representations.first?.bytes, body)

        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await gate.permit(.completeArchive)
        ))
        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.map(\.ref), [ref])
        XCTAssertTrue(page.portableRecords.contains(.memo(currentMemo)))
        await reader.end(lease)
    }

    func testCurrentMemoGenerationMarkerHidesFacetFromReadAndArchive() async throws {
        let store = try makeStore()
        let itemID = ItemID()
        let body = Data("purged memo".utf8)
        let memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        let item = ItemValue(id: itemID, title: "purged", memoID: memo.id)
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(item))]
        ))
        try await store.perform { context in
            let marker = FacetDeletionMarkerValue(
                itemID: itemID,
                facet: .memo,
                generationID: memo.id
            )
            let object = NSEntityDescription.insertNewObject(forEntityName: "FacetDeletionMarker", into: context)
            try StoredRecords.write(.facetMarker(marker), to: object, in: context)
            try context.save()
            context.reset()
        }

        let ref = ContentRef(
            itemID: itemID,
            facet: .memo,
            version: try XCTUnwrap(memo.version),
            digest: try XCTUnwrap(memo.digest)
        )
        do {
            _ = try await ContentRepository(controller: store).read(ref)
            XCTFail("The marker for the current memo generation was ignored")
        } catch {
            XCTAssertEqual(error as? StoreError, .notFound)
        }

        let gate = StoreSafetyGate(controller: store)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await gate.permit(.completeArchive)
        ))
        let page = try await reader.page(lease, after: nil)
        XCTAssertTrue(page.contents.isEmpty)
        XCTAssertTrue(page.portableRecords.isEmpty)
        await reader.end(lease)
    }

    func testVisibleOwnedMemoArchivesRetainedCaptureAndCollectionGraph() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("retained original".utf8))]
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
        let collection = CollectionValue(name: "Archive collection", color: "blue", sortOrder: 3)
        let item = ItemValue(
            id: itemID,
            title: "memo only",
            captureID: capture.id,
            memoID: memo.id,
            collectionID: collection.id,
            historyEligible: false
        )
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [
                .insert(.capture(capture)), .insert(.memo(memo)),
                .insert(.collection(collection)), .insert(.item(item))
            ]
        ))

        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await StoreSafetyGate(controller: store).permit(.completeArchive)
        ))
        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.map(\.ref.facet), [.memo])
        XCTAssertTrue(page.portableRecords.contains(.item(item)))
        XCTAssertTrue(page.portableRecords.contains(.capture(capture)))
        XCTAssertTrue(page.portableRecords.contains(.memo(memo)))
        XCTAssertTrue(page.portableRecords.contains(.collection(collection)))
        await reader.end(lease)
    }

    func testVisibleHistoryArchivesSoftDeletedMemoWithoutDanglingItemReference() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("visible history".utf8))]
        ])
        let itemID = ItemID()
        let body = Data("deleted memo body".utf8)
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let memo = MemoValue(
            itemID: itemID,
            title: "deleted memo",
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body),
            note: "retained state",
            deletedAt: deletedAt,
            purgeAfter: deletedAt.addingTimeInterval(86_400)
        )
        let item = ItemValue(
            id: itemID,
            title: "history",
            captureID: capture.id,
            memoID: memo.id,
            historyEligible: true
        )
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
        ))

        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await StoreSafetyGate(controller: store).permit(.completeArchive)
        ))
        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.map(\.ref.facet), [.history])
        XCTAssertTrue(page.portableRecords.contains(.item(item)))
        XCTAssertTrue(page.portableRecords.contains(.capture(capture)))
        XCTAssertTrue(page.portableRecords.contains(.memo(memo)))
        await reader.end(lease)
    }

    func testMissingHiddenCaptureAttachmentInvalidatesVisibleMemoLease() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("hidden history".utf8))]
        ])
        let itemID = ItemID()
        let body = Data("visible memo".utf8)
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
            historyEligible: false
        )
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
        ))
        try await removeCapture(capture.id, from: store)

        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await StoreSafetyGate(controller: store).permit(.completeArchive)
        ))
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A visible item was archived with a dangling retained capture")
        } catch {
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
        }
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A graph-incomplete snapshot lease remained valid")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }
    }

    func testCorruptSoftDeletedOwnedMemoInvalidatesVisibleHistoryLease() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("visible history".utf8))]
        ])
        let itemID = ItemID()
        let body = Data("valid memo".utf8)
        let memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body),
            deletedAt: Date()
        )
        let item = ItemValue(
            id: itemID,
            captureID: capture.id,
            memoID: memo.id,
            historyEligible: true
        )
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
        ))
        try await store.perform { context in
            guard let object = try StoredRecords.object(.memo(memo.id), in: context) else {
                throw SnapshotArchiveTestFailure.missingFixture
            }
            object.setValue(Data([0xFF, 0xFE]), forKey: "body")
            try context.save()
            context.reset()
        }

        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await StoreSafetyGate(controller: store).permit(.completeArchive)
        ))
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A corrupt retained owned memo was exported")
        } catch {
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
        }
        do {
            _ = try await reader.page(lease, after: nil)
            XCTFail("A payload-invalid snapshot lease remained valid")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }
    }
}

private extension SnapshotArchiveTests {
    struct MixedStorageFixture {
        let capture: CaptureValue
        let portableBytes: Data
        let localBytes: Data
        let localRepresentation: RepresentationValue
    }

    func makeMixedStorageCapture() throws -> MixedStorageFixture {
        let captureID = UUID()
        let portableBytes = Data("portable text".utf8)
        let localBytes = Data("local file bytes".utf8)
        let portable = RepresentationValue(
            snapshotID: captureID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.utf8-plain-text",
            storage: .portable,
            byteCount: Int64(portableBytes.count),
            digest: ContentDigest.sha256(portableBytes),
            bytes: portableBytes
        )
        let local = RepresentationValue(
            snapshotID: captureID,
            itemIndex: 1,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: Int64(localBytes.count),
            digest: ContentDigest.sha256(localBytes),
            bytes: nil
        )
        let representations = [portable, local]
        let manifest = CaptureManifest(itemCount: 2, entries: representations.map(ManifestEntry.init))
        let capture = CaptureValue(
            id: captureID,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: representations
        )
        return MixedStorageFixture(
            capture: capture,
            portableBytes: portableBytes,
            localBytes: localBytes,
            localRepresentation: local
        )
    }

    func removeCapture(_ id: UUID, from store: PersistenceController) async throws {
        try await store.perform { context in
            let representations = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
            representations.predicate = NSPredicate(format: "snapshotID == %@", id as NSUUID)
            try context.fetch(representations).forEach(context.delete)
            guard let capture = try StoredRecords.object(.capture(id), in: context) else {
                throw SnapshotArchiveTestFailure.missingFixture
            }
            context.delete(capture)
            try context.save()
            context.reset()
        }
    }

    func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        }
        return controller
    }
}

private enum SnapshotArchiveTestFailure: Error {
    case missingFixture
}
