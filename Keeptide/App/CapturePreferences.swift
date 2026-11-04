import Foundation
import Observation

@MainActor @Observable
final class CapturePreferences {
    /// Where the recording switch is stored.
    static let enabledKey = "captureEnabled"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            onChange?()
        }
    }
    var excludedApplications: [String] {
        didSet {
            guard oldValue != excludedApplications else { return }
            defaults.set(excludedApplications, forKey: "captureExcludedApplications")
            onChange?()
        }
    }

    /// Keeptide records from first launch, and a stored switch, such as the user's pause, is kept. Making the
    /// preferences writes nothing, since a test may make them on the user's own defaults: the launch stores the switch
    /// before it makes them (`settleRecordingDefault(in:)`).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        excludedApplications = Array(Set((defaults.stringArray(forKey: "captureExcludedApplications") ?? []).map(Self.normalized))).sorted()
    }

    /// Stores the recording switch where none is stored, as the launch does before anything reads it. A new install
    /// records. Someone upgrading who never turned recording on, which earlier versions waited for, stays paused: what
    /// an earlier version stored for the welcome or quick access shows they were there (`OnboardingPreferences`).
    /// Once stored, the switch is settled, so a new install whose welcome is done is never taken for an earlier
    /// version's. A stored switch, such as a pause, is kept.
    static func settleRecordingDefault(in defaults: UserDefaults) {
        guard defaults.object(forKey: enabledKey) == nil else { return }
        let usedBefore = ([OnboardingPreferences.completedVersionKey] + OnboardingPreferences.existingPreferenceKeys)
            .contains { defaults.object(forKey: $0) != nil }
        defaults.set(!usedBefore, forKey: enabledKey)
    }

    func addExclusion(_ bundleIdentifier: String) {
        let value = Self.normalized(bundleIdentifier)
        guard !value.isEmpty, !value.utf8.contains(0), !excludedApplications.contains(value) else { return }
        excludedApplications = (excludedApplications + [value]).sorted()
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func removeExclusion(_ bundleIdentifier: String) {
        excludedApplications.removeAll { $0 == Self.normalized(bundleIdentifier) }
    }
}
