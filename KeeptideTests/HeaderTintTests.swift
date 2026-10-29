import AppKit
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
        // The smaller line under the title, the time and the marks, reads at 4.5:1 as well; with Increase Contrast it
        // is as strong as the title.
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(tint.secondaryText(increasedContrast: false), band), 4.5)
        XCTAssertEqual(tint.secondaryText(increasedContrast: true), tint.text)
    }

    func testAPaleYellowIconGivesDarkText() throws {
        // #FFF0A0, the light yellow of a note's page.
        let tint = HeaderTint.tint(of: try icon(fill: (1.0, 0.94, 0.63)))

        let band = tint.background
        XCTAssertGreaterThan(band.green, band.blue + 0.3, "The band stays yellow")
        XCTAssertGreaterThan(band.red, band.blue + 0.3, "The band stays yellow")
        // White would read at less than 4.5:1 on it, so its text is a dark shade of the band's own hue.
        XCTAssertLessThan(HeaderTint.contrastRatio(white, band), 4.5)
        XCTAssertTrue(tint.usesDarkText)
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(tint.text, band), 4.5)
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(tint.secondaryText(increasedContrast: false), band), 4.5)
        XCTAssertGreaterThan(tint.text.red, tint.text.blue, "The dark text is of the yellow family, not grey")
        XCTAssertEqual(tint.secondaryText(increasedContrast: true), tint.text)

        // A dark yellow, on which neither white nor the dark text would read, is lightened until the dark text does.
        let olive = (0.55, 0.47, 0.09)
        let lightened = HeaderTint.tint(of: try icon(fill: olive))
        XCTAssertTrue(lightened.usesDarkText)
        XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(lightened.text, lightened.background), 4.5)
        XCTAssertGreaterThan(lightened.background.red + lightened.background.green, olive.0 + olive.1,
                             "The band is lighter than the icon")
    }

    func testOrangesEitherSideOfAmberGetTheSameBurntOrangeBand() throws {
        // #FF9500 and #FF9F0A lie on either side of 36 degrees, a degree and a half apart; both are deepened to a burnt
        // orange that takes white text, nearer the red of the design's #B85410 than an olive or a brown.
        for fill in [(1.0, 0x95 / 255.0, 0.0), (1.0, 0x9F / 255.0, 0x0A / 255.0)] {
            let tint = HeaderTint.tint(of: try icon(fill: fill))
            XCTAssertFalse(tint.usesDarkText, "\(fill)")
            XCTAssertGreaterThanOrEqual(HeaderTint.contrastRatio(white, tint.background), 4.5, "\(fill)")
            XCTAssertEqual(hue(of: tint.background), 28, accuracy: 1, "\(fill)")
        }
        // A real yellow keeps its light band and dark text.
        let yellow = HeaderTint.tint(of: try icon(fill: (1.0, 0.84, 0.04)))
        XCTAssertTrue(yellow.usesDarkText)
        XCTAssertEqual(hue(of: yellow.background), 50, accuracy: 4)
    }

    func testOrangesDeepenAlongTheWheelWithoutAJump() throws {
        // Icons a degree apart from red-orange to amber: their bands' hues never turn back and never jump, so two
        // oranges that look alike get bands that look alike. A degree of the icon is at most a degree of the band, give
        // or take what drawing the icon in 8 bits a channel moves it.
        var previous: Double?
        for degrees in 18...41 {
            let tint = HeaderTint.tint(of: try icon(fill: fullySaturated(hue: Double(degrees))))
            let hue = hue(of: tint.background)
            if let previous {
                XCTAssertGreaterThan(hue, previous - 0.1, "\(degrees)° turns back from \(previous) to \(hue)")
                XCTAssertLessThan(hue - previous, 1.5, "\(degrees)° jumps from \(previous) to \(hue)")
            }
            previous = hue
        }
    }

    func testAGreyOrMissingIconGivesTheNeutralHeader() throws {
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
        let sliver = try icon(fill: (0.97, 0.97, 0.97), stripe: (0.20, 0.50, 1.0), stripeShare: 0.04)
        XCTAssertEqual(HeaderTint.tint(of: sliver), neutral)
        XCTAssertEqual(HeaderTint.tint(of: try icon(fill: nil)), neutral)
        XCTAssertEqual(HeaderTint.tint(of: nil), neutral)
    }

    @MainActor
    func testTheSameIconAlwaysGivesTheSameTint() throws {
        // Two copies of the same picture, drawn apart, give one tint. The larger colour wins: blue over orange.
        let (blueFill, orangeStripe) = ((0.15, 0.45, 0.95), (0.98, 0.55, 0.15))
        let first = HeaderTint.tint(of: try icon(fill: blueFill, stripe: orangeStripe, stripeShare: 0.3))
        let second = HeaderTint.tint(of: try icon(fill: blueFill, stripe: orangeStripe, stripeShare: 0.3))
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.background.blue, first.background.red + 0.3)
        XCTAssertNotEqual(first, HeaderTint.tint(of: try icon(fill: (0.98, 0.55, 0.15), stripe: (0.15, 0.45, 0.95),
                                                               stripeShare: 0.3)))

        // An app's tint comes from the very icon its card shows, worked out once and kept by bundle identifier.
        let blue = NSImage(cgImage: try icon(fill: (0.15, 0.45, 0.95)), size: NSSize(width: 64, height: 64))
        let red = NSImage(cgImage: try icon(fill: (0.92, 0.20, 0.18)), size: NSSize(width: 64, height: 64))
        let app = "test.keeptide.header-tint.\(UUID().uuidString)"
        XCTAssertNil(HeaderTint.cachedTint(forIconOf: app), "Nothing is known before it is worked out")
        let worked = HeaderTint.tint(forIconOf: app, icon: blue)
        XCTAssertGreaterThan(worked.background.blue, worked.background.red + 0.3, "Taken from the blue icon it was given")
        XCTAssertEqual(HeaderTint.cachedTint(forIconOf: app), worked)
        // Once kept, the app's tint stays what it was, whatever icon is passed later.
        XCTAssertEqual(HeaderTint.tint(forIconOf: app, icon: red), worked)
        let redApp = "test.keeptide.header-tint.\(UUID().uuidString)"
        let redTint = HeaderTint.tint(forIconOf: redApp, icon: red)
        XCTAssertGreaterThan(redTint.background.red, redTint.background.blue + 0.3)
        XCTAssertNil(HeaderTint.cachedTint(forIconOf: nil))
    }

    /// Hue in degrees, from 0 up to 360.
    private func hue(of colour: HeaderTint.RGB) -> Double {
        let (r, g, b) = (colour.red, colour.green, colour.blue)
        let high = max(r, g, b), low = min(r, g, b)
        guard high > low else { return 0 }
        let sector = high == r ? (g - b) / (high - low) : high == g ? (b - r) / (high - low) + 2 : (r - g) / (high - low) + 4
        return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The colour of a hue below 60 degrees at full saturation and half lightness: red at full, green rising with the
    /// hue, no blue.
    private func fullySaturated(hue degrees: Double) -> (Double, Double, Double) {
        (1, degrees / 60, 0)
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
