import Foundation

enum HistoryRetentionPreset: Int, CaseIterable, Codable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case oneYear = 365
}

enum HistoryRetentionChoice: Codable, Hashable, Sendable {
    case preset(HistoryRetentionPreset)
    case custom(days: Int)
    case permanent

    var dayCount: Int? {
        switch self {
        case .preset(let preset): preset.rawValue
        case .custom(let days): days
        case .permanent: nil
        }
    }

    var isValid: Bool {
        switch self {
        case .preset, .permanent: true
        case .custom(let days): days > 0
        }
    }

    var policy: RetentionPolicy? {
        guard isValid else { return nil }
        return dayCount.map(RetentionPolicy.days) ?? .permanent
    }
}

struct LifecyclePreferencesSnapshot: Equatable, Sendable {
    let historyRetention: HistoryRetentionChoice
    let storageWarningLimitBytes: UInt64?
    /// The persisted retention value was unreadable. The safe effective value is permanent until the user chooses.
    let requiresRetentionReview: Bool
}

struct StagedHistoryRetentionChange: Equatable, Sendable {
    let current: HistoryRetentionChoice
    let proposed: HistoryRetentionChoice
    let requiresExplicitConfirmation: Bool
}

enum LifecyclePreferencesError: Error, Equatable {
    case invalidRetention
    case shorteningConfirmationRequired
    case staleChange
    case encodingFailed
}

/// Persistence and confirmation model only. The root UI owns presentation and must explicitly confirm a staged
/// shortening before committing it; committing does not run maintenance or delete anything.
final class LifecyclePreferences {
    static let retentionKey = "lifecycle.historyRetention.v1"
    private static let warningLimitKey = "lifecycle.storageWarningLimitBytes.v1"
    private static let warningDisabledKey = "lifecycle.storageWarningDisabled.v1"
    static let defaultHistoryRetention = HistoryRetentionChoice.preset(.ninetyDays)

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot() -> LifecyclePreferencesSnapshot {
        let retention = loadRetention()
        return LifecyclePreferencesSnapshot(
            historyRetention: retention.choice,
            storageWarningLimitBytes: loadWarningLimit(),
            requiresRetentionReview: retention.requiresReview
        )
    }

    func stageHistoryRetention(_ proposed: HistoryRetentionChoice) throws -> StagedHistoryRetentionChange {
        guard proposed.isValid else { throw LifecyclePreferencesError.invalidRetention }
        let current = snapshot().historyRetention
        return StagedHistoryRetentionChange(
            current: current,
            proposed: proposed,
            requiresExplicitConfirmation: isShorter(proposed, than: current)
        )
    }

    func commit(_ change: StagedHistoryRetentionChange, confirmingShortening: Bool) throws {
        guard change.proposed.isValid else { throw LifecyclePreferencesError.invalidRetention }
        guard snapshot().historyRetention == change.current else { throw LifecyclePreferencesError.staleChange }
        if isShorter(change.proposed, than: change.current) && !confirmingShortening {
            throw LifecyclePreferencesError.shorteningConfirmationRequired
        }
        guard let encoded = try? encoder.encode(change.proposed) else {
            throw LifecyclePreferencesError.encodingFailed
        }
        defaults.set(encoded, forKey: Self.retentionKey)
    }

    /// Nil disables only the warning. It is not a storage quota and does not trigger deletion.
    func setStorageWarningLimitBytes(_ bytes: UInt64?) {
        guard let bytes else {
            defaults.set(true, forKey: Self.warningDisabledKey)
            defaults.removeObject(forKey: Self.warningLimitKey)
            return
        }
        defaults.set(false, forKey: Self.warningDisabledKey)
        defaults.set(String(bytes), forKey: Self.warningLimitKey)
    }

    private func loadRetention() -> (choice: HistoryRetentionChoice, requiresReview: Bool) {
        guard let persisted = defaults.object(forKey: Self.retentionKey) else {
            return (Self.defaultHistoryRetention, false)
        }
        guard let data = persisted as? Data else { return (.permanent, true) }
        guard let choice = try? decoder.decode(HistoryRetentionChoice.self, from: data), choice.isValid else {
            return (.permanent, true)
        }
        return (choice, false)
    }

    private func loadWarningLimit() -> UInt64? {
        if defaults.bool(forKey: Self.warningDisabledKey) { return nil }
        guard let value = defaults.string(forKey: Self.warningLimitKey) else {
            return DiskPressurePolicy.defaultWarningLimitBytes
        }
        return UInt64(value) ?? DiskPressurePolicy.defaultWarningLimitBytes
    }

    private func isShorter(_ proposed: HistoryRetentionChoice, than current: HistoryRetentionChoice) -> Bool {
        switch (proposed.dayCount, current.dayCount) {
        case (nil, _): false
        case (.some, nil): true
        case (.some(let proposedDays), .some(let currentDays)): proposedDays < currentDays
        }
    }
}
