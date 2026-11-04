import Foundation
import Observation

@MainActor @Observable
final class CapturePreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: "captureEnabled")
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

    /// Keeptide records from first launch, and a stored switch, such as the user's pause, is kept. The default is
    /// never written, only a change is: a stored switch marks someone who has used Keeptide before
    /// (`OnboardingPreferences`).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: "captureEnabled") == nil || defaults.bool(forKey: "captureEnabled")
        excludedApplications = Array(Set((defaults.stringArray(forKey: "captureExcludedApplications") ?? []).map(Self.normalized))).sorted()
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
