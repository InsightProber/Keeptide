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
            showQuickAccess: { environment.panelController.show() },
            toggleQuickAccess: { environment.panelController.toggle() },
            showLibrary: { environment.showLibrary() },
            shouldRegisterHotKey: launchConfiguration.shouldRegisterGlobalHotKey,
            registration: launchConfiguration.usesSyntheticHotKey
                ? .system(keyCode: { UInt32(kVK_ANSI_9) }, modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
                : .system()
        )

        if launchConfiguration.shouldShowQuickAccess {
            environment.panelController.show()
        }
        if launchConfiguration.shouldShowLibrary {
            environment.showLibrary()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment?.showLibrary()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
