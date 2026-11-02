import AppKit

@MainActor
final class AppEnvironment {
    let settings: AppSettings
    let captureSession: CaptureSession
    let quickAccessPreferences: QuickAccessPreferences
    private let makePanel: () -> PanelController
    private let makeLibrary: () -> LibraryWindowController
    private let makeSettings: () -> SettingsWindowController
    private var panel: PanelController?
    private var library: LibraryWindowController?
    private var settingsWindow: SettingsWindowController?
    /// Shows the Enable Direct Paste alert and returns the button chosen. Tests replace it, since a real alert waits.
    var runDirectPasteAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    /// Brings Keeptide to the front for the Enable Direct Paste alert. Tests replace it, so that they never bring the
    /// test host forward.
    var activateApp: () -> Void = { NSApplication.shared.activate() }

    init(settings: AppSettings = AppSettings(),
         captureSession: CaptureSession? = nil,
         quickAccessPreferences: QuickAccessPreferences = QuickAccessPreferences(),
         makePanel: (() -> PanelController)? = nil,
         makeLibrary: (() -> LibraryWindowController)? = nil,
         makeSettings: (() -> SettingsWindowController)? = nil) {
        let captureSession = captureSession ?? CaptureSession()
        self.settings = settings
        self.captureSession = captureSession
        self.quickAccessPreferences = quickAccessPreferences
        self.makePanel = makePanel ?? { [weak captureSession] in
            // The panel reads the same preferences the Settings window edits.
            PanelController(state: QuickAccessState(services: { captureSession?.quickAccessServices }),
                            preferences: quickAccessPreferences)
        }
        self.makeLibrary = makeLibrary ?? { LibraryWindowController(session: captureSession) }
        self.makeSettings = makeSettings ?? { SettingsWindowController(preferences: quickAccessPreferences) }
    }

    var panelController: PanelController {
        if let panel { return panel }
        let panel = makePanel()
        self.panel = panel
        captureSession.onServicesChanged = { [weak panel] in panel?.state.servicesDidChange() }
        captureSession.onRecentClipsChanged = { [weak panel] in panel?.state.recentClipsChanged() }
        // The panel's ⋯ menu does what the menu bar's Open Library and Settings… do.
        panel.onOpenLibrary = { [weak self] in self?.showLibrary() }
        panel.onOpenSettings = { [weak self] in self?.showSettings() }
        panel.onEnableDirectPaste = { [weak self] in self?.showEnableDirectPaste() }
        return panel
    }

    var libraryWindowController: LibraryWindowController {
        if let library { return library }
        let library = makeLibrary()
        self.library = library
        return library
    }

    var settingsWindowController: SettingsWindowController {
        if let settingsWindow { return settingsWindow }
        let settingsWindow = makeSettings()
        self.settingsWindow = settingsWindow
        return settingsWindow
    }

    func showLibrary() {
        panel?.close()
        libraryWindowController.show()
    }

    func showSettings() {
        panel?.close()
        settingsWindowController.show()
    }

    /// Enable Direct Paste… from the panel's menu, once the panel has closed. Keeptide comes to the front and says what
    /// turning direct paste on takes. Open System Settings asks the system for access, which shows its own prompt the
    /// first time, and opens Accessibility settings where it does not grant it; Cancel asks nothing. The system lets
    /// Keeptide see the access only once Keeptide reopens, which the alert says and the panel says again until then.
    func showEnableDirectPaste() {
        panel?.close()
        activateApp()
        guard runDirectPasteAlert(Self.enableDirectPasteAlert()) == .alertFirstButtonReturn else { return }
        panel?.state.requestDirectPasteAccess()
    }

    /// What Enable Direct Paste… shows before anything is asked of the system.
    static func enableDirectPasteAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Turn On Direct Paste"
        alert.informativeText = "Keeptide pastes by sending ⌘V to the app you were using. Allow Keeptide in System "
            + "Settings › Privacy & Security › Accessibility, then quit and reopen Keeptide."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

private extension CaptureSession {
    var quickAccessServices: QuickAccessServices? {
        guard let contentRepository, let pasteService else { return nil }
        return QuickAccessServices(repository: contentRepository, search: searchService, paste: pasteService,
                                   preview: previewService)
    }
}
