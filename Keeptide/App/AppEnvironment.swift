import Foundation

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
}

private extension CaptureSession {
    var quickAccessServices: QuickAccessServices? {
        guard let contentRepository, let pasteService else { return nil }
        return QuickAccessServices(repository: contentRepository, search: searchService, paste: pasteService,
                                   preview: previewService)
    }
}
