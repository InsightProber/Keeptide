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
         makePanel: @escaping () -> PanelController = { PanelController() },
         makeLibrary: (() -> LibraryWindowController)? = nil) {
        let captureSession = captureSession ?? CaptureSession()
        self.settings = settings
        self.captureSession = captureSession
        self.makePanel = makePanel
        self.makeLibrary = makeLibrary ?? { LibraryWindowController(session: captureSession) }
    }

    var panelController: PanelController {
        if let panel { return panel }
        let panel = makePanel()
        self.panel = panel
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
