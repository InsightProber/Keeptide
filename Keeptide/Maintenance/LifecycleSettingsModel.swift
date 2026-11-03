import Foundation
import Observation

enum LifecycleSettingsPhase: Equatable, Sendable {
    case idle
    case evaluatingImpact
    case awaitingConfirmation
    case applying
    case failed
}

struct LifecycleRetentionConfirmation: Equatable, Sendable {
    let change: StagedHistoryRetentionChange
    let historyCount: Int
}

enum LifecycleRetentionOption: String, CaseIterable, Sendable {
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneYear
    case custom
    case permanent
}

enum LifecycleSettingsModelError: Error, Equatable {
    case impactUnavailable
    case invalidImpact
}

/// Main-actor state for the Settings window. It never deletes content itself: injected callbacks
/// evaluate the exact current-store impact, apply the staged CAS change, and refresh read-only usage.
@MainActor @Observable
final class LifecycleSettingsModel {
    typealias Impact = @MainActor (HistoryRetentionChoice) async throws -> Int
    typealias Apply = @MainActor (StagedHistoryRetentionChange, Bool) async throws
        -> LifecyclePreferencesSnapshot
    typealias UsageRefresh = @MainActor () async throws -> StorageUsageReport?

    private(set) var snapshot: LifecyclePreferencesSnapshot
    private(set) var selectedRetention: HistoryRetentionChoice
    var customDays: String
    private(set) var warningLimitGiB: Int
    private(set) var usage: StorageUsageReport?
    private(set) var phase: LifecycleSettingsPhase = .idle
    private(set) var pendingConfirmation: LifecycleRetentionConfirmation?
    private(set) var message: String?
    private(set) var isRefreshingUsage = false

    @ObservationIgnored private let preferences: LifecyclePreferences
    @ObservationIgnored private let impact: Impact
    @ObservationIgnored private let applyChange: Apply
    @ObservationIgnored private let usageRefresh: UsageRefresh
    @ObservationIgnored private var generation: UInt64 = 0

    init(
        preferences: LifecyclePreferences,
        impact: Impact? = nil,
        apply: Apply? = nil,
        usageRefresh: UsageRefresh? = nil
    ) {
        let initial = preferences.snapshot()
        self.preferences = preferences
        self.snapshot = initial
        self.selectedRetention = initial.historyRetention
        self.customDays = initial.historyRetention.dayCount.map(String.init) ?? "90"
        self.warningLimitGiB = Self.gibibytes(from: initial.storageWarningLimitBytes)
        self.impact = impact ?? { _ in throw LifecycleSettingsModelError.impactUnavailable }
        self.applyChange = apply ?? { change, confirmed in
            try preferences.commit(change, confirmingShortening: confirmed)
            return preferences.snapshot()
        }
        self.usageRefresh = usageRefresh ?? { nil }
    }

    var requiresRetentionReview: Bool { snapshot.requiresRetentionReview }
    var warningIsEnabled: Bool { snapshot.storageWarningLimitBytes != nil }

    var selectedOption: LifecycleRetentionOption {
        switch selectedRetention {
        case .preset(.oneDay): .oneDay
        case .preset(.sevenDays): .sevenDays
        case .preset(.thirtyDays): .thirtyDays
        case .preset(.ninetyDays): .ninetyDays
        case .preset(.oneYear): .oneYear
        case .custom: .custom
        case .permanent: .permanent
        }
    }

    func selectOption(_ option: LifecycleRetentionOption) async {
        guard phase != .applying else { return }
        switch option {
        case .oneDay: await selectRetention(.preset(.oneDay))
        case .sevenDays: await selectRetention(.preset(.sevenDays))
        case .thirtyDays: await selectRetention(.preset(.thirtyDays))
        case .ninetyDays: await selectRetention(.preset(.ninetyDays))
        case .oneYear: await selectRetention(.preset(.oneYear))
        case .custom:
            generation &+= 1
            selectedRetention = .custom(days: Int(customDays) ?? 0)
            pendingConfirmation = nil
            phase = .idle
            message = nil
        case .permanent: await selectRetention(.permanent)
        }
    }

    func selectRetention(_ proposed: HistoryRetentionChoice) async {
        guard phase != .applying else { return }
        generation &+= 1
        let request = generation
        pendingConfirmation = nil
        message = nil
        selectedRetention = proposed

        let change: StagedHistoryRetentionChange
        do {
            change = try preferences.stageHistoryRetention(proposed)
        } catch {
            fail(error, request: request)
            return
        }

        if change.requiresExplicitConfirmation {
            phase = .evaluatingImpact
            do {
                let count = try await impact(proposed)
                guard request == generation, selectedRetention == proposed else { return }
                guard count >= 0 else { throw LifecycleSettingsModelError.invalidImpact }
                pendingConfirmation = LifecycleRetentionConfirmation(
                    change: change,
                    historyCount: count
                )
                phase = .awaitingConfirmation
            } catch {
                guard request == generation else { return }
                fail(error, request: request)
            }
            return
        }

        await apply(change, confirmed: false, request: request)
    }

    func submitCustomRetention() async {
        guard phase != .applying else { return }
        guard let days = Int(customDays.trimmingCharacters(in: .whitespacesAndNewlines)), days > 0 else {
            generation &+= 1
            pendingConfirmation = nil
            selectedRetention = .custom(days: 0)
            phase = .failed
            message = "Enter a whole number of days greater than zero."
            return
        }
        await selectRetention(.custom(days: days))
    }

    func confirmShortening() async {
        guard let confirmation = pendingConfirmation else { return }
        generation &+= 1
        let request = generation
        pendingConfirmation = nil
        await apply(confirmation.change, confirmed: true, request: request)
    }

    func cancelConfirmation() {
        generation &+= 1
        pendingConfirmation = nil
        selectedRetention = snapshot.historyRetention
        phase = .idle
        message = nil
    }

    func reload() {
        guard phase != .applying else { return }
        generation &+= 1
        install(preferences.snapshot())
        pendingConfirmation = nil
        phase = .idle
        message = nil
    }

    func setWarningEnabled(_ enabled: Bool) {
        let bytes = enabled ? Self.bytes(fromGiB: warningLimitGiB) : nil
        preferences.setStorageWarningLimitBytes(bytes)
        snapshot = preferences.snapshot()
        warningLimitGiB = Self.gibibytes(from: snapshot.storageWarningLimitBytes)
    }

    func setWarningLimitGiB(_ value: Int) {
        let normalized = min(max(value, 1), 1_024)
        warningLimitGiB = normalized
        guard warningIsEnabled else { return }
        preferences.setStorageWarningLimitBytes(Self.bytes(fromGiB: normalized))
        snapshot = preferences.snapshot()
    }

    func refreshUsage() async {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        do {
            usage = try await usageRefresh()
        } catch {
            message = "Storage usage could not be refreshed."
        }
    }

    private func apply(
        _ change: StagedHistoryRetentionChange,
        confirmed: Bool,
        request: UInt64
    ) async {
        phase = .applying
        do {
            let updated = try await applyChange(change, confirmed)
            guard request == generation else { return }
            install(updated)
            pendingConfirmation = nil
            phase = .idle
            message = nil
        } catch {
            guard request == generation else { return }
            // Read the persisted truth again. A callback that failed before its CAS leaves the old value;
            // a callback that committed before a later failure must not be cosmetically reported as unchanged.
            install(preferences.snapshot())
            pendingConfirmation = nil
            phase = .failed
            message = "The retention update did not finish. The saved setting was reloaded for review."
        }
    }

    private func fail(_ error: Error, request: UInt64) {
        guard request == generation else { return }
        selectedRetention = snapshot.historyRetention
        pendingConfirmation = nil
        phase = .failed
        switch error {
        case LifecycleSettingsModelError.impactUnavailable, LifecycleSettingsModelError.invalidImpact:
            message = "Keeptide could not check how many clips would be affected. The setting was not changed."
        default:
            message = "The retention setting was not changed. Please try again."
        }
    }

    private func install(_ updated: LifecyclePreferencesSnapshot) {
        snapshot = updated
        selectedRetention = updated.historyRetention
        if case .custom(let days) = updated.historyRetention { customDays = String(days) }
        warningLimitGiB = Self.gibibytes(from: updated.storageWarningLimitBytes)
    }

    private static func gibibytes(from bytes: UInt64?) -> Int {
        guard let bytes else { return 2 }
        let gib = UInt64(1_024 * 1_024 * 1_024)
        return min(max(Int((bytes + gib - 1) / gib), 1), 1_024)
    }

    private static func bytes(fromGiB value: Int) -> UInt64 {
        UInt64(value) * UInt64(1_024 * 1_024 * 1_024)
    }
}
