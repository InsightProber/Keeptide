import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testQuitMenuRequestsTerminationOnlyOnceWhileShutdownIsPending() throws {
        var requestCount = 0
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: {},
            canRequestQuit: { true },
            requestQuit: { requestCount += 1 },
            shouldRegisterHotKey: false
        )
        let item = try XCTUnwrap(controller.menu?.item(withTitle: "Quit Keeptide"))
        let action = try XCTUnwrap(item.action)

        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(item.isEnabled)
    }

    func testQuitMenuAndHandlerHonorAnExistingApplicationShutdown() throws {
        var requestCount = 0
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: {},
            canRequestQuit: { false },
            requestQuit: { requestCount += 1 },
            shouldRegisterHotKey: false
        )
        let menu = try XCTUnwrap(controller.menu)
        controller.menuWillOpen(menu)
        let item = try XCTUnwrap(menu.item(withTitle: "Quit Keeptide"))
        let action = try XCTUnwrap(item.action)

        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(requestCount, 0)
    }

    func testSettingsItemUsesCommandCommaAndOpensSettings() throws {
        var settingsOpened = 0
        var libraryOpened = 0
        let controller = MenuBarController(
            showQuickAccess: {},
            toggleQuickAccess: {},
            showLibrary: { libraryOpened += 1 },
            showSettings: { settingsOpened += 1 },
            shouldRegisterHotKey: false
        )
        let item = try XCTUnwrap(controller.menu?.item(withTitle: "Settings…"))
        let action = try XCTUnwrap(item.action)

        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))

        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(libraryOpened, 0)
    }
}
