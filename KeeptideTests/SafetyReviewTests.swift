import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class SafetyReviewTests: XCTestCase {
    func testStalePromotionCannotLiftANewerSuspension() async throws {
        let store = try makeStore()
        let gate = StoreSafetyGate(controller: store)
        try await gate.transition(to: .quarantined, expecting: store.identity())
        let recoveringIdentity = try await store.identity()
        try await gate.transition(to: .suspended, expecting: recoveringIdentity)
        let suspendedIdentity = try await store.identity()
        do {
            try await gate.transition(to: .active, expecting: recoveringIdentity)
            XCTFail("A stale recovery task lifted the newer suspension")
        } catch { XCTAssertEqual(error as? StoreError, .preconditionFailed) }
        do {
            try await gate.transition(to: .active, expecting: suspendedIdentity)
            XCTFail("A suspended binding bypassed recovery quarantine")
        } catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        let after = try await store.identity()
        XCTAssertEqual(after, suspendedIdentity)
        do { _ = try await gate.permit(.maintenance); XCTFail("Suspended maintenance allowed") }
        catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
        try await gate.transition(to: .quarantined, expecting: suspendedIdentity)
        try await gate.transition(to: .active, expecting: store.identity())
        _ = try await gate.permit(.maintenance)
    }

    func testSameStateTransitionPreservesIdentityAndLease() async throws {
        let store = try makeStore()
        let gate = StoreSafetyGate(controller: store)
        let identity = try await store.identity()
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: gate.permit(.completeArchive)))
        try await gate.transition(to: .localReady, expecting: try await store.identity())
        let after = try await store.identity()
        XCTAssertEqual(after, identity)
        _ = try await reader.page(lease, after: nil)
        await reader.end(lease)
    }

    func testSecondControllerCannotOpenAnOwnedDirectory() async throws {
        let store = try makeStore()
        let directory = store.contentStore.url!.deletingLastPathComponent()
        do {
            let second = try PersistenceController(directory: directory)
            try await second.close()
            XCTFail("A second independent safety and lease owner opened the same content store")
        } catch {
            XCTAssertEqual(error as? StoreError, .storeInUse)
        }
        try await store.close()
        let reopened = try PersistenceController(directory: directory)
        try await reopened.close()
    }

    func testMissingLocalStoreDoesNotLiftQuarantineOfExistingContent() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("synthetic".utf8))]])
        try await ContentStoreFixtures.insert(ContentStoreFixtures.item(capture), capture, into: store)
        try await StoreSafetyGate(controller: store).transition(to: .quarantined, expecting: try await store.identity())
        let directory = store.contentStore.url!.deletingLastPathComponent()
        try await store.close()
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent("Local.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try await reopened.close() }
        do {
            _ = try await StoreSafetyGate(controller: reopened).permit(.maintenance)
            XCTFail("Losing local state must not grant maintenance on existing content")
        } catch { XCTAssertEqual(error as? StoreError, .operationDenied) }
    }

    func testTransitionRejectsDuplicateSafetyIdentityWithoutSaving() async throws {
        let store = try makeStore()
        let identity = try await store.identity()
        try await store.perform { context in
            let duplicate = NSEntityDescription.insertNewObject(forEntityName: "StoreIdentity", into: context)
            duplicate.setValue(identity.storeID, forKey: "id")
            duplicate.setValue(UUID(), forKey: "generation")
            duplicate.setValue(StoreSafetyState.localReady.rawValue, forKey: "safetyState")
            try context.save()
            context.reset()
        }
        do {
            try await StoreSafetyGate(controller: store).transition(to: .active, expecting: try await store.identity())
            XCTFail("A malformed safety identity was promoted")
        } catch { XCTAssertEqual(error as? StoreError, .corruptStore) }
        let after = try await store.identity()
        XCTAssertEqual(after, identity)
    }

    func testExpiredLeaseReleasesResourcesWithoutAnotherStoreOperation() async throws {
        let store = try makeStore()
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: StoreSafetyGate(controller: store).permit(.completeArchive), lifetime: 0.01))
        // Access the queue directly so this assertion does not itself expire leases.
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        var stillRegistered = true
        repeat {
            stillRegistered = await store.writer.perform { store.runtime.leases[lease.leaseID] != nil }
            if stillRegistered { try await Task.sleep(for: .milliseconds(10)) }
        } while stillRegistered && ContinuousClock().now < deadline
        XCTAssertFalse(stillRegistered, "The resource deadline must be enforced without page/commit calls")
        await reader.end(lease)
    }

    func testSuccessfulArchivePageRefaultsItsPayloadObjects() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.data", Data(repeating: 7, count: 1024 * 1024))]])
        try await ContentStoreFixtures.insert(ContentStoreFixtures.item(capture), capture, into: store)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(pageSize: 1, permit: StoreSafetyGate(controller: store).permit(.completeArchive)))
        let page = try await reader.page(lease, after: nil)
        XCTAssertEqual(page.contents.first?.representations.first?.bytes?.count, 1024 * 1024)
        let materialized = try await store.perform { _ in
            let context = store.runtime.leases[lease.leaseID]!.context
            return context.performAndWait {
                context.registeredObjects.filter { !$0.isFault && $0.entity.name == "CaptureRepresentation" }.count
            }
        }
        XCTAssertEqual(materialized, 0, "Page size must bound retained capture payloads")
        await reader.end(lease)
    }

    func testArchivePayloadReadDoesNotOccupyWriterAndEndRejectsInFlightResult() async throws {
        let store = try makeStore()
        let capture = try ContentStoreFixtures.capture([[("public.data", Data(repeating: 7, count: 1024 * 1024))]])
        try await ContentStoreFixtures.insert(ContentStoreFixtures.item(capture), capture, into: store)
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: StoreSafetyGate(controller: store).permit(.completeArchive)))
        let snapshot = try await store.perform { _ in store.runtime.leases[lease.leaseID]! }
        let barrier = SnapshotQueueBarrier()
        defer { barrier.release() }
        barrier.enqueue(on: snapshot.context)
        let page = Task { try await reader.page(lease, after: nil) }
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        var inFlight = false
        repeat {
            inFlight = try await store.perform { _ in snapshot.inFlightPages == 1 }
            if !inFlight { try await Task.sleep(for: .milliseconds(10)) }
        } while !inFlight && ContinuousClock().now < deadline
        XCTAssertTrue(inFlight)
        XCTAssertFalse(barrier.finished, "The writer must remain available while the payload queue is blocked")
        await reader.end(lease)
        XCTAssertFalse(barrier.finished, "Ending an in-flight lease must not synchronously wait for payload work")
        barrier.release()
        do { _ = try await page.value; XCTFail("An ended lease published its in-flight result") }
        catch { XCTAssertEqual(error as? StoreError, .invalidLease) }
        let retiredCount = try await store.perform { _ in store.runtime.retiredLeases.count }
        XCTAssertEqual(retiredCount, 0)
    }

    func testCancellationRejectsArchiveResultAndReleasesLease() async throws {
        let store = try makeStore()
        let reader = ContentSnapshotReader(controller: store)
        let lease = try await reader.begin(SnapshotRequest(permit: StoreSafetyGate(controller: store).permit(.completeArchive)))
        let snapshot = try await store.perform { _ in store.runtime.leases[lease.leaseID]! }
        let barrier = SnapshotQueueBarrier()
        defer { barrier.release() }
        barrier.enqueue(on: snapshot.context)
        let page = Task { try await reader.page(lease, after: nil) }
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while try await store.perform({ _ in snapshot.inFlightPages == 0 }) && ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        page.cancel()
        barrier.release()
        do { _ = try await page.value; XCTFail("A cancelled archive read published content") }
        catch { XCTAssertTrue(error is CancellationError || error as? StoreError == .invalidLease) }
        // Cancellation schedules end asynchronously; wait for its queue handoff.
        var registered = true
        repeat {
            registered = try await store.perform { _ in store.runtime.leases[lease.leaseID] != nil }
            if registered { try await Task.sleep(for: .milliseconds(10)) }
        } while registered && ContinuousClock().now < deadline
        XCTAssertFalse(registered)
    }

    private func makeStore() throws -> PersistenceController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
        }
        return controller
    }
}

private final class SnapshotQueueBarrier: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didFinish = false
    var finished: Bool { lock.withLock { didFinish } }

    func enqueue(on context: NSManagedObjectContext) {
        context.perform { self.wait() }
    }

    func wait() {
        // A regression must fail an assertion rather than hang the test runner.
        _ = semaphore.wait(timeout: .now() + 5)
        lock.withLock { didFinish = true }
    }

    func release() { semaphore.signal() }
}
