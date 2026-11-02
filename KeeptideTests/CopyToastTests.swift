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

    func testAMessageCanStayLongerThanTheDefault() async throws {
        let toast = CopyToastController(duration: .milliseconds(50))

        // A toast that says why a paste became a copy stays as long as it is shown for.
        toast.show("The window changed — copied instead. Press ⌘V to paste.", centeredOn: frame,
                   duration: .milliseconds(600))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(toast.isVisible, "Still up after six times the default")
        try await SearchTestSupport.waitUntil(timeout: .seconds(2)) { !toast.isVisible }

        // Shown again without a time of its own, it stays the time it was made with.
        toast.show("Copied — press ⌘V to paste", centeredOn: frame)
        XCTAssertTrue(toast.isVisible)
        try await SearchTestSupport.waitUntil(timeout: .milliseconds(400)) { !toast.isVisible }
    }
}
