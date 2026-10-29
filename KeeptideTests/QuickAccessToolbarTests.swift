import AppKit
import XCTest
@testable import Keeptide

/// The band's top row on its own, in a window that is never shown: where its parts go, what gives way on a narrow
/// screen, and how the search folds.
@MainActor
final class QuickAccessToolbarTests: XCTestCase {
    func testTheRowIsLaidOutAsTheDesignHasIt() throws {
        let toolbar = makeToolbar(width: 1376)
        toolbar.note = .copy(enabled: true)
        toolbar.layoutSubtreeIfNeeded()
        let row = toolbar.rowFrame
        XCTAssertEqual(row.height, 32)

        // Folded, the search is a 32 pt circle, 12 left of the filters, and the two are centred together.
        let search = toolbar.search.frame
        let filters = toolbar.filters.frame
        XCTAssertEqual(search.size, NSSize(width: 32, height: 32))
        XCTAssertEqual(search.minY, row.minY)
        XCTAssertEqual(filters.minX - search.maxX, 12)
        XCTAssertEqual((search.minX + filters.maxX) / 2, toolbar.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(filters.midY, row.midY, accuracy: 0.5)
        // Each filter is 28 high, 6 from the next.
        let chips = toolbar.filters.chips.map { toolbar.filters.convert($0.frame, to: toolbar) }
        XCTAssertTrue(chips.allSatisfy { $0.height == 28 })
        for (left, right) in zip(chips, chips.dropFirst()) {
            XCTAssertEqual(right.minX - left.maxX, 6, accuracy: 0.5)
        }

        // At the right end, 16 in, the ⋯ button, and 12 left of it Return's hint: a key cap at least 22 × 20, 7 pt
        // before its word.
        let more = toolbar.moreButton.frame
        XCTAssertEqual(more.size, NSSize(width: 28, height: 28))
        XCTAssertEqual(toolbar.bounds.width - more.maxX, 16)
        XCTAssertEqual(more.midY, row.midY, accuracy: 0.5)
        let hint = toolbar.copyHint.frame
        XCTAssertEqual(more.minX - hint.maxX, 12)
        XCTAssertEqual(hint.midY, row.midY, accuracy: 0.5)
        XCTAssertTrue(toolbar.copyHint.showsTitle)
        let keycap = toolbar.copyHint.keycap.frame
        XCTAssertGreaterThanOrEqual(keycap.width, 22)
        XCTAssertEqual(keycap.height, 20)
        XCTAssertEqual(keycap.minX, 0)
        XCTAssertEqual(toolbar.copyHint.keycap.symbol, "⏎")

        // Open, the search is a 300 pt pill: the magnifier 11 in, the field 8 after it, and the clear button 8 from
        // the right end, 18 across.
        toolbar.setSearchExpanded(true)
        toolbar.search.hasText = true
        toolbar.layoutSubtreeIfNeeded()
        let pill = toolbar.search.frame
        XCTAssertEqual(pill.size, NSSize(width: 300, height: 32))
        XCTAssertEqual(toolbar.filters.frame.minX - pill.maxX, 12)
        XCTAssertEqual((pill.minX + toolbar.filters.frame.maxX) / 2, toolbar.bounds.midX, accuracy: 0.5)
        let magnifier = toolbar.search.magnifier.frame
        XCTAssertEqual(magnifier.minX, 11)
        XCTAssertEqual(magnifier.size, NSSize(width: 15, height: 15))
        XCTAssertEqual(toolbar.search.field.frame.minX - magnifier.maxX, 8)
        let clear = toolbar.search.clearButton.frame
        XCTAssertEqual(clear.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(pill.width - clear.maxX, 8)
        XCTAssertEqual(clear.minX - toolbar.search.field.frame.maxX, 8)
        XCTAssertFalse(toolbar.search.clearButton.isHidden)
        XCTAssertEqual(toolbar.search.field.alphaValue, 1)
        XCTAssertTrue(toolbar.search.foldButton.isHidden)
    }

    func testANarrowRowDropsTheHintsWordBeforeAnythingMeets() throws {
        // Wide enough, the hint says "⏎ Copy". Narrower, it keeps only the key cap, and narrower still it goes, while
        // the ⋯ button stays. At no width does the right end reach the filters.
        var seen: Set<String> = []
        for width in stride(from: 1376, through: 720, by: -8) {
            let toolbar = makeToolbar(width: CGFloat(width))
            toolbar.note = .copy(enabled: true)
            toolbar.setSearchExpanded(true)
            toolbar.layoutSubtreeIfNeeded()
            let hint = toolbar.copyHint
            let shown = hint.isHidden ? "none" : (hint.showsTitle ? "word" : "keycap")
            seen.insert(shown)
            if !hint.isHidden {
                XCTAssertGreaterThanOrEqual(hint.frame.minX, toolbar.filters.frame.maxX + 12, "\(width)")
                XCTAssertEqual(hint.frame.maxX, toolbar.moreButton.frame.minX - 12, "\(width)")
            }
            XCTAssertFalse(toolbar.moreButton.isHidden, "\(width)")
            XCTAssertGreaterThanOrEqual(toolbar.moreButton.frame.minX, toolbar.filters.frame.maxX, "\(width)")
        }
        XCTAssertEqual(seen, ["word", "keycap", "none"])

        // A status too long even once the search and the filters have moved as far left as they go is cut short with
        // an ellipsis rather than run into the filters, and its whole text is in its help tag.
        let toolbar = makeToolbar(width: 900)
        toolbar.note = .status("The selected item is no longer in the results")
        toolbar.setSearchExpanded(true)
        toolbar.layoutSubtreeIfNeeded()
        let status = toolbar.statusLabel
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(toolbar.search.frame.minX, 16)
        XCTAssertGreaterThanOrEqual(status.frame.minX, toolbar.filters.frame.maxX + 12)
        XCTAssertLessThan(status.frame.width, status.intrinsicContentSize.width)
        XCTAssertEqual(status.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(status.toolTip, "The selected item is no longer in the results")
    }

    func testALongNoteMovesTheSearchAsideBeforeItIsCut() throws {
        // On 1024 and 1280 pt screens the band is 960 and 1216 wide. Centred, the open search and the filters leave the
        // right end 107 and 235 pt, too little for a failure that needs 262; they move left, no nearer than 16 to the
        // row's left end, and the failure reads in full.
        let failure = "This item changed or is no longer available."
        for width in [960, 1216] as [CGFloat] {
            let toolbar = makeToolbar(width: width)
            toolbar.setSearchExpanded(true)
            toolbar.note = .failure(failure)
            toolbar.layoutSubtreeIfNeeded()
            let status = toolbar.statusLabel
            let search = toolbar.search.frame
            let filters = toolbar.filters.frame
            XCTAssertFalse(status.isHidden, "\(width)")
            XCTAssertEqual(status.stringValue, failure)
            XCTAssertFalse(isCut(status), "\(width): read in full")
            XCTAssertGreaterThanOrEqual(status.frame.minX, filters.maxX + 12, "\(width): clear of the filters")
            XCTAssertEqual(status.frame.maxX, toolbar.moreButton.frame.minX - 12, "\(width)")
            XCTAssertNil(status.toolTip, "\(width): nothing is cut, so there is no help tag")
            XCTAssertGreaterThanOrEqual(search.minX, 16, "\(width)")
            XCTAssertLessThan((search.minX + filters.maxX) / 2, toolbar.bounds.midX, "\(width): moved left")
            // They move as one, keeping their sizes and the gap between them.
            XCTAssertEqual(search.width, 300, "\(width)")
            XCTAssertEqual(filters.minX - search.maxX, 12, "\(width)")

            // With Return's hint in its place again they are centred again.
            toolbar.note = .copy(enabled: true)
            toolbar.layoutSubtreeIfNeeded()
            let centre = (toolbar.search.frame.minX + toolbar.filters.frame.maxX) / 2
            XCTAssertEqual(centre, toolbar.bounds.midX, accuracy: 0.5, "\(width)")
        }

        // A short status needs no room it does not have: the two stay centred.
        let toolbar = makeToolbar(width: 960)
        toolbar.setSearchExpanded(true)
        toolbar.note = .status("Searching…")
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual((toolbar.search.frame.minX + toolbar.filters.frame.maxX) / 2, toolbar.bounds.midX, accuracy: 0.5)
        XCTAssertFalse(isCut(toolbar.statusLabel))
    }

    func testTheRebuildNoticeTakesTheRowsLeftEnd() throws {
        // While there are clips and the index rebuilds, the row's left end says so: 16 pt in, level with the row, in a
        // status's type and colour, and at least the right end's 12 pt gap clear of the search's ring, folded or open.
        // The search and the filters stay centred, and the right end keeps Return's hint, word and all.
        for expanded in [false, true] {
            let toolbar = makeToolbar(width: 1376)
            toolbar.setSearchExpanded(expanded)
            toolbar.note = .copy(enabled: true)
            toolbar.hasClips = true
            toolbar.indexNotice = .rebuilding
            toolbar.layoutSubtreeIfNeeded()
            let notice = toolbar.indexNoticeLabel
            let halo = toolbar.search.frame.insetBy(dx: -3, dy: -3)
            let name = expanded ? "open" : "folded"
            XCTAssertFalse(notice.isHidden, name)
            XCTAssertEqual(notice.stringValue, "Index is rebuilding — results may be incomplete", name)
            XCTAssertEqual(notice.accessibilityIdentifier(), "QuickAccessIndexNotice", name)
            XCTAssertEqual(notice.frame.minX, 16, name)
            XCTAssertEqual(notice.frame.midY, toolbar.rowFrame.midY, accuracy: 0.5, name)
            XCTAssertLessThanOrEqual(notice.frame.maxX, halo.minX - 12, name)
            XCTAssertFalse(isCut(notice), "\(name): in full")
            XCTAssertNil(notice.toolTip, name)
            XCTAssertEqual(notice.font, toolbar.statusLabel.font, name)
            XCTAssertEqual(notice.textColor, ToolbarPalette.secondary, name)
            XCTAssertEqual((toolbar.search.frame.minX + toolbar.filters.frame.maxX) / 2, toolbar.bounds.midX,
                           accuracy: 0.5, name)
            XCTAssertFalse(toolbar.copyHint.isHidden, name)
            XCTAssertTrue(toolbar.copyHint.showsTitle, name)
        }
    }

    func testOnANarrowRowTheRebuildNoticeGivesWayToTheRightEnd() throws {
        // A 960 pt row, as a 1024 pt screen gives, with the search open. The right end has what it needs first, and the
        // notice keeps clear of the search and its ring whatever it says. Beside Return's hint, or a short failure that
        // moves the search a little to the left, the notice is cut short, its whole text in its help tag and read whole.
        // A failure that moves the search as far left as it goes leaves it no room, and it is not shown.
        let cases: [(note: QuickAccessToolbar.Note, shown: Bool)] = [
            (.copy(enabled: true), true), (.failure("This item has no plain text."), true),
            (.failure("This item changed or is no longer available."), false),
        ]
        for (note, shown) in cases {
            let toolbar = makeToolbar(width: 960)
            toolbar.setSearchExpanded(true)
            toolbar.hasClips = true
            toolbar.indexNotice = .rebuilding
            toolbar.note = note
            toolbar.layoutSubtreeIfNeeded()
            let notice = toolbar.indexNoticeLabel
            let status = toolbar.statusLabel
            let halo = toolbar.search.frame.insetBy(dx: -3, dy: -3)
            if case .failure = note { XCTAssertFalse(isCut(status), "\(note): read in full") }
            XCTAssertEqual(!notice.isHidden, shown, "\(note)")
            guard shown else { continue }
            XCTAssertEqual(notice.frame.minX, 16, "\(note)")
            XCTAssertLessThanOrEqual(notice.frame.maxX, halo.minX - 12, "\(note): clear of the search's ring")
            XCTAssertTrue(isCut(notice), "\(note): cut short")
            XCTAssertEqual(notice.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(notice.toolTip, "Index is rebuilding — results may be incomplete", "\(note)")
            XCTAssertEqual(notice.accessibilityValue() as? String, "Index is rebuilding — results may be incomplete",
                           "\(note): read whole")
        }
    }

    func testTheRebuildNoticeShowsOnlyOverClipsWhileTheIndexRebuilds() throws {
        // With no clips the empty state says the index is rebuilding, and an index that is ready, or one that is
        // unavailable, has nothing to say here.
        let toolbar = makeToolbar(width: 1376)
        toolbar.note = .copy(enabled: true)
        // In this order each step changes one input at a time where it can, so either alone brings the notice or takes it.
        let cases: [(hasClips: Bool, notice: IndexNotice?, shown: Bool)] = [
            (true, .rebuilding, true), (false, .rebuilding, false), (true, .rebuilding, true), (true, nil, false),
            (true, .searchUnavailable, false), (false, nil, false), (false, .rebuilding, false),
        ]
        for (hasClips, notice, shown) in cases {
            toolbar.hasClips = hasClips
            toolbar.indexNotice = notice
            toolbar.layoutSubtreeIfNeeded()
            XCTAssertEqual(!toolbar.indexNoticeLabel.isHidden, shown, "clips \(hasClips), \(String(describing: notice))")
        }
    }

    func testTheSearchFoldsInAFifthOfASecondOrAtOnceWithReduceMotion() throws {
        let toolbar = makeToolbar(width: 1376)
        toolbar.window?.orderFront(nil)
        toolbar.layoutSubtreeIfNeeded()
        toolbar.reducesMotion = { false }
        toolbar.setSearchExpanded(true)
        let layer = try XCTUnwrap(toolbar.search.layer)
        let durations = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0)?.duration }
        XCTAssertFalse(durations.isEmpty, "The pill grows out of the circle")
        XCTAssertTrue(durations.allSatisfy { abs($0 - 0.2) < 0.001 }, "\(durations)")
        XCTAssertEqual(toolbar.search.frame.width, 300, "Its frame is the open one at once")

        // With Reduce Motion the search switches at once.
        toolbar.search.layer?.removeAllAnimations()
        toolbar.reducesMotion = { true }
        toolbar.setSearchExpanded(false)
        XCTAssertEqual(toolbar.search.layer?.animationKeys() ?? [], [])
        XCTAssertEqual(toolbar.search.frame.width, 32)

        // So it does off screen, as when the panel opens again with the search open from before.
        toolbar.reducesMotion = { false }
        toolbar.window?.orderOut(nil)
        toolbar.setSearchExpanded(true)
        XCTAssertEqual(toolbar.search.layer?.animationKeys() ?? [], [])
        XCTAssertEqual(toolbar.search.frame.width, 300)
    }

    func testTheFocusHaloShowsOnAnOpenSearchThatHasTheKeys() throws {
        let toolbar = makeToolbar(width: 1376)
        toolbar.layoutSubtreeIfNeeded()
        let halo = toolbar.focusHalo

        // Folded, there is no halo even though the keys are in the field.
        toolbar.showsSearchFocus = true
        XCTAssertTrue(halo.isHidden)
        // Open with the keys, a 3 pt ring in the accent colour lies around the pill, its corners rounder by as much,
        // inside the toolbar so that nothing cuts it off.
        toolbar.setSearchExpanded(true)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(halo.isHidden)
        XCTAssertEqual(halo.frame, toolbar.search.frame.insetBy(dx: -3, dy: -3))
        XCTAssertTrue(toolbar.bounds.contains(halo.frame))
        XCTAssertEqual(halo.layer?.borderWidth, 3)
        XCTAssertEqual(halo.layer?.cornerRadius, 19)
        // Without the keys it goes, and folding takes it too.
        toolbar.showsSearchFocus = false
        XCTAssertTrue(halo.isHidden)
        toolbar.showsSearchFocus = true
        toolbar.setSearchExpanded(false)
        XCTAssertTrue(halo.isHidden)
    }

    func testTheFiltersShowWhichAreOn() {
        let toolbar = makeToolbar(width: 1376)
        let filters = toolbar.filters
        XCTAssertEqual(filters.chips.map(\.title), ["All", "Text", "Links", "Images", "Files"])
        filters.show(kinds: [])
        XCTAssertEqual(filters.chips.map(\.state), [.on, .off, .off, .off, .off])
        filters.show(kinds: [.url, .file])
        XCTAssertEqual(filters.chips.map(\.state), [.off, .off, .on, .off, .on])
        // A click leaves the keys where they are.
        XCTAssertTrue(filters.chips.allSatisfy { $0.refusesFirstResponder })
        // A chip is as wide whether on or off, so choosing one moves none of the others.
        let widths = filters.chips.map(\.intrinsicContentSize.width)
        filters.show(kinds: [.text])
        XCTAssertEqual(filters.chips.map(\.intrinsicContentSize.width), widths)
    }

    func testAFailureReadsAtFourAndAHalfToOneOnEitherBand() throws {
        let toolbar = makeToolbar(width: 1376)
        toolbar.note = .failure("This item has no plain text.")
        // The band's solid colour in each appearance, which is what the material comes down to behind 13 pt text.
        let bands: [(NSAppearance.Name, (Double, Double, Double))] = [
            (.darkAqua, (0x1E / 255, 0x1E / 255, 0x20 / 255)), (.aqua, (0xF6 / 255, 0xF6 / 255, 0xF8 / 255)),
        ]
        for (name, band) in bands {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var text: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                text = toolbar.statusLabel.textColor?.usingColorSpace(.sRGB)
            }
            let colour = try XCTUnwrap(text, name.rawValue)
            XCTAssertEqual(colour.alphaComponent, 1, name.rawValue)
            let ratio = contrastRatio((Double(colour.redComponent), Double(colour.greenComponent),
                                       Double(colour.blueComponent)), band)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name.rawValue): \(ratio)")
            // It is still a red.
            XCTAssertGreaterThan(colour.redComponent, colour.greenComponent + 0.4, name.rawValue)
        }
    }

    func testTheFoldedIconShowsTheArrowNotTheTextCursor() throws {
        let toolbar = makeToolbar(width: 1376)
        toolbar.layoutSubtreeIfNeeded()
        // The icon, above the field that lies under it, takes the cursor updates for the pointer over it, so the
        // pointer there is its arrow and not the field's text cursor.
        let icon = toolbar.search.foldButton
        XCTAssertTrue(icon.trackingAreas.contains { $0.options.contains(.cursorUpdate) && $0.options.contains(.inVisibleRect) })
        let middle = toolbar.convert(NSPoint(x: icon.bounds.midX, y: icon.bounds.midY), from: icon)
        XCTAssertTrue(toolbar.hitTest(middle) === icon, "The pointer over the folded search is over the icon")
    }

    func testTheFieldsOwnButtonsAreNotRead() throws {
        // The field's own magnifier and cancel button are never drawn; VoiceOver must not find them either. The
        // search control's clear button is the one that is read.
        let toolbar = makeToolbar(width: 1376)
        toolbar.setSearchExpanded(true)
        toolbar.search.hasText = true
        let field = toolbar.search.field
        toolbar.layoutSubtreeIfNeeded()
        // Read as VoiceOver finds it: being edited, with a query.
        let window = try XCTUnwrap(toolbar.window)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        // The field's cell is what VoiceOver reads as the text field; nothing below it is a button.
        let below = accessibilityElements(below: field)
        XCTAssertTrue(below.contains { attribute("AXRole", of: $0) as? String == NSAccessibility.Role.textField.rawValue })
        let buttons = below.filter { attribute("AXRole", of: $0) as? String == NSAccessibility.Role.button.rawValue }
        XCTAssertEqual(buttons.count, 0, buttons.map { "\(type(of: $0))" }.joined(separator: ", "))
        XCTAssertEqual(toolbar.search.clearButton.accessibilityLabel(), "Clear search")
    }

    /// Every element below `element` that an assistive app finds: the children it is given, less those AppKit
    /// ignores, as the accessibility server leaves them out. Some of AppKit's elements, such as a search field's button
    /// cells, answer only the older attribute queries, so those are what is asked.
    private func accessibilityElements(below element: NSObject) -> [NSObject] {
        let children = NSAccessibility.unignoredChildren(from: attribute("AXChildren", of: element) as? [Any] ?? [])
            .compactMap { $0 as? NSObject }
        return children.flatMap { [$0] + accessibilityElements(below: $0) }
    }

    private func attribute(_ name: String, of element: NSObject) -> Any? {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector, with: name)?.takeUnretainedValue()
    }

    /// Whether a label shows less than its whole text, as its cell tells: a cell whose text fits needs no expansion.
    private func isCut(_ label: NSTextField) -> Bool {
        label.cell?.expansionFrame(withFrame: label.bounds, in: label) != .zero
    }

    /// The WCAG 2 contrast ratio of two opaque sRGB colours.
    private func contrastRatio(_ first: (Double, Double, Double), _ second: (Double, Double, Double)) -> Double {
        func luminance(_ colour: (Double, Double, Double)) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(colour.0) + 0.7152 * linear(colour.1) + 0.0722 * linear(colour.2)
        }
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// A toolbar `width` wide, as the band holds it, in a window that is never shown.
    private func makeToolbar(width: CGFloat) -> QuickAccessToolbar {
        let toolbar = QuickAccessToolbar(field: QuickAccessSearchField())
        let size = NSSize(width: width, height: QuickAccessToolbar.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        toolbar.frame = content.bounds
        content.addSubview(toolbar)
        return toolbar
    }
}
