import Foundation
import Observation

/// How the quick access strip is laid out and how it feels, as the Settings window edits them.
/// A change is stored at once, so the next opening of the strip and the next launch both use it.
@MainActor @Observable
final class QuickAccessPreferences {
    static let densityKey = "quickAccessClipsPerRow"
    static let ticksKey = "quickAccessTrackpadTicks"

    @ObservationIgnored private let defaults: UserDefaults

    var density: StripDensity {
        didSet { defaults.set(density.rawValue, forKey: Self.densityKey) }
    }
    /// Whether a Force Touch trackpad ticks as each clip passes.
    var trackpadTicks: Bool {
        didSet { defaults.set(trackpadTicks, forKey: Self.ticksKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        density = StripDensity.from(defaults.integer(forKey: Self.densityKey))
        // Absent means on; `bool(forKey:)` would read it as off.
        trackpadTicks = defaults.object(forKey: Self.ticksKey) as? Bool ?? true
    }
}
