import Foundation

@MainActor
final class AppSettings {
    private enum Key {
        static let captureEnabled = "captureEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var captureEnabled: Bool {
        defaults.bool(forKey: Key.captureEnabled)
    }
}
