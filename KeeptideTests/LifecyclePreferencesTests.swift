import Foundation
import XCTest
@testable import Keeptide

final class LifecyclePreferencesTests: XCTestCase {
    func testFreshPreferencesUseNinetyDaysAndTwoGiBWarning() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        let snapshot = preferences.snapshot()

        XCTAssertEqual(snapshot.historyRetention, .preset(.ninetyDays))
        XCTAssertEqual(snapshot.storageWarningLimitBytes, 2 * 1_024 * 1_024 * 1_024)
        XCTAssertFalse(snapshot.requiresRetentionReview)
    }

    func testAllPublishedRetentionChoicesMapToPolicyWithoutHeuristics() {
        XCTAssertEqual(HistoryRetentionChoice.preset(.oneDay).policy, .days(1))
        XCTAssertEqual(HistoryRetentionChoice.preset(.sevenDays).policy, .days(7))
        XCTAssertEqual(HistoryRetentionChoice.preset(.thirtyDays).policy, .days(30))
        XCTAssertEqual(HistoryRetentionChoice.preset(.ninetyDays).policy, .days(90))
        XCTAssertEqual(HistoryRetentionChoice.preset(.oneYear).policy, .days(365))
        XCTAssertEqual(HistoryRetentionChoice.custom(days: 42).policy, .days(42))
        XCTAssertEqual(HistoryRetentionChoice.permanent.policy, .permanent)
        XCTAssertNil(HistoryRetentionChoice.custom(days: 0).policy)
    }

    func testPresetCustomPermanentAndWarningChoicesSurviveRestart() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        try preferences.commit(preferences.stageHistoryRetention(.custom(days: 42)), confirmingShortening: true)
        preferences.setStorageWarningLimitBytes(5 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(LifecyclePreferences(defaults: defaults).snapshot().historyRetention, .custom(days: 42))
        XCTAssertEqual(LifecyclePreferences(defaults: defaults).snapshot().storageWarningLimitBytes,
                       5 * 1_024 * 1_024 * 1_024)

        try preferences.commit(preferences.stageHistoryRetention(.permanent), confirmingShortening: false)
        preferences.setStorageWarningLimitBytes(nil)
        let restarted = LifecyclePreferences(defaults: defaults).snapshot()
        XCTAssertEqual(restarted.historyRetention, .permanent)
        XCTAssertNil(restarted.storageWarningLimitBytes)
    }

    func testShorteningIsStagedAndCannotCommitWithoutRootUIConfirmation() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        let change = try preferences.stageHistoryRetention(.preset(.thirtyDays))
        XCTAssertEqual(change.current, .preset(.ninetyDays))
        XCTAssertEqual(change.proposed, .preset(.thirtyDays))
        XCTAssertTrue(change.requiresExplicitConfirmation)
        XCTAssertThrowsError(try preferences.commit(change, confirmingShortening: false)) { error in
            XCTAssertEqual(error as? LifecyclePreferencesError, .shorteningConfirmationRequired)
        }
        XCTAssertEqual(preferences.snapshot().historyRetention, .preset(.ninetyDays))

        try preferences.commit(change, confirmingShortening: true)
        XCTAssertEqual(preferences.snapshot().historyRetention, .preset(.thirtyDays))
    }

    func testLengtheningAndNoOpChangesNeedNoDestructiveConfirmation() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        let permanent = try preferences.stageHistoryRetention(.permanent)
        XCTAssertFalse(permanent.requiresExplicitConfirmation)
        try preferences.commit(permanent, confirmingShortening: false)

        let stillPermanent = try preferences.stageHistoryRetention(.permanent)
        XCTAssertFalse(stillPermanent.requiresExplicitConfirmation)
        try preferences.commit(stillPermanent, confirmingShortening: false)
    }

    func testCommitRechecksShorteningInsteadOfTrustingStagedMetadata() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let forged = StagedHistoryRetentionChange(
            current: .preset(.ninetyDays),
            proposed: .preset(.thirtyDays),
            requiresExplicitConfirmation: false
        )

        XCTAssertThrowsError(try preferences.commit(forged, confirmingShortening: false)) { error in
            XCTAssertEqual(error as? LifecyclePreferencesError, .shorteningConfirmationRequired)
        }
        XCTAssertEqual(preferences.snapshot().historyRetention, .preset(.ninetyDays))
    }

    func testCorruptRetentionFallsBackToPermanentAndRaisesVisibleReviewFlag() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: LifecyclePreferences.retentionKey)

        let snapshot = preferences.snapshot()

        XCTAssertEqual(snapshot.historyRetention, .permanent)
        XCTAssertTrue(snapshot.requiresRetentionReview)
        XCTAssertEqual(defaults.data(forKey: LifecyclePreferences.retentionKey), corrupt,
                       "Reading corruption must not silently replace it with a shorter policy")
    }

    func testWrongPersistedRetentionTypeAlsoFallsBackToPermanentAndRequiresReview() {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("90", forKey: LifecyclePreferences.retentionKey)

        let snapshot = preferences.snapshot()

        XCTAssertEqual(snapshot.historyRetention, .permanent)
        XCTAssertTrue(snapshot.requiresRetentionReview)
        XCTAssertEqual(defaults.string(forKey: LifecyclePreferences.retentionKey), "90")
    }

    func testInvalidCustomRetentionAndStaleStagedChangesAreRejected() throws {
        let (preferences, defaults, suite) = makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertThrowsError(try preferences.stageHistoryRetention(.custom(days: 0))) { error in
            XCTAssertEqual(error as? LifecyclePreferencesError, .invalidRetention)
        }
        let stale = try preferences.stageHistoryRetention(.preset(.thirtyDays))
        try preferences.commit(preferences.stageHistoryRetention(.permanent), confirmingShortening: false)
        XCTAssertThrowsError(try preferences.commit(stale, confirmingShortening: true)) { error in
            XCTAssertEqual(error as? LifecyclePreferencesError, .staleChange)
        }
        XCTAssertEqual(preferences.snapshot().historyRetention, .permanent)
    }

    private func makePreferences() -> (LifecyclePreferences, UserDefaults, String) {
        let suite = "KeeptideTests.LifecyclePreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LifecyclePreferences(defaults: defaults), defaults, suite)
    }
}
