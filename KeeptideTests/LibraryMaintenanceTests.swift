import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class LibraryMaintenanceTests: XCTestCase {
    func testUnknownCleanupStopsBeforeExpiryAndKeepsTheRecoveryMessage() async throws {
        let harness = try await makeHarness(retention: .preset(.oneDay))
        let fixture = try await insertHistory("preserved-old", lastCopiedAt: .distantPast, into: harness.store)
        let identity = harness.identity
        let evidence = Data("unknown cleanup evidence".utf8)
        try await harness.store.perform { context in
            let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
            row.setValue(UUID(), forKey: "id")
            row.setValue(Int64(99), forKey: "schemaVersion")
            row.setValue(identity.storeID, forKey: "storeID")
            row.setValue(identity.generation, forKey: "generation")
            row.setValue("future", forKey: "phase")
            row.setValue(evidence, forKey: "payload")
            row.setValue(Date(), forKey: "createdAt")
            row.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
        for _ in 0..<2 {
            await harness.maintenance.runScheduledMaintenance()
            XCTAssertTrue(harness.maintenance.message?.contains("newer version") == true)
            let item = try await itemValue(fixture.item.id, in: harness.store)
            XCTAssertTrue(item.historyEligible)
            _ = try await ContentRepository(controller: harness.store).recordState(.capture(fixture.capture.id))
        }
        let raw = try await harness.store.perform { context in
            let row = try XCTUnwrap(context.fetch(NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")).first)
            return row.value(forKey: "payload") as? Data
        }
        XCTAssertEqual(raw, evidence)
    }

    func testScheduledMaintenanceExpiresAndReclaimsActiveAndPrehiddenHistory() async throws {
        let harness = try await makeHarness(retention: .preset(.oneDay))
        let active = try await insertHistory("active-old", lastCopiedAt: .distantPast, into: harness.store)
        let hidden = try await insertHistory("hidden-before-crash", lastCopiedAt: .distantPast, into: harness.store)
        let hiddenState = try await ContentRepository(controller: harness.store).recordState(.item(hidden.item.id))
        guard case .item(var hiddenItem) = hiddenState.value else { return XCTFail("Missing hidden item") }
        hiddenItem.historyEligible = false
        _ = try await WriteCoordinator(controller: harness.store).commit(StoreTransaction(
            identity: harness.identity,
            preconditions: [.recordUnchanged(.item(hiddenItem.id), fingerprint: hiddenState.fingerprint)],
            mutations: [.update(.item(hiddenItem))]
        ))

        await harness.maintenance.runScheduledMaintenance()

        XCTAssertNil(harness.maintenance.message)
        await assertMissing(.capture(active.capture.id), in: harness.store)
        await assertMissing(.capture(hidden.capture.id), in: harness.store)
        let activeItem = try await itemValue(active.item.id, in: harness.store)
        let hiddenItemAfterMaintenance = try await itemValue(hidden.item.id, in: harness.store)
        let markerCount = try await facetMarkerCount(in: harness.store)
        XCTAssertNil(activeItem.captureID)
        XCTAssertNil(hiddenItemAfterMaintenance.captureID)
        XCTAssertEqual(markerCount, 2)
    }

    func testPermanentPolicyPreservesOldCaptureAndVisibleHistory() async throws {
        let harness = try await makeHarness(retention: .permanent)
        let fixture = try await insertHistory("permanent", lastCopiedAt: .distantPast, into: harness.store)

        await harness.maintenance.runScheduledMaintenance()

        XCTAssertNil(harness.maintenance.message)
        _ = try await ContentRepository(controller: harness.store).recordState(.capture(fixture.capture.id))
        let content = try await ContentRepository(controller: harness.store).read(fixture.ref)
        let markerCount = try await facetMarkerCount(in: harness.store)
        XCTAssertEqual(content.integrity, .complete)
        XCTAssertEqual(markerCount, 0)
    }

    func testExactRefSoftDeleteAndRestoreRoundTrip() async throws {
        let harness = try await makeHarness(retention: .permanent)
        let fixture = try await insertHistory("restore", lastCopiedAt: Date(), into: harness.store)

        let removed = await harness.maintenance.remove(fixture.ref)
        XCTAssertTrue(removed)
        XCTAssertEqual(harness.maintenance.trash.count, 1)
        let target = try XCTUnwrap(harness.maintenance.trash.first?.identity)
        XCTAssertEqual(target, .history(itemID: fixture.item.id, captureID: fixture.capture.id))
        let restoredResult = await harness.maintenance.restore(target)
        XCTAssertTrue(restoredResult)

        XCTAssertTrue(harness.maintenance.trash.isEmpty)
        let restored = try await ContentRepository(controller: harness.store).read(fixture.ref)
        let restoredItem = try await itemValue(fixture.item.id, in: harness.store)
        XCTAssertEqual(restored.integrity, .complete)
        XCTAssertTrue(restoredItem.historyEligible)
    }

    func testStopAndDrainWaitsForInflightDidChangeAndRejectsLaterActionsAndSettingsClosures() async throws {
        let changeGate = MaintenanceChangeGate()
        let harness = try await makeHarness(retention: .permanent) {
            await changeGate.hold()
        }
        let fixture = try await insertHistory("drain", lastCopiedAt: Date(), into: harness.store)
        let settings = harness.maintenance.settings
        let action = Task { await harness.maintenance.remove(fixture.ref) }
        await changeGate.waitUntilHeld()

        let stopped = CompletionProbe()
        let stop = Task {
            await harness.maintenance.stopAndDrain()
            await stopped.finish()
        }
        await Task.yield()
        let stoppedBeforeRelease = await stopped.isFinished
        XCTAssertFalse(stoppedBeforeRelease)

        await changeGate.release()
        let actionResult = await action.value
        XCTAssertTrue(actionResult)
        await stop.value
        let stoppedAfterRelease = await stopped.isFinished
        let laterAction = await harness.maintenance.remove(fixture.ref)
        XCTAssertTrue(stoppedAfterRelease)
        XCTAssertFalse(laterAction)

        await settings.selectRetention(.preset(.oneDay))
        XCTAssertEqual(settings.phase, .failed)
        XCTAssertEqual(harness.preferences.snapshot().historyRetention, .permanent)
    }

    func testSettingsImpactAndConfirmedApplyUseActualStoreAndIsolatedPreferences() async throws {
        let harness = try await makeHarness(retention: .preset(.ninetyDays))
        let old = try await insertHistory("affected", lastCopiedAt: .distantPast, into: harness.store)
        let recent = try await insertHistory("unaffected", lastCopiedAt: Date(), into: harness.store)
        let settings = harness.maintenance.settings

        await settings.selectRetention(.preset(.oneDay))

        XCTAssertEqual(settings.phase, .awaitingConfirmation)
        XCTAssertEqual(settings.pendingConfirmation?.historyCount, 1)
        XCTAssertEqual(harness.preferences.snapshot().historyRetention, .preset(.ninetyDays))

        await settings.confirmShortening()

        XCTAssertEqual(settings.phase, .idle)
        XCTAssertEqual(settings.snapshot.historyRetention, .preset(.oneDay))
        XCTAssertEqual(harness.preferences.snapshot().historyRetention, .preset(.oneDay))
        await assertMissing(.capture(old.capture.id), in: harness.store)
        _ = try await ContentRepository(controller: harness.store).recordState(.capture(recent.capture.id))
    }

    func testChangedStoreIdentityAndFailedMaintenanceShowTruthfulFailureWithoutDeletingContent() async throws {
        let harness = try await makeHarness(retention: .permanent)
        let fixture = try await insertHistory("preserved", lastCopiedAt: Date(), into: harness.store)
        let gate = StoreSafetyGate(controller: harness.store)
        try await gate.transition(to: .quarantined, expecting: harness.identity)
        try await gate.transition(to: .active, expecting: try await harness.store.identity())

        let result = await harness.maintenance.remove(fixture.ref)
        XCTAssertFalse(result)
        XCTAssertEqual(
            harness.maintenance.message,
            "This maintenance action could not finish. Your remaining content is preserved. Try again."
        )
        let preserved = try await ContentRepository(controller: harness.store).read(fixture.ref)
        let preservedItem = try await itemValue(fixture.item.id, in: harness.store)
        XCTAssertEqual(preserved.integrity, .complete)
        XCTAssertNil(preservedItem.historyDeletedAt)
    }

    private func makeHarness(
        retention: HistoryRetentionChoice,
        didChange: @escaping @MainActor () async -> Void = {}
    ) async throws -> MaintenanceHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-LibraryMaintenance-\(UUID().uuidString)", isDirectory: true)
        let store = try PersistenceController(directory: directory)
        let suite = "Keeptide-LibraryMaintenance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let preferences = LifecyclePreferences(defaults: defaults)
        if retention != LifecyclePreferences.defaultHistoryRetention {
            let change = try preferences.stageHistoryRetention(retention)
            try preferences.commit(change, confirmingShortening: true)
        }
        let identity = try await store.identity()
        let maintenance = LibraryMaintenance(
            controller: store,
            identity: identity,
            directory: directory,
            preferences: preferences,
            didChange: didChange
        )
        addTeardownBlock {
            await maintenance.stopAndDrain()
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return MaintenanceHarness(
            store: store,
            identity: identity,
            preferences: preferences,
            maintenance: maintenance
        )
    }

    private func insertHistory(
        _ text: String,
        lastCopiedAt: Date,
        into store: PersistenceController
    ) async throws -> HistoryFixture {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        var item = ContentStoreFixtures.item(capture)
        item.lastCopiedAt = lastCopiedAt
        try await ContentStoreFixtures.insert(item, capture, into: store)
        return HistoryFixture(item: item, capture: capture, ref: ContentStoreFixtures.ref(item, capture))
    }

    private func itemValue(_ id: ItemID, in store: PersistenceController) async throws -> ItemValue {
        guard case .item(let item) = try await ContentRepository(controller: store).recordState(.item(id)).value else {
            throw StoreError.corruptStore
        }
        return item
    }

    private func facetMarkerCount(in store: PersistenceController) async throws -> Int {
        try await store.perform { context in
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "FacetDeletionMarker"))
        }
    }

    private func assertMissing(
        _ key: RecordKey,
        in store: PersistenceController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await ContentRepository(controller: store).recordState(key)
            XCTFail("Record survived maintenance", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StoreError, .notFound, file: file, line: line)
        }
    }
}

private struct MaintenanceHarness {
    let store: PersistenceController
    let identity: StoreIdentity
    let preferences: LifecyclePreferences
    let maintenance: LibraryMaintenance
}

private struct HistoryFixture {
    let item: ItemValue
    let capture: CaptureValue
    let ref: ContentRef
}

private actor MaintenanceChangeGate {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

private actor CompletionProbe {
    private(set) var isFinished = false
    func finish() { isFinished = true }
}
