import AppKit

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
    private var environment: AppEnvironment?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.mainMenu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")

        let environment = AppEnvironment()
        self.environment = environment

        let processInfo = ProcessInfo.processInfo
        let launchConfiguration = LaunchConfiguration(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        menuBarController = MenuBarController(
            panelController: environment.panelController,
            libraryWindowController: environment.libraryWindowController,
            shouldRegisterHotKey: launchConfiguration.shouldRegisterGlobalHotKey
        )

        if launchConfiguration.shouldShowQuickAccess {
            environment.panelController.show()
        }
        if launchConfiguration.shouldShowLibrary {
            environment.libraryWindowController.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
