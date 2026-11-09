import AppKit
import Carbon

@main
enum KeeptideApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Made when the app finishes launching; a test gives a delegate its own.
    var environment: AppEnvironment?
    private var menuBarController: MenuBarController?
    private var initializationTask: Task<Void, Never>?
    private var ephemeralPreferencesSuiteName: String?
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.mainMenu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")

        let processInfo = ProcessInfo.processInfo
        let launchConfiguration = LaunchConfiguration(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        #if DEBUG
        let manualPasteQASession = launchConfiguration.shouldStartManualPasteQA
            ? ManualPasteQASession(id: UUID()) : nil
        #endif
        let preferencesDefaults: UserDefaults = {
            if let testSessionID = launchConfiguration.captureTestSessionID {
                return UserDefaults(suiteName: CaptureTestConfiguration(id: testSessionID).preferencesSuite)!
            }
            #if DEBUG
            if let manualPasteQASession {
                return UserDefaults(suiteName: manualPasteQASession.preferencesSuite)!
            }
            #endif
            if launchConfiguration.shouldUseEphemeralApplicationState {
                let suiteName = "Keeptide.Launch.\(UUID().uuidString)"
                ephemeralPreferencesSuiteName = suiteName
                return UserDefaults(suiteName: suiteName)!
            }
            return .standard
        }()
        let (onboardingPreferences, capturePreferences) = Self.launchPreferences(in: preferencesDefaults)
        let captureSession = CaptureSession(preferences: capturePreferences, directPaste: .live)
        let shortcutCoordinator = GlobalShortcutCoordinator(
            preferences: GlobalShortcutPreferences(defaults: preferencesDefaults),
            shouldInstallHandler: launchConfiguration.shouldRegisterGlobalHotKey,
            registration: Self.shortcutRegistration(for: launchConfiguration)
        )
        // The one place that wires direct paste to the system. A test session pastes only into the system test host.
        let launchAtLogin: any LaunchAtLoginControlling =
            launchConfiguration.shouldUseEphemeralApplicationState
            || launchConfiguration.captureTestSessionID != nil
            || launchConfiguration.shouldStartManualPasteQA
            ? LaunchAtLoginModel(service: InertLaunchAtLoginService())
            : LaunchAtLoginModel()
        let environment = AppEnvironment(
            captureSession: captureSession,
            quickAccessPreferences: QuickAccessPreferences(defaults: preferencesDefaults),
            shortcutCoordinator: shortcutCoordinator,
            launchAtLogin: launchAtLogin,
            onboardingPreferences: onboardingPreferences
        )
        self.environment = environment

        if launchConfiguration.shouldInitializeCaptureSession {
            initializationTask = Task {
                #if DEBUG
                if let manualPasteQASession {
                    await environment.captureSession.open(manualPasteQA: manualPasteQASession)
                } else {
                    await environment.captureSession.initialize(
                        testSessionID: launchConfiguration.captureTestSessionID,
                        cleanupTestSession: launchConfiguration.shouldCleanupCaptureTestSession,
                        seedSyntheticClips: launchConfiguration.shouldSeedSyntheticClips,
                        seedSyntheticSnippets: launchConfiguration.shouldSeedSyntheticSnippets,
                        fakeTextRecognition: launchConfiguration.usesFakeTextRecognition
                    )
                }
                #else
                await environment.captureSession.initialize(
                    testSessionID: launchConfiguration.captureTestSessionID,
                    cleanupTestSession: launchConfiguration.shouldCleanupCaptureTestSession,
                    seedSyntheticClips: launchConfiguration.shouldSeedSyntheticClips
                )
                #endif
            }
        }
        menuBarController = Self.makeMenuBarController(
            environment: environment, launchConfiguration: launchConfiguration,
            canRequestQuit: { [weak self] in self?.isShuttingDown == false }
        )

        let showedOnboarding = (launchConfiguration.shouldForceOnboarding
            || launchConfiguration.shouldPresentOnboardingIfNeeded)
            && environment.showOnboardingIfNeeded(force: launchConfiguration.shouldForceOnboarding)
        if !showedOnboarding {
            if launchConfiguration.shouldShowQuickAccess {
                environment.panelController.show()
            }
            if launchConfiguration.shouldShowLibrary {
                environment.showLibrary()
            }
            if launchConfiguration.shouldShowSettings {
                environment.showSettings()
            }
        }
    }

    /// The welcome's preferences and capture's, from the defaults this launch uses. The welcome looks for what an
    /// earlier version stored, its recording switch among it, before the launch removes the switch, which nothing reads
    /// any more: Keeptide keeps new copies whenever it runs.
    static func launchPreferences(in defaults: UserDefaults)
        -> (onboarding: OnboardingPreferences, capture: CapturePreferences) {
        let onboarding = OnboardingPreferences(defaults: defaults)
        defaults.removeObject(forKey: OnboardingPreferences.retiredRecordingSwitchKey)
        return (onboarding, CapturePreferences(defaults: defaults))
    }

    /// The status menu, wired to `environment`'s panel, windows and capture session.
    static func makeMenuBarController(environment: AppEnvironment, launchConfiguration: LaunchConfiguration,
                                      canRequestQuit: @escaping () -> Bool) -> MenuBarController {
        MenuBarController(
            showQuickAccess: { environment.panelController.show() },
            toggleQuickAccess: { environment.panelController.toggle() },
            showLibrary: { environment.showLibrary() },
            showSettings: { environment.showSettings() },
            showWelcome: { environment.showOnboarding() },
            captureNotice: { environment.captureSession.captureNotice },
            canRequestQuit: canRequestQuit,
            shouldRegisterHotKey: launchConfiguration.shouldRegisterGlobalHotKey,
            shortcutCoordinator: environment.shortcutCoordinator
        )
    }

    /// UI tests use a deliberately unusual chord and never claim the user's configured shortcut. The same
    /// coordinator remains the single state source consumed by Settings and the menu.
    private static func shortcutRegistration(for configuration: LaunchConfiguration) -> GlobalShortcutRegistration {
        guard configuration.usesSyntheticHotKey else { return .system() }
        var registration = GlobalShortcutRegistration.system(resolveSemanticV: { UInt32(kVK_ANSI_9) })
        let systemRegister = registration.register
        registration.register = { keyCode, modifiers, options, reference in
            systemRegister(
                keyCode,
                AppDelegate.syntheticModifiers(for: modifiers),
                options,
                &reference
            )
        }
        return registration
    }

    static func syntheticModifiers(for modifiers: UInt32) -> UInt32 {
        if modifiers & UInt32(shiftKey) != 0 {
            return UInt32(cmdKey | shiftKey | optionKey | controlKey)
        }
        if modifiers & UInt32(optionKey) != 0 {
            return UInt32(cmdKey | optionKey | shiftKey)
        }
        return UInt32(cmdKey | controlKey | optionKey)
    }

    /// The application menu's Settings… (⌘,), which reaches the delegate through the responder chain.
    @objc func showSettings(_ sender: Any?) {
        environment?.showSettings()
    }

    @objc func exportLibrary(_ sender: Any?) {
        environment?.exportLibrary()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        environment?.applicationDidBecomeActive()
    }

    /// Opening Keeptide again, as with a click on its Dock icon, shows the Library. While a window is on screen,
    /// such as Settings, the app comes forward with the windows it has instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        environment?.showLibrary()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateCancel }
        guard let environment else { return .terminateNow }
        isShuttingDown = true
        let initializationTask = initializationTask
        Task {
            await initializationTask?.value
            if let workspace = environment.captureSession.libraryWorkspace,
               !(await workspace.prepareToClose()) {
                isShuttingDown = false
                environment.showLibrary()
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await environment.captureSession.shutdown()
            if let ephemeralPreferencesSuiteName {
                UserDefaults(suiteName: ephemeralPreferencesSuiteName)?
                    .removePersistentDomain(forName: ephemeralPreferencesSuiteName)
                self.ephemeralPreferencesSuiteName = nil
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func newDocument(_ sender: Any?) {
        environment?.showLibrary()
        environment?.libraryWindowController.newDocument(sender)
    }

    @objc func searchLibrary(_ sender: Any?) {
        environment?.showLibrary()
        environment?.libraryWindowController.searchLibrary(sender)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(exportLibrary(_:)) {
            guard let session = environment?.captureSession else { return false }
            return session.exportCoordinator?.canStart == true
                && environment?.libraryIsRecentlyDeleted != true
        }
        return true
    }
}
