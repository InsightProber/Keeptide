import Foundation
import Observation

/// How the quick access strip is laid out and how it feels, as the Settings window edits them.
/// A change is stored at once, so the next opening of the strip and the next launch both use it.
@MainActor @Observable
final class QuickAccessPreferences {
    static let cardSizeKey = "quickAccess.cardSize"
    /// Where the choice of clips in a row was stored before the cards had sizes. It is only read, and only while no
    /// card size is stored.
    static let clipsPerRowKey = "quickAccessClipsPerRow"
    static let ticksKey = "quickAccessTrackpadTicks"
    static let showsFrequentClipsKey = "quickAccess.showsFrequentClips"

    @ObservationIgnored private let defaults: UserDefaults

    var cardSize: CardSize {
        didSet { defaults.set(cardSize.rawValue, forKey: Self.cardSizeKey) }
    }
    /// Whether a Force Touch trackpad ticks as each clip passes.
    var trackpadTicks: Bool {
        didSet { defaults.set(trackpadTicks, forKey: Self.ticksKey) }
    }
    /// Whether the strip opens with the frequent clips at its left. Absent means on.
    var showsFrequentClips: Bool {
        didSet { defaults.set(showsFrequentClips, forKey: Self.showsFrequentClipsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cardSize = Self.storedCardSize(in: defaults)
        // Absent means on; `bool(forKey:)` would read it as off.
        trackpadTicks = defaults.object(forKey: Self.ticksKey) as? Bool ?? true
        showsFrequentClips = defaults.object(forKey: Self.showsFrequentClipsKey) as? Bool ?? true
    }

    /// Stored values are not trusted: one that is not a card size gives the default. Where none is stored, the
    /// choice of clips in a row stands in for it: 7 in a row gave the largest previews, 11 the smallest, and
    /// anything else, 9 included, is the default.
    private static func storedCardSize(in defaults: UserDefaults) -> CardSize {
        if let stored = defaults.object(forKey: cardSizeKey) {
            return (stored as? String).flatMap(CardSize.init(rawValue:)) ?? .medium
        }
        return switch defaults.integer(forKey: clipsPerRowKey) {
        case 7: .large
        case 11: .small
        default: .medium
        }
    }
}
