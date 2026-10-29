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
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.mainMenu = ApplicationMenuBuilder.makeMainMenu(applicationName: "Keeptide")

        let processInfo = ProcessInfo.processInfo
        let launchConfiguration = LaunchConfiguration(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        // The one place that wires direct paste to the system. A test session pastes only into the system test host.
        let environment = AppEnvironment(captureSession: CaptureSession(directPaste: .live))
        self.environment = environment

        if launchConfiguration.shouldInitializeCaptureSession {
            initializationTask = Task {
                await environment.captureSession.initialize(
                    testSessionID: launchConfiguration.captureTestSessionID,
                    cleanupTestSession: launchConfiguration.shouldCleanupCaptureTestSession,
                    seedSyntheticClips: launchConfiguration.shouldSeedSyntheticClips,
                    manualPasteQA: launchConfiguration.shouldStartManualPasteQA
                )
            }
        }
        menuBarController = MenuBarController(
            showQuickAccess: { environment.panelController.show() },
            toggleQuickAccess: { environment.panelController.toggle() },
            showLibrary: { environment.showLibrary() },
            showSettings: { environment.showSettings() },
            captureIsReady: { environment.captureSession.isReady && !environment.captureSession.isPausing },
            captureIsEnabled: { environment.captureSession.isRecording },
            captureStatus: { environment.captureSession.status },
            toggleCapture: {
                environment.captureSession.preferences.isEnabled.toggle()
            },
            canRequestQuit: { [weak self] in self?.isShuttingDown == false },
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

    /// The application menu's Settings… (⌘,), which reaches the delegate through the responder chain.
    @objc func showSettings(_ sender: Any?) {
        environment?.showSettings()
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
        guard !isShuttingDown, let environment else { return .terminateNow }
        isShuttingDown = true
        let initializationTask = initializationTask
        Task {
            await initializationTask?.value
            await environment.captureSession.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
