import Foundation

@MainActor
final class AppEnvironment {
    let settings: AppSettings
    private let makePanel: () -> PanelController
    private let makeLibrary: () -> LibraryWindowController
    private var panel: PanelController?
    private var library: LibraryWindowController?

    init(settings: AppSettings = AppSettings(),
         makePanel: @escaping () -> PanelController = { PanelController() },
         makeLibrary: @escaping () -> LibraryWindowController = { LibraryWindowController() }) {
        self.settings = settings
        self.makePanel = makePanel
        self.makeLibrary = makeLibrary
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
