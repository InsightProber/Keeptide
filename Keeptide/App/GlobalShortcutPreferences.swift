import Carbon
import Foundation
import Observation

enum QuickAccessShortcut: String, CaseIterable, Codable, Sendable {
    case commandShiftV
    case commandOptionV
    case commandControlV
    case disabled

    var displayName: String {
        switch self {
        case .commandShiftV: "⇧⌘V"
        case .commandOptionV: "⌥⌘V"
        case .commandControlV: "⌃⌘V"
        case .disabled: "Off"
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .commandShiftV: UInt32(cmdKey | shiftKey)
        case .commandOptionV: UInt32(cmdKey | optionKey)
        case .commandControlV: UInt32(cmdKey | controlKey)
        case .disabled: nil
        }
    }
}

@MainActor @Observable
final class GlobalShortcutPreferences {
    static let selectionKey = "quickAccess.globalShortcut"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var selection: QuickAccessShortcut

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.selectionKey)
            .flatMap(QuickAccessShortcut.init(rawValue:)) ?? .commandShiftV
    }

    func store(_ selection: QuickAccessShortcut) {
        self.selection = selection
        defaults.set(selection.rawValue, forKey: Self.selectionKey)
    }
}
