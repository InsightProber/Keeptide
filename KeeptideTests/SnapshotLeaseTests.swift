import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class SnapshotLeaseTests: XCTestCase {
    func testValidateRequiresTheExactLiveLeaseAndCurrentArchivePermit() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("final publish fence".utf8))]
        ])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let gate = StoreSafetyGate(controller: store)
        let permit = try await gate.permit(.completeArchive)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: permit,
            scope: .selected([ContentStoreFixtures.ref(item, capture)])
        ))

        try await reader.validate(lease, permit: permit)
        let tampered = SnapshotLease(
            leaseID: lease.leaseID,
            identity: lease.identity,
            boundary: Data("tampered".utf8)
        )
        do {
            try await reader.validate(tampered, permit: permit)
            XCTFail("A tampered publish lease was accepted")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }

        await reader.end(lease)
        do {
            try await reader.validate(lease, permit: permit)
            XCTFail("An ended publish lease was accepted")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidLease)
        }
    }

    func testPublicationClosureDoesNotRunForEndedExpiredOrChangedLeases() async throws {
        for kind in 0..<3 {
            let store = try makeStore()
            let reader = ContentSnapshotReader(controller: store)
            let gate = StoreSafetyGate(controller: store)
            let permit = try await gate.permit(.completeArchive)
            let lease = try await reader.begin(SnapshotRequest(
                permit: permit, lifetime: kind == 1 ? 0.01 : 3600
            ))
            if kind == 0 { await reader.end(lease) }
            if kind == 1 { try await Task.sleep(for: .milliseconds(30)) }
            if kind == 2 { try await gate.transition(to: .quarantined, expecting: permit.identity) }
            do {
                _ = try await reader.withValidatedLease(lease, permit: permit) {
                    XCTFail("An invalid lease reached external publication")
                    return true
                }
                XCTFail("An invalid lease published")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidLease)
            }
        }
    }

    func testPublicationRunsBeforeAQueuedGenerationTransition() async throws {
        let store = try makeStore()
        let reader = ContentSnapshotReader(controller: store)
        let gate = StoreSafetyGate(controller: store)
        let permit = try await gate.permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(permit: permit))
        let entered = expectation(description: "publication entered writer queue")
        let release = DispatchSemaphore(value: 0)
        let publication = Task {
            try await reader.withValidatedLease(lease, permit: permit) {
                entered.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw StoreError.operationDenied }
                // A transition queued while the external commit runs cannot
                // change identity or invalidate its lease in the middle.
                return store.runtime.identity
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let transition = Task { try await gate.transition(to: .quarantined, expecting: permit.identity) }
        await Task.yield()
        release.signal()
        let publishedIdentity = try await publication.value
        XCTAssertEqual(publishedIdentity, permit.identity)
        try await transition.value
        let currentIdentity = try await store.identity()
        XCTAssertNotEqual(currentIdentity, permit.identity)
    }

    func testSelectedLeasePinsAndProtectsOnlyTheSelectedClosure() async throws {
        let store = try makeStore()
        let selectedCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("selected protected".utf8))]
        ])
        let unselectedCapture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("unselected".utf8))]
        ])
        var selectedItem = ContentStoreFixtures.item(selectedCapture)
        let unselectedItem = ContentStoreFixtures.item(unselectedCapture)
        try await ContentStoreFixtures.insert(selectedItem, selectedCapture, into: store)
        try await ContentStoreFixtures.insert(unselectedItem, unselectedCapture, into: store)
        let selectedRef = ContentStoreFixtures.ref(selectedItem, selectedCapture)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await StoreSafetyGate(controller: store).permit(.completeArchive),
            scope: .selected([selectedRef])
        ))

        let protected = try await store.perform { _ in
            store.runtime.leases[lease.leaseID]?.protectedPayloadRecords
        }
        XCTAssertEqual(protected, [.capture(selectedCapture.id)])

        let repository = ContentRepository(controller: store)
        let itemState = try await repository.recordState(.item(selectedItem.id))
        selectedItem.historyDeletedAt = Date()
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: try await store.identity(),
            preconditions: [.recordUnchanged(.item(selectedItem.id), fingerprint: itemState.fingerprint)],
            mutations: [.update(.item(selectedItem))]
        ))
        let frozen = try await reader.page(lease, after: nil)
        XCTAssertEqual(frozen.contents.map(\.ref), [selectedRef])
        XCTAssertEqual(frozen.contents.first?.representations.first?.bytes, Data("selected protected".utf8))
        await reader.end(lease)
    }

    func testSelectedHistoryLeaseProtectsItsHiddenOwnedMemoSupportPayload() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("visible history".utf8))]
        ])
        let itemID = ItemID()
        let body = Data(String(repeating: "hidden owned memo ", count: 120_000).utf8)
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body),
            deletedAt: deletedAt,
            purgeAfter: deletedAt.addingTimeInterval(86_400)
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
        let historyRef = ContentStoreFixtures.ref(item, capture)
        let gate = StoreSafetyGate(controller: store)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: try await gate.permit(.completeArchive),
            scope: .selected([historyRef])
        ))
        let protected = try await store.perform { _ in
            store.runtime.leases[lease.leaseID]?.protectedPayloadRecords
        }
        XCTAssertEqual(protected, [.capture(capture.id), .memo(memo.id)])

        let repository = ContentRepository(controller: store)
        let itemState = try await repository.recordState(.item(item.id))
        let memoState = try await repository.recordState(.memo(memo.id))
        var detached = item
        detached.memoID = nil
        let purge = StoreTransaction(
            identity: try await store.identity(),
            preconditions: [
                .recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint),
                .recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)
            ],
            mutations: [.update(.item(detached)), .delete(.memo(memo.id))],
            permit: try await gate.permit(.maintenance)
        )
        do {
            _ = try await WriteCoordinator(controller: store).commit(purge)
            XCTFail("A hidden support memo was purged while its selected history lease was active")
        } catch {
            XCTAssertEqual(error as? StoreError, .contentProtected)
        }

        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.map(\.ref), [historyRef])
        XCTAssertTrue(page.portableRecords.contains(.memo(memo)))
        await reader.end(lease)
    }

    func testExpiredLeaseReleasesItsContextAndCannotBeRead() async throws {
        let store = try makeStore()
        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(permit: permit, lifetime: 0.01))
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await reader.page(lease, after: nil); XCTFail("Expired lease was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidLease) }
        let count = try await store.perform { _ in store.runtime.leases.count }
        XCTAssertEqual(count, 0)
    }

    func testPinnedReadKeepsOldOwnedBodyWhileNewReaderSeesNewVersion() async throws {
        let store = try makeStore()
        let id = ItemID()
        let oldBody = Data("old body".utf8)
        var memo = MemoValue(itemID: id, bodyMode: .ownedPlainText, body: oldBody,
                             version: ContentVersion(), digest: ContentDigest.sha256(oldBody))
        let item = ItemValue(id: id, memoID: memo.id)
        let writer = WriteCoordinator(controller: store)
        _ = try await writer.commit(StoreTransaction(identity: try await store.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(item))]))
        let reader = ContentSnapshotReader(controller: store)
        let permit = try await StoreSafetyGate(controller: store).permit(.completeArchive)
        let lease = try await reader.begin(SnapshotRequest(pageSize: 1, permit: permit))
        let state = try await ContentRepository(controller: store).recordState(.memo(memo.id))
        memo.body = Data("new body".utf8)
        memo.version = ContentVersion()
        memo.digest = ContentDigest.sha256(memo.body!)
        _ = try await writer.commit(StoreTransaction(identity: try await store.identity(),
            preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: state.fingerprint)],
            mutations: [.update(.memo(memo))]))
        let frozen = try await reader.page(lease, after: nil)
        XCTAssertEqual(frozen.contents.flatMap(\.representations).map(\.bytes), [oldBody])
        let current = try await ContentRepository(controller: store).read(
            ContentRef(itemID: id, facet: .memo, version: memo.version!, digest: memo.digest!))
        XCTAssertEqual(current.representations.first?.bytes, Data("new body".utf8))
        await reader.end(lease)
        do { _ = try await reader.page(lease, after: nil); XCTFail("Ended lease was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidLease) }
    }

    func testLeaseProtectsCaptureUntilReleaseAndRejectsForeignCursor() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("protected".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let reader = ContentSnapshotReader(controller: store)
        let gate = StoreSafetyGate(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: try await gate.permit(.completeArchive)))
        do { _ = try await reader.page(lease, after: Data("foreign".utf8)); XCTFail("Bad cursor was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        let repo = ContentRepository(controller: store)
        let oldItem = try await repo.recordState(.item(item.id))
        item.historyEligible = false
        item.captureID = nil
        let writer = WriteCoordinator(controller: store)
        _ = try await writer.commit(StoreTransaction(identity: try await store.identity(),
            preconditions: [.recordUnchanged(.item(item.id), fingerprint: oldItem.fingerprint)],
            mutations: [.update(.item(item))]))
        let oldCapture = try await repo.recordState(.capture(capture.id))
        let references = try await repo.referenceFingerprint(snapshotID: capture.id)
        let purge = StoreTransaction(identity: try await store.identity(),
            preconditions: [.recordUnchanged(.capture(capture.id), fingerprint: oldCapture.fingerprint),
                            .referenceSet(snapshotID: capture.id, fingerprint: references)],
            mutations: [.delete(.capture(capture.id))], permit: try await gate.permit(.maintenance))
        do { _ = try await writer.commit(purge); XCTFail("Leased payload was deleted") }
        catch { XCTAssertEqual(error as? StoreError, .contentProtected) }
        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.first?.representations.first?.bytes, Data("protected".utf8))
        await reader.end(lease)
        _ = try await writer.commit(purge)
        do { _ = try await repo.recordState(.capture(capture.id)); XCTFail("Released payload was not removed") }
        catch { XCTAssertEqual(error as? StoreError, .notFound) }
    }

    func testLeaseProtectsOwnedMemoExternalBodyUntilRelease() async throws {
        let store = try makeStore()
        let body = Data(String(repeating: "external memo payload ", count: 120_000).utf8)
        let itemID = ItemID()
        let memo = MemoValue(
            itemID: itemID,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        let item = ItemValue(id: itemID, memoID: memo.id)
        let writer = WriteCoordinator(controller: store)
        _ = try await writer.commit(StoreTransaction(
            identity: try await store.identity(),
            mutations: [.insert(.memo(memo)), .insert(.item(item))]
        ))
        // Core Data owns the support-directory spelling (including a leading
        // dot on some OS versions). Inspect the isolated fixture without
        // assuming that private name or modifying its files.
        let directory = try XCTUnwrap(store.contentStore.url?.deletingLastPathComponent())
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        let externalFiles = try files.compactMap { element -> URL? in
            guard let url = element as? URL,
                  url.pathComponents.contains("_EXTERNAL_DATA"),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return url
        }
        XCTAssertFalse(externalFiles.isEmpty, "The fixture did not exercise Core Data external payload storage")

        let gate = StoreSafetyGate(controller: store)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: try await gate.permit(.completeArchive)))
        let protected = try await store.perform { _ in
            store.runtime.leases[lease.leaseID]?.protectedPayloadRecords
        }
        XCTAssertTrue(protected?.contains(.memo(memo.id)) == true)
        let repository = ContentRepository(controller: store)
        let itemState = try await repository.recordState(.item(item.id))
        let memoState = try await repository.recordState(.memo(memo.id))
        let purge = StoreTransaction(
            identity: try await store.identity(),
            preconditions: [
                .recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint),
                .recordUnchanged(.memo(memo.id), fingerprint: memoState.fingerprint)
            ],
            mutations: [
                .insert(.itemMarker(ItemDeletionMarkerValue(itemID: item.id))),
                .delete(.item(item.id)),
                .delete(.memo(memo.id))
            ],
            permit: try await gate.permit(.maintenance)
        )

        do {
            _ = try await writer.commit(purge)
            XCTFail("An owned memo payload was deleted while its archive lease was active")
        } catch {
            XCTAssertEqual(error as? StoreError, .contentProtected)
        }
        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.first?.representations.first?.bytes, body)
        await reader.end(lease)
        _ = try await writer.commit(purge)
        do { _ = try await repository.recordState(.memo(memo.id)); XCTFail("Released memo payload survived purge") }
        catch { XCTAssertEqual(error as? StoreError, .notFound) }
    }

    func testGenerationChangeInvalidatesPermitsLeasesAndPersistsQuarantine() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([
            [("public.utf8-plain-text", Data("generation selected".utf8))]
        ])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let gate = StoreSafetyGate(controller: store)
        let oldIdentity = try await store.identity()
        let oldPermit = try await gate.permit(.completeArchive)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(
            permit: oldPermit,
            scope: .selected([ContentStoreFixtures.ref(item, capture)])
        ))
        try await reader.validate(lease, permit: oldPermit)
        try await gate.transition(to: .quarantined, expecting: try await store.identity())
        do { _ = try await gate.permit(.maintenance); XCTFail("Quarantine allowed maintenance") }
        catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        do { _ = try await gate.permit(.completeArchive); XCTFail("Quarantine allowed complete archive") }
        catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        _ = try await gate.permit(.projection)
        do { _ = try await reader.page(lease, after: nil); XCTFail("Old generation lease survived") }
        catch { XCTAssertEqual(error as? StoreError, .invalidLease) }
        do { try await reader.validate(lease, permit: oldPermit); XCTFail("Old generation publish fence survived") }
        catch { XCTAssertEqual(error as? StoreError, .invalidLease) }
        let transaction = StoreTransaction(identity: oldIdentity, mutations: [.insert(.collection(CollectionValue(name: "old")))])
        do { _ = try await WriteCoordinator(controller: store).commit(transaction); XCTFail("Old writer generation survived") }
        catch { XCTAssertEqual(error as? StoreError, .preconditionFailed) }
        let current = StoreTransaction(identity: try await store.identity(), mutations: transaction.mutations)
        do { _ = try await WriteCoordinator(controller: store).commit(current); XCTFail("Quarantine allowed application writes") }
        catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        let directory = store.contentStore.url!.deletingLastPathComponent()
        try await store.close()
        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try await reopened.close() }
        do { _ = try await StoreSafetyGate(controller: reopened).permit(.completeArchive); XCTFail("Quarantine was lost") }
        catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        try await reopened.close()
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close(); try FileManager.default.removeItem(at: directory) }
        return controller
    }
}
