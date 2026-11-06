import AppKit

@MainActor
final class AppEnvironment {
    let captureSession: CaptureSession
    let quickAccessPreferences: QuickAccessPreferences
    let shortcutCoordinator: GlobalShortcutCoordinator
    let launchAtLogin: any LaunchAtLoginControlling
    let onboardingPreferences: OnboardingPreferences
    private(set) var ephemeralPreferencesSuiteName: String?
    private let makePanel: () -> PanelController
    private let makeLibrary: () -> LibraryWindowController
    private let settingsFactory: (() -> SettingsWindowController)?
    private let onboardingFactory: ((OnboardingActions) -> OnboardingWindowController)?
    private let showLibraryOverride: (() -> Void)?
    private var panel: PanelController?
    private var library: LibraryWindowController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    /// Shows the Enable Direct Paste alert and returns the button chosen. Tests replace it, since a real alert waits.
    var runDirectPasteAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    /// Brings Keeptide to the front for the Enable Direct Paste alert. Tests replace it, so that they never bring the
    /// test host forward.
    var activateApp: () -> Void = { NSApplication.shared.activate() }

    init(captureSession: CaptureSession? = nil,
         quickAccessPreferences: QuickAccessPreferences? = nil,
         shortcutCoordinator: GlobalShortcutCoordinator? = nil,
         launchAtLogin: (any LaunchAtLoginControlling)? = nil,
         onboardingPreferences: OnboardingPreferences? = nil,
         makePanel: (() -> PanelController)? = nil,
         makeLibrary: (() -> LibraryWindowController)? = nil,
         makeSettings: (() -> SettingsWindowController)? = nil,
         makeOnboarding: ((OnboardingActions) -> OnboardingWindowController)? = nil,
         showLibrary: (() -> Void)? = nil) {
        let needsEphemeralDefaults = captureSession == nil || quickAccessPreferences == nil
            || shortcutCoordinator == nil || onboardingPreferences == nil
        let ephemeralSuiteName = needsEphemeralDefaults
            ? "Keeptide.AppEnvironment.\(UUID().uuidString)" : nil
        let ephemeralDefaults = ephemeralSuiteName.flatMap(UserDefaults.init(suiteName:))
        let captureSession = captureSession ?? CaptureSession(
            preferences: CapturePreferences(defaults: ephemeralDefaults!)
        )
        let quickAccessPreferences = quickAccessPreferences ?? QuickAccessPreferences(defaults: ephemeralDefaults!)
        captureSession.preservePreferenceIdentity()
        self.captureSession = captureSession
        self.quickAccessPreferences = quickAccessPreferences
        self.shortcutCoordinator = shortcutCoordinator ?? GlobalShortcutCoordinator(
            preferences: GlobalShortcutPreferences(defaults: ephemeralDefaults!),
            shouldInstallHandler: false
        )
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginModel(service: InertLaunchAtLoginService())
        self.onboardingPreferences = onboardingPreferences
            ?? OnboardingPreferences(defaults: ephemeralDefaults!)
        ephemeralPreferencesSuiteName = ephemeralSuiteName
        self.makePanel = makePanel ?? { [weak captureSession] in
            // The panel reads the same preferences the Settings window edits.
            PanelController(state: QuickAccessState(services: { captureSession?.quickAccessServices }),
                            preferences: quickAccessPreferences)
        }
        self.makeLibrary = makeLibrary ?? {
            LibraryWindowController(
                session: captureSession,
                autosaveName: ProcessInfo.processInfo.arguments.contains("--ui-testing")
                    ? nil : "KeeptideLibraryWindow"
            )
        }
        settingsFactory = makeSettings
        onboardingFactory = makeOnboarding
        showLibraryOverride = showLibrary
        captureSession.onServicesChanged = { [weak self] in
            guard let self else { return }
            self.panel?.state.servicesDidChange()
            let lifecycle = self.captureSession.maintenance?.settings
            self.settingsModel.updateLifecycle(lifecycle)
            self.settingsWindow?.updateLifecycle(lifecycle)
        }
    }

    isolated deinit {
        if let ephemeralPreferencesSuiteName {
            UserDefaults(suiteName: ephemeralPreferencesSuiteName)?
                .removePersistentDomain(forName: ephemeralPreferencesSuiteName)
        }
    }

    lazy private(set) var settingsModel = SettingsModel(
        quickAccess: quickAccessPreferences,
        capture: captureSession.preferences,
        lifecycle: captureSession.maintenance?.settings,
        shortcut: shortcutCoordinator,
        launchAtLogin: launchAtLogin,
        directPaste: DirectPasteSettingsModel(
            read: { [weak self] in self?.directPasteAccessState() },
            turnOn: { [weak self] in self?.showEnableDirectPaste() },
            quit: { NSApplication.shared.terminate(nil) }
        ),
        actions: SettingsActions(
            showWelcome: { [weak self] in self?.showOnboarding() },
            exportArchive: { [weak self] in self?.exportLibrary() }
        ),
        canExport: { [weak self] in self?.canExportLibrary ?? false }
    )

    /// Done, and closing the welcome, only complete it; Open Library completes it and opens the Library.
    var onboardingActions: OnboardingActions {
        OnboardingActions(
            done: { [weak self] in self?.onboardingPreferences.completeCurrentVersion() },
            openLibrary: { [weak self] in
                guard let self else { return }
                self.onboardingPreferences.completeCurrentVersion()
                self.showLibrary()
            }
        )
    }

    var panelController: PanelController {
        if let panel { return panel }
        let panel = makePanel()
        self.panel = panel
        captureSession.onRecentClipsChanged = { [weak panel] in panel?.state.recentClipsChanged() }
        // The panel's ⋯ menu does what the menu bar's Open Library and Settings… do.
        panel.onOpenLibrary = { [weak self] in self?.showLibrary() }
        panel.onOpenInLibrary = { [weak self] ref in
            self?.showLibrary()
            self?.libraryWindowController.open(ref)
        }
        panel.onNewSnippet = { [weak self] in
            self?.showLibrary()
            self?.libraryWindowController.newDocument(nil)
        }
        panel.onOpenSettings = { [weak self] in self?.showSettings() }
        panel.onEnableDirectPaste = { [weak self] in self?.showEnableDirectPaste() }
        // The toolbar says why new copies are not kept, while that is so.
        panel.captureNotice = { [weak self] in self?.captureSession.captureNotice }
        return panel
    }

    var libraryWindowController: LibraryWindowController {
        if let library { return library }
        let library = makeLibrary()
        self.library = library
        library.shouldRestoreAccessory = { [weak self, weak library] in
            self?.shouldRestoreAccessory(excluding: library?.window) ?? true
        }
        return library
    }

    var settingsWindowController: SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let settingsWindow = settingsFactory?() ?? SettingsWindowController(
            model: settingsModel
        )
        self.settingsWindow = settingsWindow
        settingsWindow.shouldRestoreAccessory = { [weak self, weak settingsWindow] in
            self?.shouldRestoreAccessory(excluding: settingsWindow?.window) ?? true
        }
        return settingsWindow
    }

    var libraryIsRecentlyDeleted: Bool {
        library?.commands.isRecentlyDeleted == true
    }

    var onboardingWindowController: OnboardingWindowController {
        if let onboardingWindow { return onboardingWindow }
        let actions = onboardingActions
        let onboardingWindow = onboardingFactory?(actions) ?? OnboardingWindowController(
            actions: actions
        )
        self.onboardingWindow = onboardingWindow
        onboardingWindow.shouldRestoreAccessory = { [weak self, weak onboardingWindow] in
            self?.shouldRestoreAccessory(excluding: onboardingWindow?.window) ?? true
        }
        return onboardingWindow
    }

    func showLibrary() {
        panel?.close()
        if let showLibraryOverride {
            showLibraryOverride()
            return
        }
        libraryWindowController.show()
    }

    func showSettings() {
        panel?.close()
        launchAtLogin.refresh()
        settingsModel.directPaste.refresh()
        let lifecycle = captureSession.maintenance?.settings
        settingsModel.updateLifecycle(lifecycle)
        settingsWindowController.updateLifecycle(lifecycle)
        settingsWindowController.show()
    }

    var canExportLibrary: Bool {
        captureSession.isReady && captureSession.exportCoordinator?.canStart == true && !libraryIsRecentlyDeleted
    }

    func exportLibrary() {
        guard canExportLibrary else { return }
        showLibrary()
        libraryWindowController.exportLibrary(nil)
    }

    func showOnboarding() {
        panel?.close()
        onboardingWindowController.show()
    }

    func showOnboardingIfNeeded(force: Bool = false) -> Bool {
        guard force || onboardingPreferences.snapshot().needsCurrentOnboarding else { return false }
        showOnboarding()
        return true
    }

    func applicationDidBecomeActive() {
        launchAtLogin.refresh()
        // Coming back from System Settings, Settings shows what was changed there.
        settingsModel.directPaste.refresh()
    }

    /// Whether Keeptide can paste directly, read through the panel's paste service, the capture session's own; nil
    /// without a library.
    func directPasteAccessState() -> DirectPasteAccessState? {
        if let panel { return panel.state.directPasteAccessState() }
        return captureSession.pasteService?.accessState()
    }

    /// Enable Direct Paste… from the panel's menu, once the panel has closed, and Turn On Direct Paste… in Settings.
    /// Keeptide comes to the front and says what turning direct paste on takes. Open System Settings asks the system
    /// for access, which shows its own prompt the first time, and opens Accessibility settings where it does not grant
    /// it; Cancel asks nothing. The system lets Keeptide see the access only once Keeptide reopens, which the alert
    /// says and the panel and Settings say again until then.
    func showEnableDirectPaste() {
        panel?.close()
        activateApp()
        guard runDirectPasteAlert(Self.enableDirectPasteAlert()) == .alertFirstButtonReturn else { return }
        if let panel {
            panel.state.requestDirectPasteAccess()
        } else {
            captureSession.pasteService?.requestDirectPasteAccess()
        }
        settingsModel.directPaste.refresh()
    }

    /// What Enable Direct Paste… shows before anything is asked of the system.
    static func enableDirectPasteAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Turn On Direct Paste"
        alert.informativeText = "Keeptide pastes by sending ⌘V to the app you were using. Allow Keeptide in "
            + "\(DirectPasteSettingsLocation.path()), then quit and reopen Keeptide. If Keeptide is already on there, "
            + "remove it from the list with − and add it again with + before reopening."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private func shouldRestoreAccessory(excluding closingWindow: NSWindow?) -> Bool {
        let regularWindows = [library?.window, settingsWindow?.window, onboardingWindow?.window]
        return !regularWindows.compactMap { $0 }.contains { $0 !== closingWindow && $0.isVisible }
    }
}

@MainActor
final class InertLaunchAtLoginService: LaunchAtLoginServicing {
    let status: LaunchAtLoginServiceStatus = .unavailable
    func register() async throws {}
    func unregister() async throws {}
}

extension CaptureSession {
    /// What the quick access panel reads and acts through while the library is open; nil while it is not. The frequent
    /// wing reads the same usage store that the session's copies and pastes record their uses in.
    var quickAccessServices: QuickAccessServices? {
        guard let contentRepository, let pasteService else { return nil }
        return QuickAccessServices(
            repository: contentRepository,
            search: searchService,
            paste: pasteService,
            preview: previewService,
            usage: usageStore,
            library: libraryService,
            fileAccess: fileAccessStore,
            fileAccessIdentity: fileAccessIdentity
        )
    }
}
