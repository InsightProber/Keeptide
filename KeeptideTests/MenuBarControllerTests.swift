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
}
