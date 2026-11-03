import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class LifecycleSettingsModelTests: XCTestCase {
    func testShorteningWaitsForExactImpactAndCancelLeavesPreferenceUntouched() async throws {
        let fixture = try makeFixture()
        var applied = 0
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { choice in
                XCTAssertEqual(choice, .preset(.thirtyDays))
                return 17
            },
            apply: { change, confirmed in
                applied += 1
                try fixture.preferences.commit(change, confirmingShortening: confirmed)
                return fixture.preferences.snapshot()
            }
        )

        await model.selectRetention(.preset(.thirtyDays))

        XCTAssertEqual(model.pendingConfirmation?.historyCount, 17)
        XCTAssertEqual(model.pendingConfirmation?.change.proposed, .preset(.thirtyDays))
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(fixture.preferences.snapshot().historyRetention, .preset(.ninetyDays))

        model.cancelConfirmation()

        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.selectedRetention, .preset(.ninetyDays))
        XCTAssertEqual(fixture.preferences.snapshot().historyRetention, .preset(.ninetyDays))
    }

    func testConfirmedShorteningAppliesTheExactStagedChange() async throws {
        let fixture = try makeFixture()
        var appliedChange: StagedHistoryRetentionChange?
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { _ in 3 },
            apply: { change, confirmed in
                appliedChange = change
                try fixture.preferences.commit(change, confirmingShortening: confirmed)
                return fixture.preferences.snapshot()
            }
        )

        await model.selectRetention(.preset(.thirtyDays))
        await model.confirmShortening()

        XCTAssertEqual(appliedChange?.current, .preset(.ninetyDays))
        XCTAssertEqual(appliedChange?.proposed, .preset(.thirtyDays))
        XCTAssertEqual(model.snapshot.historyRetention, .preset(.thirtyDays))
        XCTAssertEqual(model.selectedRetention, .preset(.thirtyDays))
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.phase, .idle)
    }

    func testOldImpactCannotPublishOrCommitAfterASecondSelection() async throws {
        let fixture = try makeFixture()
        let impacts = ImpactContinuations()
        var applied: [HistoryRetentionChoice] = []
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { choice in await impacts.value(for: choice) },
            apply: { change, confirmed in
                applied.append(change.proposed)
                try fixture.preferences.commit(change, confirmingShortening: confirmed)
                return fixture.preferences.snapshot()
            }
        )

        let first = Task { await model.selectRetention(.preset(.thirtyDays)) }
        await impacts.waitUntilRequested(.preset(.thirtyDays))
        let second = Task { await model.selectRetention(.preset(.sevenDays)) }
        await impacts.waitUntilRequested(.preset(.sevenDays))

        await impacts.resume(.preset(.thirtyDays), with: 30)
        await first.value
        XCTAssertNil(model.pendingConfirmation)

        await impacts.resume(.preset(.sevenDays), with: 70)
        await second.value
        XCTAssertEqual(model.pendingConfirmation?.historyCount, 70)
        XCTAssertEqual(model.pendingConfirmation?.change.proposed, .preset(.sevenDays))

        await model.confirmShortening()
        XCTAssertEqual(applied, [.preset(.sevenDays)])
    }

    func testFailedApplyKeepsPersistedSnapshotAndShowsFailure() async throws {
        let fixture = try makeFixture()
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { _ in 2 },
            apply: { _, _ in throw TestFailure.applyFailed }
        )

        await model.selectRetention(.preset(.thirtyDays))
        await model.confirmShortening()

        XCTAssertEqual(model.snapshot.historyRetention, .preset(.ninetyDays))
        XCTAssertEqual(fixture.preferences.snapshot().historyRetention, .preset(.ninetyDays))
        XCTAssertEqual(model.selectedRetention, .preset(.ninetyDays))
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNotNil(model.message)
    }

    func testInvalidCustomValueNeverRequestsImpactOrChangesPreference() async throws {
        let fixture = try makeFixture()
        var impactRequests = 0
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { _ in impactRequests += 1; return 0 },
            apply: { _, _ in XCTFail("Invalid custom value must not apply"); return fixture.preferences.snapshot() }
        )
        model.customDays = "0"

        await model.submitCustomRetention()

        XCTAssertEqual(impactRequests, 0)
        XCTAssertEqual(model.snapshot.historyRetention, .preset(.ninetyDays))
        XCTAssertEqual(model.phase, .failed)
        XCTAssertNotNil(model.message)
    }

    func testNegativeImpactIsRejectedInsteadOfDisplayedAsZero() async throws {
        let fixture = try makeFixture()
        var applied = false
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { _ in -1 },
            apply: { _, _ in applied = true; return fixture.preferences.snapshot() }
        )

        await model.selectRetention(.preset(.thirtyDays))

        XCTAssertFalse(applied)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.selectedRetention, .preset(.ninetyDays))
        XCTAssertEqual(fixture.preferences.snapshot().historyRetention, .preset(.ninetyDays))
    }

    func testSelectingCustomInvalidatesAnOlderImpactRequest() async throws {
        let fixture = try makeFixture()
        let impacts = ImpactContinuations()
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { choice in await impacts.value(for: choice) }
        )
        let request = Task { await model.selectRetention(.preset(.thirtyDays)) }
        await impacts.waitUntilRequested(.preset(.thirtyDays))

        await model.selectOption(.custom)
        await impacts.resume(.preset(.thirtyDays), with: 5)
        await request.value

        XCTAssertEqual(model.selectedOption, .custom)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(fixture.preferences.snapshot().historyRetention, .preset(.ninetyDays))
    }

    func testStorageWarningCanBeAdjustedOrDisabledWithoutBecomingAQuota() throws {
        let fixture = try makeFixture()
        let model = LifecycleSettingsModel(preferences: fixture.preferences)

        model.setWarningLimitGiB(5)
        XCTAssertEqual(model.snapshot.storageWarningLimitBytes, 5 * 1_024 * 1_024 * 1_024)
        model.setWarningEnabled(false)
        XCTAssertNil(model.snapshot.storageWarningLimitBytes)
        model.setWarningLimitGiB(7)
        XCTAssertNil(model.snapshot.storageWarningLimitBytes)
        model.setWarningEnabled(true)
        XCTAssertEqual(model.snapshot.storageWarningLimitBytes, 7 * 1_024 * 1_024 * 1_024)
    }

    func testCorruptPersistedRetentionIsPermanentAndRequiresVisibleReview() throws {
        let fixture = try makeFixture()
        fixture.defaults.set(Data("not-json".utf8), forKey: LifecyclePreferences.retentionKey)

        let model = LifecycleSettingsModel(preferences: fixture.preferences)

        XCTAssertEqual(model.snapshot.historyRetention, .permanent)
        XCTAssertEqual(model.selectedRetention, .permanent)
        XCTAssertTrue(model.snapshot.requiresRetentionReview)
        XCTAssertTrue(model.requiresRetentionReview)
    }

    func testReloadInvalidatesPendingConfirmationAndRestoresPersistedChoice() async throws {
        let fixture = try makeFixture()
        let model = LifecycleSettingsModel(preferences: fixture.preferences, impact: { _ in 8 })
        await model.selectRetention(.preset(.thirtyDays))
        XCTAssertNotNil(model.pendingConfirmation)

        model.reload()

        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.selectedRetention, .preset(.ninetyDays))
    }

    func testSelectionAndReloadCannotOvertakeAnApplyingCASChange() async throws {
        let fixture = try makeFixture()
        let applyGate = ApplyContinuation()
        let model = LifecycleSettingsModel(
            preferences: fixture.preferences,
            impact: { _ in 4 },
            apply: { change, confirmed in
                await applyGate.wait()
                try fixture.preferences.commit(change, confirmingShortening: confirmed)
                return fixture.preferences.snapshot()
            }
        )
        await model.selectRetention(.preset(.thirtyDays))

        let confirmation = Task { await model.confirmShortening() }
        await applyGate.waitUntilStarted()
        XCTAssertEqual(model.phase, .applying)

        await model.selectRetention(.permanent)
        model.reload()
        XCTAssertEqual(model.selectedRetention, .preset(.thirtyDays))
        XCTAssertEqual(model.phase, .applying)

        await applyGate.resume()
        await confirmation.value
        XCTAssertEqual(model.snapshot.historyRetention, .preset(.thirtyDays))
        XCTAssertEqual(fixture.preferences.snapshot().historyRetention, .preset(.thirtyDays))
    }

    private func makeFixture() throws -> Fixture {
        let suite = "LifecycleSettingsModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Fixture(defaults: defaults, preferences: LifecyclePreferences(defaults: defaults))
    }
}

private struct Fixture {
    let defaults: UserDefaults
    let preferences: LifecyclePreferences
}

private enum TestFailure: Error {
    case applyFailed
}

private actor ImpactContinuations {
    private var continuations: [HistoryRetentionChoice: CheckedContinuation<Int, Never>] = [:]
    private var requestWaiters: [HistoryRetentionChoice: [CheckedContinuation<Void, Never>]] = [:]

    func value(for choice: HistoryRetentionChoice) async -> Int {
        requestWaiters.removeValue(forKey: choice)?.forEach { $0.resume() }
        return await withCheckedContinuation { continuations[choice] = $0 }
    }

    func waitUntilRequested(_ choice: HistoryRetentionChoice) async {
        if continuations[choice] != nil { return }
        await withCheckedContinuation { requestWaiters[choice, default: []].append($0) }
    }

    func resume(_ choice: HistoryRetentionChoice, with count: Int) {
        continuations.removeValue(forKey: choice)?.resume(returning: count)
    }
}

private actor ApplyContinuation {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
