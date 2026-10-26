import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class AppLaunchTests: XCTestCase {
    func testCaptureStartsDisabled() {
        let suiteName = "AppLaunchTests.captureStartsDisabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.captureEnabled)
    }

    func testXCTestLaunchDoesNotRegisterTheGlobalShortcut() {
        let configuration = LaunchConfiguration(
            arguments: [],
            environment: ["XCTestConfigurationFilePath": "/synthetic/test.xctestconfiguration"]
        )

        XCTAssertFalse(configuration.shouldRegisterGlobalHotKey)
    }

    func testOpeningAndClosingQuickPanelDoesNotChangeAnIsolatedPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AppLaunchTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let initialChangeCount = pasteboard.changeCount
        let controller = PanelController()

        controller.show()
        controller.close()

        XCTAssertEqual(pasteboard.changeCount, initialChangeCount)
    }

    func testClosingLibraryDoesNotRequestApplicationTermination() {
        let delegate = AppDelegate()
        let controller = LibraryWindowController()

        controller.show()
        controller.close()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
