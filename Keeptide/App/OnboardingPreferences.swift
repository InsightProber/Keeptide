import Foundation

struct OnboardingSnapshot: Equatable, Sendable {
    let completedVersion: Int
    let needsCurrentOnboarding: Bool
}

@MainActor
final class OnboardingPreferences {
    static let currentVersion = 1
    static let completedVersionKey = "onboarding.completedVersion"

    private static let existingPreferenceKeys = [
        "captureEnabled",
        "quickAccess.cardSize",
        "quickAccessClipsPerRow",
        "quickAccessTrackpadTicks",
        "quickAccess.showsFrequentClips",
        "quickAccess.fadesStripEnds",
        "quickAccess.selectedCardScale",
    ]

    private let defaults: UserDefaults
    private let currentVersion: Int

    init(defaults: UserDefaults = .standard, currentVersion: Int = OnboardingPreferences.currentVersion) {
        self.defaults = defaults
        self.currentVersion = max(currentVersion, 1)
        migrateExistingUserIfNeeded()
    }

    func snapshot() -> OnboardingSnapshot {
        let completedVersion = storedCompletedVersion
        return OnboardingSnapshot(
            completedVersion: completedVersion,
            needsCurrentOnboarding: completedVersion < currentVersion
        )
    }

    func completeCurrentVersion() {
        guard storedCompletedVersion < currentVersion else { return }
        defaults.set(currentVersion, forKey: Self.completedVersionKey)
    }

    private var storedCompletedVersion: Int {
        guard let number = defaults.object(forKey: Self.completedVersionKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= Double(Int.max) else {
            return 0
        }
        return number.intValue
    }

    private func migrateExistingUserIfNeeded() {
        guard defaults.object(forKey: Self.completedVersionKey) == nil,
              Self.existingPreferenceKeys.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return
        }
        defaults.set(currentVersion, forKey: Self.completedVersionKey)
    }
}
