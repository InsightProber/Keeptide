import Foundation

@MainActor
final class AppEnvironment {
    let settings: AppSettings
    let panelController: PanelController
    let libraryWindowController: LibraryWindowController

    init(
        settings: AppSettings = AppSettings(),
        panelController: PanelController = PanelController(),
        libraryWindowController: LibraryWindowController = LibraryWindowController()
    ) {
        self.settings = settings
        self.panelController = panelController
        self.libraryWindowController = libraryWindowController
    }
}
