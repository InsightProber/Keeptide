import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class SnapshotArchiveTests: XCTestCase {
    func testSelectedScopePreservesRequestedOrderDeduplicatesExactRefsAndKeepsOnlyTheirSupportGraph() async throws {
        let store = try makeStore()
        let firstCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("first history".utf8))]
        ])
        let firstItem = ContentStoreFixtures.item(firstCapture)
        try await ContentStoreFixtures.insert(firstItem, firstCapture, into: store)

        let secondCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("second history".utf8))]
        ])
        let secondItemID = ItemID()
        let memoBody = Data("selected memo".utf8)
        let memo = MemoValue(
            itemID: secondItemID,
            bodyMode: .ownedMarkdown,
            body: memoBody,
            version: ContentVersion(),
            digest: ContentDigest.sha256(memoBody)
        )
        let collection = CollectionValue(name: "Selected collection", color: "blue", sortOrder: 1)
        let secondItem = ItemValue(
            id: secondItemID,
            title: "second",
            captureID: secondCapture.id,
            memoID: memo.id,
            collectionIDs: [collection.id],
            historyEligible: true,
            copyCount: 1
        )
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [
                .insert(.capture(secondCapture)), .insert(.memo(memo)),
                .insert(.collection(collection)), .insert(.item(secondItem))
            ]
        ))

        let firstHistory = ContentStoreFixtures.ref(firstItem, firstCapture)
        let selectedMemo = ContentRef(
            itemID: secondItem.id,
            facet: .memo,
            version: try XCTUnwrap(memo.version),
            digest: try XCTUnwrap(memo.digest)
        )
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            pageSize: 1,
            permit: try await StoreSafetyGate(controller: store).permit(.completeArchive),
            scope: .selected([selectedMemo, firstHistory, selectedMemo])
        ))

        let firstPage = try await reader.page(lease, after: nil)
        XCTAssertEqual(firstPage.contents.map(\.ref), [selectedMemo])
        XCTAssertTrue(firstPage.portableRecords.contains(.item(secondItem)))
        XCTAssertTrue(firstPage.portableRecords.contains(.capture(secondCapture)))
        XCTAssertTrue(firstPage.portableRecords.contains(.memo(memo)))
        XCTAssertTrue(firstPage.portableRecords.contains(.collection(collection)))
        XCTAssertFalse(firstPage.portableRecords.contains(.item(firstItem)))

        let secondPage = try await reader.page(lease, after: try XCTUnwrap(firstPage.next))
        XCTAssertEqual(secondPage.contents.map(\.ref), [firstHistory])
        XCTAssertNil(secondPage.next)
        XCTAssertTrue(secondPage.portableRecords.contains(.item(firstItem)))
        XCTAssertFalse(secondPage.portableRecords.contains(.item(secondItem)))
        await reader.end(lease)
    }

    func testSelectedScopeRejectsEmptyConflictingStaleAndHiddenRefsAsWholeRequests() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("selected validation".utf8))]
        ])
        var item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let ref = ContentStoreFixtures.ref(item, capture)
        let gate = StoreSafetyGate(controller: store)
        let reader = ContentSnapshotReader(controller: store)

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.begin(SnapshotRequest(
                permit: try await gate.permit(.completeArchive),
                scope: .selected([])
            ))
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .invalidTransaction)
        }

        var conflicting = ref
        conflicting.version = ContentVersion()
        await XCTAssertThrowsErrorAsync {
            _ = try await reader.begin(SnapshotRequest(
                permit: try await gate.permit(.completeArchive),
                scope: .selected([ref, conflicting])
            ))
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .invalidTransaction)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.begin(SnapshotRequest(
                permit: try await gate.permit(.completeArchive),
                scope: .selected([conflicting])
            ))
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
        }

        var stale = ref
        stale.digest = ContentDigest.sha256(Data("wrong digest".utf8))
        await XCTAssertThrowsErrorAsync {
            _ = try await reader.begin(SnapshotRequest(
                permit: try await gate.permit(.completeArchive),
                scope: .selected([stale])
            ))
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
        }

        let repository = ContentRepository(controller: store)
        let itemState = try await repository.recordState(.item(item.id))
        item.historyDeletedAt = Date()
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
            mutations: [.update(.item(item))]
        ))
        await XCTAssertThrowsErrorAsync {
            _ = try await reader.begin(SnapshotRequest(
                permit: try await gate.permit(.completeArchive),
                scope: .selected([ref])
            ))
        } verify: { error in
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
        }
    }

    func testSelectedBoundaryUsesTheExactDeduplicatedScopeInsteadOfAllVisibleRefs() async throws {
        let store = try makeStore()
        let firstCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("boundary one".utf8))]
        ])
        let secondCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("boundary two".utf8))]
        ])
        let firstItem = ContentStoreFixtures.item(firstCapture)
        let secondItem = ContentStoreFixtures.item(secondCapture)
        try await ContentStoreFixtures.insert(firstItem, firstCapture, into: store)
        try await ContentStoreFixtures.insert(secondItem, secondCapture, into: store)
        let firstRef = ContentStoreFixtures.ref(firstItem, firstCapture)
        let reader = ContentSnapshotReader(controller: store)
        let gate = StoreSafetyGate(controller: store)

        let selected = try await reader.begin(SnapshotRequest(
            permit: try await gate.permit(.completeArchive),
            scope: .selected([firstRef, firstRef])
        ))
        let allVisible = try await reader.begin(SnapshotRequest(
            permit: try await gate.permit(.completeArchive)
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expectedBoundary = ContentDigest.sha256(try encoder.encode([firstRef]))
        XCTAssertEqual(selected.boundary, expectedBoundary)
        XCTAssertNotEqual(selected.boundary, allVisible.boundary)
        await reader.end(selected)
        await reader.end(allVisible)
    }

    func testSelectedScopeDoesNotInspectAnUnrelatedLegacyLocalReference() async throws {
        let store = try makeStore()
        let safeCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("safe selection".utf8))]
        ])
        let safeItem = ContentStoreFixtures.item(safeCapture)
        try await ContentStoreFixtures.insert(safeItem, safeCapture, into: store)

        let localBytes = Data("file:///Users/example/Private.txt".utf8)
        let legacyCaptureID = UUID()
        let legacyRepresentation = RepresentationValue(
            snapshotID: legacyCaptureID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: Int64(localBytes.count),
            digest: ContentDigest.sha256(localBytes),
            bytes: nil
        )
        let legacyManifest = CaptureManifest(
            version: LocalReferencePrivacy.legacyManifestVersion,
            itemCount: 1,
            entries: [ManifestEntry(legacyRepresentation)]
        )
        let legacyCapture = CaptureValue(
            id: legacyCaptureID,
            manifest: legacyManifest,
            digest: ContentDigest.sha256(try legacyManifest.canonicalData()),
            representations: [legacyRepresentation]
        )
        let legacyItem = ContentStoreFixtures.item(legacyCapture)
        try await insertDirectly(legacyItem, capture: legacyCapture, into: store)

        let safeRef = ContentStoreFixtures.ref(safeItem, safeCapture)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await StoreSafetyGate(controller: store).permit(.completeArchive),
            scope: .selected([safeRef])
        ))
        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.map(\.ref), [safeRef])
        XCTAssertFalse(page.portableRecords.contains(.item(legacyItem)))
        XCTAssertFalse(page.portableRecords.contains(.capture(legacyCapture)))
        await reader.end(lease)
    }

    func testArchiveNeverExportsLocalReferenceBytesOrPartialExecutableContent() async throws {
        let store = try makeStore()
        let fixture = try makeMixedStorageCapture()
        let item = ContentStoreFixtures.item(fixture.capture)
        let accessStore = FileAccessStore(controller: store)
        try await accessStore.put(LocalFileAccess(
            id: fixture.localRepresentation.id,
            snapshotID: fixture.capture.id,
            bytes: fixture.localBytes
        ), expecting: store.identity())
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

        // Local-only damage must affect an ordinary read without invalidating
        // the portable archive, which never exports these access bytes.
        let localID = fixture.localRepresentation.id
        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(format: "id == %@", localID as NSUUID)
            let record = try XCTUnwrap(context.fetch(request).first)
            record.setValue(Data("damaged local-only bytes".utf8), forKey: "bytes")
            try context.save()
            context.reset()
        }
        let ref = ContentStoreFixtures.ref(item, fixture.capture)
        let damagedLocalRead = try await ContentRepository(controller: store).read(ref)
        XCTAssertEqual(damagedLocalRead.integrity, .corrupt)
        XCTAssertTrue(damagedLocalRead.representations.isEmpty)
        let damagedLocalLease = try await reader.begin(SnapshotRequest(permit: permit))
        let damagedLocalArchive = try await reader.page(damagedLocalLease, after: nil)
        XCTAssertEqual(damagedLocalArchive.portableRecords, page.portableRecords)
        XCTAssertEqual(damagedLocalArchive.contents.first?.integrity, .requiresRelocation)
        await reader.end(damagedLocalLease)

        try await accessStore.remove(representationID: localID,
            permit: StoreSafetyGate(controller: store).permit(.maintenance))
        let missingLocalLease = try await reader.begin(SnapshotRequest(permit: permit))
        let missingLocalArchive = try await reader.page(missingLocalLease, after: nil)
        XCTAssertEqual(missingLocalArchive.portableRecords, page.portableRecords)
        await reader.end(missingLocalLease)
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
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
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
            XCTAssertEqual(error as? StoreError, .snapshotUnavailable)
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
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
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
        addTeardownBlock { try await reopened.close() }
        do {
            _ = try await ContentSnapshotReader(controller: reopened).page(lease, after: nil)
            XCTFail("A process-local pinned lease survived reopen")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }
        try await reopened.close()
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
            collectionIDs: [collection.id],
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
            byteCount: 0,
            digest: Data(repeating: 0x91, count: 32),
            bytes: nil
        )
        let representations = [portable, local]
        let manifest = CaptureManifest(
            version: LocalReferencePrivacy.manifestVersion,
            itemCount: 2,
            entries: representations.map(ManifestEntry.init)
        )
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

    func insertDirectly(
        _ item: ItemValue,
        capture: CaptureValue,
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

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        verify(error)
    }
}
