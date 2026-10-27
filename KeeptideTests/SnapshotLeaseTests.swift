import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class SnapshotLeaseTests: XCTestCase {
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

    func testGenerationChangeInvalidatesPermitsLeasesAndPersistsQuarantine() async throws {
        let store = try makeStore()
        let gate = StoreSafetyGate(controller: store)
        let oldIdentity = try await store.identity()
        let oldPermit = try await gate.permit(.completeArchive)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: oldPermit))
        try await gate.transition(to: .quarantined)
        do { _ = try await gate.permit(.maintenance); XCTFail("Quarantine allowed maintenance") }
        catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        do { _ = try await gate.permit(.completeArchive); XCTFail("Quarantine allowed complete archive") }
        catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        _ = try await gate.permit(.projection)
        do { _ = try await reader.page(lease, after: nil); XCTFail("Old generation lease survived") }
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
