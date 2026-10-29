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

        // A status is cut short with an ellipsis rather than run into the filters.
        let toolbar = makeToolbar(width: 900)
        toolbar.note = .status("The selected item is no longer in the results")
        toolbar.setSearchExpanded(true)
        toolbar.layoutSubtreeIfNeeded()
        let status = toolbar.statusLabel
        XCTAssertFalse(status.isHidden)
        XCTAssertGreaterThanOrEqual(status.frame.minX, toolbar.filters.frame.maxX + 12)
        XCTAssertLessThan(status.frame.width, status.intrinsicContentSize.width)
        XCTAssertEqual(status.lineBreakMode, .byTruncatingTail)
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
