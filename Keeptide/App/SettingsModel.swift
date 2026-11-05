import Foundation
import Observation

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case shortcuts
    case privacy
    case iCloud

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .iCloud: "iCloud"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .privacy: "hand.raised"
        case .iCloud: "icloud.slash"
        }
    }
}

enum CloudSettingsState: Equatable, Sendable {
    case unavailableInThisBuild
}

/// What Settings says about direct paste. It reads the system when Keeptide becomes active and when Settings opens,
/// so a change made in System Settings shows once the user comes back.
@MainActor @Observable
final class DirectPasteSettingsModel {
    /// nil without a library to paste from.
    private(set) var state: DirectPasteAccessState?
    /// Explains what turning direct paste on takes and asks the system for access, as Enable Direct Paste… does.
    let turnOn: @MainActor () -> Void
    /// Quits Keeptide, so that reopening it lets it use the access it was given.
    let quit: @MainActor () -> Void
    @ObservationIgnored private let read: @MainActor () -> DirectPasteAccessState?

    init(read: @escaping @MainActor () -> DirectPasteAccessState? = { nil },
         turnOn: @escaping @MainActor () -> Void = {},
         quit: @escaping @MainActor () -> Void = {}) {
        self.read = read
        self.turnOn = turnOn
        self.quit = quit
    }

    func refresh() {
        let current = read()
        if current != state { state = current }
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
    let directPaste: DirectPasteSettingsModel
    let cloud: CloudSettingsState
    let actions: SettingsActions
    @ObservationIgnored private let canExport: @MainActor () -> Bool
    var canExportLibrary: Bool { canExport() }
    @ObservationIgnored private var temporaryPreferencesSuite: String?
    var selectedTab: SettingsTab = .general

    init(
        quickAccess: QuickAccessPreferences,
        capture: CapturePreferences,
        lifecycle: LifecycleSettingsModel?,
        shortcut: GlobalShortcutCoordinator,
        launchAtLogin: any LaunchAtLoginControlling,
        directPaste: DirectPasteSettingsModel = DirectPasteSettingsModel(),
        cloud: CloudSettingsState = .unavailableInThisBuild,
        actions: SettingsActions = .inert,
        canExport: @escaping @MainActor () -> Bool = { false }
    ) {
        self.quickAccess = quickAccess
        self.capture = capture
        self.lifecycle = lifecycle
        self.shortcut = shortcut
        self.launchAtLogin = launchAtLogin
        self.directPaste = directPaste
        self.cloud = cloud
        self.actions = actions
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
