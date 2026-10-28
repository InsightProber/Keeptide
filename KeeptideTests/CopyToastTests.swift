import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class CopyToastTests: XCTestCase {
    private let frame = NSRect(x: 200, y: 200, width: 680, height: 496)

    func testToastShowsWithoutTakingKeyAndHidesAfterItsDuration() async throws {
        let toast = CopyToastController(duration: .milliseconds(50))
        let keyWindow = NSApp.keyWindow

        toast.show("Copied — press ⌘V to paste", centeredOn: frame)

        XCTAssertTrue(toast.isVisible)
        let window = try XCTUnwrap(toast.window)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(window.frame.midX, frame.midX, accuracy: 1)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        try await SearchTestSupport.waitUntil(timeout: .seconds(2)) { !toast.isVisible }
        XCTAssertFalse(window.isVisible)
    }

    func testShowingAgainRestartsTheTimer() async throws {
        let toast = CopyToastController(duration: .milliseconds(500))

        toast.show("Copied — press ⌘V to paste", centeredOn: frame)
        try await Task.sleep(for: .milliseconds(300))
        toast.show("Copied — press ⌘V to paste", centeredOn: frame)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(toast.isVisible, "The second copy restarts the toast's time on screen")
        try await SearchTestSupport.waitUntil(timeout: .seconds(2)) { !toast.isVisible }
    }
}
