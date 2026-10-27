import Foundation
import Observation

@MainActor @Observable
final class CapturePreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "captureEnabled")
            onChange?()
        }
    }
    var excludedApplications: [String] {
        didSet {
            defaults.set(excludedApplications, forKey: "captureExcludedApplications")
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "captureEnabled")
        excludedApplications = defaults.stringArray(forKey: "captureExcludedApplications") ?? []
    }

    func addExclusion(_ bundleIdentifier: String) {
        let value = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.utf8.contains(0), !excludedApplications.contains(value) else { return }
        excludedApplications.append(value)
        excludedApplications.sort()
    }

    func removeExclusion(_ bundleIdentifier: String) {
        excludedApplications.removeAll { $0 == bundleIdentifier }
    }
}
