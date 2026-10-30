import XCTest
@testable import Keeptide

final class StripLayoutTests: XCTestCase {
    /// A band 1360 pt wide with frames 164 pt wide and 176 pt apart, docked 24 pt in from its ends: the geometry
    /// the placement numbers below were worked out for. It is no card size's own.
    private var metrics: StripMetrics {
        StripMetrics(cardSize: .medium, bandWidth: 1360, frameSize: CGSize(width: 164, height: 109), gap: 12,
                     cornerRadius: 12, dockInset: 24, headerHeight: 56, footerHeight: 30, iconSize: 40, toolbarGap: 20,
                     bottomPadding: 22)
    }

    func testCardSizesMatchTheSpec() {
        let sizes: [(size: CardSize, card: CGSize, header: CGFloat, icon: CGFloat, footer: CGFloat, radius: CGFloat)] = [
            (.small, CGSize(width: 200, height: 220), 52, 36, 28, 18),
            (.medium, CGSize(width: 228, height: 250), 56, 40, 30, 20),
            (.large, CGSize(width: 260, height: 286), 60, 44, 32, 22),
        ]
        for (size, card, header, icon, footer, radius) in sizes {
            let m = StripLayout.metrics(for: size, visibleWidth: 1440)
            XCTAssertEqual(m.cardSize, size)
            XCTAssertEqual(m.frameSize, card, "\(size)")
            XCTAssertEqual(m.headerHeight, header, "\(size)")
            XCTAssertEqual(m.iconSize, icon, "\(size)")
            XCTAssertEqual(m.footerHeight, footer, "\(size)")
            // Larger cards have rounder corners.
            XCTAssertEqual(m.cornerRadius, radius, "\(size)")
            // Gap and dock inset are the same at every size.
            XCTAssertEqual(m.gap, 14, "\(size)")
            XCTAssertEqual(m.dockInset, 20, "\(size)")
            XCTAssertEqual(m.step, card.width + 14, "\(size)")
        }
    }

    func testBandIsTheVisibleWidthLessSixtyFour() {
        for (visible, band) in [(1440, 1376), (2560, 2496), (1024, 960)] as [(CGFloat, CGFloat)] {
            XCTAssertEqual(StripLayout.metrics(for: .medium, visibleWidth: visible).bandWidth, band, "\(visible)")
        }
    }

    func testANarrowScreenKeepsTheCardSizeAndShowsFewerCards() {
        for size in CardSize.allCases {
            let wide = StripLayout.metrics(for: size, visibleWidth: 2560)
            let narrow = StripLayout.metrics(for: size, visibleWidth: 1024)
            XCTAssertEqual(narrow.cardSize, size)
            XCTAssertEqual(narrow.frameSize, wide.frameSize, "\(size)")
            XCTAssertEqual(narrow.gap, wide.gap, "\(size)")
            XCTAssertEqual(narrow.cornerRadius, wide.cornerRadius, "\(size)")
            XCTAssertEqual(narrow.dockInset, wide.dockInset, "\(size)")
        }
        // The film docks the same 20 pt in from the band's left end.
        let narrow = StripLayout.metrics(for: .large, visibleWidth: 1024)
        XCTAssertEqual(StripLayout.placement(narrow, count: 50, position: 0, oldestIsLoaded: false).firstOrigin, 20)
    }

    func testTheBandIsTheToolbarTheCardsAndTheirPadding() {
        // 16 above the toolbar, the toolbar's 32, 20 down to the cards, the cards, and 22 below them. With the selected
        // card not enlarged, and without the frequent wing, which is how the metrics come unless asked, the band is as
        // it was before either.
        let unscaled = StripStyle(selectedScale: 1)
        for (size, height) in [(CardSize.small, 310), (.medium, 340), (.large, 376)] as [(CardSize, CGFloat)] {
            let m = StripLayout.metrics(for: size, visibleWidth: 1440, style: unscaled)
            XCTAssertEqual(m, StripLayout.metrics(for: size, visibleWidth: 1440, showsFrequentClips: false,
                                                  style: unscaled), "\(size)")
            XCTAssertEqual(m.toolbarGap, 20, "\(size)")
            XCTAssertEqual(m.bottomPadding, 22, "\(size)")
            XCTAssertEqual(StripLayout.bandHeight(m), height, "\(size)")
            XCTAssertEqual(StripLayout.cardTop(m), 68, "\(size)")
            XCTAssertEqual(StripLayout.bandHeight(m) - StripLayout.cardTop(m) - m.frameSize.height, 22, "\(size)")
        }
        // Its corners are rounder than the cards'.
        XCTAssertEqual(StripLayout.cornerRadius, 36)
    }

    func testTheFrequentWingMakesRoomForItsIconsBelowTheCards() {
        // With the frequent wing, the section icons lie below the cards, so the room there is 28 instead of 22 and the
        // band is 6 taller. The gap between the toolbar and the cards stays 20, so the cards start 68 below the band's
        // top edge, as without the wing. The cards and the band's width are the same. With the selected card not
        // enlarged, the band is as it was before the enlargement.
        let unscaled = StripStyle(selectedScale: 1)
        for (size, height) in [(CardSize.small, 316), (.medium, 346), (.large, 382)] as [(CardSize, CGFloat)] {
            let m = StripLayout.metrics(for: size, visibleWidth: 1440, showsFrequentClips: true, style: unscaled)
            let plain = StripLayout.metrics(for: size, visibleWidth: 1440, style: unscaled)
            XCTAssertEqual(m.toolbarGap, 20, "\(size)")
            XCTAssertEqual(m.bottomPadding, 28, "\(size)")
            XCTAssertEqual(StripLayout.bandHeight(m), height, "\(size)")
            XCTAssertEqual(StripLayout.cardTop(m), 68, "\(size)")
            XCTAssertEqual(StripLayout.bandHeight(m) - StripLayout.cardTop(m) - m.frameSize.height, 28, "\(size)")
            XCTAssertEqual(StripLayout.bandHeight(m) - StripLayout.bandHeight(plain), 6, "\(size)")
            XCTAssertEqual(m.frameSize, plain.frameSize, "\(size)")
            XCTAssertEqual(m.bandWidth, plain.bandWidth, "\(size)")
        }
    }

    func testTheSelectedCardsScaleSetsThePushAndTheRoomAroundTheCards() {
        // (size, scale) → (push, growth, toolbarGap, bottomPadding, band, band with the frequent wing). The selected
        // card enlarged about its middle reaches its growth past the other cards' top and bottom edges, and the band
        // makes that much more room above the cards and below them. Its neighbours stand aside by the push; not at all
        // at 1.00, where the strip is as it was before the selected card was enlarged.
        let cases: [(CardSize, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (.small, 1.00, 0, 0, 20, 22, 310, 316), (.small, 1.12, 18, 14, 34, 36, 338, 344),
            (.small, 1.25, 19, 28, 48, 50, 366, 372),
            (.medium, 1.00, 0, 0, 20, 22, 340, 346), (.medium, 1.12, 18, 15, 35, 37, 370, 376),
            (.medium, 1.25, 23, 32, 52, 54, 404, 410),
            (.large, 1.00, 0, 0, 20, 22, 376, 382), (.large, 1.12, 18, 18, 38, 40, 412, 418),
            (.large, 1.25, 27, 36, 56, 58, 448, 454),
        ]
        for (size, scale, push, growth, toolbarGap, bottomPadding, band, wingBand) in cases {
            let name = "\(size) \(scale)"
            let style = StripStyle(selectedScale: scale)
            let m = StripLayout.metrics(for: size, visibleWidth: 1440, style: style)
            XCTAssertEqual(m.selectedScale, scale, name)
            XCTAssertEqual(m.neighbourPush, push, name)
            XCTAssertEqual(m.selectionGrowth, growth, name)
            XCTAssertEqual(m.toolbarGap, toolbarGap, name)
            XCTAssertEqual(m.bottomPadding, bottomPadding, name)
            XCTAssertEqual(StripLayout.bandHeight(m), band, name)
            XCTAssertEqual(StripLayout.cardTop(m), 68 + growth, name)
            let wing = StripLayout.metrics(for: size, visibleWidth: 1440, showsFrequentClips: true, style: style)
            XCTAssertEqual(wing.bottomPadding, bottomPadding + 6, name)
            XCTAssertEqual(StripLayout.bandHeight(wing), wingBand, name)
            // The cards themselves, their gaps and the band's width are the same at every scale.
            let plain = StripLayout.metrics(for: size, visibleWidth: 1440, style: StripStyle(selectedScale: 1))
            XCTAssertEqual([m.frameSize.width, m.frameSize.height, m.gap, m.bandWidth, m.dockInset],
                           [plain.frameSize.width, plain.frameSize.height, plain.gap, plain.bandWidth, plain.dockInset],
                           name)
        }
        // Unless asked otherwise, the metrics take the standard enlargement.
        XCTAssertEqual(StripLayout.metrics(for: .medium, visibleWidth: 1440),
                       StripLayout.metrics(for: .medium, visibleWidth: 1440, style: .standard))
        XCTAssertEqual(StripStyle.standard.selectedScale, 1.12)

        // The ring keeps 3 pt from the card and is 3 pt wide, so it reaches 6 pt beyond it; 4 pt wide, and 7 pt, with
        // Increase Contrast.
        XCTAssertEqual(StripLayout.selectionRingGap + StripLayout.selectionRingWidth(increasedContrast: false), 6)
        XCTAssertEqual(StripLayout.selectionRingGap + StripLayout.selectionRingWidth(increasedContrast: true), 7)
        // Every value the slider gives keeps the ring clear of a neighbour. The enlarged card reaches (s − 1)·W/2 into
        // the gap on either side and its ring 6 pt beyond that, and 2 pt are left before the neighbour, which stands
        // aside by the push; 1 pt with Increase Contrast's ring. At small size and 1.24–1.25 that is exactly 2, or 1,
        // give or take rounding.
        for hundredths in 100...125 {
            let scale = CGFloat(hundredths) / 100
            for size in CardSize.allCases {
                let m = StripLayout.metrics(for: size, visibleWidth: 1440, style: StripStyle(selectedScale: scale))
                let clear = m.gap + m.neighbourPush - (scale - 1) * m.frameSize.width / 2
                XCTAssertGreaterThanOrEqual(clear - 6, 2 - 1e-9, "\(size) \(scale)")
                XCTAssertGreaterThanOrEqual(clear - 7, 1 - 1e-9, "\(size) \(scale), Increase Contrast")
            }
        }
        // The scale stays within what the slider offers.
        XCTAssertEqual(StripStyle(selectedScale: 1.4).selectedScale, 1.25)
        XCTAssertEqual(StripStyle(selectedScale: 0.9).selectedScale, 1)
    }

    func testTheSectionIconsStayThreePointsAboveTheBandsEdge() {
        // Below the cards, a section icon is centred between the band's bottom edge and the lowest reach of the ring
        // around the enlarged selected card: the growth, then 7 pt with Increase Contrast. The room there grows with
        // the card, so a 15 pt icon starts 3 pt above the edge at every scale and card size.
        for size in CardSize.allCases {
            for scale in [1.0, 1.12, 1.25] as [CGFloat] {
                let m = StripLayout.metrics(for: size, visibleWidth: 1440, showsFrequentClips: true,
                                            style: StripStyle(selectedScale: scale))
                XCTAssertEqual(StripLayout.sectionLabelBottom(m, height: 15), 3, "\(size) \(scale)")
            }
        }
    }

    func testOpenDocksTheNewestAtTheLeftEnd() {
        assertPlacement(count: 50, position: 0, origin: 24)
    }

    func testTheSelectionWalksToTheMiddleBeforeTheFilmMoves() {
        // The film rests while the selection walks right along it: the selected frame is at 24 + 3 · 176 = 552.
        assertPlacement(count: 50, position: 3, origin: 24)
        // One step further it would pass the middle, so the film moves instead and the selected frame stays centred.
        assertPlacement(count: 50, position: 4, origin: -106)
        let moved = StripLayout.placement(metrics, count: 50, position: 4, oldestIsLoaded: false)
        XCTAssertEqual(moved.firstOrigin + 4 * metrics.step + metrics.frameSize.width / 2, metrics.bandWidth / 2)
    }

    func testFingersMoveTheFilmOnlyPastTheDock() {
        // A fractional position is a selection under the fingers, between two clips. Short of the middle, which
        // it reaches at about 3.26, the film rests; past it the film follows.
        assertPlacement(count: 50, position: 3.2, origin: 24)
        assertPlacement(count: 50, position: 3.3, origin: 17.2, accuracy: 0.001)
        assertPlacement(count: 50, position: 3.5, origin: -18)
    }

    func testTheOldestEndDocksOnlyWhenLoaded() {
        // Loaded, the film follows the selection until the last frame's right edge would pass 1360 − 24 = 1336,
        // at about index 45.7. From there it stops and the selection walks on to the last clip.
        assertPlacement(count: 50, position: 45, loaded: true, origin: -7322)
        assertPlacement(count: 50, position: 46, loaded: true, origin: -7452)
        assertPlacement(count: 50, position: 49, loaded: true, origin: -7452)
        let docked = StripLayout.placement(metrics, count: 50, position: 49, oldestIsLoaded: true)
        let last = StripLayout.frameOrigins(metrics, count: 50, placement: docked)[49]
        XCTAssertEqual(last + metrics.frameSize.width, 1336)
        // While more may follow, the film keeps moving to the last clip.
        assertPlacement(count: 50, position: 49, origin: -8026)
    }

    func testAShortLoadedFilmIsCentredAsAGroup() {
        // Three clips are 516 wide, which leaves 422 on each side whichever of them is selected.
        assertPlacement(count: 3, position: 0, loaded: true, origin: 422)
        assertPlacement(count: 3, position: 2, loaded: true, origin: 422)
        // Seven (1220) still fit between the docks (1312). Eight (1396) do not, so the film docks at the left end.
        assertPlacement(count: 7, position: 0, loaded: true, origin: 70)
        assertPlacement(count: 8, position: 0, loaded: true, origin: 24)
        // A single clip sits in the middle.
        assertPlacement(count: 1, position: 0, loaded: true, origin: 598)
        // Clips that more may follow are not centred.
        assertPlacement(count: 3, position: 0, origin: 24)
    }

    func testAVanishedSelectionKeepsAnEmptySlotAtTheDock() {
        // The empty slot takes the dock and index 0 stands one step to its right: 24 + 176.
        assertPlacement(count: 50, position: -1, origin: 200)
        // A short loaded film is centred with the slot in it: four frames are 692 wide, so index 0 is at 334 + 176.
        assertPlacement(count: 3, position: -1, loaded: true, origin: 510)
        // Six clips and the slot (1220) still fit between the docks; seven and the slot (1396) do not, so the
        // slot docks at the left end.
        assertPlacement(count: 6, position: -1, loaded: true, origin: 246)
        assertPlacement(count: 7, position: -1, loaded: true, origin: 200)
        // Fingers between the slot and index 0 do not move the film.
        assertPlacement(count: 50, position: -0.5, origin: 200)
    }

    func testFrameOriginsStepRightFromTheFirst() {
        let placement = StripPlacement(firstOrigin: 24)
        XCTAssertEqual(StripLayout.frameOrigins(metrics, count: 3, placement: placement), [24, 200, 376])
    }

    // MARK: The frequent wing

    // Medium cards on a screen 1440 wide with the selected card not enlarged: band 1376, card 228, gap 14, step 242,
    // dock 20. The frequent wing's cases below were worked out before the selected card was enlarged; the enlargement
    // has cases of its own.
    private var medium: StripMetrics {
        StripLayout.metrics(for: .medium, visibleWidth: 1440, style: StripStyle(selectedScale: 1))
    }

    func testFirstScreenCountsTheCardsTheBandShowsWhole() {
        // Without a frequent wing the newest clip rests at the left dock, and the band shows
        // floor((bandWidth − 2·dockInset + gap) / step) whole.
        for (size, visible, count) in [(CardSize.medium, 1440, 5), (.medium, 1300, 5), (.medium, 1299, 4),
                                       (.medium, 1024, 3), (.medium, 2560, 10), (.small, 1440, 6),
                                       (.large, 1440, 4)] as [(CardSize, CGFloat, Int)] {
            let m = StripLayout.metrics(for: size, visibleWidth: visible)
            XCTAssertEqual(StripLayout.recentShownWhole(m, frequentCount: 0), count, "\(size) \(visible)")
        }
        // A band too narrow for a single card shows none, never fewer: the panel drops the clips it shows whole from
        // the frequent wing by this count. So narrow a band puts the newest clip in its middle with a wing or without.
        for (visible, count) in [(332, 1), (331, 0), (64, 0)] as [(CGFloat, Int)] {
            let narrow = StripLayout.metrics(for: .medium, visibleWidth: visible)
            for wing in [0, 1, 3] {
                XCTAssertEqual(StripLayout.recentShownWhole(narrow, frequentCount: wing), count, "\(visible), \(wing)")
            }
        }
    }

    func testAWingThatReachesTheMiddleLeavesFewerNewestClipsWhole() {
        // The strip opens on the newest clip. Beside a wing long enough to put it in the middle, the band shows it and
        // the cards wholly right of the middle: floor((bandWidth/2 + W/2 + gap − dockInset) / step), 3 at 1440 and 2 at
        // 1024. A shorter wing rests at the left dock with the newest clip left of the middle, and more of the newest
        // are whole: 4 at 1440 beside one frequent card. At 1024 one frequent card leaves two whole, as a longer wing.
        for (visible, counts) in [(1440, [5, 4, 3, 3, 3]), (1024, [3, 2, 2, 2, 2])] as [(CGFloat, [Int])] {
            let m = StripLayout.metrics(for: .medium, visibleWidth: visible)
            let wings = [0, 1, 2, 3, 20]
            XCTAssertEqual(wings.map { StripLayout.recentShownWhole(m, frequentCount: $0) }, counts, "\(visible)")
            XCTAssertEqual(Int(((m.bandWidth / 2 + m.frameSize.width / 2 + m.gap - m.dockInset) / m.step)
                .rounded(.down)), counts[4], "\(visible)")
            // Where the newest clip rests beside each wing, the last card counted ends short of the right dock and the
            // next one does not.
            for (wing, count) in zip(wings, counts) where count > 0 {
                let film = StripLayout.placement(m, count: wing + 30, position: CGFloat(wing), oldestIsLoaded: true,
                                                 frequentCount: wing)
                let origins = StripLayout.frameOrigins(m, count: wing + 30, placement: film)
                let dock = m.bandWidth - m.dockInset
                XCTAssertLessThanOrEqual(origins[wing + count - 1] + m.frameSize.width, dock, "\(visible), \(wing)")
                XCTAssertGreaterThan(origins[wing + count] + m.frameSize.width, dock, "\(visible), \(wing)")
            }
        }
    }

    func testTheFirstScreenCountDoesNotDependOnTheEnlargement() {
        // The frequent wing leaves out the newest clips the band shows whole as the strip opens. The band counts the
        // same clips whole however much the selected card is enlarged, so the enlargement never changes which clips
        // the wing lists.
        for (visible, counts) in [(1300, [5, 3, 3, 3, 3]), (1440, [5, 4, 3, 3, 3])] as [(CGFloat, [Int])] {
            for scale in [1.0, 1.12, 1.25] as [CGFloat] {
                let m = StripLayout.metrics(for: .medium, visibleWidth: visible, showsFrequentClips: true,
                                            style: StripStyle(selectedScale: scale))
                XCTAssertEqual([0, 1, 2, 3, 20].map { StripLayout.recentShownWhole(m, frequentCount: $0) }, counts,
                               "\(visible) \(scale)")
            }
        }
    }

    func testTheDividerWidensOneGapByAThirdOfACard() {
        XCTAssertEqual(CardSize.allCases.map { StripLayout.metrics(for: $0, visibleWidth: 1440).dividerExtra },
                       [67, 76, 87])
        // Three frequent clips, then the recent ones a third of a card further right. The line stands in the middle of
        // the wider gap, from 732 to 822.
        let placed = StripPlacement(firstOrigin: 20, dividerBefore: 3)
        XCTAssertEqual(StripLayout.frameOrigins(medium, count: 6, placement: placed), [20, 262, 504, 822, 1064, 1306])
        XCTAssertEqual(StripLayout.dividerX(medium, placement: placed), 777)
        XCTAssertNil(StripLayout.dividerX(medium, placement: StripPlacement(firstOrigin: 20)))
    }

    func testAShortFrequentWingDocksTheWholeFilmLeft() {
        // One frequent clip leaves the newest short of the middle, so the film rests at the left dock and the
        // selection stands on the newest clip left of the middle.
        let p = StripLayout.placement(medium, count: 31, position: 1, oldestIsLoaded: true, frequentCount: 1)
        XCTAssertEqual(p, StripPlacement(firstOrigin: 20, dividerBefore: 1))
        XCTAssertEqual(StripLayout.frameOrigins(medium, count: 31, placement: p)[1], 338)
    }

    func testAFrequentWingOfTwoOrMoreCentresTheNewestClip() {
        for (k, origin) in [(2, 14), (3, -228)] as [(Int, CGFloat)] {
            let p = StripLayout.placement(medium, count: k + 30, position: CGFloat(k), oldestIsLoaded: true,
                                          frequentCount: k)
            XCTAssertEqual(p.firstOrigin, origin, "\(k)")
            XCTAssertEqual(StripLayout.frameOrigins(medium, count: k + 30, placement: p)[k] + 114, 688, "\(k)")
        }
    }

    func testCrossingTheDividerUnderTheFingersMovesSmoothly() {
        // Carried from the last frequent clip to the newest one, the selection crosses the wider gap a share at a time,
        // so the film follows the fingers without a jump.
        for (position, origin) in [(2, 20), (2.5, -69), (3, -228)] as [(CGFloat, CGFloat)] {
            XCTAssertEqual(StripLayout.placement(medium, count: 33, position: position, oldestIsLoaded: true,
                                                 frequentCount: 3).firstOrigin, origin, accuracy: 0.5, "\(position)")
        }
    }

    func testWithoutRecentClipsThereIsNoDivider() {
        let p = StripLayout.placement(medium, count: 3, position: 0, oldestIsLoaded: true, frequentCount: 3)
        XCTAssertNil(p.dividerBefore)
        // Nor does the film take the divider's room: three frames are 712 wide, centred.
        XCTAssertEqual(p.firstOrigin, 332)
        XCTAssertNil(StripLayout.placement(medium, count: 3, position: 0, oldestIsLoaded: true).dividerBefore)
    }

    func testTheDividerWidensTheFilmItself() {
        // The oldest clip still comes to rest at the right dock.
        let docked = StripLayout.placement(medium, count: 33, position: 32, oldestIsLoaded: true, frequentCount: 3)
        XCTAssertEqual(StripLayout.frameOrigins(medium, count: 33, placement: docked)[32] + 228,
                       medium.bandWidth - medium.dockInset)
        // A short loaded film is centred as a group with the divider in it: 788 wide, 294 from either end.
        let group = StripLayout.placement(medium, count: 3, position: 0, oldestIsLoaded: true, frequentCount: 1)
        let origins = StripLayout.frameOrigins(medium, count: 3, placement: group)
        XCTAssertEqual(origins, [294, 612, 854])
        XCTAssertEqual(medium.bandWidth - (origins[2] + 228), 294)
    }

    func testAVanishedSelectionKeepsItsSlotAtTheDivider() {
        // The empty slot stands just past the divider, where the newest clip rests as the strip opens: in the middle,
        // with the wing to its left, the most used clip beside the divider, and the newest clip a step to its right.
        let p = StripLayout.placement(medium, count: 33, position: -1, oldestIsLoaded: true, frequentCount: 3)
        XCTAssertEqual(p, StripPlacement(firstOrigin: -228, dividerBefore: 3, slotBefore: 3))
        XCTAssertEqual(StripLayout.slotOrigin(medium, placement: p), 574)
        XCTAssertEqual(StripLayout.frameOrigins(medium, count: 5, placement: p), [-228, 14, 256, 816, 1058])
        XCTAssertEqual(StripLayout.dividerX(medium, placement: p), 529)
        // A short loaded film is centred with the slot and the divider in it: 1030 wide, from 173, with the slot at
        // 491 between the frequent clip and the newest one.
        let group = StripLayout.placement(medium, count: 3, position: -1, oldestIsLoaded: true, frequentCount: 1)
        XCTAssertEqual(group, StripPlacement(firstOrigin: 173, dividerBefore: 1, slotBefore: 1))
        XCTAssertEqual(StripLayout.slotOrigin(medium, placement: group), 491)
        XCTAssertEqual(StripLayout.frameOrigins(medium, count: 3, placement: group), [173, 733, 975])
        // Without a wing the slot stays before index 0, which the first origin leaves room for: the slot at the dock.
        let plain = StripLayout.placement(medium, count: 30, position: -1, oldestIsLoaded: true)
        XCTAssertEqual(plain, StripPlacement(firstOrigin: 262, slotBefore: 0))
        XCTAssertEqual(StripLayout.slotOrigin(medium, placement: plain), medium.dockInset)
        XCTAssertEqual(StripLayout.frameOrigins(medium, count: 2, placement: plain), [262, 504])
        // A selected row has no slot.
        XCTAssertNil(StripLayout.placement(medium, count: 33, position: 3, oldestIsLoaded: true, frequentCount: 3)
            .slotBefore)
        XCTAssertNil(StripLayout.slotOrigin(medium, placement: StripPlacement(firstOrigin: 20)))
    }

    func testSectionLabelsSitBesideTheDividerAndStickAtTheEnds() {
        // Icons 70 and 60 wide here, so that their edges tell apart. Each stands 8 from the line, but never closer than
        // 42 to an end of the band: it follows the line until it reaches that inset, then stays there, until the line
        // passes it and its wing has gone off that end. The other icon then rests at that end.
        let cases: [(CGFloat, StripSectionLabels)] = [
            (600, .init(frequent: 522, recent: 608)),
            // At the left end "Frequent" reaches 42 with the line at 120, stays there, and goes once the line passes
            // its right edge, at 112; "Recent" goes on beside the line until it too reaches 42, and stays there.
            (120, .init(frequent: 42, recent: 128)), (119, .init(frequent: 42, recent: 127)),
            (112, .init(frequent: 42, recent: 120)), (111, .init(frequent: nil, recent: 119)),
            (45, .init(frequent: nil, recent: 53)), (34, .init(frequent: nil, recent: 42)),
            (33, .init(frequent: nil, recent: 42)), (-500, .init(frequent: nil, recent: 42)),
            // The mirror at the right end, 1376 wide: "Recent" stays at 1274, 42 short of the end, from the line at
            // 1266 until the line passes its left edge.
            (1266, .init(frequent: 1188, recent: 1274)), (1267, .init(frequent: 1189, recent: 1274)),
            (1274, .init(frequent: 1196, recent: 1274)), (1275, .init(frequent: 1197, recent: nil)),
            (1342, .init(frequent: 1264, recent: nil)), (1343, .init(frequent: 1264, recent: nil)),
            (2000, .init(frequent: 1264, recent: nil)),
        ]
        for (divider, expected) in cases {
            let origins = StripLayout.sectionLabelOrigins(medium, dividerX: divider, frequentWidth: 70, recentWidth: 60)
            XCTAssertEqual(origins, expected, "\(divider)")
            // Neither ever stands within 42 of an end, nor on the other side of the line from its wing.
            if let frequent = origins.frequent {
                XCTAssertGreaterThanOrEqual(frequent, 42, "\(divider)")
                XCTAssertLessThanOrEqual(frequent + 70, min(divider, medium.bandWidth - 42), "\(divider)")
            }
            if let recent = origins.recent {
                XCTAssertGreaterThanOrEqual(recent, max(divider, 42), "\(divider)")
                XCTAssertLessThanOrEqual(recent + 60, medium.bandWidth - 42, "\(divider)")
            }
        }
        // They keep 42 from the band's ends whatever the dock inset is: 24 in a band 1360 wide here.
        let custom: [(CGFloat, StripSectionLabels)] = [
            (33, .init(frequent: nil, recent: 42)), (111, .init(frequent: nil, recent: 119)),
            (112, .init(frequent: 42, recent: 120)),
            (1258, .init(frequent: 1180, recent: 1258)), (1259, .init(frequent: 1181, recent: nil)),
            (1327, .init(frequent: 1248, recent: nil)),
        ]
        for (divider, expected) in custom {
            let origins = StripLayout.sectionLabelOrigins(metrics, dividerX: divider, frequentWidth: 70,
                                                          recentWidth: 60)
            XCTAssertEqual(origins, expected, "\(divider)")
        }
    }

    func testPanelAndPreviewStayInsideOddVisibleFrames() {
        for visible in [NSRect(x: 0, y: 25, width: 1280, height: 760), NSRect(x: 0, y: 0, width: 1100, height: 680),
                        NSRect(x: -1800, y: 30, width: 1600, height: 1000), NSRect(x: 0, y: 900, width: 400, height: 640),
                        NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: 0, y: 0, width: 2560, height: 1415)] {
            // The band the frequent wing makes taller stays inside as well.
            for (size, wing) in CardSize.allCases.flatMap({ size in [(size, false), (size, true)] }) {
                let m = StripLayout.metrics(for: size, visibleWidth: visible.width, showsFrequentClips: wing)
                let label = "\(size) wing \(wing) \(visible)"
                let band = StripLayout.bandFrame(m, in: visible)
                XCTAssertEqual(band.midX, visible.midX, accuracy: 0.5, label)
                XCTAssertEqual(band.midY, visible.midY, accuracy: 0.5, label)
                XCTAssertEqual(band.size, NSSize(width: m.bandWidth, height: StripLayout.bandHeight(m)), label)
                XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: band, preview: nil, in: visible)), label)
                let (preview, moved) = StripLayout.previewLayout(band: band, in: visible)
                XCTAssertTrue(visible.contains(StripLayout.panelFrame(band: moved, preview: preview, in: visible)),
                              label)
                // The card sits above the band.
                XCTAssertGreaterThanOrEqual(preview.minY, moved.maxY + StripLayout.previewGap - 0.5, label)
            }
        }
    }

    func testALaptopScreenHoldsThePreviewCardAboveTheBand() {
        // 1440 × 875 is what a 1440 × 900 laptop screen leaves under the menu bar. Above the band, the preview card
        // keeps as much of its 760 × 470 as the screen leaves it, the two centred together. With the standard
        // enlargement the band is taller, by the room around the cards for the selected card: small cards still leave
        // the whole card, medium ones 441 pt of its height, and 435 with the frequent wing's room below the cards.
        // Without the enlargement medium cards leave the whole card, as they did before it.
        let laptop = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let cases: [(size: CardSize, wing: Bool, scale: CGFloat, height: CGFloat)] = [
            (.small, false, 1.12, 470), (.medium, false, 1.12, 441), (.medium, true, 1.12, 435),
            (.medium, false, 1, 470),
        ]
        for (size, wing, scale, height) in cases {
            let name = "\(size), wing \(wing), \(scale)"
            let m = StripLayout.metrics(for: size, visibleWidth: laptop.width, showsFrequentClips: wing,
                                        style: StripStyle(selectedScale: scale))
            let band = StripLayout.bandFrame(m, in: laptop)
            let (preview, moved) = StripLayout.previewLayout(band: band, in: laptop)
            XCTAssertEqual(preview.size, NSSize(width: StripLayout.previewMaximum.width, height: height), name)
            XCTAssertEqual(preview.minY, moved.maxY + StripLayout.previewGap, accuracy: 0.5, name)
            XCTAssertEqual((preview.maxY + moved.minY) / 2, laptop.midY, accuracy: 0.5, name)
            XCTAssertTrue(laptop.contains(StripLayout.panelFrame(band: moved, preview: preview, in: laptop)), name)
        }
    }

    func testThePanelGivesTheShadowWhatRoomTheScreenHas() {
        // On a tall screen the panel reaches 32 beside the band, 40 above it and 100 below, where the shadow falls.
        let tall = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let m = StripLayout.metrics(for: .medium, visibleWidth: tall.width)
        let band = StripLayout.bandFrame(m, in: tall)
        let panel = StripLayout.panelFrame(band: band, preview: nil, in: tall)
        XCTAssertEqual(band.minX - panel.minX, 32)
        XCTAssertEqual(panel.maxX - band.maxX, 32)
        XCTAssertEqual(panel.maxY - band.maxY, 40)
        XCTAssertEqual(band.minY - panel.minY, 100)

        // Where the screen is shorter the panel stops at its edges, and the band stays in the middle: on a screen 480
        // high, the band, 370 high with the standard enlargement, leaves its shadow 55 below it.
        let short = NSRect(x: 0, y: 40, width: 1440, height: 480)
        let shortBand = StripLayout.bandFrame(m, in: short)
        let shortPanel = StripLayout.panelFrame(band: shortBand, preview: nil, in: short)
        XCTAssertEqual(shortBand.midY, short.midY, accuracy: 0.5)
        XCTAssertEqual(shortPanel.minY, short.minY, accuracy: 0.5)
        XCTAssertEqual(shortPanel.maxY, shortBand.maxY + 40, accuracy: 0.5)
        XCTAssertEqual(shortBand.minY - shortPanel.minY, 55, accuracy: 0.5)

        // The preview card above the band takes the room above in the same way.
        let (preview, moved) = StripLayout.previewLayout(band: band, in: tall)
        let withCard = StripLayout.panelFrame(band: moved, preview: preview, in: tall)
        XCTAssertEqual(withCard.maxY, min(tall.maxY, preview.maxY + 40), accuracy: 0.5)
        XCTAssertEqual(withCard.minY, max(tall.minY, moved.minY - 100), accuracy: 0.5)
    }

    func testThePreviewGoesAboveTheBandAndMovesItOnlyWhenThereIsNoRoom() {
        // On a tall screen the card fits above the band, which stays where it is.
        let tall = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let tallMetrics = StripLayout.metrics(for: .medium, visibleWidth: tall.width)
        let band = StripLayout.bandFrame(tallMetrics, in: tall)
        let above = StripLayout.previewLayout(band: band, in: tall)
        XCTAssertEqual(above.band, band)
        XCTAssertEqual(above.preview.minY, band.maxY + StripLayout.previewGap, accuracy: 0.5)
        XCTAssertEqual(above.preview.size, StripLayout.previewMaximum)

        // On a lower screen it has no room there, so the card and the band are centred as one group and the band
        // moves down.
        let lower = NSRect(x: 0, y: 0, width: 1440, height: 1000)
        let m = StripLayout.metrics(for: .medium, visibleWidth: lower.width)
        let plain = StripLayout.bandFrame(m, in: lower)
        let centred = StripLayout.previewLayout(band: plain, in: lower)
        XCTAssertLessThan(centred.band.maxY, plain.maxY)
        XCTAssertEqual((centred.preview.maxY + centred.band.minY) / 2, lower.midY, accuracy: 0.5)
        XCTAssertEqual(centred.preview.size, StripLayout.previewMaximum)
    }

    func testALowScreenKeepsThePreviewCardAtLeast160High() {
        // 1024 × 520, as a small laptop at a larger text size leaves under the menu bar and above the Dock: the room
        // above the band would leave the card 86 high with medium cards, and less than nothing on a lower screen. The
        // card is never under 160, and it stays on the screen with the band.
        let low = NSRect(x: 0, y: 0, width: 1024, height: 520)
        for size in CardSize.allCases {
            let m = StripLayout.metrics(for: size, visibleWidth: low.width)
            let band = StripLayout.bandFrame(m, in: low)
            let (preview, moved) = StripLayout.previewLayout(band: band, in: low)
            XCTAssertGreaterThanOrEqual(preview.height, 160, "\(size)")
            XCTAssertEqual(preview.width, StripLayout.previewMaximum.width, "\(size)")
            XCTAssertTrue(low.contains(preview), "\(size): \(preview)")
            XCTAssertTrue(low.contains(moved), "\(size): \(moved)")
            XCTAssertEqual(moved.size, band.size, "\(size)")
            XCTAssertTrue(low.contains(StripLayout.panelFrame(band: moved, preview: preview, in: low)), "\(size)")
        }

        // With medium cards the band, taller by the room the standard enlargement needs around the cards, leaves the
        // card no room above it even across the screen's whole height: the card lies 10 pt over the band's top edge.
        // Without the enlargement it still fits above the band, as it did before.
        let m = StripLayout.metrics(for: .medium, visibleWidth: low.width)
        let (preview, moved) = StripLayout.previewLayout(band: StripLayout.bandFrame(m, in: low), in: low)
        XCTAssertEqual(preview.minY, moved.maxY - 10, accuracy: 0.5)
        let plain = StripLayout.metrics(for: .medium, visibleWidth: low.width, style: StripStyle(selectedScale: 1))
        let unscaled = StripLayout.previewLayout(band: StripLayout.bandFrame(plain, in: low), in: low)
        XCTAssertEqual(unscaled.preview.minY, unscaled.band.maxY + StripLayout.previewGap, accuracy: 0.5)

        // On a screen lower still there is no room for it above the band at all: it is drawn over the band's top edge
        // rather than be cut down further or leave the screen.
        let lower = NSRect(x: 0, y: 30, width: 1024, height: 440)
        for size in CardSize.allCases {
            let m = StripLayout.metrics(for: size, visibleWidth: lower.width)
            let (preview, moved) = StripLayout.previewLayout(band: StripLayout.bandFrame(m, in: lower), in: lower)
            XCTAssertEqual(preview.height, 160, "\(size)")
            XCTAssertTrue(lower.contains(preview), "\(size): \(preview)")
            XCTAssertEqual(moved.minY, lower.minY, accuracy: 0.5, "\(size)")
            XCTAssertLessThan(preview.minY, moved.maxY, "\(size): over the band")
            XCTAssertTrue(lower.contains(StripLayout.panelFrame(band: moved, preview: preview, in: lower)), "\(size)")
        }
    }

    /// The first origin exactly, or within `accuracy` where the arithmetic is not exact.
    private func assertPlacement(count: Int, position: CGFloat, loaded: Bool = false, origin: CGFloat,
                                 accuracy: CGFloat = 0, file: StaticString = #filePath, line: UInt = #line) {
        let placement = StripLayout.placement(metrics, count: count, position: position, oldestIsLoaded: loaded)
        XCTAssertEqual(placement.firstOrigin, origin, accuracy: accuracy, "origin", file: file, line: line)
    }
}
