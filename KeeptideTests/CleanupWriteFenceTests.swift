import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class CleanupWriteFenceTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 30_000_000)

    func testPreparedIntentBlocksOrdinaryValidateCommitSameIDForgeryAndSecondPrepareUntilCompletion() async throws {
        let fixture = try await makeFixture()
        let reclaimer = PayloadReclaimer(controller: fixture.store)
        let prepared = try await reclaimer.prepare(
            fixture.request,
            expecting: fixture.identity,
            permit: fixture.permit,
            at: now
        )
        let legacyIntentID = UUID()
        try await insertLegacyIntent(copying: prepared, id: legacyIntentID, into: fixture.store)

        await assertMaintenanceInProgress {
            try await WriteCoordinator(controller: fixture.store).validate(StoreTransaction(
                identity: fixture.identity,
                mutations: []
            ))
        }
        await assertMaintenanceInProgress {
            try await WriteCoordinator(controller: fixture.store).validate(StoreTransaction(
                transactionID: prepared.id,
                identity: fixture.identity,
                preconditions: [],
                mutations: [],
                permit: fixture.permit
            ))
        }
        let forged = CollectionValue(name: "same id must not authorize another plan")
        await assertMaintenanceInProgress {
            _ = try await WriteCoordinator(controller: fixture.store).commit(StoreTransaction(
                transactionID: prepared.id,
                identity: fixture.identity,
                mutations: [.insert(.collection(forged))],
                permit: fixture.permit
            ))
        }
        await assertMaintenanceInProgress {
            _ = try await reclaimer.prepare(
                fixture.request,
                expecting: fixture.identity,
                permit: fixture.permit,
                at: now + 1
            )
        }

        let completed = try await reclaimer.resume(
            prepared.id,
            expecting: fixture.identity,
            permit: fixture.permit,
            at: now + 2
        )
        XCTAssertEqual(completed.phase, .completed)

        let retry = CollectionValue(name: "ordinary retry after cleanup")
        await assertMaintenanceInProgress {
            _ = try await WriteCoordinator(controller: fixture.store).commit(StoreTransaction(
                identity: fixture.identity,
                mutations: [.insert(.collection(retry))]
            ))
        }
        let legacyCompleted = try await reclaimer.resume(
            legacyIntentID,
            expecting: fixture.identity,
            permit: fixture.permit,
            at: now + 3
        )
        XCTAssertEqual(legacyCompleted.phase, .completed)
        _ = try await WriteCoordinator(controller: fixture.store).commit(StoreTransaction(
            identity: fixture.identity,
            mutations: [.insert(.collection(retry))]
        ))
        _ = try await ContentRepository(controller: fixture.store).recordState(.collection(retry.id))
    }

    func testAfterCloudCommitCrashFencesInterleavingWriteThenResumeReleasesFence() async throws {
        let fixture = try await makeFixture()
        let directory = fixture.store.contentStore.url!.deletingLastPathComponent()
        let checkpoint = CleanupFenceCheckpoint(target: .afterCloudCommitBeforePhaseRecord)
        do {
            _ = try await PayloadReclaimer(controller: fixture.store, checkpoint: checkpoint.hit).reclaim(
                fixture.request,
                expecting: fixture.identity,
                permit: fixture.permit,
                at: now
            )
            XCTFail("Synthetic cloud checkpoint did not fire")
        } catch is CleanupFenceCrash {
            // CloudContent committed; the durable intent is still prepared.
        }
        let intentID = try await onlyIntentID(in: fixture.store)
        let persisted = try await CleanupIntentStore(controller: fixture.store).load(
            intentID,
            expecting: fixture.identity
        )
        XCTAssertEqual(persisted.phase, .prepared)

        try await fixture.store.close()
        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try? await reopened.close() }
        let reopenedIdentity = try await reopened.identity()
        let reopenedPermit = try await StoreSafetyGate(controller: reopened).permit(.maintenance)
        XCTAssertEqual(reopenedIdentity, fixture.identity)

        let interleaving = CollectionValue(name: "must wait for local cleanup")
        await assertMaintenanceInProgress {
            _ = try await WriteCoordinator(controller: reopened).commit(StoreTransaction(
                identity: reopenedIdentity,
                mutations: [.insert(.collection(interleaving))]
            ))
        }

        let completed = try await PayloadReclaimer(controller: reopened).resume(
            intentID,
            expecting: reopenedIdentity,
            permit: reopenedPermit,
            at: now + 1
        )
        XCTAssertEqual(completed.phase, .completed)
        _ = try await WriteCoordinator(controller: reopened).commit(StoreTransaction(
            identity: reopenedIdentity,
            mutations: [.insert(.collection(interleaving))]
        ))
    }

    func testUnknownSchemaPreparedIntentFailsClosedWhileTerminalRowDoesNotFence() async throws {
        let fixture = try await makeFixture(insertContent: false)
        let intentID = UUID()
        let timestamp = now
        try await fixture.store.perform { context in
            let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
            row.setValue(intentID, forKey: "id")
            row.setValue(Int64(99), forKey: "schemaVersion")
            row.setValue(fixture.identity.storeID, forKey: "storeID")
            row.setValue(fixture.identity.generation, forKey: "generation")
            row.setValue(CleanupIntentPhase.prepared.rawValue, forKey: "phase")
            row.setValue(Data("unknown plan".utf8), forKey: "payload")
            row.setValue(timestamp, forKey: "createdAt")
            row.setValue(timestamp, forKey: "updatedAt")
            try context.save()
        }
        let value = CollectionValue(name: "unknown prepared fence")
        do {
            _ = try await WriteCoordinator(controller: fixture.store).commit(StoreTransaction(
                identity: fixture.identity,
                mutations: [.insert(.collection(value))]
            ))
            XCTFail("Unknown cleanup schema released the write fence")
        } catch {
            XCTAssertEqual(error as? StoreError, .operationDenied)
        }

        try await fixture.store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")
            request.predicate = NSPredicate(format: "id == %@", intentID as NSUUID)
            guard let row = try context.fetch(request).first else { throw StoreError.notFound }
            row.setValue(CleanupIntentPhase.blocked.rawValue, forKey: "phase")
            try context.save()
        }
        _ = try await WriteCoordinator(controller: fixture.store).commit(StoreTransaction(
            identity: fixture.identity,
            mutations: [.insert(.collection(value))]
        ))
    }

    private func makeFixture(insertContent: Bool = true) async throws -> CleanupFenceFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-CleanupFence-\(UUID().uuidString)", isDirectory: true)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let identity = try await store.identity()
        let permit = try await StoreSafetyGate(controller: store).permit(.maintenance)
        guard insertContent else {
            return CleanupFenceFixture(
                store: store,
                identity: identity,
                permit: permit,
                request: CleanupRequest(target: .item(ItemID()), preconditions: [], mutations: [])
            )
        }

        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("fenced".utf8))]])
        var item = ContentStoreFixtures.item(capture)
        let body = Data("memo".utf8)
        let memo = MemoValue(
            itemID: item.id,
            bodyMode: .ownedPlainText,
            body: body,
            version: ContentVersion(),
            digest: ContentDigest.sha256(body)
        )
        item.memoID = memo.id
        _ = try await WriteCoordinator(controller: store).commit(StoreTransaction(
            identity: identity,
            mutations: [.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))]
        ))
        let target = try await LifecycleService(controller: store).remove(
            itemID: item.id,
            facet: .memo,
            at: now,
            expecting: identity,
            permit: permit
        ).target
        let request = try await LifecycleCleanupPlanner(controller: store).facetRequest(
            target,
            trigger: .explicitUserRequest,
            at: now,
            expecting: identity,
            permit: permit
        )
        return CleanupFenceFixture(store: store, identity: identity, permit: permit, request: request)
    }

    private func onlyIntentID(in store: PersistenceController) async throws -> UUID {
        try await store.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")
            let rows = try context.fetch(request)
            guard rows.count == 1, let id = rows.first?.value(forKey: "id") as? UUID else {
                throw StoreError.corruptStore
            }
            return id
        }
    }

    private func insertLegacyIntent(
        copying intent: CleanupIntentRecord,
        id: UUID,
        into store: PersistenceController
    ) async throws {
        let payload = try CleanupIntentStore.canonicalData(intent.payload)
        try await store.perform { context in
            let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
            row.setValue(id, forKey: "id")
            row.setValue(CleanupIntentStore.schemaVersion, forKey: "schemaVersion")
            row.setValue(intent.identity.storeID, forKey: "storeID")
            row.setValue(intent.identity.generation, forKey: "generation")
            row.setValue(CleanupIntentPhase.prepared.rawValue, forKey: "phase")
            row.setValue(payload, forKey: "payload")
            row.setValue(intent.createdAt, forKey: "createdAt")
            row.setValue(intent.updatedAt, forKey: "updatedAt")
            try context.save()
        }
    }

    private func assertMaintenanceInProgress(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected maintenance fence", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StoreError, .maintenanceInProgress, file: file, line: line)
        }
    }
}

private struct CleanupFenceFixture {
    let store: PersistenceController
    let identity: StoreIdentity
    let permit: StorePermit
    let request: CleanupRequest
}

private struct CleanupFenceCrash: Error {}

private final class CleanupFenceCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let target: PayloadReclaimerCheckpoint
    private var fired = false

    init(target: PayloadReclaimerCheckpoint) {
        self.target = target
    }

    func hit(_ checkpoint: PayloadReclaimerCheckpoint) throws {
        let matches: Bool
        switch (target, checkpoint) {
        case (.afterPrepared, .afterPrepared),
             (.afterCloudCommitBeforePhaseRecord, .afterCloudCommitBeforePhaseRecord),
             (.beforeLocalCompletionSave, .beforeLocalCompletionSave):
            matches = true
        default:
            matches = false
        }
        try lock.withLock {
            guard matches, !fired else { return }
            fired = true
            throw CleanupFenceCrash()
        }
    }
}
