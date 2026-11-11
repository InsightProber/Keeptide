import AppKit
import Foundation
import FoundationModels
import Observation

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case shortcuts
    case privacy
    case ai
    case iCloud

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .privacy: "Privacy"
        case .ai: "AI"
        case .iCloud: "iCloud"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .privacy: "hand.raised"
        case .ai: "sparkles"
        case .iCloud: "icloud.slash"
        }
    }
}

/// What Settings › AI says of Apple Intelligence on this Mac. Keeptide only reads whether the system has it: nothing
/// uses it yet, and translation and text recognition run with the system's own engines either way.
enum AppleIntelligenceState: Equatable, Sendable {
    case available
    case notOnThisMac
    case turnedOff
    case gettingReady

    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available: self = .available
        case .unavailable(.appleIntelligenceNotEnabled): self = .turnedOff
        case .unavailable(.modelNotReady): self = .gettingReady
        case .unavailable: self = .notOnThisMac
        }
    }

    /// As the system reports it now. It can change while Keeptide runs, as the person turns it on or its model
    /// finishes getting ready.
    static var current: Self { Self(SystemLanguageModel.default.availability) }

    var sentence: String {
        switch self {
        case .available: "Apple Intelligence is available on this Mac. Keeptide doesn't use it yet."
        case .notOnThisMac: "Apple Intelligence isn't available on this Mac. " + Self.stillWorks
        case .turnedOff: "Apple Intelligence is turned off. " + Self.stillWorks
        case .gettingReady: "Apple Intelligence is getting ready. " + Self.stillWorks
        }
    }

    private static let stillWorks = "Translation and text recognition still work on this Mac."
}

/// What Settings › AI reads of the engines on this Mac: whether Apple Intelligence is there, the languages Translation
/// translates into, and what translating from each of the person's languages into the one translations are made in
/// needs. The page reads them as it appears and as Keeptide becomes active again, so a language downloaded in System
/// Settings meanwhile shows once the person comes back.
@MainActor @Observable
final class AISettingsModel {
    /// A language as Settings names it: its code, as translations name it, without a region, and its name.
    struct Language: Equatable, Identifiable, Sendable {
        let code: String
        let name: String
        var id: String { code }

        init(_ language: Locale.Language) {
            code = language.translationCode
            name = language.displayName
        }
    }

    /// One of the person's languages, and what translating from it into the target needs: nothing once both are
    /// downloaded. It is said as the language menu says it.
    struct Row: Equatable, Identifiable, Sendable {
        let language: Language
        let note: TranslationLanguageMenu.Note?
        var id: String { language.code }
        var name: String { language.name }
        var status: String { note?.title ?? "Downloaded" }
        /// What VoiceOver reads, as in "Japanese, not downloaded".
        var spokenName: String { "\(name), \(note?.spoken ?? "downloaded")" }
    }

    let preferences: QuickAccessPreferences
    /// As the system has it now: the system's model is observable, so the page follows it as it changes.
    var appleIntelligence: AppleIntelligenceState { readAppleIntelligence() }
    /// The language translations are made in, as quick access would make one now; nil until read.
    private(set) var target: Language?
    /// What Translate to offers besides Last Used: the person's languages, then the others Translation offers.
    private(set) var targetChoices: (preferred: [Language], others: [Language]) = ([], [])
    /// The person's languages and English, but the target, with what translating from each into it needs.
    private(set) var languages: [Row] = []
    /// The language fixed in Settings where Translate to doesn't list it: before Translation's languages are read, or
    /// where Translation doesn't offer it. nil where none is fixed or it is listed.
    var unlistedFixedTarget: Language? {
        guard let code = preferences.fixedTranslationTarget.flatMap(TranslationTargets.code(of:)),
              !(targetChoices.preferred + targetChoices.others).contains(where: { $0.code == code }) else { return nil }
        return Language(Locale.Language(identifier: code))
    }
    /// Whether Translation's languages have been read, so that a language Translate to doesn't list isn't offered.
    var choicesAreKnown: Bool { !targetChoices.preferred.isEmpty || !targetChoices.others.isEmpty }
    @ObservationIgnored private let translator: any TranslationEngine
    @ObservationIgnored private let readAppleIntelligence: @MainActor () -> AppleIntelligenceState
    @ObservationIgnored private let preferredLanguages: @MainActor () -> [String]
    @ObservationIgnored private let open: @MainActor (URL) -> Void
    @ObservationIgnored private var reads = 0
    /// What Translation listed last, for a moment it lists nothing, as quick access keeps it.
    @ObservationIgnored private var lastOffered: [Locale.Language] = []

    init(preferences: QuickAccessPreferences, translator: any TranslationEngine,
         appleIntelligence: @escaping @MainActor () -> AppleIntelligenceState = { .current },
         preferredLanguages: @escaping @MainActor () -> [String] = { Locale.preferredLanguages },
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.preferences = preferences
        self.translator = translator
        readAppleIntelligence = appleIntelligence
        self.preferredLanguages = preferredLanguages
        self.open = open
    }

    /// Opens Language & Region in System Settings, where Translation Languages… downloads and removes the languages.
    func manageLanguages() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        open(url)
    }

    /// Reads it all again. A read that a newer one overtakes, or one cancelled, changes nothing.
    func refresh() async {
        reads += 1
        let read = reads
        var offered: [Locale.Language] = []
        for language in await translator.supportedLanguages() where !offered.contains(language) {
            offered.append(language)
        }
        if offered.isEmpty { offered = lastOffered } else { lastOffered = offered }
        let preferred = preferredLanguages()
        let target = TranslationTargets.target(fixed: preferences.fixedTranslationTarget,
                                               lastUsed: preferences.translationTarget, preferred: preferred,
                                               offered: offered)
        let ordered = TranslationTargets.ordered(preferred: preferred, offered: offered)
        var rows: [Row] = []
        for language in ordered.preferred where !language.isSameLanguage(as: target) && !Task.isCancelled {
            let status = await translator.status(of: TranslationPair(source: language, target: target))
            rows.append(Row(language: Language(language), note: TranslationLanguageMenu.Note(status)))
        }
        guard read == reads, !Task.isCancelled else { return }
        self.target = Language(target)
        targetChoices = (ordered.preferred.map(Language.init), ordered.others.map(Language.init))
        languages = rows
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
    var exportArchive: (@MainActor () -> Void)?

    static let inert = Self(showWelcome: {}, exportArchive: nil)
}

@MainActor @Observable
final class SettingsModel {
    let quickAccess: QuickAccessPreferences
    let capture: CapturePreferences
    private(set) var lifecycle: LifecycleSettingsModel?
    let shortcut: GlobalShortcutCoordinator
    let launchAtLogin: any LaunchAtLoginControlling
    let directPaste: DirectPasteSettingsModel
    let ai: AISettingsModel
    let cloud: CloudSettingsState
    let actions: SettingsActions
    @ObservationIgnored private let canExport: @MainActor () -> Bool
    var canExportLibrary: Bool { canExport() }
    @ObservationIgnored private var temporaryPreferencesSuite: String?
    var selectedTab: SettingsTab = .general
    /// The ignored-applications sheet, shown over the Settings window.
    var showsIgnoredApplications = false

    func presentIgnoredApplications() { showsIgnoredApplications = true }

    init(
        quickAccess: QuickAccessPreferences,
        capture: CapturePreferences,
        lifecycle: LifecycleSettingsModel?,
        shortcut: GlobalShortcutCoordinator,
        launchAtLogin: any LaunchAtLoginControlling,
        directPaste: DirectPasteSettingsModel = DirectPasteSettingsModel(),
        ai: AISettingsModel? = nil,
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
        self.ai = ai ?? AISettingsModel(preferences: quickAccess, translator: OnDeviceTranslationEngine())
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
