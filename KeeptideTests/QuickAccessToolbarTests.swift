import AppKit
import XCTest
@testable import Keeptide

/// The band's top row on its own, in a window that is never shown: where its parts go, what gives way on a narrow
/// screen, and how the search folds. From the left: the All | Snippets switch and, under Snippets, the collection chips;
/// in the middle, a notice; at the right, the filter button, the search, what Return does and the ⋯ button.
@MainActor
final class QuickAccessToolbarTests: XCTestCase {
    func testTheRowIsLaidOutAsTheDesignHasIt() throws {
        let toolbar = makeToolbar(width: 1240)
        let paste = QuickAccessToolbar.Note.action(title: "Paste into TextEdit", enabled: true, hint: nil)
        toolbar.reservedNotes = [paste]
        toolbar.note = paste
        toolbar.layoutSubtreeIfNeeded()
        let row = toolbar.rowFrame
        XCTAssertEqual(row.height, 30)

        // The list switch at the left inset, level with the row: two 24 pt segments in a 30 pt capsule.
        let segments = toolbar.lists.convert(toolbar.lists.segments.frame, to: toolbar)
        XCTAssertEqual(segments.minX, 16)
        XCTAssertEqual(segments.height, 30)
        XCTAssertEqual(segments.midY, row.midY, accuracy: 0.5)
        XCTAssertEqual(toolbar.lists.segments.buttons.map(\.title), ["All", "Snippets"])
        XCTAssertTrue(toolbar.lists.segments.buttons.allSatisfy { $0.frame.height == 24 })
        XCTAssertEqual(toolbar.lists.segments.buttons.map(\.state), [.on, .off])

        // At the right end, 16 in, the ⋯ button, and 12 left of it Return's hint: a key cap at least 20 × 18, 6 pt
        // before its word. Then, 12 apart, the folded search and the filter button, both 28 pt circles.
        let more = toolbar.moreButton.frame
        XCTAssertEqual(more.size, NSSize(width: 26, height: 26))
        XCTAssertEqual(toolbar.bounds.width - more.maxX, 16)
        XCTAssertEqual(more.midY, row.midY, accuracy: 0.5)
        let hint = toolbar.copyHint.frame
        XCTAssertEqual(more.minX - hint.maxX, 12)
        XCTAssertEqual(hint.midY, row.midY, accuracy: 0.5)
        XCTAssertTrue(toolbar.copyHint.showsTitle)
        XCTAssertEqual(hint.width, toolbar.copyHint.fullWidth)
        let keycap = toolbar.copyHint.keycap.frame
        XCTAssertGreaterThanOrEqual(keycap.width, 20)
        XCTAssertEqual(keycap.height, 18)
        XCTAssertEqual(keycap.minX, 0)
        XCTAssertEqual(toolbar.copyHint.keycap.symbol, "⏎")
        let search = toolbar.search.frame
        XCTAssertEqual(search.size, NSSize(width: 28, height: 28))
        XCTAssertEqual(search.midY, row.midY, accuracy: 0.5)
        XCTAssertEqual(hint.minX - search.maxX, 12)
        let filter = toolbar.filterButton.frame
        XCTAssertEqual(filter.size, NSSize(width: 28, height: 28))
        XCTAssertEqual(search.minX - filter.maxX, 12)
        XCTAssertEqual(filter.midY, row.midY, accuracy: 0.5)

        // Open, the search is a 300 pt pill grown to the left: it pushes the filter button and nothing else. The
        // magnifier is 11 in, the field 8 after it, and the clear button 8 from the right end, 16 across.
        toolbar.setSearchExpanded(true)
        toolbar.search.hasText = true
        toolbar.layoutSubtreeIfNeeded()
        let pill = toolbar.search.frame
        XCTAssertEqual(pill.size, NSSize(width: 300, height: 28))
        XCTAssertEqual(pill.maxX, search.maxX)
        XCTAssertEqual(pill.minX - toolbar.filterButton.frame.maxX, 12)
        XCTAssertEqual(toolbar.lists.convert(toolbar.lists.segments.frame, to: toolbar), segments)
        XCTAssertEqual(toolbar.copyHint.frame, hint)
        XCTAssertEqual(toolbar.moreButton.frame, more)
        let magnifier = toolbar.search.magnifier.frame
        XCTAssertEqual(magnifier.minX, 11)
        XCTAssertEqual(magnifier.size, NSSize(width: 14, height: 14))
        XCTAssertEqual(toolbar.search.field.frame.minX - magnifier.maxX, 8)
        let clear = toolbar.search.clearButton.frame
        XCTAssertEqual(clear.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(pill.width - clear.maxX, 8)
        XCTAssertEqual(clear.minX - toolbar.search.field.frame.maxX, 8)
        XCTAssertFalse(toolbar.search.clearButton.isHidden)
        XCTAssertEqual(toolbar.search.field.alphaValue, 1)
        XCTAssertTrue(toolbar.search.foldButton.isHidden)
    }

    func testTheSearchKeepsItsPlaceWhateverTheRightEndSays() throws {
        // The right end keeps room for the widest thing Return can do in the session and for the common statuses, so
        // that a status, typing or a save never moves the search. Beside a short "⏎ Copy" the search keeps that room.
        let copy = QuickAccessToolbar.Note.action(title: "Copy", enabled: true, hint: nil)
        let common = ["Searching…", "Saved to Snippets", "Already in Snippets", "Save undone"]
        for width in [960, 1216, 1376] as [CGFloat] {
            for expanded in [false, true] {
                let toolbar = makeToolbar(width: width)
                toolbar.reservedNotes = [copy]
                toolbar.setSearchExpanded(expanded)
                toolbar.note = copy
                toolbar.layoutSubtreeIfNeeded()
                let name = "\(width), expanded \(expanded)"
                let search = toolbar.search.frame
                XCTAssertEqual(search.maxX, toolbar.moreButton.frame.minX - 12 - toolbar.noteReserve - 12, name)
                XCTAssertGreaterThan(toolbar.copyHint.frame.minX - search.maxX, 12, "\(name): room kept beside Copy")
                for text in common {
                    toolbar.note = .status(text)
                    toolbar.layoutSubtreeIfNeeded()
                    XCTAssertEqual(toolbar.search.frame, search, "\(name), \(text)")
                    XCTAssertFalse(toolbar.statusLabel.isHidden, "\(name), \(text)")
                    XCTAssertFalse(isCut(toolbar.statusLabel), "\(name), \(text): read in full")
                    XCTAssertEqual(toolbar.statusLabel.frame.maxX, toolbar.moreButton.frame.minX - 12, "\(name), \(text)")
                    XCTAssertGreaterThanOrEqual(toolbar.statusLabel.frame.minX, search.maxX + 12, "\(name), \(text)")
                }
                toolbar.note = .none
                toolbar.layoutSubtreeIfNeeded()
                XCTAssertEqual(toolbar.search.frame, search, "\(name): with nothing said")
            }
        }
    }

    func testALongerNoteBorrowsRoomOnlyWhileTheSearchIsFolded() throws {
        // A failure longer than the room kept for the right end reads in full while the search is folded: the search
        // and the filter button make way, and go back once it goes. Open, the search stays put and the failure is cut.
        let failure = "This item changed or is no longer available."
        for width in [960, 1216, 1376] as [CGFloat] {
            let toolbar = makeToolbar(width: width)
            toolbar.lists.show(list: .snippets, collections: collections(3), unavailable: false)
            toolbar.reservedNotes = [.action(title: "Copy", enabled: true, hint: nil)]
            toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
            toolbar.layoutSubtreeIfNeeded()
            let folded = toolbar.search.frame
            let chips = chipFrames(toolbar)

            toolbar.note = .failure(failure)
            toolbar.layoutSubtreeIfNeeded()
            let status = toolbar.statusLabel
            XCTAssertFalse(isCut(status), "\(width): read in full")
            XCTAssertEqual(status.frame.maxX, toolbar.moreButton.frame.minX - 12, "\(width)")
            XCTAssertEqual(status.frame.minX - toolbar.search.frame.maxX, 12, "\(width)")
            XCTAssertLessThan(toolbar.search.frame.minX, folded.minX, "\(width): the search made way")
            XCTAssertGreaterThanOrEqual(toolbar.filterButton.frame.minX, toolbar.lists.frame.maxX + 12, "\(width)")
            XCTAssertEqual(chipFrames(toolbar), chips, "\(width): the chips stay")

            toolbar.setSearchExpanded(true)
            toolbar.layoutSubtreeIfNeeded()
            let open = toolbar.search.frame
            XCTAssertEqual(open.maxX, folded.maxX, "\(width): open, the search keeps its place")
            XCTAssertTrue(isCut(status), "\(width): cut short")
            XCTAssertEqual(status.toolTip, failure, "\(width)")
            XCTAssertEqual(status.accessibilityValue(), failure, "\(width): read whole")

            toolbar.setSearchExpanded(false)
            toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
            toolbar.layoutSubtreeIfNeeded()
            XCTAssertEqual(toolbar.search.frame, folded, "\(width): back in its place")
        }
    }

    func testANarrowRowPutsCollectionsInMoreBeforeTheHintGivesWay() throws {
        // Twelve collections under Snippets, with the search open. As the row narrows, collections go into More first;
        // only once none is left beside it does Return's hint give way: its word is cut, then only the key cap is left,
        // and last it goes. At no width does anything at the right end reach the lists.
        let title = "Paste into TextEdit"
        var seen: [String] = []
        for width in stride(from: 1664, through: 700, by: -8) {
            let toolbar = makeToolbar(width: CGFloat(width))
            toolbar.lists.show(list: .snippets, collections: collections(12), unavailable: false)
            toolbar.reservedNotes = [.action(title: title, enabled: true, hint: nil)]
            toolbar.note = .action(title: title, enabled: true, hint: nil)
            toolbar.filterButton.show(favoritesOnly: true, kinds: [.text])
            toolbar.setSearchExpanded(true)
            toolbar.layoutSubtreeIfNeeded()
            let hint = toolbar.copyHint
            let shown = hint.isHidden ? "none"
                : (!hint.showsTitle ? "keycap" : (hint.frame.width < hint.fullWidth ? "cut word" : "word"))
            let chips = toolbar.lists.visibleChipCount
            if shown != "word" { XCTAssertEqual(chips, 0, "\(width): collections give way before the hint") }
            // More, as wide as it gets, stays until the hint has gone.
            if shown != "none" { XCTAssertFalse(toolbar.lists.moreChip.isHidden, "\(width): More stays while the hint does") }
            let state = chips > 0 ? "chips, \(shown)" : "more, \(shown)"
            if seen.last != state { seen.append(state) }
            XCTAssertGreaterThanOrEqual(toolbar.filterButton.frame.minX, toolbar.lists.frame.maxX + 12, "\(width)")
            XCTAssertFalse(toolbar.moreButton.isHidden, "\(width)")
            if !hint.isHidden {
                XCTAssertEqual(hint.frame.maxX, toolbar.moreButton.frame.minX - 12, "\(width)")
                XCTAssertGreaterThanOrEqual(hint.frame.minX, toolbar.search.frame.maxX + 12, "\(width)")
            }
        }
        XCTAssertEqual(seen, ["chips, word", "more, word", "more, cut word", "more, keycap", "more, none"])
    }

    func testALongPrimaryTitleIsCutBeforeTheKeycapGoes() throws {
        // "Paste into " and a 30-character app name. The word is cut at its tail, whole in its help tag and for
        // VoiceOver, before only the key cap is left, and that goes last. The search never reaches the lists.
        let title = "Paste into Synthetic Application Named Xy"
        XCTAssertEqual(title.count, "Paste into ".count + 30)
        var seen: [String] = []
        for width in stride(from: 1376, through: 600, by: -4) {
            let toolbar = makeToolbar(width: CGFloat(width))
            toolbar.reservedNotes = [.action(title: title, enabled: true, hint: nil)]
            toolbar.setSearchExpanded(true)
            toolbar.note = .action(title: title, enabled: true, hint: nil)
            toolbar.layoutSubtreeIfNeeded()
            let action = toolbar.copyHint
            let shown = action.isHidden ? "none"
                : (!action.showsTitle ? "keycap" : (action.frame.width < action.fullWidth ? "cut word" : "word"))
            if seen.last != shown { seen.append(shown) }
            XCTAssertGreaterThanOrEqual(toolbar.filterButton.frame.minX, toolbar.lists.frame.maxX + 12, "\(width)")
            guard !action.isHidden else { continue }
            XCTAssertEqual(action.frame.maxX, toolbar.moreButton.frame.minX - 12, "\(width)")
            XCTAssertGreaterThanOrEqual(action.frame.minX, toolbar.search.frame.maxX + 12, "\(width)")
            XCTAssertEqual(action.accessibilityLabel(), title, "\(width)")
            if action.frame.width < action.fullWidth { XCTAssertEqual(action.toolTip, title, "\(width)") }
            if action.showsTitle, action.frame.width < action.fullWidth {
                // A word cut shorter than a status may be says nothing, so the key cap is left alone first.
                XCTAssertGreaterThanOrEqual(action.frame.width - action.compactWidth - QuickAccessCopyHint.spacing, 24,
                                            "\(width)")
            }
        }
        XCTAssertEqual(seen, ["word", "cut word", "keycap", "none"])
    }

    func testTheReasonHintGivesWayBeforeThePrimaryAction() throws {
        // A terminal's command, copied because secure input is on, says why left of "⏎ Copy Command". As the row
        // narrows, the reason is cut and then goes before the command's word is cut, and the word before the key cap.
        let reason = "Secure input is on"
        var seen: [String] = []
        for width in stride(from: 1376, through: 640, by: -4) {
            let toolbar = makeToolbar(width: CGFloat(width))
            let note = QuickAccessToolbar.Note.action(title: "Copy Command", enabled: true, hint: reason)
            toolbar.reservedNotes = [note]
            toolbar.setSearchExpanded(true)
            toolbar.note = note
            toolbar.layoutSubtreeIfNeeded()
            let hint = toolbar.directPasteHint
            let action = toolbar.copyHint
            let hintShown = hint.isHidden ? "none" : (isCut(hint) ? "cut" : "full")
            let actionShown = action.isHidden ? "none"
                : (!action.showsTitle ? "keycap" : (action.frame.width < action.fullWidth ? "cut" : "full"))
            let state = "reason \(hintShown), action \(actionShown)"
            if seen.last != state { seen.append(state) }
            guard !hint.isHidden else { continue }
            XCTAssertEqual(actionShown, "full", "\(width): the reason gives way first")
            XCTAssertEqual(hint.accessibilityIdentifier(), "QuickAccessDirectPasteHint")
            XCTAssertEqual(hint.accessibilityValue(), reason, "\(width): read whole")
            XCTAssertEqual(hint.toolTip, hintShown == "cut" ? reason : nil, "\(width)")
            XCTAssertEqual(hint.textColor, ToolbarPalette.secondary)
            XCTAssertEqual(hint.lineBreakMode, .byTruncatingTail)
            XCTAssertGreaterThanOrEqual(hint.frame.width, 24, "\(width)")
            XCTAssertEqual(hint.frame.maxX, action.frame.minX - 12, "\(width)")
            XCTAssertGreaterThanOrEqual(hint.frame.minX, toolbar.search.frame.maxX + 12, "\(width)")
            XCTAssertEqual(hint.frame.midY, toolbar.rowFrame.midY, accuracy: 0.5, "\(width)")
        }
        XCTAssertEqual(seen, ["reason full, action full", "reason cut, action full", "reason none, action full",
                              "reason none, action cut", "reason none, action keycap", "reason none, action none"])

        // On a 960 pt row both the action and its reason read whole; without a reason nothing shows there.
        let toolbar = makeToolbar(width: 960)
        let note = QuickAccessToolbar.Note.action(title: "Copy Command", enabled: true, hint: reason)
        toolbar.reservedNotes = [note]
        toolbar.setSearchExpanded(true)
        toolbar.note = note
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(toolbar.directPasteHint.isHidden)
        XCTAssertFalse(isCut(toolbar.directPasteHint))
        XCTAssertEqual(toolbar.copyHint.frame.width, toolbar.copyHint.fullWidth)
        toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertTrue(toolbar.directPasteHint.isHidden)
    }

    func testTheRebuildNoticeTakesTheRoomBetweenTheListsAndTheFilterButton() throws {
        // While there are clips and the index rebuilds, its notice follows the lists by 12 pt, level with the row, in a
        // status's type and colour, and ends 12 pt before the filter button. The right end keeps Return's hint.
        for list in [QuickAccessList.all, .snippets] {
            for expanded in [false, true] {
                let toolbar = makeToolbar(width: 1376)
                toolbar.lists.show(list: list, collections: collections(2), unavailable: false)
                toolbar.setSearchExpanded(expanded)
                toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
                toolbar.hasClips = true
                toolbar.indexNotice = .rebuilding
                toolbar.layoutSubtreeIfNeeded()
                let notice = toolbar.indexNoticeLabel
                let name = "\(list), \(expanded ? "open" : "folded")"
                XCTAssertFalse(notice.isHidden, name)
                XCTAssertEqual(notice.stringValue, "Index is rebuilding — results may be incomplete", name)
                XCTAssertEqual(notice.accessibilityIdentifier(), "QuickAccessIndexNotice", name)
                XCTAssertEqual(notice.frame.minX, toolbar.lists.frame.maxX + 12, name)
                XCTAssertEqual(notice.frame.midY, toolbar.rowFrame.midY, accuracy: 0.5, name)
                XCTAssertLessThanOrEqual(notice.frame.maxX, toolbar.filterButton.frame.minX - 12, name)
                XCTAssertFalse(isCut(notice), "\(name): in full")
                XCTAssertNil(notice.toolTip, name)
                XCTAssertEqual(notice.font, toolbar.statusLabel.font, name)
                XCTAssertEqual(notice.textColor, ToolbarPalette.secondary, name)
                XCTAssertFalse(toolbar.copyHint.isHidden, name)
                XCTAssertTrue(toolbar.copyHint.showsTitle, name)
            }
        }
    }

    func testOnANarrowRowTheRebuildNoticeGivesWayToTheRightEnd() throws {
        // A 960 pt row, as a 1024 pt screen gives, with the search open and collections beside the switch: the notice
        // takes the gap that is left, cut short with its whole text in its help tag and read whole.
        let toolbar = makeToolbar(width: 960)
        toolbar.lists.show(list: .snippets, collections: collections(2), unavailable: false)
        toolbar.setSearchExpanded(true)
        toolbar.hasClips = true
        toolbar.indexNotice = .rebuilding
        toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
        toolbar.layoutSubtreeIfNeeded()
        let notice = toolbar.indexNoticeLabel
        if !notice.isHidden {
            XCTAssertEqual(notice.frame.minX, toolbar.lists.frame.maxX + 12)
            XCTAssertLessThanOrEqual(notice.frame.maxX, toolbar.filterButton.frame.minX - 12)
            XCTAssertTrue(isCut(notice), "cut short")
            XCTAssertEqual(notice.lineBreakMode, .byTruncatingTail)
            XCTAssertEqual(notice.toolTip, "Index is rebuilding — results may be incomplete")
            XCTAssertEqual(notice.accessibilityValue(), "Index is rebuilding — results may be incomplete", "read whole")
        }
        // With no room left at all, it is not shown rather than squeezed.
        toolbar.lists.show(list: .snippets, collections: collections(12), unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        if !notice.isHidden { XCTAssertGreaterThanOrEqual(notice.frame.width, 24) }
    }

    func testTheRebuildNoticeShowsOnlyOverClipsWhileTheIndexRebuilds() throws {
        // With no clips the empty state says the index is rebuilding, and an index that is ready, or one that is
        // unavailable, has nothing to say here.
        let toolbar = makeToolbar(width: 1376)
        toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
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

    func testTheNoticeEndsBeforeTheFilterButtonAsTheSearchUnfolds() throws {
        let toolbar = makeToolbar(width: 1376)
        toolbar.hasClips = true
        toolbar.indexNotice = .rebuilding
        toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
        toolbar.window?.contentView?.wantsLayer = true
        toolbar.window?.orderFront(nil)
        toolbar.layoutSubtreeIfNeeded()
        toolbar.window?.contentView?.layer?.speed = 0
        toolbar.reducesMotion = { false }
        XCTAssertFalse(toolbar.indexNoticeLabel.isHidden)
        let start = toolbar.indexNoticeLabel.frame.minX
        toolbar.setSearchExpanded(true)
        CATransaction.flush()
        // The filter button moves over in a fifth of a second, and the notice keeps its start.
        let layer = try XCTUnwrap(toolbar.filterButton.layer)
        let animation = try XCTUnwrap(layer.animation(forKey: "fold position") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, 0.2, accuracy: 0.001)
        XCTAssertEqual(toolbar.indexNoticeLabel.frame.minX, start)
        XCTAssertLessThanOrEqual(toolbar.indexNoticeLabel.frame.maxX, toolbar.filterButton.frame.minX - 12)

        layer.removeAllAnimations()
        toolbar.reducesMotion = { true }
        toolbar.setSearchExpanded(false)
        XCTAssertEqual(layer.animationKeys() ?? [], [])
        XCTAssertLessThanOrEqual(toolbar.indexNoticeLabel.frame.maxX, toolbar.filterButton.frame.minX - 12)
        toolbar.window?.orderOut(nil)
    }

    /// Why new copies are not kept while the disk is full.
    private let full = "Storage is full. Free some space to keep new copies."

    func testTheCaptureNoticeTakesTheNoticesPlaceWithOrWithoutClips() throws {
        // While new copies are not kept, the row says why where the rebuild notice goes, folded or open. It shows over
        // clips and without them, and while the index rebuilds it takes that notice's place.
        for expanded in [false, true] {
            for hasClips in [false, true] {
                let toolbar = makeToolbar(width: 1376)
                toolbar.setSearchExpanded(expanded)
                toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
                toolbar.hasClips = hasClips
                toolbar.indexNotice = .rebuilding
                toolbar.captureNotice = full
                toolbar.layoutSubtreeIfNeeded()
                let notice = toolbar.captureNoticeLabel
                let name = "\(expanded ? "open" : "folded"), clips: \(hasClips)"
                XCTAssertFalse(notice.isHidden, name)
                XCTAssertEqual(notice.stringValue, full, name)
                XCTAssertEqual(notice.accessibilityIdentifier(), "QuickAccessCaptureNotice", name)
                XCTAssertEqual(notice.frame.minX, toolbar.lists.frame.maxX + 12, name)
                XCTAssertEqual(notice.frame.midY, toolbar.rowFrame.midY, accuracy: 0.5, name)
                XCTAssertLessThanOrEqual(notice.frame.maxX, toolbar.filterButton.frame.minX - 12, name)
                XCTAssertFalse(isCut(notice), "\(name): in full")
                XCTAssertTrue(toolbar.indexNoticeLabel.isHidden, "\(name): in place of the rebuild notice")
                XCTAssertFalse(toolbar.copyHint.isHidden, name)
            }
        }
    }

    func testOnceNewCopiesAreKeptAgainTheRowSaysNothingAboutThem() throws {
        // Kept again, the notice goes, and the rebuild notice, if any, is back in its place.
        let toolbar = makeToolbar(width: 1376)
        toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
        toolbar.hasClips = true
        toolbar.indexNotice = .rebuilding
        toolbar.captureNotice = full
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(toolbar.captureNoticeLabel.isHidden)
        XCTAssertTrue(toolbar.indexNoticeLabel.isHidden)

        toolbar.captureNotice = nil
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertTrue(toolbar.captureNoticeLabel.isHidden)
        XCTAssertFalse(toolbar.indexNoticeLabel.isHidden)

        toolbar.indexNotice = nil
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertTrue(toolbar.captureNoticeLabel.isHidden)
        XCTAssertTrue(toolbar.indexNoticeLabel.isHidden)
    }

    func testOnANarrowRowWhyNewCopiesAreNotKeptIsCutShortAndReadWhole() throws {
        let reason = "Clipboard access is denied. Allow Keeptide in System Settings to keep new copies."
        let toolbar = makeToolbar(width: 960)
        toolbar.setSearchExpanded(true)
        toolbar.note = .action(title: "Copy", enabled: true, hint: nil)
        toolbar.captureNotice = reason
        toolbar.layoutSubtreeIfNeeded()
        let notice = toolbar.captureNoticeLabel
        XCTAssertFalse(notice.isHidden)
        XCTAssertEqual(notice.frame.minX, toolbar.lists.frame.maxX + 12)
        XCTAssertLessThanOrEqual(notice.frame.maxX, toolbar.filterButton.frame.minX - 12)
        XCTAssertTrue(isCut(notice), "Cut short")
        XCTAssertEqual(notice.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(notice.toolTip, reason)
        XCTAssertEqual(notice.accessibilityValue(), reason, "Read whole")
        XCTAssertFalse(toolbar.copyHint.isHidden)

        // With room for it all, nothing is cut and there is no help tag.
        toolbar.captureNotice = "Test session removed"
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(isCut(notice))
        XCTAssertNil(notice.toolTip)
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
        XCTAssertEqual(toolbar.search.frame.width, 28)

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
        XCTAssertEqual(halo.layer?.cornerRadius, 17)
        // Without the keys it goes, and folding takes it too.
        toolbar.showsSearchFocus = false
        XCTAssertTrue(halo.isHidden)
        toolbar.showsSearchFocus = true
        toolbar.setSearchExpanded(false)
        XCTAssertTrue(halo.isHidden)
    }

    func testTheFilterButtonShowsWhichFiltersAreOn() throws {
        let toolbar = makeToolbar(width: 1376)
        let button = toolbar.filterButton
        // With no filter, a 28 pt circle that says "Filter" to the pointer and to VoiceOver.
        button.show(favoritesOnly: false, kinds: [])
        XCTAssertNil(button.title)
        XCTAssertEqual(button.intrinsicContentSize, NSSize(width: 28, height: 28))
        // The face, a real button, is what VoiceOver reads and what is clicked; the view around it takes Tab.
        XCTAssertFalse(button.isAccessibilityElement())
        XCTAssertTrue(button.face.isAccessibilityEnabled())
        // The groups are views, not controls: they say they are enabled, or VoiceOver would call them dimmed.
        XCTAssertTrue(toolbar.lists.segments.isAccessibilityEnabled())
        XCTAssertTrue(toolbar.lists.chipsView.isAccessibilityEnabled())
        XCTAssertEqual(button.face.accessibilityRole(), .popUpButton)
        XCTAssertEqual(button.face.accessibilityLabel(), "Filter")
        XCTAssertEqual(button.face.accessibilityIdentifier(), "QuickAccessFilterButton")
        XCTAssertEqual(button.face.accessibilityValue() as? String, "None")
        XCTAssertEqual(button.face.toolTip, "Filter")
        // With filters on, a 28 pt high capsule that names them: one by its name, more by their number.
        let cases: [(favorites: Bool, kinds: Set<ContentKind>, title: String, value: String)] = [
            (true, [], "Favorites", "Favorites"),
            (false, [.image], "Images", "Images"),
            (false, [.url, .file], "2 Filters", "Links, Files"),
            (true, [.text, .url], "3 Filters", "Favorites, Text, Links"),
        ]
        for item in cases {
            button.show(favoritesOnly: item.favorites, kinds: item.kinds)
            XCTAssertEqual(button.title, item.title)
            XCTAssertEqual(button.intrinsicContentSize.height, 28, item.title)
            XCTAssertGreaterThan(button.intrinsicContentSize.width, 28, item.title)
            XCTAssertLessThanOrEqual(button.intrinsicContentSize.width, button.maximumWidth, item.title)
            XCTAssertEqual(button.face.accessibilityValue() as? String, item.value)
            XCTAssertEqual(button.face.accessibilityHelp(), item.value)
            XCTAssertEqual(button.face.toolTip, item.value)
        }
        // A click opens the menu and leaves the keys where they are; so do VoiceOver's press and Show Menu.
        XCTAssertTrue(button.face.refusesFirstResponder)
        var opened = 0
        button.onOpen = { opened += 1 }
        button.face.performClick(nil)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(button.face.accessibilityPerformPress())
        XCTAssertEqual(opened, 2)
        XCTAssertTrue(button.face.accessibilityPerformShowMenu())
        XCTAssertEqual(opened, 3)
        // With the keys on the button, as Tab leaves them, VoiceOver's focus is on the face.
        XCTAssertTrue(try XCTUnwrap(button.window).makeFirstResponder(button))
        XCTAssertTrue(button.accessibilityFocusedUIElement as AnyObject === button.face)
    }

    func testTheRowFollowsAChangeOfListOrFilterOnItsOwn() throws {
        // Nothing else in the row changes: the toolbar lays itself out again because the lists and the filter button
        // asked, and the chips land inside the lists, where they take clicks.
        let toolbar = makeToolbar(width: 1376)
        toolbar.layoutSubtreeIfNeeded()
        let lists = toolbar.lists
        XCTAssertEqual(lists.frame.width, lists.segmentsWidth)
        lists.show(list: .snippets, collections: collections(3), unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(lists.visibleChipCount, 3)
        XCTAssertEqual(lists.frame.width, lists.contentWidth)
        XCTAssertGreaterThan(lists.frame.width, lists.segmentsWidth)
        for chip in lists.chips {
            XCTAssertTrue(lists.chipsView.bounds.contains(chip.frame), chip.title)
            // A hit test takes a point in the view's superview, the toolbar.
            let centre = toolbar.convert(NSPoint(x: chip.frame.midX, y: chip.frame.midY), from: lists.chipsView)
            XCTAssertTrue(lists.hitTest(centre) === chip, chip.title)
        }
        toolbar.filterButton.show(favoritesOnly: true, kinds: [])
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.filterButton.frame.width, toolbar.filterButton.intrinsicContentSize.width)
        XCTAssertGreaterThan(toolbar.filterButton.frame.width, 28)
        XCTAssertEqual(toolbar.filterButton.frame.maxX + 12, toolbar.search.frame.minX)
    }

    func testTheChosenSegmentClickedAgainStaysChosen() throws {
        let toolbar = makeToolbar(width: 1376)
        let lists = toolbar.lists
        lists.show(list: .snippets, collections: collections(2), unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        var chosen: [QuickAccessListStop] = []
        lists.onChoose = { chosen.append($0) }
        lists.segments.buttons[1].performClick(nil)
        XCTAssertEqual(chosen, [.snippets])
        XCTAssertEqual(lists.segments.buttons.map(\.state), [.off, .on])
        XCTAssertEqual(lists.segments.buttons[1].accessibilityValue() as? NSNumber, 1)
        lists.show(list: .all, collections: collections(2), unavailable: false)
        lists.segments.buttons[0].performClick(nil)
        XCTAssertEqual(lists.segments.buttons.map(\.state), [.on, .off])
    }

    func testVoiceOverFollowsTheListCursor() throws {
        let toolbar = makeToolbar(width: 1376)
        let lists = toolbar.lists
        let made = collections(2)
        lists.show(list: .snippets, collections: made, unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        // Without the keys, the row is what VoiceOver has in focus; with them, the segment or chip under the cursor.
        XCTAssertFalse(lists.accessibilityFocusedUIElement as AnyObject === lists.segments.buttons[1])
        XCTAssertTrue(try XCTUnwrap(lists.window).makeFirstResponder(lists))
        XCTAssertTrue(lists.accessibilityFocusedUIElement as AnyObject === lists.segments.buttons[1])
        lists.moveCursor(by: 1)
        XCTAssertTrue(lists.accessibilityFocusedUIElement as AnyObject === lists.chips[0])
        XCTAssertEqual(lists.chips[0].accessibilityLabel(), made[0].name)
    }

    func testChipsAppearOnlyUnderSnippets() throws {
        let toolbar = makeToolbar(width: 1376)
        let lists = toolbar.lists
        let two = collections(2)
        // Under All there are no chips: only the switch.
        lists.show(list: .all, collections: two, unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertTrue(lists.chipsView.isHidden)
        XCTAssertEqual(lists.stops, [.all, .snippets])
        XCTAssertEqual(lists.segments.buttons.map(\.state), [.on, .off])
        XCTAssertEqual(lists.frame.width, lists.segments.frame.width)

        // Under Snippets, the collections in order, 12 pt after the switch, 24 pt high, 6 apart, each a dot and a name.
        lists.show(list: .snippets, collections: two, unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(lists.chipsView.isHidden)
        XCTAssertEqual(lists.segments.buttons.map(\.state), [.off, .on])
        XCTAssertEqual(lists.chips.map(\.title), two.map(\.name))
        XCTAssertEqual(lists.stops, [.all, .snippets] + two.map { .collection($0.id) })
        let frames = chipFrames(toolbar)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].minX - toolbar.lists.convert(lists.segments.frame, to: toolbar).maxX, 12)
        XCTAssertTrue(frames.allSatisfy { $0.height == 24 })
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 6, accuracy: 0.5)
        XCTAssertTrue(lists.chips.allSatisfy { $0.state == .off })
        XCTAssertTrue(lists.moreChip.isHidden)

        // A collection's list keeps the Snippets segment and marks its chip; the chip is as wide either way.
        let width = lists.chips[0].intrinsicContentSize.width
        lists.show(list: .collection(two[0].id), collections: two, unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(lists.segments.buttons.map(\.state), [.off, .on])
        XCTAssertEqual(lists.chips.map(\.state), [.on, .off])
        XCTAssertEqual(lists.chips[0].intrinsicContentSize.width, width)
        XCTAssertEqual(chipFrames(toolbar), frames)

        // VoiceOver hears two groups of choices: the lists, and the collections.
        XCTAssertEqual(lists.segments.accessibilityRole(), .radioGroup)
        XCTAssertEqual(lists.segments.accessibilityLabel(), "List")
        XCTAssertTrue(lists.segments.buttons.allSatisfy { $0.accessibilityRole() == .radioButton })
        XCTAssertEqual(lists.chipsView.accessibilityRole(), .radioGroup)
        XCTAssertEqual(lists.chipsView.accessibilityLabel(), "Collections")
        XCTAssertTrue(lists.chips.allSatisfy { $0.accessibilityRole() == .radioButton })
        // A click leaves the keys where they are.
        XCTAssertTrue((lists.segments.buttons + lists.chips).allSatisfy { $0.refusesFirstResponder })
    }

    func testChipsNeverReflowWhileTyping() throws {
        // The chips are fitted to the row as if the search were open, the filter button at its widest and the right end
        // full, so typing, a filter or anything the right end says leaves them where they are.
        let toolbar = makeToolbar(width: 1216)
        toolbar.lists.show(list: .snippets, collections: collections(8), unavailable: false)
        toolbar.reservedNotes = [.action(title: "Paste into TextEdit", enabled: true, hint: nil)]
        toolbar.note = .action(title: "Paste into TextEdit", enabled: true, hint: nil)
        toolbar.layoutSubtreeIfNeeded()
        let frames = chipFrames(toolbar)
        let count = toolbar.lists.visibleChipCount
        XCTAssertGreaterThan(count, 0)
        let changes: [(String, () -> Void)] = [
            ("search open", { toolbar.setSearchExpanded(true) }),
            ("a query", { toolbar.search.hasText = true }),
            ("Searching…", { toolbar.note = .status("Searching…") }),
            ("a failure", { toolbar.note = .failure("This item changed or is no longer available.") }),
            ("favorites", { toolbar.filterButton.show(favoritesOnly: true, kinds: []) }),
            ("three filters", { toolbar.filterButton.show(favoritesOnly: true, kinds: [.text, .image]) }),
            ("the rebuild notice", { toolbar.hasClips = true; toolbar.indexNotice = .rebuilding }),
            ("the capture notice", { toolbar.captureNotice = self.full }),
            ("search folded", { toolbar.setSearchExpanded(false) }),
        ]
        for (name, change) in changes {
            change()
            toolbar.needsLayout = true
            toolbar.layoutSubtreeIfNeeded()
            XCTAssertEqual(toolbar.lists.visibleChipCount, count, name)
            XCTAssertEqual(chipFrames(toolbar), frames, name)
            XCTAssertGreaterThanOrEqual(toolbar.filterButton.frame.minX, toolbar.lists.frame.maxX + 12, name)
        }
    }

    func testTheChipsKeepClearOfTheRightEndOnTheThreeScreenWidths() throws {
        // Screens 1280, 1470 and 1728 pt wide hold bands 64 pt narrower. With no collections, three or twelve, one of
        // them named longer than a chip shows, the search folded or open, filters off or on, and a long app name in
        // Return's hint: no chip reaches the filter button, the filter button keeps clear of the search, collections
        // that do not fit are behind More, and a hidden one chosen shows in More without moving a chip. Under All the
        // row holds the switch and the right end only.
        let title = "Paste into Synthetic Application Named Xy"
        let longName = "一个名字特别特别长的中文分类用来检查截断"
        for width in [1216, 1406, 1664] as [CGFloat] {
            for count in [0, 3, 12] {
                var made = collections(count)
                if count > 0 { made[1] = CollectionSummary(id: CollectionID(), name: longName, color: "green", sortOrder: 1) }
                for expanded in [false, true] {
                    for filtered in [false, true] {
                        let label = "\(width) pt, \(count) collections, search \(expanded ? "open" : "folded"), "
                            + "filters \(filtered ? "on" : "off")"
                        let toolbar = makeToolbar(width: width)
                        let lists = toolbar.lists
                        lists.show(list: .snippets, collections: made, unavailable: false)
                        toolbar.reservedNotes = [.action(title: title, enabled: true, hint: nil)]
                        toolbar.note = .action(title: title, enabled: true, hint: nil)
                        toolbar.filterButton.show(favoritesOnly: filtered, kinds: filtered ? [.text, .image] : [])
                        toolbar.setSearchExpanded(expanded)
                        toolbar.layoutSubtreeIfNeeded()
                        let chips = chipFrames(toolbar)
                        XCTAssertEqual(chips.isEmpty, count == 0, label)
                        for chip in chips {
                            XCTAssertLessThanOrEqual(chip.maxX + 12, toolbar.filterButton.frame.minX, label)
                            XCTAssertLessThanOrEqual(chip.width, 195, label)
                        }
                        XCTAssertLessThanOrEqual(toolbar.filterButton.frame.maxX + 12, toolbar.search.frame.minX, label)
                        if !toolbar.copyHint.isHidden {
                            XCTAssertGreaterThanOrEqual(toolbar.copyHint.frame.minX, toolbar.search.frame.maxX + 12, label)
                            XCTAssertEqual(toolbar.copyHint.frame.maxX, toolbar.moreButton.frame.minX - 12, label)
                        }
                        if lists.visibleChipCount < count {
                            XCTAssertFalse(lists.moreChip.isHidden, label)
                            XCTAssertEqual(lists.stops.last, .more, label)
                        }
                        guard count == 12, lists.visibleChipCount < count else { continue }
                        let others = Array(chips.dropLast())
                        let moreStart = try XCTUnwrap(chips.last).minX
                        lists.show(list: .collection(made[11].id), collections: made, unavailable: false)
                        toolbar.layoutSubtreeIfNeeded()
                        let after = chipFrames(toolbar)
                        XCTAssertEqual(lists.moreChip.title, made[11].name, label)
                        XCTAssertEqual(Array(after.dropLast()), others, label)
                        XCTAssertEqual(try XCTUnwrap(after.last).minX, moreStart, label)
                        XCTAssertLessThanOrEqual(try XCTUnwrap(after.last).maxX + 12, toolbar.filterButton.frame.minX,
                                                 label)
                    }
                }
                let toolbar = makeToolbar(width: width)
                toolbar.lists.show(list: .all, collections: made, unavailable: false)
                toolbar.layoutSubtreeIfNeeded()
                XCTAssertTrue(toolbar.lists.chipsView.isHidden, "\(width) pt, \(count) collections under All")
                XCTAssertEqual(toolbar.lists.frame.width, toolbar.lists.segmentsWidth, "\(width) pt under All")
            }
        }
    }

    func testAHiddenChosenCollectionShowsInTheOverflow() throws {
        let toolbar = makeToolbar(width: 1216)
        let lists = toolbar.lists
        let many = collections(12)
        lists.show(list: .snippets, collections: many, unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        let count = lists.visibleChipCount
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, many.count)
        XCTAssertFalse(lists.moreChip.isHidden)
        XCTAssertEqual(lists.moreChip.title, "More")
        XCTAssertEqual(lists.moreChip.accessibilityRole(), .popUpButton)
        XCTAssertEqual(lists.moreChip.accessibilityLabel(), "More Collections")
        XCTAssertEqual(lists.moreChip.accessibilityValue() as? String, "")
        XCTAssertEqual(lists.hiddenCollections.map(\.id), many.dropFirst(count).map(\.id))
        XCTAssertEqual(lists.stops.last, .more)
        let frames = chipFrames(toolbar)

        // Choosing a collection that does not fit shows it in More's place, chosen, and moves no other chip.
        let hidden = many[many.count - 1]
        lists.show(list: .collection(hidden.id), collections: many, unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertEqual(lists.visibleChipCount, count)
        XCTAssertEqual(lists.moreChip.title, hidden.name)
        XCTAssertEqual(lists.moreChip.state, .on)
        XCTAssertEqual(lists.moreChip.accessibilityValue() as? String, hidden.name)
        XCTAssertTrue(lists.chips.prefix(count).allSatisfy { $0.state == .off })
        // More grows to the right to show the name, within the room it kept.
        let after = chipFrames(toolbar)
        XCTAssertEqual(Array(after.dropLast()), Array(frames.dropLast()))
        XCTAssertEqual(after.last?.minX, frames.last?.minX)
        XCTAssertGreaterThan(try XCTUnwrap(after.last).width, try XCTUnwrap(frames.last).width)
        XCTAssertGreaterThanOrEqual(toolbar.filterButton.frame.minX, lists.frame.maxX + 12)
    }

    func testCollectionsThatCannotBeReadShowOneDisabledChip() throws {
        let toolbar = makeToolbar(width: 1376)
        let lists = toolbar.lists
        lists.show(list: .snippets, collections: [], unavailable: true)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(lists.unavailableChip.isHidden)
        XCTAssertFalse(lists.unavailableChip.isEnabled)
        XCTAssertEqual(lists.unavailableChip.title, "Collections unavailable")
        XCTAssertEqual(lists.unavailableChip.accessibilityRole(), .staticText)
        XCTAssertEqual(lists.unavailableChip.accessibilityValue() as? String, "Collections unavailable")
        XCTAssertEqual(lists.unavailableChip.toolTip, "Close and reopen quick access to try again.")
        XCTAssertEqual(lists.stops, [.all, .snippets])
        // Under All it is not shown either.
        lists.show(list: .all, collections: [], unavailable: true)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertTrue(lists.chipsView.isHidden)
    }

    func testTheListCursorStopsAtEitherEndAndFollowsTheChosenList() throws {
        let toolbar = makeToolbar(width: 1216)
        let lists = toolbar.lists
        let many = collections(12)
        lists.show(list: .snippets, collections: many, unavailable: false)
        toolbar.layoutSubtreeIfNeeded()
        lists.cursor = 0
        lists.moveCursor(by: -1)
        XCTAssertEqual(lists.cursor, 0)
        for _ in 0..<40 { lists.moveCursor(by: 1) }
        XCTAssertEqual(lists.stopUnderCursor, .more)
        // ⌘L puts the cursor on the list shown: a segment, a chip, or More for a collection that does not fit.
        lists.moveCursor(to: .all)
        XCTAssertEqual(lists.stopUnderCursor, .all)
        lists.moveCursor(to: .collection(many[1].id))
        XCTAssertEqual(lists.stopUnderCursor, .collection(many[1].id))
        lists.moveCursor(to: .collection(many[11].id))
        XCTAssertEqual(lists.stopUnderCursor, .more)
        // Under All the chips are gone, and the cursor keeps to the switch.
        lists.show(list: .all, collections: many, unavailable: false)
        XCTAssertLessThanOrEqual(lists.cursor, 1)
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

    /// `count` synthetic collections, in the sidebar's order, with names of different lengths.
    private func collections(_ count: Int) -> [CollectionSummary] {
        let names = ["Prompts", "Drafts", "Release notes", "Code review", "Meeting templates", "Customer replies",
                     "Shell", "Design", "Reading list", "Travel", "Interview questions", "Weekly report"]
        return (0..<count).map { index in
            CollectionSummary(id: CollectionID(), name: names[index % names.count], color: "blue",
                              sortOrder: Double(index))
        }
    }

    /// The chips shown, and More when it shows, in the toolbar's coordinates.
    private func chipFrames(_ toolbar: QuickAccessToolbar) -> [NSRect] {
        let lists = toolbar.lists
        return (lists.chips + [lists.moreChip]).filter { !$0.isHidden && !lists.chipsView.isHidden }
            .map { lists.chipsView.convert($0.frame, to: toolbar) }
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
