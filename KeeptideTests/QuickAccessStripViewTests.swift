import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Keeptide

@MainActor
final class QuickAccessStripViewTests: XCTestCase {
    /// Nine clips in a row on a band at its full width: frames 164 pt wide, 176 pt apart.
    private var metrics: StripMetrics { StripLayout.metrics(for: .nine, visibleWidth: 1440) }
    private var centre: CGFloat { metrics.bandWidth / 2 }

    func testSelectedFrameIsCentredInTheBand() throws {
        let strip = makeStrip()
        let rows = makeRows(20)

        strip.show(rows, selection: rows[5].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        let selected = try XCTUnwrap(drawings(in: strip).first { $0.rootView.isSelected })
        XCTAssertEqual(title(of: selected), "Row 5")
        XCTAssertEqual(drawings(in: strip).filter { $0.rootView.isSelected }.count, 1)
        let frame = rect(of: selected, in: strip)
        XCTAssertEqual(frame.midX, centre, accuracy: 0.5)
        XCTAssertEqual(frame.midY, strip.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(frame.size, metrics.frameSize)
        // Older clips to the left and newer ones to the right, a frame and a gap apart.
        XCTAssertEqual(try midX(of: "Row 6", in: strip), centre - metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 4", in: strip), centre + metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 9", in: strip), centre - 4 * metrics.step, accuracy: 0.5)

        // A narrow screen steps down a density, and the frames are drawn for the density in effect.
        let narrow = StripLayout.metrics(for: .nine, visibleWidth: 1100)
        XCTAssertEqual(narrow.density, .seven)
        let small = makeStrip(narrow)
        small.show(rows, selection: rows[5].ref, details: [:], metrics: narrow, applicationNames: ApplicationNames())
        XCTAssertFalse(drawings(in: small).isEmpty)
        XCTAssertTrue(drawings(in: small).allSatisfy { $0.rootView.density == .seven })
        XCTAssertEqual(try midX(of: "Row 5", in: small), narrow.bandWidth / 2, accuracy: 0.5)
        XCTAssertEqual(try rect(titled: "Row 5", in: small).size, narrow.frameSize)
    }

    func testLostSelectionLeavesTheCentreEmpty() throws {
        let strip = makeStrip()
        let rows = makeRows(6)
        strip.show(rows, selection: rows[2].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // The selected clip disappears, and the state selects nothing in its place.
        let remaining = rows.filter { $0.ref != rows[2].ref }
        strip.show(remaining, selection: nil, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        let frames = drawings(in: strip)
        XCTAssertEqual(frames.count, 5)
        XCTAssertFalse(frames.contains { $0.rootView.isSelected })
        XCTAssertTrue(frames.allSatisfy { rect(of: $0, in: strip).maxX < centre }, "Nothing covers the middle")
        // Every frame sits to the left of the empty middle, the newest next to it.
        XCTAssertEqual(try midX(of: "Row 0", in: strip), centre - metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 1", in: strip), centre - 2 * metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 3", in: strip), centre - 3 * metrics.step, accuracy: 0.5)
        XCTAssertEqual(strip.accessibilitySelectedChildren()?.count ?? 0, 0)
    }

    func testOnlyFramesNearTheCentreExist() throws {
        let strip = makeStrip()
        let rows = makeRows(200)
        var reports: [(refs: [ContentRef], lastOnScreen: Int)] = []
        strip.onVisibleRefsChanged = { reports.append(($0, $1)) }

        strip.show(rows, selection: rows[100].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Nine in a row are on screen, and two more on each side keep a step from showing a gap.
        XCTAssertLessThanOrEqual(drawings(in: strip).count, StripDensity.nine.rawValue + 4)
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((94...106).map { "Row \($0)" }))
        // Details are asked for only the rows with a frame, the selected clip's first. The last row on
        // screen is the one that decides when to load more.
        let report = try XCTUnwrap(reports.last)
        XCTAssertEqual(Set(report.refs), Set(rows[94...106].map(\.ref)))
        XCTAssertEqual(report.refs.count, 13)
        XCTAssertEqual(report.refs.first, rows[100].ref)
        XCTAssertEqual(report.lastOnScreen, 104)

        // One step later every frame is still in use: the one that left now draws the one that arrived.
        let before = Set(drawings(in: strip).map(ObjectIdentifier.init))
        strip.show(rows, selection: rows[101].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(Set(drawings(in: strip).map(ObjectIdentifier.init)), before)
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((95...107).map { "Row \($0)" }))

        // At the newest end there are frames on the older side only.
        strip.show(rows, selection: rows[0].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((0...6).map { "Row \($0)" }))
        XCTAssertEqual(Set(try XCTUnwrap(reports.last).refs), Set(rows[0...6].map(\.ref)))
        XCTAssertEqual(reports.last?.lastOnScreen, 4)

        strip.show(rows, selection: rows[199].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((193...199).map { "Row \($0)" }))
        XCTAssertEqual(reports.last?.lastOnScreen, 199)

        // Shown again unchanged, the rows are asked for again while their details are missing, as when
        // the panel opens again over the same clips.
        let asked = reports.count
        strip.show(rows, selection: rows[199].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(reports.count, asked + 1)
        // Once every framed row has its details, an unchanged strip asks for nothing more.
        let details = Dictionary(uniqueKeysWithValues: rows[193...199].map { ($0.ref, ClipDetail()) })
        for _ in 1...2 {
            strip.show(rows, selection: rows[199].ref, details: details, metrics: metrics,
                       applicationNames: ApplicationNames())
        }
        XCTAssertEqual(reports.count, asked + 1)
    }

    func testLoadingMoreKeepsTheSelectedFrameCentred() throws {
        let strip = makeStrip()
        let page = makeRows(60)
        strip.show(page, selection: page[57].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let before = try rect(titled: "Row 57", in: strip)
        let neighbour = try rect(titled: "Row 59", in: strip)

        strip.show(page + makeRows(60, from: 60), selection: page[57].ref, details: [:], metrics: metrics,
                   applicationNames: ApplicationNames())

        XCTAssertEqual(try rect(titled: "Row 57", in: strip), before)
        XCTAssertEqual(before.midX, centre, accuracy: 0.5)
        XCTAssertEqual(drawings(in: strip).first { $0.rootView.isSelected }.flatMap(title(of:)), "Row 57")
        XCTAssertEqual(try rect(titled: "Row 59", in: strip), neighbour)
        // The rows that arrived take their places on the older side, as if they had always been there.
        XCTAssertEqual(try midX(of: "Row 60", in: strip), centre - 3 * metrics.step, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 63", in: strip), centre - 6 * metrics.step, accuracy: 0.5)
    }

    func testClickAsksTheStateAndMovesOnlyWhenItAgrees() throws {
        let strip = makeStrip()
        let rows = makeRows(8)
        var asked: [ContentRef] = []
        strip.onSelect = { asked.append($0) }
        strip.show(rows, selection: rows[2].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
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

        XCTAssertEqual(asked, [rows[4].ref])
        XCTAssertTrue(strip.window?.firstResponder === strip)
        // Until the state agrees, the ring stays where the state put it, in the middle.
        XCTAssertEqual(selectedTitle(in: strip), "Row 2")
        XCTAssertEqual(try midX(of: "Row 2", in: strip), centre, accuracy: 0.5)
        XCTAssertEqual(try midX(of: "Row 4", in: strip), centre - 2 * metrics.step, accuracy: 0.5)

        // The state refused and shows its own selection again: nothing moves.
        strip.show(rows, selection: rows[2].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(selectedTitle(in: strip), "Row 2")
        XCTAssertEqual(try midX(of: "Row 2", in: strip), centre, accuracy: 0.5)

        // The state agreed: the clicked clip comes to the middle with the ring.
        strip.show(rows, selection: rows[4].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(selectedTitle(in: strip), "Row 4")
        XCTAssertEqual(try midX(of: "Row 4", in: strip), centre, accuracy: 0.5)

        // A click between two frames asks for nothing.
        let gap = NSPoint(x: centre + (metrics.frameSize.width + metrics.gap) / 2, y: target.midY)
        strip.mouseDown(with: try mouse(.leftMouseDown, at: gap, in: strip))
        XCTAssertEqual(asked, [rows[4].ref])
    }

    func testDoubleClickNeverExecutes() throws {
        let strip = makeStrip()
        let rows = makeRows(4)
        var asked: [ContentRef] = []
        var commands: [QuickAccessCommand] = []
        strip.onSelect = { asked.append($0) }
        strip.onCommand = { commands.append($0) }
        strip.show(rows, selection: rows[0].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // A double click on a neighbour, then on the clip in the middle.
        for title in ["Row 1", "Row 0"] {
            let target = try rect(titled: title, in: strip)
            let point = NSPoint(x: target.midX, y: target.midY)
            for count in 1...2 {
                strip.mouseDown(with: try mouse(.leftMouseDown, at: point, clickCount: count, in: strip))
                strip.mouseUp(with: try mouse(.leftMouseUp, at: point, clickCount: count, in: strip))
            }
        }

        XCTAssertFalse(commands.contains(.primary))
        XCTAssertEqual(commands, [])
        // The second click of a double click is one more click.
        XCTAssertEqual(asked, [rows[1].ref, rows[1].ref, rows[0].ref, rows[0].ref])
    }

    func testScrollMovesTicksAndRespectsTheSwitch() throws {
        let strip = makeStrip()
        let haptics = RecordingHaptics()
        strip.haptics = haptics
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(10)
        strip.show(rows, selection: rows[0].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // A swipe toward older clips: a clip for every 30 pt, with a tick as each reaches the middle.
        strip.scrollWheel(with: try swipe(dx: 20, phase: .began, at: 1.0))
        XCTAssertEqual(commands, [])
        XCTAssertEqual(haptics.ticks, 0)
        strip.scrollWheel(with: try swipe(dx: 20, phase: .changed, at: 1.1))
        XCTAssertEqual(commands, [.move(1)])
        XCTAssertEqual(haptics.ticks, 1)
        // The panel shows the move it accepted; a fast push passes two clips with one tick.
        strip.show(rows, selection: rows[1].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 60, phase: .changed, at: 1.2))
        XCTAssertEqual(commands, [.move(1), .move(2)])
        XCTAssertEqual(haptics.ticks, 2)
        strip.show(rows, selection: rows[3].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.3))

        // Coasting after the fingers lift moves nothing and plays nothing.
        strip.scrollWheel(with: try coast(dx: 90, at: 1.4))
        XCTAssertEqual(commands, [.move(1), .move(2)])
        XCTAssertEqual(haptics.ticks, 2)
        // A mouse wheel turned down moves one clip older a notch; its own click is the feedback.
        strip.scrollWheel(with: try wheel(dy: -1, at: 1.5))
        XCTAssertEqual(commands, [.move(1), .move(2), .move(1)])
        XCTAssertEqual(haptics.ticks, 2)

        // With the switch off a swipe moves the same, without a tick.
        strip.ticksEnabled = false
        strip.show(rows, selection: rows[4].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: -40, phase: .began, at: 2.0))
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
        strip.show(rows, selection: rows[2].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        strip.keyDown(with: try key(kVK_LeftArrow, "\u{F702}"))
        strip.show(rows, selection: rows[3].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.keyDown(with: try key(kVK_LeftArrow, "\u{F702}", isARepeat: true))
        strip.show(rows, selection: rows[4].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.keyDown(with: try key(kVK_RightArrow, "\u{F703}"))

        XCTAssertEqual(commands, [.move(1), .move(1), .move(-1)])
        XCTAssertEqual(haptics.ticks, 0)
    }

    func testTypingInTheStripRoutesToTheSearchField() throws {
        let strip = makeStrip()
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(3)
        strip.show(rows, selection: rows[0].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

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
        ]
        let details = [rows[0].ref: ClipDetail(excerpt: "Quarterly numbers draft..", characterCount: 25)]

        strip.show(rows, selection: rows[0].ref, details: details, metrics: metrics, applicationNames: names)

        XCTAssertEqual(strip.accessibilityRole(), .list)
        XCTAssertEqual(strip.accessibilityLabel(), "Clips")
        XCTAssertEqual(strip.accessibilityIdentifier(), "QuickAccessStrip")
        // One element per frame, left to right: the oldest first and the selected newest last.
        let children = try XCTUnwrap(strip.accessibilityChildren() as? [NSView])
        guard children.count == 3 else { return XCTFail("Expected an element per frame, got \(children.count)") }
        let (link, memo, selected) = (children[0], children[1], children[2])
        let time = { (row: QuickAccessRow) in QuickAccessRowContent.detail(for: row, applicationName: nil) }

        XCTAssertEqual(selected.accessibilityLabel(), "Text, from \(app), \(time(rows[0])): Quarterly numbers draft")
        XCTAssertEqual(selected.accessibilityValue() as? String, "25 characters")
        XCTAssertTrue(selected.isAccessibilitySelected())
        XCTAssertEqual(strip.accessibilitySelectedChildren() as? [NSView], [selected])
        // Without a known source app the label leaves out where it came from; the marks follow the title.
        XCTAssertEqual(memo.accessibilityLabel(),
                       "Text, \(time(rows[1])): Standup notes, Saved as Memo, Partially indexed, Text unavailable")
        XCTAssertNil(memo.accessibilityValue(), "No info line before the details arrive")
        XCTAssertFalse(memo.isAccessibilitySelected())
        XCTAssertEqual(link.accessibilityLabel(), "Link, \(time(rows[2])): Clipboard Item")
        // The text drawn in a frame is read through its label and value, not a second time.
        XCTAssertEqual(selected.accessibilityChildren()?.count ?? 0, 0)

        // Frames kept beyond the ends of the band are not read: nine are on screen.
        let many = makeRows(20)
        strip.show(many, selection: many[10].ref, details: [:], metrics: metrics, applicationNames: names)
        XCTAssertEqual(strip.accessibilityChildren()?.count, 9)
        XCTAssertEqual(drawings(in: strip).count, 13)
    }

    // MARK: Beyond the named cases

    func testTheStripFollowsTheFingersAndStretchesAtTheEnds() throws {
        let strip = makeStrip()
        strip.haptics = RecordingHaptics()
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(3)
        strip.show(rows, selection: rows[1].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Fingers a third of the way to the next older clip carry the frames a third of a step.
        strip.scrollWheel(with: try swipe(dx: 10, phase: .began, at: 1.0))
        XCTAssertEqual(try midX(of: "Row 1", in: strip), centre + metrics.step / 3, accuracy: 0.5)
        // Lifting them settles back on the selected clip.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
        XCTAssertEqual(try midX(of: "Row 1", in: strip), centre, accuracy: 0.5)
        // So does a panel that stops being key under the fingers, since their lift never reaches it.
        strip.scrollWheel(with: try swipe(dx: 10, phase: .began, at: 1.2))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: strip.window)
        XCTAssertEqual(try midX(of: "Row 1", in: strip), centre, accuracy: 0.5)

        // At the oldest clip a push stretches the end, 0.3 pt for every point pushed.
        strip.show(rows, selection: rows[2].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: 40, phase: .began, at: 2.0))
        XCTAssertEqual(try midX(of: "Row 2", in: strip), centre + 12, accuracy: 0.5)
        // Fingers resting change nothing, so the stretch holds instead of snapping back mid-gesture.
        strip.scrollWheel(with: try swipe(dx: 0, phase: .mayBegin, at: 2.05))
        XCTAssertEqual(try midX(of: "Row 2", in: strip), centre + 12, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 2.1))
        XCTAssertEqual(try midX(of: "Row 2", in: strip), centre, accuracy: 0.5)
        // At the newest clip the stretch goes the other way.
        strip.show(rows, selection: rows[0].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: -40, phase: .began, at: 2.5))
        XCTAssertEqual(try midX(of: "Row 0", in: strip), centre - 12, accuracy: 0.5)
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 2.6))
        XCTAssertEqual(commands, [])

        // With the selection gone nothing is newer than the empty middle, and every clip is older.
        strip.show(rows, selection: nil, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        strip.scrollWheel(with: try swipe(dx: -40, phase: .began, at: 3.0))
        XCTAssertEqual(try midX(of: "Row 0", in: strip), centre - metrics.step - 12, accuracy: 0.5)
        XCTAssertEqual(commands, [])
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 3.1))
        strip.scrollWheel(with: try swipe(dx: 100, phase: .began, at: 4.0))
        XCTAssertEqual(commands, [.move(3)])
    }

    func testASlideKeepsTheFramesItPassesUntilItSettles() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Frames do not slide with Reduce Motion")
        let strip = makeStrip()
        strip.haptics = RecordingHaptics()
        // Frames slide only where they can be seen.
        strip.window?.orderFront(nil)
        var reports: [[ContentRef]] = []
        strip.onVisibleRefsChanged = { refs, _ in reports.append(refs) }
        let rows = makeRows(40)
        strip.show(rows, selection: rows[20].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // The frame four steps older is selected and slides from where it was drawn to the middle.
        strip.show(rows, selection: rows[24].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        XCTAssertEqual(try midX(of: "Row 24", in: strip), centre, accuracy: 0.5)
        // The frames it passes on the newer side stay while they slide out past the end.
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((14...30).map { "Row \($0)" }))
        // Only the rows framed around the new middle are asked for their details.
        XCTAssertEqual(Set(try XCTUnwrap(reports.last)), Set(rows[18...30].map(\.ref)))
        // Once the slide has settled only the frames near the middle are left.
        let settled = Set((18...30).map { "Row \($0)" })
        try await waitUntil { Set(self.drawings(in: strip).compactMap(self.title(of:))) == settled }

        // Under the fingers the frames follow them instead of sliding, so nothing is kept.
        strip.scrollWheel(with: try swipe(dx: 10, phase: .began, at: 1.0))
        strip.show(rows, selection: rows[25].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        XCTAssertEqual(Set(drawings(in: strip).compactMap(title(of:))), Set((19...31).map { "Row \($0)" }))
        strip.scrollWheel(with: try swipe(dx: 0, phase: .ended, at: 1.1))
    }

    func testKeysFollowThePanelAndTheRestAreDroppedSilently() throws {
        let strip = makeStrip()
        let parent = try XCTUnwrap(strip.superview as? KeyRecordingView)
        var commands: [QuickAccessCommand] = []
        strip.onCommand = { commands.append($0) }
        let rows = makeRows(3)
        strip.show(rows, selection: rows[1].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())

        // Up goes to the filter row only while the panel shows it.
        strip.keyDown(with: try key(kVK_UpArrow, "\u{F700}"))
        strip.filtersVisible = true
        strip.keyDown(with: try key(kVK_UpArrow, "\u{F700}"))
        strip.keyDown(with: try key(kVK_Escape, "\u{1B}"))
        XCTAssertEqual(commands, [.focusSearchField, .focusFilters, .escape])

        // Down, Delete and shortcuts mean nothing here: no command, and not passed on to end in an alert.
        strip.keyDown(with: try key(kVK_DownArrow, "\u{F701}"))
        strip.keyDown(with: try key(kVK_Delete, "\u{7F}"))
        strip.keyDown(with: try key(kVK_ANSI_C, "c", modifiers: .command))
        XCTAssertEqual(commands, [.focusSearchField, .focusFilters, .escape])
        XCTAssertEqual(parent.keys, 0)
    }

    func testContextMenuIsForTheFrameUnderThePointer() throws {
        let strip = makeStrip()
        let rows = makeRows(4)
        let menu = NSMenu(title: "Actions")
        var asked: [ContentRef] = []
        var selected: [ContentRef] = []
        strip.onContextMenu = { asked.append($0); return menu }
        strip.onSelect = { selected.append($0) }
        strip.show(rows, selection: rows[0].ref, details: [:], metrics: metrics, applicationNames: ApplicationNames())
        let target = try rect(titled: "Row 2", in: strip)

        let shown = strip.menu(for: try mouse(.rightMouseDown, at: NSPoint(x: target.midX, y: target.midY), in: strip))

        XCTAssertTrue(shown === menu)
        XCTAssertEqual(asked, [rows[2].ref])
        XCTAssertEqual(selected, [])
        // Between two frames there is nothing to act on.
        let gap = NSPoint(x: target.maxX + metrics.gap / 2, y: target.midY)
        XCTAssertNil(strip.menu(for: try mouse(.rightMouseDown, at: gap, in: strip)))
        XCTAssertEqual(asked, [rows[2].ref])
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

    /// A strip one band wide in a window that is never shown, so frames go straight to their places.
    private func makeStrip(_ metrics: StripMetrics? = nil) -> QuickAccessStripView {
        let metrics = metrics ?? self.metrics
        let size = NSSize(width: metrics.bandWidth, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = KeyRecordingView(frame: NSRect(origin: .zero, size: size))
        let strip = QuickAccessStripView(frame: NSRect(x: 0, y: 100, width: metrics.bandWidth,
                                                       height: metrics.frameSize.height + 24))
        content.addSubview(strip)
        window.contentView = content
        addTeardownBlock { window.close() }
        return strip
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

    private func selectedTitle(in strip: NSView) -> String? {
        drawings(in: strip).first { $0.rootView.isSelected }.flatMap(title(of:))
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
