import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Keeptide

@MainActor
final class QuickAccessStripViewTests: XCTestCase {
    /// A band 1360 pt wide with frames 164 pt wide and 176 pt apart, docked 24 pt in from its ends: the geometry the
    /// numbers below were worked out for. It is no card size's own.
    private var metrics: StripMetrics {
        StripMetrics(cardSize: .medium, bandWidth: 1360, frameSize: CGSize(width: 164, height: 109), gap: 12,
                     cornerRadius: 12, dockInset: 24, headerHeight: 56, footerHeight: 30, iconSize: 40, toolbarGap: 20,
                     bottomPadding: 22)
    }
    private var centre: CGFloat { metrics.bandWidth / 2 }
    /// The middle of the frame resting at the left dock.
    private var dock: CGFloat { metrics.dockInset + metrics.frameSize.width / 2 }

    func testSelectedFrameIsCentredInTheBand() throws {
        let strip = makeStrip()
        let rows = makeRows(20)

        strip.show(rows, selection: rows[5].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        let selected = try XCTUnwrap(drawings(in: strip).first { $0.rootView.isSelected })
        XCTAssertEqual(title(of: selected), "Row 5")
        XCTAssertEqual(drawings(in: strip).filter { $0.rootView.isSelected }.count, 1)
        let frame = rect(of: selected, in: strip)
        XCTAssertEqual(frame.midX, centre, accuracy: 0.5)
        XCTAssertEqual(frame.midY, strip.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(frame.size, metrics.frameSize)
        // Newer clips to the left and older ones to the right, a frame and a gap apart.
        XCTAssertEqual(try midX(of: "Row 4", in: strip), centre - metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 6", in: strip), centre + metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 9", in: strip), centre + 4 * metrics.step, accuracy: 0.5)

        // A narrow screen keeps the card size, and the frames are drawn for it.
        let narrow = StripLayout.metrics(for: .large, visibleWidth: 1024)
        let narrowStrip = makeStrip(narrow)
        narrowStrip.show(rows, selection: rows[5].id, details: [:], metrics: narrow,
                         applicationNames: ApplicationNames())
        XCTAssertFalse(drawings(in: narrowStrip).isEmpty)
        XCTAssertTrue(drawings(in: narrowStrip).allSatisfy { $0.rootView.metrics == narrow })
        XCTAssertEqual(try midX(of: "Row 5", in: narrowStrip), narrow.bandWidth / 2, accuracy: 0.5)
        XCTAssertEqual(try rect(titled: "Row 5", in: narrowStrip).size, narrow.frameSize)
    }

    func testEveryFrameTakesItsCardSizesCorners() throws {
        let rows = makeRows(20)
        for size in CardSize.allCases {
            let sized = StripLayout.metrics(for: size, visibleWidth: 1440)
            let strip = makeStrip(sized)
            strip.show(rows, selection: rows[5].id, details: [:], metrics: sized, applicationNames: ApplicationNames())

            // Each frame is drawn with the card size's corners, and so is the wash its host lays over it on hover.
            let frames = drawings(in: strip)
            XCTAssertFalse(frames.isEmpty)
            for drawing in frames {
                XCTAssertEqual(drawing.rootView.metrics.cornerRadius, sized.cornerRadius, "\(size)")
                let wash = try XCTUnwrap(drawing.superview?.subviews.first { $0 !== drawing }, "\(size)")
                XCTAssertEqual(wash.layer?.cornerRadius, sized.cornerRadius, "\(size)")
            }
        }
    }

    func testTheFilmRestsAtItsEndsAndTheSelectionWalksAlongIt() throws {
        let strip = makeStrip()
        let rows = makeRows(20)

        // The newest clip rests at the left dock with the older ones to its right. Short of the middle the ring
        // walks along the film, which stays where it is.
        for index in 0...3 {
            strip.show(rows, selection: rows[index].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            XCTAssertEqual(selectedTitle(in: strip), "Row \(index)")
            XCTAssertEqual(try midX(of: "Row 0", in: strip), dock, accuracy: 0.5)
            XCTAssertEqual(try midX(of: "Row \(index)", in: strip), dock + CGFloat(index) * metrics.step, accuracy: 0.5)
        }
        // One step more would take the ring past the middle, so the film moves instead.
        strip.show(rows, selection: rows[4].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(try midX(of: "Row 4", in: strip), centre, accuracy: 0.5)

        // The oldest clip rests at the right dock once it is known to be the oldest.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(try rect(titled: "Row 19", in: strip).maxX, metrics.bandWidth - metrics.dockInset, accuracy: 0.5)
        // While more may follow, the film keeps the last clip there is in the middle.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames(),
                   oldestIsLoaded: false)
        XCTAssertEqual(try midX(of: "Row 19", in: strip), centre, accuracy: 0.5)
    }

    func testLostSelectionLeavesTheDockEmpty() throws {
        let strip = makeStrip()
        let rows = makeRows(20)
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // The selected clip disappears, and the state selects nothing in its place.
        let remaining = rows.filter { $0.ref != rows[2].ref }
        strip.show(remaining, selection: nil, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        let frames = drawings(in: strip)
        XCTAssertFalse(frames.isEmpty)
        XCTAssertFalse(frames.contains { $0.rootView.isSelected })
        XCTAssertTrue(frames.allSatisfy { rect(of: $0, in: strip).minX > dock + metrics.frameSize.width / 2 },
                      "Nothing covers the dock")
        // Every frame stands to the right of the empty dock, the newest next to it.
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock + metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 1", in: strip), dock + 2 * metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 3", in: strip), dock + 3 * metrics.step, accuracy: 0.5)
        XCTAssertEqual(strip.accessibilitySelectedChildren()?.count ?? 0, 0)
    }

    func testOnlyFramesOnScreenAndASpareAtEachEndExist() throws {
        let strip = makeStrip()
        let rows = makeRows(200)
        var reports: [(refs: [ContentRef], lastOnScreen: Int)] = []
        strip.onVisibleRefsChanged = { reports.append(($0, $1)) }

        strip.show(rows, selection: rows[100].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Nine frames reach into the band, and one more on each side keeps a step from showing a gap.
        XCTAssertLessThanOrEqual(drawings(in: strip).count, 11)
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((95...105).map { "Row \($0)" }))
        // Details are asked for only the rows with a frame, the selected clip's first. The last row on
        // screen is the one that decides when to load more.
        let report = try XCTUnwrap(reports.last)
        XCTAssertEqual(Set(report.refs), Set(rows[95...105].map(\.ref)))
        XCTAssertEqual(report.refs.count, 11)
        XCTAssertEqual(report.refs.first, rows[100].ref)
        XCTAssertEqual(report.lastOnScreen, 104)

        // One step later every frame is still in use: the one that left now draws the one that arrived.
        let before = Set(drawings(in: strip).map(ObjectIdentifier.init))
        strip.show(rows, selection: rows[101].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(Set(drawings(in: strip).map(ObjectIdentifier.init)), before)
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((96...106).map { "Row \($0)" }))

        // At the newest end the film rests at the dock, with frames on the older side only.
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((0...8).map { "Row \($0)" }))
        XCTAssertEqual(Set(try XCTUnwrap(reports.last).refs), Set(rows[0...8].map(\.ref)))
        XCTAssertEqual(reports.last?.lastOnScreen, 7)

        strip.show(rows, selection: rows[199].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((191...199).map { "Row \($0)" }))
        XCTAssertEqual(reports.last?.lastOnScreen, 199)

        // Shown again unchanged, the rows are asked for again while their details are missing, as when
        // the panel opens again over the same clips.
        let asked = reports.count
        strip.show(rows, selection: rows[199].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(reports.count, asked + 1)
        // Once every framed row has its details, an unchanged strip asks for nothing more.
        let details = Dictionary(uniqueKeysWithValues: rows[191...199].map { ($0.ref, ClipDetail()) })
        for _ in 1...2 {
            strip.show(rows, selection: rows[199].id, details: details, metrics: metrics,
                       applicationNames: ApplicationNames())
        }
        XCTAssertEqual(reports.count, asked + 1)
    }

    func testLoadingMoreKeepsTheSelectedFrameCentred() throws {
        let strip = makeStrip()
        let page = makeRows(60)
        // Another page may follow this one, so near its end the film keeps the selected clip in the middle.
        strip.show(page, selection: page[57].id, details: [:], metrics: metrics, applicationNames: ApplicationNames(),
                   oldestIsLoaded: false)
        let before = try rect(titled: "Row 57", in: strip)
        let neighbour = try rect(titled: "Row 59", in: strip)
        XCTAssertEqual(before.midX, centre, accuracy: 0.5)

        let pages = page + makeRows(60, from: 60)
        strip.show(pages, selection: page[57].id, details: [:], metrics: metrics, applicationNames: ApplicationNames(),
                   oldestIsLoaded: false)

        XCTAssertEqual(try rect(titled: "Row 57", in: strip), before)
        XCTAssertEqual(drawings(in: strip).first { $0.rootView.isSelected }.flatMap(title(of:)), "Row 57")
        XCTAssertEqual(try rect(titled: "Row 59", in: strip), neighbour)
        // The rows that arrived take their places on the older side, as if they had always been there.
        XCTAssertEqual(try midX(of: "Row 60", in: strip), centre + 3 * metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 62", in: strip), centre + 5 * metrics.step, accuracy: 0.5)

        // Once no more can follow, the last clip is the oldest, and the film stops with it at the right dock.
        strip.show(pages, selection: pages[118].id, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames())
        XCTAssertEqual(try rect(titled: "Row 119", in: strip).maxX, metrics.bandWidth - metrics.dockInset,
                       accuracy: 0.5)
    }

    func testClickAsksTheStateAndMovesOnlyWhenItAgrees() throws {
        let strip = makeStrip()
        let rows = makeRows(20)
        var asked: [QuickAccessRow.ID] = []
        strip.onSelect = { asked.append($0) }
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let target = try rect(titled: "Row 4", in: strip)
        let point = NSPoint(x: target.midX, y: target.midY)
        // The click reaches the strip, not the drawing inside the frame.
        XCTAssertTrue(strip.hitTest(strip.convert(point, to: strip.superview)) === strip)
        // Hovering asks for nothing.
        strip.mouseMoved(with: try mouse(.mouseMoved, at: point, in: strip))
        XCTAssertEqual(asked, [])
        XCTAssertEqual(selectedTitle(in: strip), "Row 2")

        strip.mouseDown(with: try mouse(.leftMouseDown, at: point, in: strip))
        strip.mouseUp(with: try mouse(.leftMouseUp, at: point, in: strip))

        XCTAssertEqual(asked, [rows[4].id])
        XCTAssertTrue(strip.window?.firstResponder === strip)
        // Until the state agrees, the ring stays where the state put it, on the third clip from the dock.
        XCTAssertEqual(selectedTitle(in: strip), "Row 2")
        XCTAssertEqual(try midX(of: "Row 2", in: strip), dock + 2 * metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 4", in: strip), dock + 4 * metrics.step, accuracy: 0.5)

        // The state refused and shows its own selection again: nothing moves.
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(selectedTitle(in: strip), "Row 2")
        XCTAssertEqual(try midX(of: "Row 2", in: strip), dock + 2 * metrics.step, accuracy: 0.5)

        // The state agreed: the clicked clip lies past the middle, so the film brings it there with the ring.
        strip.show(rows, selection: rows[4].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(selectedTitle(in: strip), "Row 4")
        XCTAssertEqual(try midX(of: "Row 4", in: strip), centre, accuracy: 0.5)

        // A click between two frames asks for nothing.
        let gap = NSPoint(x: centre + (metrics.frameSize.width + metrics.gap) / 2, y: target.midY)
        strip.mouseDown(with: try mouse(.leftMouseDown, at: gap, in: strip))
        XCTAssertEqual(asked, [rows[4].id])
    }

    func testDoubleClickNeverExecutes() throws {
        let strip = makeStrip()
        let rows = makeRows(20)
        var asked: [QuickAccessRow.ID] = []
        var commands: [QuickAccessCommand] = []
        strip.onSelect = { asked.append($0) }
        strip.onCommand = { commands.append($0) }
        strip.show(rows, selection: rows[6].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        let click = { (point: NSPoint, count: Int) in
            strip.mouseDown(with: try self.mouse(.leftMouseDown, at: point, clickCount: count, in: strip))
            strip.mouseUp(with: try self.mouse(.leftMouseUp, at: point, clickCount: count, in: strip))
        }

        // A double click on a neighbour. The panel takes the first click and brings that clip to the middle,
        // so the next older frame now lies under the pointer; the second click is one more on the same clip.
        let target = try rect(titled: "Row 7", in: strip)
        let point = NSPoint(x: target.midX, y: target.midY)
        try click(point, 1)
        strip.show(rows, selection: rows[7].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(try midX(of: "Row 8", in: strip), point.x, accuracy: 0.5)
        try click(point, 2)
        XCTAssertEqual(asked, [rows[7].id, rows[7].id])

        // A double click on the clip in the middle is no different.
        let middle = NSPoint(x: centre, y: target.midY)
        try click(middle, 1)
        try click(middle, 2)

        XCTAssertFalse(commands.contains(.primary))
        XCTAssertEqual(commands, [])
        XCTAssertEqual(asked, Array(repeating: rows[7].id, count: 4))
    }

    func testScrollMovesTicksAndRespectsTheSwitch() throws {
        let strip = makeStrip()
        let haptics = RecordingHaptics()
        strip.haptics = haptics
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(10)
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // A swipe toward older clips, the fingers moving left: a clip for every 30 pt, with a tick as each is
        // selected.
        strip.scrollWheel(with: try swipe(dx: -20, phase: .began, at: 1.0))
        XCTAssertEqual(commands, [])
        XCTAssertEqual(haptics.ticks, 0)
        strip.scrollWheel(with: try swipe(dx: -20, phase: .changed, at: 1.1))
        XCTAssertEqual(commands, [.move(1)])
        XCTAssertEqual(haptics.ticks, 1)
        // The panel shows the move it accepted; a fast push passes two clips with one tick.
        strip.show(rows, selection: rows[1].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: -60, phase: .changed, at: 1.2))
        XCTAssertEqual(commands, [.move(1), .move(2)])
        XCTAssertEqual(haptics.ticks, 2)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.3))

        // Coasting after the fingers lift moves nothing and plays nothing.
        strip.scrollWheel(with: try coast(dx: -90, at: 1.4))
        XCTAssertEqual(commands, [.move(1), .move(2)])
        XCTAssertEqual(haptics.ticks, 2)
        // A mouse wheel turned down moves one clip older a notch; its own click is the feedback.
        strip.scrollWheel(with: try wheel(dy: -1, at: 1.5))
        XCTAssertEqual(commands, [.move(1), .move(2), .move(1)])
        XCTAssertEqual(haptics.ticks, 2)

        // With the switch off a swipe moves the same, without a tick: the fingers moving right go newer.
        strip.ticksEnabled = false
        strip.show(rows, selection: rows[4].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 40, phase: .began, at: 2.0))
        XCTAssertEqual(commands.last, .move(-1))
        XCTAssertEqual(haptics.ticks, 2)
    }

    func testKeyboardMovesNeverTick() throws {
        let strip = makeStrip()
        let haptics = RecordingHaptics()
        strip.haptics = haptics
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(5)
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Right is older and left newer.
        strip.keyDown(with: try key(kVK_RightArrow, "\u{F703}"))
        strip.show(rows, selection: rows[3].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.keyDown(with: try key(kVK_RightArrow, "\u{F703}", isARepeat: true))
        strip.show(rows, selection: rows[4].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.keyDown(with: try key(kVK_LeftArrow, "\u{F702}"))

        XCTAssertEqual(commands, [.move(1), .move(1), .move(-1)])
        XCTAssertEqual(haptics.ticks, 0)
    }

    func testHeldSpaceReturnAndEscapeActOnceWhileArrowsRepeat() throws {
        let strip = makeStrip()
        let parent = try XCTUnwrap(strip.superview as? KeyRecordingView)
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(5)
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Held down, each acts on its first press alone. Repeating, Space would toggle the preview at the key
        // repeat rate, Return would copy again, and Escape would peel the panel's layers one after another.
        let held = [(kVK_Space, " "), (kVK_Return, "\r"), (kVK_ANSI_KeypadEnter, "\u{3}"), (kVK_Escape, "\u{1B}")]
        for (code, characters) in held {
            strip.keyDown(with: try key(code, characters))
            strip.keyDown(with: try key(code, characters, isARepeat: true))
            strip.keyDown(with: try key(code, characters, isARepeat: true))
        }
        XCTAssertEqual(commands, [.togglePreview, .primary, .primary, .escape])
        XCTAssertEqual(parent.keys, 0, "The repeats are dropped, not passed on to end in an alert")

        // The arrows keep stepping while held.
        commands = []
        strip.keyDown(with: try key(kVK_RightArrow, "\u{F703}"))
        strip.keyDown(with: try key(kVK_RightArrow, "\u{F703}", isARepeat: true))
        strip.keyDown(with: try key(kVK_RightArrow, "\u{F703}", isARepeat: true))
        XCTAssertEqual(commands, [.move(1), .move(1), .move(1)])

        // The toolbar's filters drop them the same way, and their cursor keeps moving while an arrow is held.
        let filters = QuickAccessFilterRow()
        var filterCommands: [QuickAccessCommand] = []
        filters.onCommand = { filterCommands.append($0) }
        for (code, characters) in held {
            filters.keyDown(with: try key(code, characters))
            filters.keyDown(with: try key(code, characters, isARepeat: true))
        }
        filters.keyDown(with: try key(kVK_RightArrow, "\u{F703}"))
        filters.keyDown(with: try key(kVK_RightArrow, "\u{F703}", isARepeat: true))
        XCTAssertEqual(filterCommands, [.toggleFilter, .primary, .primary, .escape, .moveFilter(1), .moveFilter(1)])
    }

    func testTypingInTheStripRoutesToTheSearchField() throws {
        let strip = makeStrip()
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(3)
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        strip.keyDown(with: try key(kVK_ANSI_A, "a"))
        XCTAssertEqual(commands, [.typeIntoSearch])

        // Capitals, ⌥ characters and a dead key that starts an accent are typing too.
        strip.keyDown(with: try key(kVK_ANSI_A, "A", modifiers: .shift))
        strip.keyDown(with: try key(kVK_ANSI_A, "å", modifiers: .option, ignoringModifiers: "a"))
        strip.keyDown(with: try key(kVK_ANSI_E, "", modifiers: .option, ignoringModifiers: "e"))
        XCTAssertEqual(commands, Array(repeating: .typeIntoSearch, count: 4))

        // Space, Return and Tab keep meanings of their own, and a shortcut is not typing.
        commands = []
        strip.keyDown(with: try key(kVK_Space, " "))
        strip.keyDown(with: try key(kVK_Return, "\r"))
        strip.keyDown(with: try key(kVK_Return, "\r", modifiers: .shift))
        strip.keyDown(with: try key(kVK_Tab, "\t"))
        strip.keyDown(with: try key(kVK_Tab, "\u{19}", modifiers: .shift))
        strip.keyDown(with: try key(kVK_ANSI_A, "a", modifiers: .command))
        strip.keyDown(with: try key(kVK_ANSI_A, "\u{1}", modifiers: .control, ignoringModifiers: "a"))
        XCTAssertEqual(commands, [.togglePreview, .primary, .plainText, .cycleFocus(forward: true),
                                  .cycleFocus(forward: false)])
    }

    func testAccessibilityLabelsAndInfoValues() throws {
        let strip = makeStrip()
        let names = ApplicationNames()
        let finder = "com.apple.finder"
        let app = try XCTUnwrap(names.name(for: finder))
        let rows = [
            makeRow(title: "Quarterly numbers draft", sourceApp: finder),
            makeRow(title: "Standup notes", savedAsMemo: true, isPartiallyIndexed: true, isTextUnavailable: true),
            makeRow(kind: .url, title: ""),
            makeRow(kind: .image, title: "Screenshot"),
            makeRow(kind: .url, title: "https://git-scm.com/docs/git-rebase"),
        ]
        let details = [rows[0].ref: ClipDetail(excerpt: "Quarterly numbers draft..", characterCount: 25),
                       rows[3].ref: ClipDetail(pixelSize: CGSize(width: 2880, height: 1800)),
                       rows[4].ref: ClipDetail(excerpt: "https://git-scm.com/docs/git-rebase", characterCount: 35,
                                               linkTitle: "Git - git-rebase Documentation")]

        strip.show(rows, selection: rows[0].id, details: details, metrics: metrics, applicationNames: names)

        XCTAssertEqual(strip.accessibilityRole(), .list)
        XCTAssertEqual(strip.accessibilityLabel(), "Clips")
        XCTAssertEqual(strip.accessibilityIdentifier(), "QuickAccessStrip")
        // One element per frame, left to right as on screen: the selected newest first and the oldest last.
        let children = try XCTUnwrap(strip.accessibilityChildren() as? [NSView])
        guard children.count == 5 else { return XCTFail("Expected an element per frame, got \(children.count)") }
        let (selected, memo, link, image, page) = (children[0], children[1], children[2], children[3], children[4])
        let time = { (row: QuickAccessRow) in QuickAccessRowContent.time(of: row.date, spoken: true) }

        // The kind, the time, where the clip came from and what its footer says, as the card shows them; then what
        // the clip holds.
        XCTAssertEqual(selected.accessibilityLabel(),
                       "Text, \(time(rows[0])), from \(app), 25 characters: Quarterly numbers draft")
        XCTAssertNil(selected.accessibilityValue(), "The footer is read with the label, not a second time")
        XCTAssertTrue(selected.isAccessibilitySelected())
        XCTAssertEqual(strip.accessibilitySelectedChildren() as? [NSView], [selected])
        // Without a known source app the label leaves out where it came from, and without details what the footer
        // would say; the marks follow the title.
        XCTAssertEqual(memo.accessibilityLabel(),
                       "Text, \(time(rows[1])): Standup notes, Saved as Memo, Partially indexed, Text unavailable")
        XCTAssertNil(memo.accessibilityValue())
        XCTAssertFalse(memo.isAccessibilitySelected())
        XCTAssertEqual(link.accessibilityLabel(), "Link, \(time(rows[2])): Clipboard Item")
        // A picture's size is said in words.
        XCTAssertEqual(image.accessibilityLabel(), "Image, \(time(rows[3])), 2880 by 1800: Screenshot")
        // A link is named by the title its card shows, not by its address.
        XCTAssertEqual(page.accessibilityLabel(), "Link, \(time(rows[4])), git-scm.com: Git - git-rebase Documentation")
        // The text drawn in a frame is read through its label, not a second time.
        XCTAssertEqual(selected.accessibilityChildren()?.count ?? 0, 0)

        // Frames kept beyond the ends of the band are not read: nine are on screen.
        let many = makeRows(20)
        strip.show(many, selection: many[10].id, details: [:], metrics: metrics, applicationNames: names)
        XCTAssertEqual(strip.accessibilityChildren()?.count, 9)
        XCTAssertEqual(drawings(in: strip).count, 11)
    }

    func testTheFirstShowOfAnAppAlreadyCarriesItsBandColour() throws {
        let strip = makeStrip()
        let names = ApplicationNames()
        // An app that is not installed shows the system's generic app icon, which is grey, so its band is the dark
        // neutral one. Nothing is known of the app before its first frame.
        let app = "test.keeptide.not-installed.\(UUID().uuidString)"
        XCTAssertNil(HeaderTint.cachedTint(forIconOf: app))
        let rows = [makeRow(title: "From an unknown app", sourceApp: app), makeRow(title: "From no app")]

        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: names)

        // The first frame already has the band's own colour, worked out from the icon it shows, with no neutral
        // first pass to be replaced later.
        let unknown = try XCTUnwrap(drawings(in: strip).first { title(of: $0) == "From an unknown app" })
        XCTAssertTrue(unknown.rootView.applicationIcon === names.icon(for: app))
        XCTAssertEqual(unknown.rootView.headerTint, .neutral(dark: true))
        XCTAssertEqual(HeaderTint.cachedTint(forIconOf: app), .neutral(dark: true))
        // A clip without a source app has no tint: its band is the neutral one of the appearance it is drawn in.
        XCTAssertNil(try XCTUnwrap(drawings(in: strip).first { title(of: $0) == "From no app" }).rootView.headerTint)
    }

    // MARK: Beyond the named cases

    func testTheStripFollowsTheFingersAndStretchesAtTheEnds() throws {
        let strip = makeStrip()
        strip.haptics = RecordingHaptics()
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(20)
        strip.show(rows, selection: rows[6].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Fingers moving left a third of the way to the next older clip carry the film a third of a step left.
        strip.scrollWheel(with: try swipe(dx: -10, phase: .began, at: 1.0))
        XCTAssertEqual(try midX(of: "Row 6", in: strip), centre - metrics.step / 3, accuracy: 0.5)
        // Lifting them settles back on the selected clip.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
        XCTAssertEqual(try midX(of: "Row 6", in: strip), centre, accuracy: 0.5)
        // So does a panel that stops being key under the fingers, since their lift never reaches it, and the
        // swipe it cut short is forgotten: fingers touching down again later move nothing.
        strip.scrollWheel(with: try swipe(dx: -10, phase: .began, at: 1.2))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: strip.window)
        XCTAssertEqual(try midX(of: "Row 6", in: strip), centre, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 1.3))
        XCTAssertEqual(try midX(of: "Row 6", in: strip), centre, accuracy: 0.5)

        // Near the newest end the fingers carry the selection along a docked film, which stays where it is.
        strip.show(rows, selection: rows[1].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: -10, phase: .began, at: 1.5))
        XCTAssertEqual(try midX(of: "Row 1", in: strip), dock + metrics.step, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.6))

        // At the oldest clip, resting at the right dock, a push stretches the end, 0.3 pt for every point pushed,
        // and pulls the film left.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let oldest = metrics.bandWidth - metrics.dockInset - metrics.frameSize.width / 2
        XCTAssertEqual(try midX(of: "Row 19", in: strip), oldest, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: -40, phase: .began, at: 2.0))
        XCTAssertEqual(try midX(of: "Row 19", in: strip), oldest - 12, accuracy: 0.5)
        // Fingers resting change nothing, so the stretch holds instead of snapping back mid-gesture.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 2.05))
        XCTAssertEqual(try midX(of: "Row 19", in: strip), oldest - 12, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 2.1))
        XCTAssertEqual(try midX(of: "Row 19", in: strip), oldest, accuracy: 0.5)
        // At the newest clip the stretch goes the other way.
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 40, phase: .began, at: 2.5))
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock + 12, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 2.6))
        XCTAssertEqual(commands, [])

        // With the selection gone nothing is newer than the empty dock, and every clip is older. Fingers short of
        // the newest clip leave the film where it is.
        strip.show(rows, selection: nil, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 40, phase: .began, at: 3.0))
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock + metrics.step + 12, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 3.1))
        strip.scrollWheel(with: try swipe(dx: -10, phase: .began, at: 3.5))
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock + metrics.step, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 3.6))
        XCTAssertEqual(commands, [])
        strip.scrollWheel(with: try swipe(dx: -100, phase: .began, at: 4.0))
        XCTAssertEqual(commands, [.move(3)])
    }

    func testASwipeFromTheDockIntoTheMiddleNeverJumps() throws {
        let strip = makeStrip()
        strip.haptics = RecordingHaptics()
        let rows = makeRows(20)
        var selected = 0
        // The panel shows each step in the same turn as the swipe that asked for it.
        strip.onCommand = { [unowned strip, metrics = self.metrics] command in
            guard case .move(let offset) = command else { return }
            selected += offset
            strip.show(rows, selection: rows[selected].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
        }
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Fingers moving left a sixth of a clip at a time, from the newest clip to the eighth. After each event,
        // where index 0's frame lies, going by the selected one.
        var origins: [CGFloat] = []
        for event in 1...42 {
            strip.scrollWheel(with: try swipe(dx: -5, phase: event == 1 ? .began : .changed, at: 1 + Double(event) / 20))
            origins.append(try rect(titled: "Row \(selected)", in: strip).minX - CGFloat(selected) * metrics.step)
        }
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 4))

        XCTAssertEqual(selected, 7)
        // The film rests at the dock until the selection reaches the middle, then follows the fingers: it only ever
        // moves left, and never further in one event than the fingers carried the selection, a sixth of a step.
        XCTAssertEqual(origins.first ?? 0, metrics.dockInset, accuracy: 0.5)
        XCTAssertEqual(origins.last ?? 0, centre - metrics.frameSize.width / 2 - 7 * metrics.step, accuracy: 0.5)
        for (before, after) in zip(origins, origins.dropFirst()) {
            XCTAssertLessThanOrEqual(after, before + 0.5)
            XCTAssertLessThanOrEqual(before - after, metrics.step / 6 + 1)
        }
    }

    func testAClipChosenElsewhereStartsTheFingersAfresh() throws {
        let strip = makeStrip()
        strip.haptics = RecordingHaptics()
        let rows = makeRows(20)

        // The fingers push half a clip toward newer from the second clip, and then a key selects the newest. An
        // event of resting fingers does not carry that push over: the newest clip stays at the dock.
        strip.show(rows, selection: rows[1].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 15, phase: .began, at: 1.0))
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 1.1))
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.2))

        // In the middle as well: half a clip pushed toward older is not played back against the clip a key chose.
        strip.show(rows, selection: rows[6].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: -15, phase: .began, at: 2.0))
        XCTAssertEqual(try midX(of: "Row 6", in: strip), centre - metrics.step / 2, accuracy: 0.5)
        strip.show(rows, selection: rows[7].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 2.1))
        XCTAssertEqual(try midX(of: "Row 7", in: strip), centre, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 2.2))
    }

    func testARealSelectionIsNeverTakenForTheEmptyDock() throws {
        let strip = makeStrip()
        strip.haptics = RecordingHaptics()
        let rows = makeRows(20)
        // The panel may show another clip than a step asked for. This one always shows the newest.
        strip.onCommand = { [unowned strip, metrics = self.metrics] command in
            guard case .move = command else { return }
            strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
        }
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // A clip and a half toward newer from the third clip: the step lands on the newest clip, and the half
        // left over has nowhere to go. The newest clip stays at the dock, not taken for a vanished selection.
        strip.scrollWheel(with: try swipe(dx: 45, phase: .began, at: 1.0))
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
    }

    func testLeavingTheEmptyDockUnderTheFingersSlides() throws {
        let strip = makeStrip()
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        strip.haptics = RecordingHaptics()
        var selected: [QuickAccessRow.ID] = []
        strip.onSelect = { selected.append($0) }
        let rows = makeRows(20)
        // The panel shows each step in the same turn as the swipe that asked for it.
        strip.onCommand = { [unowned strip, metrics = self.metrics] command in
            guard case .move = command else { return }
            strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
        }
        // With the selection gone, the newest clip stands a step to the right of the empty dock.
        strip.show(rows, selection: nil, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let before = try rect(titled: "Row 0", in: strip)
        let point = NSPoint(x: before.midX, y: before.midY)

        // Time stands still from here, so the slide the step starts stays at its beginning.
        content.layer?.speed = 0
        // A clip's worth of swipe selects the newest clip, and the empty slot goes. The film slides across that
        // step rather than jumping, so the newest clip is still drawn where it stood, under the pointer.
        strip.scrollWheel(with: try swipe(dx: -30, phase: .began, at: 1.0))
        CATransaction.flush()
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock, accuracy: 0.5)
        strip.mouseDown(with: try mouse(.leftMouseDown, at: point, in: strip))
        XCTAssertEqual(selected, [rows[0].id])
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
    }

    func testAClampUnderRestingFingersSlides() throws {
        let strip = makeStrip()
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        strip.haptics = RecordingHaptics()
        let rows = makeRows(20)
        // Another page may follow the last clip there is, so the film keeps it in the middle.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames(),
                   oldestIsLoaded: false)
        // The fingers carry the selection a third of a step toward newer clips, and the film with it, and rest there.
        strip.scrollWheel(with: try swipe(dx: 10, phase: .began, at: 1.0))
        CATransaction.flush()
        let carried = try drawnMidX(of: "Row 19", in: strip)
        XCTAssertEqual(carried, centre + metrics.step / 3, accuracy: 0.5)

        // Time stands still from here, so the slide stays at its beginning.
        content.layer?.speed = 0
        // The last page brings nothing more: the last clip is the oldest, and the film comes to rest with it at the
        // right dock, where the fingers carry the selection along the film instead. The film slides there under the
        // resting fingers rather than jumping, so the clip is still drawn where they carried it.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        CATransaction.flush()
        XCTAssertEqual(try rect(titled: "Row 19", in: strip).maxX, metrics.bandWidth - metrics.dockInset, accuracy: 0.5)
        XCTAssertEqual(try drawnMidX(of: "Row 19", in: strip), carried, accuracy: 0.5)
        // Their push was measured again from the film's new place, so their next event moves nothing.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 1.1))
        CATransaction.flush()
        XCTAssertEqual(try drawnMidX(of: "Row 19", in: strip), carried, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.2))
    }

    func testAScanFinishingUnderTheFingersSlides() throws {
        let strip = makeStrip()
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        strip.haptics = RecordingHaptics()
        let rows = makeRows(3)
        // A scan still under way has found two clips. More may follow, so the two rest at the left dock.
        strip.show(Array(rows[...1]), selection: rows[0].id, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames(), oldestIsLoaded: false)
        // The fingers push past the newest clip, stretching the end, and rest there.
        strip.scrollWheel(with: try swipe(dx: 40, phase: .began, at: 1.0))
        CATransaction.flush()
        let stretched = try drawnMidX(of: "Row 0", in: strip)
        XCTAssertEqual(stretched, dock + 12, accuracy: 0.5)

        // Time stands still from here, so the slide stays at its beginning.
        content.layer?.speed = 0
        // The scan ends with a third clip, and the three, all there is, are centred as a group. The film slides there
        // under the resting fingers rather than jumping, and keeps their stretch.
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        CATransaction.flush()
        let group = 3 * metrics.step - metrics.gap
        XCTAssertEqual(try rect(titled: "Row 0", in: strip).minX, (metrics.bandWidth - group) / 2 + 12, accuracy: 0.5)
        XCTAssertEqual(try drawnMidX(of: "Row 0", in: strip), stretched, accuracy: 0.5)
        // The stretch was kept for the film's new place, so the fingers' next event moves nothing.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 1.1))
        CATransaction.flush()
        XCTAssertEqual(try drawnMidX(of: "Row 0", in: strip), stretched, accuracy: 0.5)
        // As they lift, the film's own place is its resting one at once, and the stretch springs back from where it is
        // drawn: still there while time stands still.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.2))
        CATransaction.flush()
        XCTAssertEqual(try XCTUnwrap(strip.subviews.first).frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(try drawnMidX(of: "Row 0", in: strip), stretched, accuracy: 0.5)
    }

    func testAClipArrivingUnderTheFingersSlides() throws {
        let strip = makeStrip()
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        strip.haptics = RecordingHaptics()
        let rows = makeRows(20)
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        // The fingers push past the newest clip, stretching the end, and rest there.
        strip.scrollWheel(with: try swipe(dx: 40, phase: .began, at: 1.0))
        CATransaction.flush()
        let stretched = try drawnMidX(of: "Row 0", in: strip)
        XCTAssertEqual(stretched, dock + 12, accuracy: 0.5)

        // Time stands still from here, so the slide stays at its beginning.
        content.layer?.speed = 0
        // A newer clip arrives at the dock, and the selected clip's place moves a step along the film. The change
        // starts the fingers afresh, so their stretch goes with it; the film slides from where the clip was drawn
        // rather than jumping.
        strip.show([makeRow(title: "Row new")] + rows, selection: rows[0].id, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames())
        CATransaction.flush()
        XCTAssertEqual(try midX(of: "Row 0", in: strip), dock + metrics.step, accuracy: 0.5)
        XCTAssertEqual(try drawnMidX(of: "Row 0", in: strip), stretched, accuracy: 0.5)
        // The fingers' next event, still resting, moves nothing.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 1.1))
        CATransaction.flush()
        XCTAssertEqual(try drawnMidX(of: "Row 0", in: strip), stretched, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.2))
    }

    func testAClipArrivingBeforeACentredSelectionMovesNothing() throws {
        let strip = makeStrip()
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        let rows = makeRows(20)
        strip.show(rows, selection: rows[8].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Time stands still from here, so a slide would stay at its beginning.
        content.layer?.speed = 0
        // A new clip arrives before all the others, and the selected one becomes the tenth. Every clip on screen
        // keeps its place, so nothing slides: the selected clip rests and is drawn in the middle.
        strip.show([makeRow(title: "Row new")] + rows, selection: rows[8].id, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames())
        CATransaction.flush()
        XCTAssertEqual(try midX(of: "Row 8", in: strip), centre, accuracy: 0.5)
        XCTAssertEqual(try drawnMidX(of: "Row 8", in: strip), centre, accuracy: 0.5)
    }

    func testAClipArrivingBeforeADockedSelectionSlidesItAlong() throws {
        let strip = makeStrip()
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        let rows = makeRows(20)
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let before = try midX(of: "Row 2", in: strip)

        // Time stands still from here, so the slide stays at its beginning.
        content.layer?.speed = 0
        // A new clip arrives at the dock, and along the docked film the selected clip's place moves a step right.
        // It slides there from where it was rather than jumping: it is still drawn where it stood.
        strip.show([makeRow(title: "Row new")] + rows, selection: rows[2].id, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames())
        CATransaction.flush()
        XCTAssertEqual(try midX(of: "Row 2", in: strip), before + metrics.step, accuracy: 0.5)
        XCTAssertEqual(try drawnMidX(of: "Row 2", in: strip), before, accuracy: 0.5)
    }

    func testAWheelTurnedRightMovesOneClipOlder() throws {
        let strip = makeStrip()
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(5)
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // A notch to the right shows content further right, which is older; one to the left comes back.
        strip.scrollWheel(with: try wheel(dx: -1, at: 1.0))
        XCTAssertEqual(commands, [.move(1)])
        strip.scrollWheel(with: try wheel(dx: 1, at: 1.1))
        XCTAssertEqual(commands, [.move(1), .move(-1)])
    }

    func testASlideKeepsTheFramesItPassesUntilItSettles() async throws {
        let strip = makeStrip()
        strip.haptics = RecordingHaptics()
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        var reports: [[ContentRef]] = []
        strip.onVisibleRefsChanged = { refs, _ in reports.append(refs) }
        let rows = makeRows(40)
        strip.show(rows, selection: rows[20].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // The frame four steps older is selected and slides from where it was drawn to the middle.
        strip.show(rows, selection: rows[24].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        XCTAssertEqual(try midX(of: "Row 24", in: strip), centre, accuracy: 0.5)
        // The frames it passes on the newer side stay while they slide out past the end.
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((15...29).map { "Row \($0)" }))
        // Only the rows framed where the film now rests are asked for their details.
        XCTAssertEqual(Set(try XCTUnwrap(reports.last)), Set(rows[19...29].map(\.ref)))
        // Once the slide has settled only the frames on screen and the spares are left.
        let settled = Set((19...29).map { "Row \($0)" })
        try await waitUntil { Set(self.drawings(in: strip).compactMap(self.title(of:))) == settled }

        // A step the fingers take follows them instead of sliding, so nothing is kept. The panel shows the step in the
        // same turn as the swipe that asked for it.
        var selected = 24
        strip.onCommand = { [unowned strip, metrics = self.metrics] command in
            guard case .move(let offset) = command else { return }
            selected += offset
            strip.show(rows, selection: rows[selected].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
        }
        strip.scrollWheel(with: try swipe(dx: -30, phase: .began, at: 1.0))
        XCTAssertEqual(selected, 25)
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((20...30).map { "Row \($0)" }))
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
    }

    func testInMidSlideThePointerFindsTheFrameWhereItIsDrawn() throws {
        let strip = makeStrip()
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        var selected: [QuickAccessRow.ID] = []
        var menus: [QuickAccessRow.ID] = []
        strip.onSelect = { selected.append($0) }
        strip.onContextMenu = { menus.append($0); return nil }
        let rows = makeRows(40)
        strip.show(rows, selection: rows[20].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let before = try rect(titled: "Row 19", in: strip)
        let point = NSPoint(x: before.midX, y: before.midY)

        // Time stands still from here, so the slide the next selection starts stays at its beginning, with
        // every frame still drawn where it was.
        content.layer?.speed = 0
        strip.show(rows, selection: rows[24].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        CATransaction.flush()
        // By the places the frames are sliding to, another clip already lies under the pointer.
        XCTAssertEqual(try midX(of: "Row 23", in: strip), point.x, accuracy: 0.5)
        // ⌘K opens its actions beside the selected clip where it comes to rest, not where it is drawn: the menu does
        // not follow the film, so it would cover the clip once the slide settles.
        XCTAssertEqual(try XCTUnwrap(strip.selectionAnchorFrame).midX, try midX(of: "Row 24", in: strip), accuracy: 0.5)

        strip.mouseDown(with: try mouse(.leftMouseDown, at: point, in: strip))
        _ = strip.menu(for: try mouse(.rightMouseDown, at: point, in: strip))

        XCTAssertEqual(selected, [rows[19].id])
        XCTAssertEqual(menus, [rows[19].id])

        // A new selection before the first slide has moved takes over from where the frames are drawn: the
        // springs add up, so the same clip stays under the pointer.
        strip.show(rows, selection: rows[25].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        CATransaction.flush()
        strip.mouseDown(with: try mouse(.leftMouseDown, at: point, in: strip))
        XCTAssertEqual(selected, [rows[19].id, rows[19].id])
    }

    func testStackedSlidesKeepTheSweepFramed() throws {
        let rows = makeRows(40)
        // Selects each clip in turn after the first, 30 ms apart, in a strip on screen whose time stands still once the
        // first is shown. No slide has got anywhere when the next one starts, as when steps come faster than the
        // springs move, such as from a flicked wheel; the 30 ms waits do not move them on. Every clip drawn in the band
        // must have its frame. Returns how far the springs, added up, draw the film from its place.
        func select(_ first: Int, then others: [Int]) throws -> CGFloat {
            let strip = makeStrip()
            let content = try XCTUnwrap(strip.superview)
            content.wantsLayer = true
            strip.window?.orderFront(nil)
            strip.show(rows, selection: rows[first].id, details: [:], metrics: metrics,
                       applicationNames: ApplicationNames())
            content.layer?.speed = 0
            for index in others {
                strip.show(rows, selection: rows[index].id, details: [:], metrics: metrics,
                           applicationNames: ApplicationNames())
                CATransaction.flush()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            }
            let film = try XCTUnwrap(strip.subviews.first?.layer)
            let offset = try XCTUnwrap(film.presentation()).position.x - film.position.x
            let framed = Set(drawings(in: strip).compactMap(title(of:)))
            let last = try XCTUnwrap(others.last)
            let selected = try rect(titled: "Row \(last)", in: strip)
            let band = strip.bounds.insetBy(dx: (strip.bounds.width - metrics.bandWidth) / 2, dy: 0)
            for index in rows.indices {
                let drawn = selected.offsetBy(dx: CGFloat(index - last) * metrics.step + offset, dy: 0)
                guard drawn.intersects(band) else { continue }
                XCTAssertTrue(framed.contains("Row \(index)"), "Row \(index) is drawn in the band without a frame")
            }
            return offset
        }

        // Three steps toward older clips in the middle of the film: the film is still drawn where it was before the
        // first, three steps from its place.
        XCTAssertEqual(try select(20, then: [21, 22, 23]), 3 * metrics.step, accuracy: 0.5)
        // Three steps toward newer clips into the dock. The last walks the selection along the docked film and moves
        // nothing itself, while the springs before it still draw the film where it was at the sixth clip.
        let sixth = centre - metrics.frameSize.width / 2 - 5 * metrics.step
        XCTAssertEqual(try select(5, then: [4, 3, 2]), sixth - metrics.dockInset, accuracy: 0.5)
    }

    func testReduceMotionStopsEverySlide() throws {
        let strip = makeStrip()
        strip.reducesMotion = { true }
        strip.haptics = RecordingHaptics()
        // On screen, where the frames would otherwise slide.
        strip.window?.orderFront(nil)
        let film = try XCTUnwrap(strip.subviews.first?.layer)
        let rows = makeRows(20)
        strip.show(rows, selection: rows[18].id, details: [:], metrics: metrics, applicationNames: ApplicationNames(),
                   oldestIsLoaded: false)

        // A step goes straight to its place.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames(),
                   oldestIsLoaded: false)
        XCTAssertEqual(film.animationKeys() ?? [], [], "A step")
        XCTAssertEqual(try midX(of: "Row 19", in: strip), centre, accuracy: 0.5)
        // So does the film when the last clip turns out to be the oldest and it comes to rest at the right dock.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(film.animationKeys() ?? [], [], "A clamp")
        XCTAssertEqual(try rect(titled: "Row 19", in: strip).maxX, metrics.bandWidth - metrics.dockInset, accuracy: 0.5)
        // And under the fingers. While another page may follow the last clip, they stretch its end; the page brings
        // nothing, so the film comes to rest at the right dock beneath them, and they lift. Neither the change of rest
        // nor the stretch going back slides.
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames(),
                   oldestIsLoaded: false)
        strip.scrollWheel(with: try swipe(dx: -40, phase: .began, at: 1.0))
        strip.show(rows, selection: rows[19].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
        XCTAssertEqual(film.animationKeys() ?? [], [], "Under the fingers")
        XCTAssertEqual(try rect(titled: "Row 19", in: strip).maxX, metrics.bandWidth - metrics.dockInset, accuracy: 0.5)
        // And a selected clip at the dock whose place moves along the film as a newer clip arrives before it.
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let arrived = [makeRow(title: "Row new")] + rows
        strip.show(arrived, selection: rows[2].id, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames())
        XCTAssertEqual(film.animationKeys() ?? [], [], "An arrival")
        XCTAssertEqual(try midX(of: "Row 2", in: strip), dock + 3 * metrics.step, accuracy: 0.5)

        // Without Reduce Motion the next arrival slides.
        strip.reducesMotion = { false }
        strip.show([makeRow(title: "Row newer")] + arrived, selection: rows[2].id, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames())
        XCTAssertFalse((film.animationKeys() ?? []).isEmpty)
    }

    func testKeysFollowThePanelAndTheRestAreDroppedSilently() throws {
        let strip = makeStrip()
        let parent = try XCTUnwrap(strip.superview as? KeyRecordingView)
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(3)
        strip.show(rows, selection: rows[1].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Up goes back to the search field, whatever the query holds.
        strip.keyDown(with: try key(kVK_UpArrow, "\u{F700}"))
        strip.queryIsEmpty = false
        strip.keyDown(with: try key(kVK_UpArrow, "\u{F700}"))
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        XCTAssertEqual(commands, [.focusSearchField, .focusSearchField, .escape])

        // Down, Delete and shortcuts mean nothing here: no command, and not passed on to end in an alert.
        strip.keyDown(with: try key(kVK_DownArrow, "\u{F701}"))
        strip.keyDown(with: try key(kVK_Delete, "\u{7F}"))
        strip.keyDown(with: try key(kVK_ANSI_C, "c", modifiers: .command))
        XCTAssertEqual(commands, [.focusSearchField, .focusSearchField, .escape])
        XCTAssertEqual(parent.keys, 0)
    }

    func testContextMenuIsForTheFrameUnderThePointer() throws {
        let strip = makeStrip()
        let rows = makeRows(4)
        let menu = NSMenu(title: "Actions")
        var asked: [QuickAccessRow.ID] = []
        var selected: [QuickAccessRow.ID] = []
        strip.onContextMenu = { asked.append($0); return menu }
        strip.onSelect = { selected.append($0) }
        strip.show(rows, selection: rows[0].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let target = try rect(titled: "Row 2", in: strip)

        let shown = strip.menu(for: try mouse(.rightMouseDown, at: NSPoint(x: target.midX, y: target.midY), in: strip))

        XCTAssertTrue(shown === menu)
        XCTAssertEqual(asked, [rows[2].id])
        XCTAssertEqual(selected, [])
        // Between two frames there is nothing to act on.
        let gap = NSPoint(x: target.maxX + metrics.gap / 2, y: target.midY)
        XCTAssertNil(strip.menu(for: try mouse(.rightMouseDown, at: gap, in: strip)))
        XCTAssertEqual(asked, [rows[2].id])
    }

    func testAClipInBothWingsGetsAFrameInEach() throws {
        let strip = makeStrip()
        let shared = makeRow(title: "Shared")
        let rows = [frequent(shared, uses: 3), makeRow(title: "Row 1"), shared]
        var asked: [QuickAccessRow.ID] = []
        var menus: [QuickAccessRow.ID] = []
        var reports: [(refs: [ContentRef], lastOnScreen: Int)] = []
        strip.onSelect = { asked.append($0) }
        strip.onContextMenu = { menus.append($0); return nil }
        strip.onVisibleRefsChanged = { reports.append(($0, $1)) }
        strip.show(rows, selection: rows[1].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        let copies = drawings(in: strip).filter { title(of: $0) == "Shared" }
            .sorted { rect(of: $0, in: strip).minX < rect(of: $1, in: strip).minX }
        XCTAssertEqual(copies.count, 2)
        guard copies.count == 2 else { return }
        let centres = copies.map { NSPoint(x: rect(of: $0, in: strip).midX, y: rect(of: $0, in: strip).midY) }
        // The clip's details are asked for once, the selected clip's first.
        XCTAssertEqual(try XCTUnwrap(reports.last).refs, [rows[1].ref, shared.ref])

        // A click or a right-click on either copy asks for that copy.
        strip.mouseDown(with: try mouse(.leftMouseDown, at: centres[0], in: strip))
        XCTAssertEqual(asked.last, rows[0].id)
        strip.mouseDown(with: try mouse(.leftMouseDown, at: centres[1], in: strip))
        XCTAssertEqual(asked.last, rows[2].id)
        _ = strip.menu(for: try mouse(.rightMouseDown, at: centres[0], in: strip))
        _ = strip.menu(for: try mouse(.rightMouseDown, at: centres[1], in: strip))
        XCTAssertEqual(menus, [rows[0].id, rows[2].id])
        // The pointer washes the copy under it alone.
        let washed = { (drawing: NSView) in drawing.superview?.subviews.first { $0 !== drawing }?.isHidden == false }
        strip.mouseMoved(with: try mouse(.mouseMoved, at: centres[0], in: strip))
        XCTAssertEqual(copies.map(washed), [true, false])

        // Only the selected copy is ringed, ⌘K's menu goes beside it, and the clip's details are still asked for once.
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(drawings(in: strip).filter { $0.rootView.isSelected }.map { rect(of: $0, in: strip) },
                       [rect(of: copies[1], in: strip)])
        XCTAssertEqual(try XCTUnwrap(strip.selectionAnchorFrame).midX, rect(of: copies[1], in: strip).midX,
                       accuracy: 0.5)
        let report = try XCTUnwrap(reports.last)
        XCTAssertEqual(Set(report.refs).count, report.refs.count)
        XCTAssertEqual(report.refs, [shared.ref, rows[1].ref])
    }

    // MARK: The frequent wing

    func testTheWingSitsLeftOfTheDividerWithTheNewestClipInTheMiddle() throws {
        let strip = makeStrip(medium)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())

        // The newest clip, selected, is in the middle, and the three most used stand to its left past a gap a third of
        // a card wider than the others. The divider's line is in the middle of that gap, as tall as the cards and
        // level with them.
        XCTAssertEqual(try midX(of: "Row 0", in: strip), 688, accuracy: 0.5)
        XCTAssertEqual(try rect(titled: "Row 0", in: strip).minX - rect(titled: "Freq 2", in: strip).maxX, 90,
                       accuracy: 0.5)
        XCTAssertFalse(try dividerView(in: strip).isHidden)
        let divider = try dividerRect(in: strip)
        XCTAssertEqual(divider.midX, 529, accuracy: 0.5)
        XCTAssertEqual(divider.width, 1)
        XCTAssertEqual(divider.height, 250)
        XCTAssertEqual(divider.minY, try rect(titled: "Row 0", in: strip).minY, accuracy: 0.5)
        // ⌘K's menu goes beside the selected clip.
        XCTAssertEqual(strip.selectionAnchorFrame, try rect(titled: "Row 0", in: strip))

        // Without frequent rows the strip is as it was: the newest docked at the dock inset, and no divider.
        let plain = makeRows(20)
        strip.show(plain, selection: plain[0].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        XCTAssertEqual(try rect(titled: "Row 0", in: strip).minX, medium.dockInset, accuracy: 0.5)
        XCTAssertTrue(try dividerView(in: strip).isHidden)
    }

    func testWithTheSelectionGoneTheMenuAnchorsAtTheSlotBeforeTheWing() throws {
        let strip = makeStrip(medium)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: nil, details: [:], metrics: medium, applicationNames: ApplicationNames())

        // The empty slot takes the left dock, a step before the most used clip, and ⌘K's menu goes there.
        let anchor = try XCTUnwrap(strip.selectionAnchorFrame)
        let first = try rect(titled: "Freq 0", in: strip)
        XCTAssertEqual(anchor.minX, medium.dockInset, accuracy: 0.5)
        XCTAssertEqual(first.minX - anchor.minX, medium.step, accuracy: 0.5)
        XCTAssertEqual(anchor.size, medium.frameSize)
        XCTAssertEqual(anchor.minY, first.minY, accuracy: 0.5)
        XCTAssertFalse(try dividerView(in: strip).isHidden)
    }

    func testSectionLabelsFollowTheDividerAndStickAtTheEnds() throws {
        let strip = makeStrip(medium)
        strip.haptics = RecordingHaptics()
        let frequentLabel = try sectionLabel("QuickAccessFrequentLabel", of: strip)
        let recentLabel = try sectionLabel("QuickAccessRecentLabel", of: strip)
        let rows = makeWing(frequent: 3, recent: 20)

        // Row 0 selected: "Frequent" ends 8 short of the divider at 529 and "Recent" starts 8 past it, both below the
        // cards.
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        XCTAssertFalse(frequentLabel.isHidden)
        XCTAssertFalse(recentLabel.isHidden)
        XCTAssertEqual(frequentLabel.frame.maxX, 521, accuracy: 0.5)
        XCTAssertEqual(recentLabel.frame.minX, 537, accuracy: 0.5)
        XCTAssertGreaterThan(frequentLabel.frame.width, 0)
        // The fingers carry them as they carry the film: four tenths of a step toward older clips moves both 96.8 left,
        // and lifting brings them back.
        strip.scrollWheel(with: try swipe(dx: -12, phase: .began, at: 1.0))
        XCTAssertEqual(frequentLabel.frame.maxX, 521 - 96.8, accuracy: 0.5)
        XCTAssertEqual(recentLabel.frame.minX, 537 - 96.8, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
        XCTAssertEqual(recentLabel.frame.minX, 537, accuracy: 0.5)

        // Row 10 selected: the divider has gone off the left end, so "Recent" rests 40 in from the left end, clear of
        // the band's rounded corner, and "Frequent" goes.
        strip.show(rows, selection: rows[13].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        XCTAssertEqual(recentLabel.frame.minX, StripLayout.sectionLabelPinInset, accuracy: 0.5)
        XCTAssertFalse(recentLabel.isHidden)
        XCTAssertTrue(frequentLabel.isHidden)

        // 20 frequent + 20 recent, Freq 0 selected: the divider is off the right end, so "Frequent" ends 40 in from the
        // right end and "Recent" goes.
        let wide = makeWing(frequent: 20, recent: 20)
        strip.show(wide, selection: wide[0].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        XCTAssertEqual(frequentLabel.frame.maxX, medium.bandWidth - StripLayout.sectionLabelPinInset, accuracy: 0.5)
        XCTAssertFalse(frequentLabel.isHidden)
        XCTAssertTrue(recentLabel.isHidden)

        // Search results (no frequent rows): no labels, no divider.
        let results = makeRows(20)
        strip.show(results, selection: results[0].id, details: [:], metrics: medium,
                   applicationNames: ApplicationNames())
        XCTAssertTrue(frequentLabel.isHidden)
        XCTAssertTrue(recentLabel.isHidden)
        XCTAssertTrue(try dividerView(in: strip).isHidden)
    }

    func testAPinnedLabelStaysPutWhileTheFilmSlides() throws {
        let rows = makeWing(frequent: 3, recent: 20)
        let select = { (strip: QuickAccessStripView, index: Int) in
            strip.show(rows, selection: rows[index].id, details: [:], metrics: self.medium,
                       applicationNames: ApplicationNames())
        }

        // On screen, where the film slides. Row 0 → Row 1: the film slides, and both labels slide with it.
        let strip = makeStrip(medium)
        strip.window?.orderFront(nil)
        let frequent = try XCTUnwrap(sectionLabel("QuickAccessFrequentLabel", of: strip).layer)
        let recent = try XCTUnwrap(sectionLabel("QuickAccessRecentLabel", of: strip).layer)
        select(strip, 3)
        select(strip, 4)
        XCTAssertFalse(frequent.animationKeys()?.isEmpty ?? true)
        XCTAssertFalse(recent.animationKeys()?.isEmpty ?? true)

        // Row 10 → Row 11 (fresh strip): the film slides; "Recent", resting at the left end, does not, and "Frequent",
        // hidden before the slide, stays hidden through it.
        let pinned = makeStrip(medium)
        pinned.window?.orderFront(nil)
        let pinnedLabel = try sectionLabel("QuickAccessRecentLabel", of: pinned)
        select(pinned, 13)
        select(pinned, 14)
        XCTAssertFalse(try XCTUnwrap(pinned.subviews.first?.layer).animationKeys()?.isEmpty ?? true)
        XCTAssertEqual(try XCTUnwrap(pinnedLabel.layer).animationKeys() ?? [], [])
        XCTAssertEqual(pinnedLabel.frame.minX, StripLayout.sectionLabelPinInset, accuracy: 0.5)
        XCTAssertTrue(try sectionLabel("QuickAccessFrequentLabel", of: pinned).isHidden)
        // The same at the right end (fresh strip, 20 frequent clips, Freq 5 → Freq 6): the film slides; "Frequent",
        // resting at the right end, does not, and "Recent", hidden before the slide, stays hidden through it.
        let wide = makeWing(frequent: 20, recent: 20)
        let right = makeStrip(medium)
        right.window?.orderFront(nil)
        let rightLabel = try sectionLabel("QuickAccessFrequentLabel", of: right)
        for index in [5, 6] {
            right.show(wide, selection: wide[index].id, details: [:], metrics: medium,
                       applicationNames: ApplicationNames())
        }
        XCTAssertFalse(try XCTUnwrap(right.subviews.first?.layer).animationKeys()?.isEmpty ?? true)
        XCTAssertEqual(try XCTUnwrap(rightLabel.layer).animationKeys() ?? [], [])
        XCTAssertEqual(rightLabel.frame.maxX, medium.bandWidth - StripLayout.sectionLabelPinInset, accuracy: 0.5)
        XCTAssertTrue(try sectionLabel("QuickAccessRecentLabel", of: right).isHidden)
        // A step from Row 3 to Row 2 brings the divider back into the band, and the label leaves the end, sliding.
        // (Row 3 is too far from Row 11 to slide to, so nothing moves on the way there.)
        select(pinned, 6)
        XCTAssertEqual(try XCTUnwrap(pinnedLabel.layer).animationKeys() ?? [], [])
        select(pinned, 5)
        XCTAssertFalse(try XCTUnwrap(pinnedLabel.layer).animationKeys()?.isEmpty ?? true)

        // With Reduce Motion (fresh strip, Row 0 → Row 1) nothing slides.
        let still = makeStrip(medium)
        still.reducesMotion = { true }
        still.window?.orderFront(nil)
        let stillFrequent = try XCTUnwrap(sectionLabel("QuickAccessFrequentLabel", of: still).layer)
        let stillRecent = try XCTUnwrap(sectionLabel("QuickAccessRecentLabel", of: still).layer)
        select(still, 3)
        select(still, 4)
        XCTAssertEqual(stillFrequent.animationKeys() ?? [], [])
        XCTAssertEqual(stillRecent.animationKeys() ?? [], [])
        // Without it, the next step slides them.
        still.reducesMotion = { false }
        select(still, 5)
        XCTAssertFalse(stillFrequent.animationKeys()?.isEmpty ?? true)
        XCTAssertFalse(stillRecent.animationKeys()?.isEmpty ?? true)
    }

    func testALabelLeavingTheDockSlidesFromWhereItIsDrawn() throws {
        let strip = makeStrip(medium)
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Labels slide only where they can be seen.
        strip.window?.orderFront(nil)
        let frequentLabel = try sectionLabel("QuickAccessFrequentLabel", of: strip)
        let recentLabel = try sectionLabel("QuickAccessRecentLabel", of: strip)
        let rows = makeWing(frequent: 3, recent: 20)
        // Row 3 in the middle: the divider is at -197, off the left end, so "Recent" rests 40 in from the left end.
        strip.show(rows, selection: rows[6].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        XCTAssertEqual(recentLabel.frame.minX, StripLayout.sectionLabelPinInset, accuracy: 0.5)
        XCTAssertTrue(frequentLabel.isHidden)

        // Time stands still from here, so the slide stays at its beginning.
        content.layer?.speed = 0
        // Row 2: the film slides a step right, which brings the divider back into the band at 45.
        strip.show(rows, selection: rows[5].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        CATransaction.flush()
        // "Recent" is bound for 53 but still drawn where it rested: it slides from where it is drawn, not with the
        // film.
        XCTAssertEqual(recentLabel.frame.minX, 53, accuracy: 0.5)
        XCTAssertEqual(try drawnMinX(of: recentLabel), StripLayout.sectionLabelPinInset, accuracy: 0.5)
        // "Frequent" comes in with the film, 8 short of the divider where it is drawn: a step left of its place.
        let film = try XCTUnwrap(strip.subviews.first?.layer)
        let drawnDivider = try dividerRect(in: strip).midX + (try XCTUnwrap(film.presentation()).position.x
            - film.position.x)
        XCTAssertEqual(drawnDivider, 45 - medium.step, accuracy: 0.5)
        XCTAssertFalse(frequentLabel.isHidden)
        XCTAssertEqual(try drawnMinX(of: frequentLabel) + frequentLabel.frame.width, drawnDivider - 8, accuracy: 0.5)
    }

    func testTheLabelsSpringBackWithTheFilmWhenTheFingersLift() throws {
        let strip = makeStrip(medium)
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Labels slide only where they can be seen.
        strip.window?.orderFront(nil)
        strip.haptics = RecordingHaptics()
        let recentLabel = try sectionLabel("QuickAccessRecentLabel", of: strip)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        // The fingers carry the film four tenths of a step toward older clips, and the label with it.
        strip.scrollWheel(with: try swipe(dx: -12, phase: .began, at: 1.0))
        XCTAssertEqual(recentLabel.frame.minX, 537 - 96.8, accuracy: 0.5)

        // Time stands still from here, so the spring back stays at its beginning.
        content.layer?.speed = 0
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
        CATransaction.flush()
        // The label's place is beside the resting divider again, but it is still drawn where the fingers left it.
        XCTAssertEqual(recentLabel.frame.minX, 537, accuracy: 0.5)
        XCTAssertEqual(try drawnMinX(of: recentLabel), 537 - 96.8, accuracy: 0.5)
    }

    func testAClipChosenUnderPushedFingersSlidesTheLabelsFromWhereTheyAreDrawn() throws {
        let strip = makeStrip(medium)
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Labels slide only where they can be seen.
        strip.window?.orderFront(nil)
        strip.haptics = RecordingHaptics()
        let recentLabel = try sectionLabel("QuickAccessRecentLabel", of: strip)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        // The fingers carry the film four tenths of a step toward older clips, and rest there.
        strip.scrollWheel(with: try swipe(dx: -12, phase: .began, at: 1.0))
        let pushed = recentLabel.frame.minX
        XCTAssertEqual(pushed, 537 - 96.8, accuracy: 0.5)

        // Time stands still from here, so the slide stays at its beginning.
        content.layer?.speed = 0
        // A key chooses Row 1, which starts the fingers afresh. The film slides from where they left it, and the label
        // from where it is drawn, not from where the film rested before they pushed it.
        strip.show(rows, selection: rows[4].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        CATransaction.flush()
        XCTAssertEqual(recentLabel.frame.minX, 295, accuracy: 0.5)
        XCTAssertEqual(try drawnMinX(of: recentLabel), pushed, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
    }

    func testAStepTheFingersCompleteAsTheyLiftKeepsTheLabelsWithTheFilm() throws {
        // The fingers carry the film six tenths of a step and lift, which completes the step: the panel shows it in the
        // same turn, while their push is still on the film, and the push then springs back. Returns the label's place
        // and where it is drawn as they lift, with time standing still, and where it was drawn before.
        func lift(frequent: Int, from start: Int, dx: Int32, label identifier: String) throws
            -> (place: NSRect, drawn: CGFloat, before: CGFloat, hidden: Bool) {
            let strip = makeStrip(medium)
            let content = try XCTUnwrap(strip.superview)
            content.wantsLayer = true
            // Labels slide only where they can be seen.
            strip.window?.orderFront(nil)
            strip.haptics = RecordingHaptics()
            let label = try sectionLabel(identifier, of: strip)
            let rows = makeWing(frequent: frequent, recent: 20)
            var selected = start
            strip.onCommand = { [unowned strip, medium = self.medium] command in
                guard case .move(let offset) = command else { return }
                selected += offset
                strip.show(rows, selection: rows[selected].id, details: [:], metrics: medium,
                           applicationNames: ApplicationNames())
            }
            strip.show(rows, selection: rows[start].id, details: [:], metrics: medium,
                       applicationNames: ApplicationNames())
            strip.scrollWheel(with: try swipe(dx: dx, phase: .began, at: 1.0))
            let before = try drawnMinX(of: label)
            // Time stands still from here, so the slide stays at its beginning.
            content.layer?.speed = 0
            strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
            CATransaction.flush()
            XCTAssertEqual(selected, start + (dx < 0 ? 1 : -1))
            return (label.frame, try drawnMinX(of: label), before, label.isHidden)
        }

        // Row 1 in the middle, the divider at 287, and a push toward older clips: the step to Row 2 rests the divider
        // at 45. "Frequent" is bound for its place 8 short of it, and is still drawn where it was: no jump of a step.
        let frequent = try lift(frequent: 3, from: 4, dx: -18, label: "QuickAccessFrequentLabel")
        XCTAssertFalse(frequent.hidden)
        XCTAssertEqual(frequent.place.maxX, 37, accuracy: 0.5)
        XCTAssertEqual(frequent.drawn, frequent.before, accuracy: 0.5)
        // The mirror at the right end: Freq 4 of six in the middle, the divider at 1089, and a push toward newer clips:
        // the step to Freq 3 rests the divider at 1331, and "Recent" is bound for 1339, still drawn where it was.
        let recent = try lift(frequent: 6, from: 4, dx: 18, label: "QuickAccessRecentLabel")
        XCTAssertFalse(recent.hidden)
        XCTAssertEqual(recent.place.minX, 1339, accuracy: 0.5)
        XCTAssertEqual(recent.drawn, recent.before, accuracy: 0.5)
    }

    func testALabelLeavingWithTheFilmGoesOnlyOnceTheSlideSettles() async throws {
        // A key chooses the clip at `end` on a strip on screen, with time standing still from then on, so the slide
        // stays at its beginning. Returns the label and where it was drawn before.
        func press(frequent: Int, from start: Int, to end: Int, label identifier: String) throws
            -> (label: NSView, before: CGFloat) {
            let strip = makeStrip(medium)
            let content = try XCTUnwrap(strip.superview)
            content.wantsLayer = true
            strip.window?.orderFront(nil)
            let label = try sectionLabel(identifier, of: strip)
            let rows = makeWing(frequent: frequent, recent: 20)
            strip.show(rows, selection: rows[start].id, details: [:], metrics: medium,
                       applicationNames: ApplicationNames())
            XCTAssertFalse(label.isHidden, identifier)
            let before = try drawnMinX(of: label)
            content.layer?.speed = 0
            strip.show(rows, selection: rows[end].id, details: [:], metrics: medium,
                       applicationNames: ApplicationNames())
            CATransaction.flush()
            return (label, before)
        }

        // Row 2 → Row 3 takes the divider from 45 to -197, off the left end, where "Frequent" has no place. While the
        // film is still drawn where it was, the label stays with it, bound for its place 8 short of the divider.
        let frequent = try press(frequent: 3, from: 5, to: 6, label: "QuickAccessFrequentLabel")
        XCTAssertFalse(frequent.label.isHidden)
        XCTAssertEqual(frequent.label.frame.maxX, -197 - 8, accuracy: 0.5)
        XCTAssertEqual(try drawnMinX(of: frequent.label), frequent.before, accuracy: 0.5)
        // The mirror at the right end: Freq 3 → Freq 2 of six takes the divider from 1331 to 1503, off the right end,
        // and "Recent" stays with the film, bound for its place 8 past the divider.
        let recent = try press(frequent: 6, from: 3, to: 2, label: "QuickAccessRecentLabel")
        XCTAssertFalse(recent.label.isHidden)
        XCTAssertEqual(recent.label.frame.minX, 1503 + 8, accuracy: 0.5)
        XCTAssertEqual(try drawnMinX(of: recent.label), recent.before, accuracy: 0.5)
        // Once the slides have settled, both go.
        try await waitUntil { frequent.label.isHidden && recent.label.isHidden }
    }

    func testALabelKeptThroughASpringBackGoesOnceItSettles() async throws {
        let large = StripLayout.metrics(for: .large, visibleWidth: 1440)
        let strip = makeStrip(large)
        let content = try XCTUnwrap(strip.superview)
        content.wantsLayer = true
        // Labels slide only where they can be seen.
        strip.window?.orderFront(nil)
        strip.haptics = RecordingHaptics()
        let frequentLabel = try sectionLabel("QuickAccessFrequentLabel", of: strip)
        let rows = makeWing(frequent: 3, recent: 20)
        // Large cards with Row 2 in the middle: the divider rests at -40.5, off the left end, so "Frequent" is hidden.
        strip.show(rows, selection: rows[5].id, details: [:], metrics: large, applicationNames: ApplicationNames())
        XCTAssertTrue(frequentLabel.isHidden)
        // The fingers carry the film just short of half a step toward newer clips, which brings the divider and the
        // label in.
        strip.scrollWheel(with: try swipe(dx: 14, phase: .began, at: 1.0))
        XCTAssertFalse(frequentLabel.isHidden)
        let before = try drawnMinX(of: frequentLabel)

        // Time stands still from here, so the spring back stays at its beginning.
        content.layer?.speed = 0
        // They lift short of half a step: the film springs back, and the label stays with it, still drawn where it was.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
        CATransaction.flush()
        XCTAssertFalse(frequentLabel.isHidden)
        XCTAssertEqual(try drawnMinX(of: frequentLabel), before, accuracy: 0.5)
        // Once the spring back has settled, it goes.
        try await waitUntil { frequentLabel.isHidden }
    }

    func testTheSectionIconsSitBelowTheCardsAndStayWhenTheBandResizesTheirView() throws {
        // With the frequent wing there are 28 pt below the cards. The ring around a selected card reaches 7 pt into
        // them with Increase Contrast, and each icon is centred in the 21 pt left between the ring and the band's
        // bottom edge: a 15 pt icon starts 3 above that edge and ends 3 short of the ring. QuickAccessBandTests
        // measures the ink the icons draw.
        let wing = StripLayout.metrics(for: .medium, visibleWidth: 1440, showsFrequentClips: true)
        let strip = makeStrip(wing)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: wing, applicationNames: ApplicationNames())
        let cardBottom = strip.convert(try rect(titled: "Row 0", in: strip), to: nil).minY
        let bandBottom = strip.sectionLabels.convert(strip.sectionLabels.bounds, to: nil).minY
        XCTAssertEqual(cardBottom - bandBottom, 28, accuracy: 0.01)
        var places: [String: CGFloat] = [:]
        for identifier in ["QuickAccessFrequentLabel", "QuickAccessRecentLabel"] {
            let icon = try sectionLabel(identifier, of: strip)
            XCTAssertFalse(icon.isHidden, identifier)
            let frame = icon.convert(icon.bounds, to: nil)
            // Centred to the pixel: as far above the band's bottom edge as short of the ring.
            XCTAssertEqual(frame.minY - bandBottom, (21 - frame.height) / 2, accuracy: 0.5, identifier)
            XCTAssertLessThanOrEqual(frame.maxY, cardBottom - 7, identifier)
            places[identifier] = frame.minY - bandBottom
        }

        // The band gives the icons' view the room below the cards, 28 pt with the frequent wing turned on and 22
        // without, and may do so after the strip has placed them. Its bottom stays at the band's bottom edge, and so
        // do the icons' places.
        for height in [22, 28] as [CGFloat] {
            strip.sectionLabels.setFrameSize(NSSize(width: wing.bandWidth, height: height))
            for identifier in ["QuickAccessFrequentLabel", "QuickAccessRecentLabel"] {
                let icon = try sectionLabel(identifier, of: strip)
                XCTAssertEqual(icon.convert(icon.bounds, to: nil).minY - bandBottom, try XCTUnwrap(places[identifier]),
                               accuracy: 0.01, "\(identifier) in \(height) pt")
            }
        }
    }

    func testAPushTowardNewerClipsFindsAFrameForEveryClipItBringsIn() throws {
        let strip = makeStrip(medium)
        strip.haptics = RecordingHaptics()
        let rows = makeWing(frequent: 3, recent: 20)
        // Row 10 in the middle: recent clips reach the band's left end, each a third of a card further right than it
        // would stand without the wing, and Row 7 is the one the end cuts.
        strip.show(rows, selection: rows[13].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        XCTAssertEqual(try rect(titled: "Row 7", in: strip).minX, -152, accuracy: 0.5)

        // The fingers carry the selection most of the way to the next newer clip, and the film with it. Row 6 comes
        // into the band, and it has its frame.
        strip.scrollWheel(with: try swipe(dx: 29, phase: .began, at: 1.0))
        let arriving = try rect(titled: "Row 6", in: strip)
        XCTAssertEqual(arriving.minX, -394 + medium.step * 29 / 30, accuracy: 0.5)
        XCTAssertGreaterThan(arriving.maxX, 0)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
    }

    func testIncreaseContrastWidensTheDivider() throws {
        let strip = makeStrip(medium)
        strip.increasesContrast = { true }
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        XCTAssertEqual(try dividerRect(in: strip).width, 2)
        XCTAssertEqual(try dividerRect(in: strip).midX, 529, accuracy: 0.5)

        // The setting can change while the panel is open: the divider takes the new width when the system says so.
        strip.increasesContrast = { false }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: NSWorkspace.shared)
        XCTAssertEqual(try dividerRect(in: strip).width, 1)
        XCTAssertEqual(try dividerRect(in: strip).midX, 529, accuracy: 0.5)
    }

    func testTheDividerTakesTheCardsSeparatorColour() throws {
        let strip = makeStrip(medium)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        let divider = try dividerView(in: strip)

        // White at 7 percent in dark mode and black at 7 percent in light, as the line over each card's footer. AppKit
        // makes the high-contrast appearances only from the system setting, never by name, so the signed build has to
        // show that Increase Contrast leaves this colour as it is.
        for (name, white) in [(NSAppearance.Name.darkAqua, 1), (.aqua, 0)] as [(NSAppearance.Name, CGFloat)] {
            var drawn: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                divider.updateLayer()
                drawn = divider.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB)
            }
            let colour = try XCTUnwrap(drawn, name.rawValue)
            XCTAssertEqual(colour.redComponent, white, accuracy: 0.01, name.rawValue)
            XCTAssertEqual(colour.greenComponent, white, accuracy: 0.01, name.rawValue)
            XCTAssertEqual(colour.blueComponent, white, accuracy: 0.01, name.rawValue)
            XCTAssertEqual(colour.alphaComponent, 0.07, accuracy: 0.001, name.rawValue)
        }
    }

    func testTheDividerAndTheLabelsTakeNoClicksNoKeysAndAreNotRead() throws {
        let strip = makeStrip(medium)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        let labels = strip.sectionLabels
        let recent = try sectionLabel("QuickAccessRecentLabel", of: strip)
        let divider = try dividerView(in: strip)

        // A click on a label goes through to whatever lies beneath.
        XCTAssertNil(labels.hitTest(labels.convert(NSPoint(x: recent.frame.midX, y: recent.frame.midY),
                                                   to: labels.superview)))
        // Neither takes the keys.
        XCTAssertFalse(recent.acceptsFirstResponder)
        XCTAssertFalse(divider.acceptsFirstResponder)
        // VoiceOver reads the frames alone; the labels have nothing for it.
        XCTAssertEqual(labels.accessibilityChildren()?.count ?? 0, 0)
        XCTAssertFalse((strip.accessibilityChildren() as? [NSView] ?? []).contains(divider))
    }

    func testEachSectionIconNamesItsWingInItsHelpTagAndAccessibilityLabel() throws {
        // No word is drawn beside an icon; the pointer resting on it shows the wing's name, and the icon's
        // accessibility label is the same word.
        let strip = makeStrip(medium)
        let rows = makeWing(frequent: 3, recent: 20)
        strip.show(rows, selection: rows[3].id, details: [:], metrics: medium, applicationNames: ApplicationNames())
        for (identifier, word) in [("QuickAccessFrequentLabel", "Frequent"), ("QuickAccessRecentLabel", "Recent")] {
            let icon = try sectionLabel(identifier, of: strip)
            XCTAssertFalse(icon.isHidden, identifier)
            XCTAssertEqual(icon.toolTip, word, identifier)
            XCTAssertEqual(icon.accessibilityLabel(), word, identifier)
        }
    }

    func testPreviewDimsTheFramesBesideTheSelectedOne() throws {
        let strip = makeStrip()
        let rows = makeRows(5)
        strip.show(rows, selection: rows[2].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(opacities(in: strip), ["Row 0": 1, "Row 1": 1, "Row 2": 1, "Row 3": 1, "Row 4": 1])

        // While the preview is open the clips beside the selected one step back to half strength.
        strip.dimsSideFrames = true
        XCTAssertEqual(opacities(in: strip), ["Row 0": 0.5, "Row 1": 0.5, "Row 2": 1, "Row 3": 0.5, "Row 4": 0.5])
        // The clip selected next comes forward, and the one selected before steps back.
        strip.show(rows, selection: rows[3].id, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(opacities(in: strip), ["Row 0": 0.5, "Row 1": 0.5, "Row 2": 0.5, "Row 3": 1, "Row 4": 0.5])

        strip.dimsSideFrames = false
        XCTAssertEqual(opacities(in: strip), ["Row 0": 1, "Row 1": 1, "Row 2": 1, "Row 3": 1, "Row 4": 1])
    }

    func testApplicationIconsAreCachedWithAGenericFallback() {
        let names = ApplicationNames()
        let generic = names.icon(for: nil)

        XCTAssertTrue(names.icon(for: "com.keeptide.tests.no-such-app") === generic)
        let finder = names.icon(for: "com.apple.finder")
        XCTAssertFalse(finder === generic)
        XCTAssertTrue(names.icon(for: "com.apple.finder") === finder)
    }

    // MARK: Helpers

    /// Medium cards on a screen 1440 pt wide: a band 1376 wide, frames 228 by 250 and 242 apart, a dock inset of 20.
    private var medium: StripMetrics { StripLayout.metrics(for: .medium, visibleWidth: 1440) }

    /// A strip one band wide in a window that is never shown, so frames go straight to their places, with its section
    /// icons below the cards as the band places them. A test that shows the window sees the frames slide, whatever
    /// Reduce Motion is set to on the Mac that runs it; the divider is as wide as without Increase Contrast either way.
    private func makeStrip(_ metrics: StripMetrics? = nil) -> QuickAccessStripView {
        let metrics = metrics ?? self.metrics
        let size = NSSize(width: metrics.bandWidth, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = KeyRecordingView(frame: NSRect(origin: .zero, size: size))
        let strip = QuickAccessStripView(frame: NSRect(x: 0, y: 100, width: metrics.bandWidth,
                                                       height: metrics.frameSize.height + 24))
        strip.reducesMotion = { false }
        strip.increasesContrast = { false }
        content.addSubview(strip)
        // The icons' view starts at the cards' bottom, half the room the strip keeps around them above its own bottom,
        // and reaches down as far as the band's bottom edge.
        let cardBottom = strip.frame.minY + (strip.frame.height - metrics.frameSize.height) / 2
        strip.sectionLabels.frame = NSRect(x: 0, y: cardBottom - metrics.bottomPadding, width: metrics.bandWidth,
                                           height: metrics.bottomPadding)
        content.addSubview(strip.sectionLabels)
        window.contentView = content
        addTeardownBlock { window.close() }
        return strip
    }

    /// `frequent` rows of the frequent wing, titled "Freq 0" on and the most used first, then `recent` rows titled
    /// "Row 0" on.
    private func makeWing(frequent: Int, recent: Int) -> [QuickAccessRow] {
        (0..<frequent).map { self.frequent(makeRow(title: "Freq \($0)"), uses: Int64(100 - $0)) } + makeRows(recent)
    }

    /// The line between the wings, found by its identifier.
    private func dividerView(in strip: QuickAccessStripView) throws -> NSView {
        func find(_ view: NSView) -> NSView? {
            view.accessibilityIdentifier() == "QuickAccessDivider" ? view : view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(strip), "QuickAccessDivider")
    }

    /// The divider's line in the strip's coordinates.
    private func dividerRect(in strip: QuickAccessStripView) throws -> NSRect {
        let divider = try dividerView(in: strip)
        return strip.convert(divider.bounds, from: divider)
    }

    /// One of the two section labels, found by its identifier. Its frame is in the band's coordinates.
    private func sectionLabel(_ identifier: String, of strip: QuickAccessStripView) throws -> NSView {
        try XCTUnwrap(strip.sectionLabels.subviews.first { $0.accessibilityIdentifier() == identifier }, identifier)
    }

    /// Where a section label's left edge is drawn at this moment, a running slide included.
    private func drawnMinX(of label: NSView) throws -> CGFloat {
        let layer = try XCTUnwrap(label.layer)
        return label.frame.minX + (layer.presentation()?.position.x ?? layer.position.x) - layer.position.x
    }

    /// The frames drawn in the strip, wherever they sit in its views.
    private func drawings(in view: NSView) -> [NSHostingView<StripFrameView>] {
        view.subviews.flatMap { subview in
            (subview as? NSHostingView<StripFrameView>).map { [$0] } ?? drawings(in: subview)
        }
    }

    /// The title a frame shows while its details have not arrived.
    private func title(of drawing: NSHostingView<StripFrameView>) -> String? {
        guard case .placeholder(_, let title) = drawing.rootView.content.body else { return nil }
        return title
    }

    private func rect(of drawing: NSView, in strip: NSView) -> NSRect {
        strip.convert(drawing.bounds, from: drawing)
    }

    private func rect(titled title: String, in strip: NSView) throws -> NSRect {
        rect(of: try XCTUnwrap(drawings(in: strip).first { self.title(of: $0) == title }, title), in: strip)
    }

    private func midX(of title: String, in strip: NSView) throws -> CGFloat {
        try rect(titled: title, in: strip).midX
    }

    /// Where the frame with this title is drawn at this moment, a running slide included: the frames move as one in
    /// the strip's film.
    private func drawnMidX(of title: String, in strip: NSView) throws -> CGFloat {
        let film = try XCTUnwrap(strip.subviews.first?.layer)
        return try midX(of: title, in: strip) + (film.presentation()?.position.x ?? film.position.x) - film.position.x
    }

    private func selectedTitle(in strip: NSView) -> String? {
        drawings(in: strip).first { $0.rootView.isSelected }.flatMap(title(of:))
    }

    /// How strongly each frame is drawn, by title: the opacity of its drawing and of every view up to the strip.
    private func opacities(in strip: NSView) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        for drawing in drawings(in: strip) {
            var opacity: CGFloat = 1
            var view: NSView? = drawing
            while let current = view, current !== strip {
                opacity *= current.alphaValue
                view = current.superview
            }
            if let title = title(of: drawing) { result[title] = opacity }
        }
        return result
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1,
                       in strip: NSView) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: strip.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: strip.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [],
                     ignoringModifiers: String? = nil, isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: isARepeat, keyCode: UInt16(code)
        ))
    }

    /// A trackpad event: whole points, with the gesture's phase.
    private func swipe(dx: Int32, phase: CGScrollPhase, at time: TimeInterval) throws -> NSEvent {
        try scrollEvent(dx: dx, dy: 0, isPrecise: true, phase: Int64(phase.rawValue), momentum: 0, at: time)
    }

    /// The coasting the system sends after the fingers have lifted.
    private func coast(dx: Int32, at time: TimeInterval) throws -> NSEvent {
        // 2 is the momentum phase in which coasting continues.
        try scrollEvent(dx: dx, dy: 0, isPrecise: true, phase: 0, momentum: 2, at: time)
    }

    /// A notch of an ordinary mouse wheel, which has no phase.
    private func wheel(dy: Int32, at time: TimeInterval) throws -> NSEvent {
        try scrollEvent(dx: 0, dy: dy, isPrecise: false, phase: 0, momentum: 0, at: time)
    }

    /// A notch of a mouse wheel turned sideways.
    private func wheel(dx: Int32, at time: TimeInterval) throws -> NSEvent {
        try scrollEvent(dx: dx, dy: 0, isPrecise: false, phase: 0, momentum: 0, at: time)
    }

    private func scrollEvent(dx: Int32, dy: Int32, isPrecise: Bool, phase: Int64, momentum: Int64,
                             at time: TimeInterval) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: isPrecise ? .pixel : .line,
                                          wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: isPrecise ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.timestamp = UInt64(time * 1_000_000_000)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeRows(_ count: Int, from start: Int = 0) -> [QuickAccessRow] {
        (start..<start + count).map { makeRow(title: "Row \($0)") }
    }

    /// A copy of `row` listed in the frequent wing, used `uses` times.
    private func frequent(_ row: QuickAccessRow, uses: Int64) -> QuickAccessRow {
        var copy = row
        copy.frequentUses = uses
        return copy
    }

    private func makeRow(kind: ContentKind = .text, title: String, sourceApp: String? = nil, savedAsMemo: Bool = false,
                         isPartiallyIndexed: Bool = false, isTextUnavailable: Bool = false) -> QuickAccessRow {
        QuickAccessRow(
            ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                            digest: Data(repeating: 7, count: 32)),
            title: title, snippet: nil, kind: kind, sourceApp: sourceApp, date: Date(timeIntervalSince1970: 1_000),
            savedAsMemo: savedAsMemo, isPartiallyIndexed: isPartiallyIndexed, isTextUnavailable: isTextUnavailable
        )
    }
}

@MainActor
private final class RecordingHaptics: HapticPerforming {
    private(set) var ticks = 0
    func tick() { ticks += 1 }
}

/// Counts the keys that reach it, so a test can tell a key the strip passed on from one it dropped.
private final class KeyRecordingView: NSView {
    private(set) var keys = 0
    override func keyDown(with event: NSEvent) { keys += 1 }
}
