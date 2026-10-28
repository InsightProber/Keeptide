import CoreGraphics
import XCTest
@testable import Keeptide

final class PasteTargetTests: XCTestCase {
    func testFrontmostNormalWindowOfTheAppIsChosen() {
        let list = [window(pid: 7, layer: 25, number: 90), window(pid: 9, layer: 0, number: 12),
                    window(pid: 7, layer: 0, number: 41), window(pid: 7, layer: 0, number: 40)]
        XCTAssertEqual(PasteTarget.frontmostWindow(in: list, processIdentifier: 7), 41)
    }

    func testFrontAppWithoutAnOnScreenNormalWindowHasNoTarget() {
        let raisedOnly = [window(pid: 7, layer: 25, number: 90), window(pid: 9, layer: 0, number: 12),
                          window(pid: 7, layer: 3, number: 91)]
        XCTAssertNil(PasteTarget.frontmostWindow(in: raisedOnly, processIdentifier: 7))
        XCTAssertNil(PasteTarget.frontmostWindow(in: [], processIdentifier: 7))
        let unnumbered = window(pid: 7, layer: 0, number: nil)
        XCTAssertNil(PasteTarget.frontmostWindow(in: [unnumbered], processIdentifier: 7))
        XCTAssertEqual(PasteTarget.frontmostWindow(in: [unnumbered, window(pid: 7, layer: 0, number: 41)],
                                                   processIdentifier: 7), 41)
    }

    func testKnownTerminalsCoverTheDesignList() {
        for identifier in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                           "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty"] {
            XCTAssertTrue(KnownTerminals.contains(identifier), identifier)
        }
        XCTAssertFalse(KnownTerminals.contains("com.apple.TextEdit"))
        XCTAssertFalse(KnownTerminals.contains(nil))
        XCTAssertTrue(PasteTarget(processIdentifier: 7, bundleIdentifier: "com.apple.Terminal", name: "Terminal",
                                  windowNumber: 41).isTerminal)
        XCTAssertFalse(PasteTarget(processIdentifier: 7, bundleIdentifier: nil, name: "App", windowNumber: 41).isTerminal)
    }

    func testKeystrokeIsOneCommandVWithLocalKeysHeldBack() throws {
        // Builds the events only. Posting them would paste the general clipboard into the frontmost app.
        let keystroke = try XCTUnwrap(DirectPasteKeystroke.make(keyCode: 9))
        XCTAssertEqual(keystroke.down.type, .keyDown)
        XCTAssertEqual(keystroke.up.type, .keyUp)
        for event in [keystroke.down, keystroke.up] {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 9)
            XCTAssertEqual(event.flags, .maskCommand)
        }
        XCTAssertEqual(keystroke.source.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateSuppressionInterval),
                       [.permitLocalMouseEvents, .permitSystemDefinedEvents])
    }

    /// One CGWindowListCopyWindowInfo entry as Swift receives it: the CFNumber values arrive as NSNumbers.
    private func window(pid: Int32, layer: Int32, number: Int32?) -> [String: Any] {
        var entry: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid),
                                    kCGWindowLayer as String: NSNumber(value: layer)]
        if let number { entry[kCGWindowNumber as String] = NSNumber(value: number) }
        return entry
    }
}
