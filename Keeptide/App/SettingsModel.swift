import Foundation
import Observation

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case shortcuts
    case recordingAndPrivacy
    case iCloud

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .recordingAndPrivacy: "Recording & Privacy"
        case .iCloud: "iCloud"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .recordingAndPrivacy: "hand.raised"
        case .iCloud: "icloud.slash"
        }
    }
}

enum CloudSettingsState: Equatable, Sendable {
    case unavailableInThisBuild
}

enum SettingsRecordingState: Equatable {
    case waitingForLibrary
    case recording
    case pausing
    case paused
    case unavailable(String)

    func message(consentEnabled: Bool) -> String {
        switch self {
        case .waitingForLibrary:
            return consentEnabled ? "Recording will start when the local library is ready."
                : "Recording is off. The local library is opening."
        case .recording: return "Recording new copies."
        case .pausing: return "Finishing the current capture before pausing."
        case .paused: return "Recording is paused."
        case .unavailable(let reason): return reason
        }
    }
}

struct SettingsActions {
    var showWelcome: @MainActor () -> Void
    var manageIgnoredApplications: @MainActor () -> Void
    var exportArchive: (@MainActor () -> Void)?

    static let inert = Self(showWelcome: {}, manageIgnoredApplications: {}, exportArchive: nil)
}

@MainActor @Observable
final class SettingsModel {
    let quickAccess: QuickAccessPreferences
    let capture: CapturePreferences
    private(set) var lifecycle: LifecycleSettingsModel?
    let shortcut: GlobalShortcutCoordinator
    let launchAtLogin: any LaunchAtLoginControlling
    let cloud: CloudSettingsState
    let actions: SettingsActions
    @ObservationIgnored private let readRecordingState: @MainActor () -> SettingsRecordingState
    @ObservationIgnored private let canChangeRecording: @MainActor () -> Bool
    @ObservationIgnored private let canExport: @MainActor () -> Bool
    var canExportLibrary: Bool { canExport() }
    var recordingState: SettingsRecordingState { readRecordingState() }
    var canChangeRecordingConsent: Bool { canChangeRecording() }
    var recordingStatusDescription: String { recordingState.message(consentEnabled: capture.isEnabled) }
    @ObservationIgnored private var temporaryPreferencesSuite: String?
    var selectedTab: SettingsTab = .general

    init(
        quickAccess: QuickAccessPreferences,
        capture: CapturePreferences,
        lifecycle: LifecycleSettingsModel?,
        shortcut: GlobalShortcutCoordinator,
        launchAtLogin: any LaunchAtLoginControlling,
        cloud: CloudSettingsState = .unavailableInThisBuild,
        actions: SettingsActions = .inert,
        recordingState: @escaping @MainActor () -> SettingsRecordingState = { .unavailable("Recording is unavailable.") },
        canChangeRecording: @escaping @MainActor () -> Bool = { false },
        canExport: @escaping @MainActor () -> Bool = { false }
    ) {
        self.quickAccess = quickAccess
        self.capture = capture
        self.lifecycle = lifecycle
        self.shortcut = shortcut
        self.launchAtLogin = launchAtLogin
        self.cloud = cloud
        self.actions = actions
        readRecordingState = recordingState
        self.canChangeRecording = canChangeRecording
        self.canExport = canExport
    }

    func updateLifecycle(_ lifecycle: LifecycleSettingsModel?) {
        guard !Self.sameIdentity(self.lifecycle, lifecycle) else { return }
        self.lifecycle = lifecycle
    }

    static func compatibility(
        quickAccess: QuickAccessPreferences,
        lifecycle: LifecycleSettingsModel?
    ) -> SettingsModel {
        let suite = "Keeptide.SettingsCompatibility.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("An isolated settings preferences suite is required")
        }
        defaults.set(QuickAccessShortcut.disabled.rawValue, forKey: GlobalShortcutPreferences.selectionKey)
        let model = SettingsModel(
            quickAccess: quickAccess,
            capture: CapturePreferences(defaults: defaults),
            lifecycle: lifecycle,
            shortcut: GlobalShortcutCoordinator(preferences: GlobalShortcutPreferences(defaults: defaults)),
            launchAtLogin: UnavailableLaunchAtLoginController()
        )
        model.temporaryPreferencesSuite = suite
        return model
    }

    isolated deinit {
        if let temporaryPreferencesSuite {
            UserDefaults(suiteName: temporaryPreferencesSuite)?
                .removePersistentDomain(forName: temporaryPreferencesSuite)
        }
    }

    private static func sameIdentity(
        _ lhs: LifecycleSettingsModel?,
        _ rhs: LifecycleSettingsModel?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let lhs), .some(let rhs)): lhs === rhs
        default: false
        }
    }
}

@MainActor @Observable
private final class UnavailableLaunchAtLoginController: LaunchAtLoginControlling {
    let state: LaunchAtLoginState = .unavailable
    let isBusy = false
    func refresh() {}
    func setEnabled(_ enabled: Bool) async {}
}
