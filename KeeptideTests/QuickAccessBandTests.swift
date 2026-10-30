import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

/// What the band stands on, as the band view sets it up from SwiftUI's environment: the material in each appearance,
/// and what Reduce Transparency and Increase Contrast make of it.
@MainActor
final class QuickAccessBandTests: XCTestCase {
    func testTheBackdropTakesTheSwitchersMaterialInEachAppearance() throws {
        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false)
        // Dark: a HUD's material behind the window, with a hairline edge and no solid fill.
        window.appearance = NSAppearance(named: .darkAqua)
        settle(window)
        XCTAssertEqual(backdrop.material.material, .hudWindow)
        XCTAssertEqual(backdrop.material.blendingMode, .behindWindow)
        XCTAssertEqual(backdrop.material.state, .active)
        XCTAssertFalse(backdrop.material.isHidden)
        XCTAssertFalse(backdrop.surface.isSolid)
        XCTAssertEqual(backdrop.surface.edgeWidth, 0.5)
        XCTAssertNotNil(backdrop.material.maskImage, "The material is cut to the band's rounded shape")

        // A change of appearance restyles it: light takes a popover's light material.
        window.appearance = NSAppearance(named: .aqua)
        settle(window)
        XCTAssertEqual(backdrop.material.material, .popover)
        XCTAssertFalse(backdrop.material.isHidden)
    }

    func testReduceTransparencyMakesTheBandSolid() throws {
        let (window, backdrop) = try host(reducesTransparency: true, increasedContrast: false)
        window.appearance = NSAppearance(named: .darkAqua)
        settle(window)
        XCTAssertTrue(backdrop.material.isHidden)
        XCTAssertTrue(backdrop.surface.isSolid)
        XCTAssertEqual(backdrop.surface.edgeWidth, 0.5)
    }

    func testIncreaseContrastWidensTheEdge() throws {
        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: true)
        window.appearance = NSAppearance(named: .aqua)
        settle(window)
        XCTAssertEqual(backdrop.surface.edgeWidth, 1)
        XCTAssertFalse(backdrop.material.isHidden)
        XCTAssertFalse(backdrop.surface.isSolid)
    }

    func testTheSectionLabelsLieInTheGapBetweenTheToolbarAndTheCards() throws {
        let strip = QuickAccessStripView()
        let (window, backdrop) = try host(reducesTransparency: false, increasedContrast: false, strip: strip)

        // As wide as the band, in the 20 pt between the toolbar and the cards.
        let band = backdrop.convert(backdrop.bandRect, to: nil)
        let labels = strip.sectionLabels.convert(strip.sectionLabels.bounds, to: nil)
        XCTAssertEqual(labels.minX, band.minX, accuracy: 0.5)
        XCTAssertEqual(labels.width, band.width, accuracy: 0.5)
        XCTAssertEqual(labels.height, StripLayout.toolbarGap, accuracy: 0.5)
        XCTAssertEqual(band.maxY - labels.maxY, StripLayout.toolbarTop + StripLayout.toolbarHeight, accuracy: 0.5)
        // They take no clicks: just above the cards the pointer finds the strip beneath them.
        let aboveTheCards = NSPoint(x: band.midX, y: band.maxY - StripLayout.cardTop + 4)
        XCTAssertTrue(labels.contains(aboveTheCards))
        XCTAssertTrue(window.contentView?.hitTest(aboveTheCards) === strip)
    }

    /// The band view with medium cards and nothing to show, in a window that is never shown, with the two settings
    /// given through SwiftUI's environment as the system would give them; and the backdrop it made.
    private func host(
        reducesTransparency: Bool, increasedContrast: Bool, strip: QuickAccessStripView = QuickAccessStripView()
    ) throws -> (NSWindow, QuickAccessBandBackdrop) {
        let metrics = StripLayout.metrics(for: .medium, visibleWidth: 1440)
        let band = QuickAccessBandView(
            layout: QuickAccessBandView.Layout(metrics: metrics, previewSize: nil,
                                               roomBelow: StripLayout.shadowRoom.below),
            state: QuickAccessState(services: { nil }), toolbar: QuickAccessToolbar(field: QuickAccessSearchField()),
            strip: strip, applicationNames: ApplicationNames(),
            actions: QuickAccessBandView.Actions(previewCommand: { _ in }, confirmCommand: {}, cancelCommandReview: {})
        )
        let root = band
            .environment(\._accessibilityReduceTransparency, reducesTransparency)
            .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard)
        let size = NSSize(width: metrics.bandWidth + 2 * StripLayout.sideMargin,
                          height: StripLayout.bandHeight(metrics) + StripLayout.shadowRoom.above
                              + StripLayout.shadowRoom.below)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
        settle(window)
        let backdrop = try XCTUnwrap(backdrops(in: hosting).first)
        return (window, backdrop)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func backdrops(in view: NSView) -> [QuickAccessBandBackdrop] {
        ((view as? QuickAccessBandBackdrop).map { [$0] } ?? []) + view.subviews.flatMap { backdrops(in: $0) }
    }
}
