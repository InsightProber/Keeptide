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
    static let selectedCardScaleKey = "quickAccess.selectedCardScale"

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
    /// How much larger the strip draws the selected card than the others, from 1.00, as large, to 1.25, as the
    /// Settings slider moves it in steps of 0.01. It is stored kept to that range and to hundredths. Absent means 1.12.
    var selectedCardScale: Double {
        didSet { defaults.set(Self.keptCardScale(selectedCardScale), forKey: Self.selectedCardScaleKey) }
    }

    /// The strip's style as these settings make it, with the enlargement as it is stored. The panel takes it as it
    /// opens.
    var stripStyle: StripStyle {
        StripStyle(selectedScale: CGFloat(Self.keptCardScale(selectedCardScale)))
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        cardSize = Self.storedCardSize(in: defaults)
        // Absent means on; `bool(forKey:)` would read it as off.
        trackpadTicks = defaults.object(forKey: Self.ticksKey) as? Bool ?? true
        showsFrequentClips = defaults.object(forKey: Self.showsFrequentClipsKey) as? Bool ?? true
        selectedCardScale = Self.storedCardScale(in: defaults)
    }

    /// Stored values are not trusted: a number is kept to 1.00–1.25 and to hundredths, and anything else gives the
    /// default. A flag is stored as a number too, and would read as 1 or 0, so it is told apart by its type.
    private static func storedCardScale(in defaults: UserDefaults) -> Double {
        guard let number = defaults.object(forKey: selectedCardScaleKey) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return Double(StripStyle.standard.selectedScale)
        }
        return keptCardScale(number.doubleValue)
    }

    /// `scale` taken to the nearer end of 1.00–1.25 and rounded to hundredths; one that is not finite gives the
    /// default.
    private static func keptCardScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return Double(StripStyle.standard.selectedScale) }
        let range = StripStyle.scaleRange
        return min(max((scale * 100).rounded() / 100, Double(range.lowerBound)), Double(range.upperBound))
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
