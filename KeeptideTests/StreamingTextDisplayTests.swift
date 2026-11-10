import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class StreamingTextDisplayTests: XCTestCase {
    private var time = 0.0
    private var announced: [String] = []
    private let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")

    private func makeDisplay() -> StreamingTextDisplay {
        let display = StreamingTextDisplay(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        display.now = { [unowned self] in time }
        display.isOnScreen = { _ in true }
        display.reducesMotion = { false }
        display.postAnnouncement = { [unowned self] _, message in announced.append(message) }
        return display
    }

    func testTextAlreadyThereShowsAtOnce() {
        let display = makeDisplay()
        display.update(text: "Already here", mode: .writing)
        XCTAssertEqual(display.shownText, "Already here")
    }

    func testTextThatArrivesLaterIsTypedOutByAppending() {
        let display = makeDisplay()
        display.update(text: "", mode: .writing)
        display.update(text: "Hello, world. This arrives in one burst.", mode: .writing)
        XCTAssertEqual(display.shownText, "")
        display.tick(at: 0.05)
        XCTAssertFalse(display.shownText.isEmpty)
        XCTAssertLessThan(display.shownText.count, 40)
        var previous = display.shownText
        for frame in 4...30 {
            display.tick(at: Double(frame) / 60)
            XCTAssertTrue(display.shownText.hasPrefix(previous), "text is only ever added")
            previous = display.shownText
        }
        XCTAssertEqual(display.shownText, "Hello, world. This arrives in one burst.")
    }

    func testTextGrowingInRandomPiecesIsShownWholeCharacterByCharacter() {
        let display = makeDisplay()
        let text = "Team 👩‍💻 cafe\u{301} 🇺🇸 done. 季度报告周五截止。Ready 👍🏽!"
        let scalars = Array(text.unicodeScalars)
        let boundaries = Set(text.indices.map { $0.utf16Offset(in: text) } + [text.utf16.count])
        var random = SeededRandom(seed: 7)
        var received = 0
        display.update(text: "", mode: .writing)
        var frame = 0
        while received < scalars.count || display.shownText != text {
            if received < scalars.count {
                received = min(scalars.count, received + Int(random.next() % 4) + 1)
                var piece = String.UnicodeScalarView()
                piece.append(contentsOf: scalars[..<received])
                time = Double(frame) / 120
                display.update(text: String(piece), mode: .writing)
            }
            frame += 1
            display.tick(at: Double(frame) / 120)
            let shown = display.shownText
            XCTAssertTrue(text.utf16.starts(with: shown.utf16), "only a prefix of the text is shown")
            if received == scalars.count {
                XCTAssertTrue(boundaries.contains(shown.utf16.count), "“\(shown)” ends inside a character")
            }
            if frame > 2_000 { return XCTFail("the display never caught up") }
        }
    }

    func testACharacterCompletedByTheNextDeltaIsShownWhole() {
        let display = makeDisplay()
        display.update(text: "", mode: .writing)
        display.update(text: "Team 👩", mode: .writing)
        display.tick(at: 1)
        XCTAssertEqual(display.shownText, "Team 👩")
        time = 2
        display.update(text: "Team 👩\u{200D}💻 done", mode: .writing)
        display.tick(at: 3)
        XCTAssertEqual(display.shownText, "Team 👩‍💻 done")
    }

    func testTheSelectionStaysPutWhileTextIsAppended() {
        let display = makeDisplay()
        display.update(text: "", mode: .writing)
        display.update(text: "First part", mode: .writing)
        display.tick(at: 1)
        display.textView.setSelectedRange(NSRange(location: 6, length: 4))
        time = 2
        display.update(text: "First part, and a second part", mode: .writing)
        display.tick(at: 2.1)
        display.tick(at: 3)
        XCTAssertEqual(display.shownText, "First part, and a second part")
        XCTAssertEqual(display.textView.selectedRange(), NSRange(location: 6, length: 4), "even touching the old end")
    }

    func testTextThatChangesOtherThanByGrowingShowsAtOnce() {
        let display = makeDisplay()
        display.update(text: "", mode: .writing)
        display.update(text: "Draft that is", mode: .writing)
        display.update(text: "Rewritten", mode: .writing)
        XCTAssertEqual(display.shownText, "Rewritten")
    }

    func testStoppingShowsEverythingReceived() {
        let display = makeDisplay()
        display.update(text: "", mode: .writing)
        let text = "A sentence that is still being typed when the person stops"
        display.update(text: text, mode: .writing)
        display.tick(at: 0.05)
        XCTAssertNotEqual(display.shownText, text)
        display.update(text: text, mode: .still)
        XCTAssertEqual(display.shownText, text)
    }

    func testReduceMotionShowsTextAsItArrives() {
        let display = makeDisplay()
        display.reducesMotion = { true }
        display.update(text: "", mode: .writing)
        display.update(text: "A whole chunk", mode: .writing)
        XCTAssertEqual(display.shownText, "A whole chunk")
    }

    func testADisplayOffScreenDoesNotType() {
        let display = makeDisplay()
        display.isOnScreen = { _ in false }
        display.update(text: "", mode: .writing)
        display.update(text: "Arrived while hidden", mode: .writing)
        XCTAssertEqual(display.shownText, "Arrived while hidden")
    }

    func testCopyGoesToTheHandlerAndIsOffWithoutOne() {
        let display = makeDisplay()
        display.update(text: "Copy me", mode: .still)
        XCTAssertFalse(display.textView.validateMenuItem(copyItem), "no handler, no Copy")

        var copied: [String] = []
        display.onCopy = { copied.append($0) }
        display.textView.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(display.textView.validateMenuItem(copyItem))
        display.textView.copy(nil)
        XCTAssertEqual(copied, ["Copy"])
    }

    func testCopyingEverythingNeedsAWholeResult() {
        let display = makeDisplay()
        var copied: [String] = []
        display.onCopy = { copied.append($0) }
        display.update(text: "A stopped translation", mode: .still)
        display.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(display.textView.validateMenuItem(copyItem), "part of a result can only be copied by selecting")

        display.allowsCopyingAll = true
        XCTAssertTrue(display.textView.validateMenuItem(copyItem))
        XCTAssertTrue(display.textView.validateUserInterfaceItem(copyItem))
        display.textView.copy(nil)
        XCTAssertEqual(copied, ["A stopped translation"])
    }

    func testCopyingEverythingWhileItIsTypedOutTakesTheWholeText() {
        let display = makeDisplay()
        var copied: [String] = []
        display.onCopy = { copied.append($0) }
        display.allowsCopyingAll = true
        display.update(text: "", mode: .writing)
        display.update(text: "Hello, world. This arrives in one burst.", mode: .finishing)
        display.tick(at: 0.05)
        XCTAssertLessThan(display.shownText.count, 40, "Still being typed out")

        display.textView.copy(nil)

        XCTAssertEqual(copied, ["Hello, world. This arrives in one burst."])
    }

    func testCopyTakesEverySelectedRange() {
        let display = makeDisplay()
        var copied: [String] = []
        display.onCopy = { copied.append($0) }
        display.update(text: "one two three", mode: .still)
        display.textView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 3)), NSValue(range: NSRange(location: 8, length: 5)),
        ]
        display.textView.copy(nil)
        XCTAssertEqual(copied, ["one\nthree"])
    }

    func testTheCaretShowsOnlyWhileWriting() {
        let display = makeDisplay()
        display.update(text: "", mode: .writing)
        XCTAssertTrue(display.isCaretVisible)
        display.update(text: "Finished text", mode: .finishing)
        XCTAssertTrue(display.isCaretVisible, "the rest is still being typed")
        display.tick(at: 1)
        XCTAssertFalse(display.isCaretVisible)
        display.update(text: "Finished text", mode: .still)
        XCTAssertFalse(display.isCaretVisible)
    }

    func testVoiceOverHearsWhenWritingStartsAndEnds() {
        let display = makeDisplay()
        display.announcements = .init(start: "Translating with Claude Haiku 5.5", finish: "Translation ready")
        display.update(text: "", mode: .still)
        XCTAssertEqual(announced, [], "a queued job hasn't started")
        display.update(text: "", mode: .writing)
        display.update(text: "Some", mode: .writing)
        display.update(text: "Some text", mode: .writing)
        XCTAssertEqual(announced, ["Translating with Claude Haiku 5.5"])
        display.update(text: "Some text", mode: .finishing)
        XCTAssertEqual(announced, ["Translating with Claude Haiku 5.5", "Translation ready"])
    }

    func testOnlyAWholeResultAnnouncesItsEndAndCanBeCopiedWhole() {
        let announcements = StreamingTextDisplay.Announcements(start: "Translating", finish: "Translation ready")
        let cutOff = StreamingTextView(
            snapshot: GenerationSnapshot(phase: .finished(.truncated), texts: [.main: "Cut"]),
            announcements: announcements)
        XCTAssertNil(cutOff.announcements.finish)
        XCTAssertFalse(cutOff.allowsCopyingAll)
        let whole = StreamingTextView(
            snapshot: GenerationSnapshot(phase: .finished(.completed), texts: [.main: "Done"]),
            announcements: announcements)
        XCTAssertEqual(whole.announcements.finish, "Translation ready")
        XCTAssertTrue(whole.allowsCopyingAll)
        XCTAssertEqual(whole.mode, .finishing)
    }
}

/// A small deterministic generator, so a failing random case can be replayed.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}
