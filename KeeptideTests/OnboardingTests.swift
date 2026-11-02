import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class OnboardingTests: XCTestCase {
    func testFreshPreferencesNeedOnboardingWithoutChangingCapture() {
        let defaults = makeDefaults()
        let preferences = OnboardingPreferences(defaults: defaults)

        XCTAssertEqual(
            preferences.snapshot(),
            OnboardingSnapshot(completedVersion: 0, needsCurrentOnboarding: true)
        )
        XCTAssertNil(defaults.object(forKey: "captureEnabled"))
    }

    func testCompletingCurrentVersionDoesNotEnableCapture() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "captureEnabled")
        let preferences = OnboardingPreferences(defaults: defaults, currentVersion: 2)

        preferences.completeCurrentVersion()

        XCTAssertEqual(
            preferences.snapshot(),
            OnboardingSnapshot(completedVersion: 2, needsCurrentOnboarding: false)
        )
        XCTAssertFalse(defaults.bool(forKey: "captureEnabled"))
    }

    func testVersionIncreaseRequiresOnlyTheNewOnboardingVersion() {
        let defaults = makeDefaults()
        defaults.set(1, forKey: OnboardingPreferences.completedVersionKey)

        let preferences = OnboardingPreferences(defaults: defaults, currentVersion: 2)

        XCTAssertEqual(
            preferences.snapshot(),
            OnboardingSnapshot(completedVersion: 1, needsCurrentOnboarding: true)
        )
        preferences.completeCurrentVersion()
        XCTAssertEqual(defaults.integer(forKey: OnboardingPreferences.completedVersionKey), 2)
    }

    func testExistingCapturePreferenceMigratesSeenWithoutChangingItsValue() {
        for captureEnabled in [false, true] {
            let defaults = makeDefaults()
            defaults.set(captureEnabled, forKey: "captureEnabled")

            let preferences = OnboardingPreferences(defaults: defaults)

            XCTAssertEqual(
                preferences.snapshot(),
                OnboardingSnapshot(
                    completedVersion: OnboardingPreferences.currentVersion,
                    needsCurrentOnboarding: false
                )
            )
            XCTAssertEqual(defaults.bool(forKey: "captureEnabled"), captureEnabled)
        }
    }

    func testExistingQuickAccessPreferenceMigratesSeenWithoutCreatingCapturePreference() {
        let knownKeys = [
            "quickAccess.cardSize",
            "quickAccessClipsPerRow",
            "quickAccessTrackpadTicks",
            "quickAccess.showsFrequentClips",
            "quickAccess.fadesStripEnds",
            "quickAccess.selectedCardScale",
        ]
        for key in knownKeys {
            let defaults = makeDefaults()
            defaults.set("existing", forKey: key)

            let preferences = OnboardingPreferences(defaults: defaults)

            XCTAssertFalse(preferences.snapshot().needsCurrentOnboarding, key)
            XCTAssertNil(defaults.object(forKey: "captureEnabled"), key)
        }
    }

    func testCorruptCompletedVersionIsNotRewrittenOrTreatedAsComplete() {
        let defaults = makeDefaults()
        defaults.set("not-a-version", forKey: OnboardingPreferences.completedVersionKey)

        let preferences = OnboardingPreferences(defaults: defaults)

        XCTAssertEqual(
            preferences.snapshot(),
            OnboardingSnapshot(completedVersion: 0, needsCurrentOnboarding: true)
        )
        XCTAssertEqual(defaults.string(forKey: OnboardingPreferences.completedVersionKey), "not-a-version")
    }

    func testFutureCompletedVersionRemainsCompleteAndIsNotDowngraded() {
        let defaults = makeDefaults()
        defaults.set(99, forKey: OnboardingPreferences.completedVersionKey)

        let preferences = OnboardingPreferences(defaults: defaults)
        preferences.completeCurrentVersion()

        XCTAssertEqual(
            preferences.snapshot(),
            OnboardingSnapshot(completedVersion: 99, needsCurrentOnboarding: false)
        )
        XCTAssertEqual(defaults.integer(forKey: OnboardingPreferences.completedVersionKey), 99)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
