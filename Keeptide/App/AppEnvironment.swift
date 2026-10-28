import Foundation

@MainActor
final class AppEnvironment {
    let settings: AppSettings
    let captureSession: CaptureSession
    private let makePanel: () -> PanelController
    private let makeLibrary: () -> LibraryWindowController
    private var panel: PanelController?
    private var library: LibraryWindowController?

    init(settings: AppSettings = AppSettings(),
         captureSession: CaptureSession? = nil,
         makePanel: (() -> PanelController)? = nil,
         makeLibrary: (() -> LibraryWindowController)? = nil) {
        let captureSession = captureSession ?? CaptureSession()
        self.settings = settings
        self.captureSession = captureSession
        self.makePanel = makePanel ?? {
            PanelController(state: QuickAccessState(services: { [weak captureSession] in
                captureSession?.quickAccessServices
            }))
        }
        self.makeLibrary = makeLibrary ?? { LibraryWindowController(session: captureSession) }
    }

    var panelController: PanelController {
        if let panel { return panel }
        let panel = makePanel()
        self.panel = panel
        captureSession.onServicesChanged = { [weak panel] in panel?.state.servicesDidChange() }
        captureSession.onRecentClipsChanged = { [weak panel] in panel?.state.recentClipsChanged() }
        return panel
    }

    var libraryWindowController: LibraryWindowController {
        if let library { return library }
        let library = makeLibrary()
        self.library = library
        return library
    }

    func showLibrary() {
        panel?.close()
        libraryWindowController.show()
    }
}

private extension CaptureSession {
    var quickAccessServices: QuickAccessServices? {
        guard let contentRepository, let pasteService else { return nil }
        return QuickAccessServices(repository: contentRepository, search: searchService, paste: pasteService)
    }
}
