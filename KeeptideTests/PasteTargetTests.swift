import CoreGraphics
import XCTest
@testable import Keeptide

final class PasteTargetTests: XCTestCase {
    func testFrontmostNormalWindowOfTheAppIsChosen() {
        // A raised window of its own, such as a menu, sits above the app's normal windows and is not the target.
        let list = [window(pid: 7, layer: 25, number: 90), window(pid: 7, layer: 0, number: 41),
                    window(pid: 7, layer: 0, number: 40), window(pid: 9, layer: 0, number: 12)]
        XCTAssertEqual(targetWindow(in: list), 41)
    }

    func testFrontAppWithoutAnOnScreenNormalWindowHasNoTarget() {
        // Only raised windows of its own, as a menu bar app has, whether or not another app's window is on screen.
        let raisedOnly = [window(pid: 7, layer: 25, number: 90), window(pid: 7, layer: 3, number: 91)]
        XCTAssertNil(targetWindow(in: raisedOnly))
        XCTAssertNil(targetWindow(in: [window(pid: 7, layer: 25, number: 90), window(pid: 9, layer: 0, number: 12),
                                       window(pid: 7, layer: 3, number: 91)]))
        // No window of its own on screen, as when they are all minimized: only another app's.
        XCTAssertNil(targetWindow(in: [window(pid: 9, layer: 0, number: 12)]))
        XCTAssertNil(targetWindow(in: []))
        let unnumbered = window(pid: 7, layer: 0, number: nil)
        XCTAssertNil(targetWindow(in: [unnumbered]))
        XCTAssertEqual(targetWindow(in: [unnumbered, window(pid: 7, layer: 0, number: 41)]), 41)
    }

    func testAnotherAppsWindowOnTopMeansNoTarget() {
        let list = [window(pid: 9, layer: 0, number: 12), window(pid: 7, layer: 0, number: 41)]
        XCTAssertNil(PasteTarget.targetWindow(in: list, frontProcessIdentifier: 7, ownProcessIdentifier: 3))
    }

    func testKeeptidesOwnWindowsAreIgnoredForTheTopCheck() {
        // Raised windows, such as the menu bar's, sit above every normal window and do not count either.
        let list = [window(pid: 9, layer: 25, number: 90), window(pid: 3, layer: 0, number: 5),
                    window(pid: 7, layer: 0, number: 41), window(pid: 9, layer: 0, number: 12)]
        XCTAssertEqual(PasteTarget.targetWindow(in: list, frontProcessIdentifier: 7, ownProcessIdentifier: 3), 41)
    }

    func testTargetNameFallsBackToTheBundleIdentifierThenApp() {
        XCTAssertEqual(PasteTarget.name(localizedName: "TextEdit", bundleIdentifier: "com.apple.TextEdit"), "TextEdit")
        for blank in [nil, "", " \t"] {
            XCTAssertEqual(PasteTarget.name(localizedName: blank, bundleIdentifier: "com.apple.TextEdit"),
                           "com.apple.TextEdit")
            XCTAssertEqual(PasteTarget.name(localizedName: blank, bundleIdentifier: nil), "App")
            XCTAssertEqual(PasteTarget.name(localizedName: nil, bundleIdentifier: blank), "App")
        }
    }

    func testKnownTerminalsCoverTheDesignList() {
        for identifier in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                           "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty",
                           "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio", "dev.warp.Warp-Preview"] {
            XCTAssertTrue(KnownTerminals.contains(identifier), identifier)
        }
        XCTAssertTrue(KnownTerminals.contains("com.googlecode.iTerm2"))
        XCTAssertFalse(KnownTerminals.contains("com.apple.TextEdit"))
        XCTAssertFalse(KnownTerminals.contains(nil))
        XCTAssertTrue(PasteTarget(processIdentifier: 7, bundleIdentifier: "com.apple.Terminal", name: "Terminal",
                                  windowNumber: 41).isTerminal)
        XCTAssertFalse(PasteTarget(processIdentifier: 7, bundleIdentifier: nil, name: "App", windowNumber: 41).isTerminal)
    }

    func testKeystrokeIsOneCommandVWithLocalKeysHeldBack() throws {
        // Builds the events only. Posting them would paste the general clipboard into the frontmost app.
        let keystroke = try XCTUnwrap(DirectPasteKeystroke.make(keyCode: 9))
        XCTAssertEqual(keystroke.source.sourceStateID, .combinedSessionState)
        XCTAssertEqual(keystroke.down.type, .keyDown)
        XCTAssertEqual(keystroke.up.type, .keyUp)
        for event in [keystroke.down, keystroke.up] {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 9)
            XCTAssertEqual(event.flags, .maskCommand)
        }
        XCTAssertEqual(keystroke.source.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateSuppressionInterval),
                       [.permitLocalMouseEvents, .permitSystemDefinedEvents])
    }

    /// The window to paste into with process 7 in front, as Keeptide, process 3, reads the list.
    private func targetWindow(in list: [[String: Any]]) -> Int? {
        PasteTarget.targetWindow(in: list, frontProcessIdentifier: 7, ownProcessIdentifier: 3)
    }

    /// One CGWindowListCopyWindowInfo entry as Swift receives it: the CFNumber values arrive as NSNumbers.
    private func window(pid: Int32, layer: Int32, number: Int32?) -> [String: Any] {
        var entry: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid),
                                    kCGWindowLayer as String: NSNumber(value: layer)]
        if let number { entry[kCGWindowNumber as String] = NSNumber(value: number) }
        return entry
    }
}
