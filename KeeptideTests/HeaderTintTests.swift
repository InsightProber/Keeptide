import CoreGraphics
import Foundation
import XCTest
@testable import Keeptide

/// The icons here are drawn by the tests: rounded squares on a clear canvas, the way an app icon sits in its image. No
/// real app's icon is read.
final class HeaderTintTests: XCTestCase {
    private let white = HeaderTint.RGB(red: 1, green: 1, blue: 1)

    func testARedIconGivesARedHeaderWithWhiteText() throws {
        let tint = HeaderTint.tint(of: try icon(fill: (0.92, 0.20, 0.18)))

        let band = tint.background
        XCTAssertGreaterThan(band.red, band.green + 0.3, "The band keeps the icon's red")
        XCTAssertGreaterThan(band.red, band.blue + 0.3, "The band keeps the icon's red")
        XCTAssertFalse(tint.usesDarkText)
        XCTAssertEqual(tint.text, white)
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(white, band), 4.5)
        // The smaller line under the title, the time and the marks, reads at 4.5:1 as well.
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(tint.secondaryText(increasedContrast: false), band), 4.5)
    }

    func testAPaleYellowIconGivesDarkText() throws {
        let tint = HeaderTint.tint(of: try icon(fill: (1.0, 0.89, 0.40)))

        let band = tint.background
        XCTAssertGreaterThan(band.green, band.blue + 0.3, "The band stays yellow")
        XCTAssertGreaterThan(band.red, band.blue + 0.3, "The band stays yellow")
        // White would read at less than 4.5:1 on it, so its text is a dark shade of the band's own hue.
        XCTAssertLessThan(HeaderTint.contrastRatio(white, band), 4.5)
        XCTAssertTrue(tint.usesDarkText)
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(tint.text, band), 4.5)
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(tint.secondaryText(increasedContrast: false), band), 4.5)
        XCTAssertGreaterThan(tint.text.red, tint.text.blue, "The dark text is of the yellow family, not grey")
    }

    func testAGreyOrMissingIconGivesTheNeutralHeader() async throws {
        let neutral = HeaderTint.neutral(dark: true)
        XCTAssertEqual(neutral.background, HeaderTint.RGB(red: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255))
        XCTAssertFalse(neutral.usesDarkText)
        let light = HeaderTint.neutral(dark: false)
        XCTAssertEqual(light.background, HeaderTint.RGB(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255))
        // White on the light neutral grey is 3.3:1, so it takes dark text like any other light band.
        XCTAssertTrue(light.usesDarkText)
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(light.text, light.background), 4.5)

        // A grey icon, a pale one, a white one with a sliver of colour, and a canvas with nothing on it have no colour
        // to give: they get the neutral band, as a missing icon does.
        XCTAssertEqual(HeaderTint.tint(of: try icon(fill: (0.55, 0.55, 0.57))), neutral)
        XCTAssertEqual(HeaderTint.tint(of: try icon(fill: (0.10, 0.10, 0.11))), neutral)
        XCTAssertEqual(HeaderTint.tint(of: try icon(fill: (1.0, 0.96, 0.82))), neutral)
        XCTAssertEqual(HeaderTint.tint(of: try icon(fill: (0.97, 0.97, 0.97), stripe: (0.20, 0.50, 1.0), stripeShare: 0.04)),
                       neutral)
        XCTAssertEqual(HeaderTint.tint(of: try icon(fill: nil)), neutral)
        XCTAssertEqual(HeaderTint.tint(of: nil), neutral)
        let missing = await HeaderTint.tint(forIconOf: "test.keeptide.no-icon.\(UUID().uuidString)", loadingIcon: { _ in nil })
        XCTAssertEqual(missing, neutral)
    }

    @MainActor
    func testTheSameIconAlwaysGivesTheSameTint() async throws {
        // Two copies of the same picture, drawn apart, give one tint. The larger colour wins: blue over orange.
        let first = HeaderTint.tint(of: try icon(fill: (0.15, 0.45, 0.95), stripe: (0.98, 0.55, 0.15), stripeShare: 0.3))
        let second = HeaderTint.tint(of: try icon(fill: (0.15, 0.45, 0.95), stripe: (0.98, 0.55, 0.15), stripeShare: 0.3))
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.background.blue, first.background.red + 0.3)
        XCTAssertNotEqual(first, HeaderTint.tint(of: try icon(fill: (0.98, 0.55, 0.15), stripe: (0.15, 0.45, 0.95),
                                                               stripeShare: 0.3)))

        // An app's icon is read once, away from the main thread, and its tint kept by bundle identifier.
        let picture = try icon(fill: (0.15, 0.45, 0.95))
        let loads = LoadLog()
        let app = "test.keeptide.header-tint.\(UUID().uuidString)"
        XCTAssertNil(HeaderTint.cachedTint(forIconOf: app), "Nothing is known before it is worked out")
        let worked = await HeaderTint.tint(forIconOf: app, loadingIcon: { _ in
            loads.record(onMainThread: Thread.isMainThread)
            return picture
        })
        let again = await HeaderTint.tint(forIconOf: app, loadingIcon: { _ in
            loads.record(onMainThread: Thread.isMainThread)
            return picture
        })
        XCTAssertEqual(worked, HeaderTint.tint(of: picture))
        XCTAssertEqual(again, worked)
        XCTAssertEqual(loads.calls, [false], "Read once, off the main thread")
        XCTAssertEqual(HeaderTint.cachedTint(forIconOf: app), worked)
        XCTAssertNil(HeaderTint.cachedTint(forIconOf: nil))
    }

    /// A 64 × 64 icon: a rounded square inset as an app icon is, filled with one colour, with a band of another colour
    /// across `stripeShare` of its height at the top. A nil fill leaves the canvas clear.
    private func icon(fill: (Double, Double, Double)?, stripe: (Double, Double, Double)? = nil,
                      stripeShare: Double = 0) throws -> CGImage {
        let side = 64
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let square = CGRect(x: 6, y: 6, width: 52, height: 52)
        let shape = CGPath(roundedRect: square, cornerWidth: 12, cornerHeight: 12, transform: nil)
        if let fill {
            context.addPath(shape)
            context.setFillColor(CGColor(srgbRed: fill.0, green: fill.1, blue: fill.2, alpha: 1))
            context.fillPath()
        }
        if let stripe {
            context.addPath(shape)
            context.clip()
            let height = square.height * stripeShare
            context.setFillColor(CGColor(srgbRed: stripe.0, green: stripe.1, blue: stripe.2, alpha: 1))
            context.fill(CGRect(x: square.minX, y: square.maxY - height, width: square.width, height: height))
        }
        return try XCTUnwrap(context.makeImage())
    }
}

/// Where each icon load ran, in order.
private final class LoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Bool] = []

    var calls: [Bool] { lock.withLock { log } }

    func record(onMainThread: Bool) {
        lock.withLock { log.append(onMainThread) }
    }
}
