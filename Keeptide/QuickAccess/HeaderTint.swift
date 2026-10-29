import AppKit
import os
import SwiftUI

/// The colour band across the top of a card, taken from the icon of the app the clip came from.
///
/// The band is the colour that most of the icon's clearly coloured pixels share, made solid: deep enough for white
/// text to read on it at better than 4.5:1. Oranges are drawn toward red as they deepen, so that they become a burnt
/// orange and not a brown. Yellows stay light instead, since deepened they turn olive, and their text is a dark shade
/// of the same hue. An icon with no colour to speak of (grey, pale, or white with only a touch of colour) gives the
/// dark neutral band, as Terminal's does. The same icon always gives the same band.
struct HeaderTint: Equatable, Sendable {
    /// A colour in sRGB, each component from 0 to 1.
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
    }

    let background: RGB
    /// Whether the band's text is dark, because white on the band would read at less than 4.5:1.
    let usesDarkText: Bool

    /// The colour of the band's title: white, or a dark shade of the band's own hue, such as #2E2300 on a yellow.
    var text: RGB { usesDarkText ? Self.darkShade(of: background) : Self.white }

    /// The colour of the smaller line under the title, the time and the marks, as it shows on the band. As in the
    /// design it lets a little of the band through, but never so much that it reads at less than 4.5:1; with
    /// Increase Contrast it is the title's colour.
    func secondaryText(increasedContrast: Bool) -> RGB {
        guard !increasedContrast else { return text }
        var opacity = usesDarkText ? 0.78 : (Self.hsl(background).saturation < 0.1 ? 0.80 : 0.86)
        while opacity < 1, Self.contrastRatio(Self.blend(text, over: background, opacity: opacity), background) < 4.5 {
            opacity = min(1, opacity + 0.02)
        }
        return Self.blend(text, over: background, opacity: opacity)
    }

    /// The band of a card whose clip has no source app, so no icon to take a colour from: #3A3A3C in dark mode and
    /// #8E8E93 in light mode, each with the text that reads on it.
    static func neutral(dark: Bool) -> HeaderTint {
        banded(dark ? RGB(hex: 0x3A3A3C) : RGB(hex: 0x8E8E93))
    }

    // MARK: From an icon

    /// The icon is sampled at this many pixels a side.
    private static let sampleSide = 32
    /// Hues are counted in this many slices of the colour wheel, 15 degrees each.
    private static let hueSlices = 24
    /// A pixel counts as coloured when its strongest and weakest components lie at least this far apart.
    private static let minimumChroma = 0.25
    /// The share of the icon's opaque pixels the leading colour must cover to be the icon's colour.
    private static let minimumShare = 0.08
    /// Oranges, which are drawn into the burnt oranges below as they deepen, keeping their order. The range starts
    /// where the burnt oranges do, so a hue just below it and one just inside it stay as close as they were.
    private static let oranges = 25.0..<42.0
    private static let burntOranges = 25.0...30.0
    /// Yellows, from where the oranges end to yellow-green, which stay light.
    private static let lightHues = oranges.upperBound...85.0
    /// A band is never lighter than this, nor deepened past the floor below it.
    private static let lightnessRange = 0.25...0.54
    private static let saturationRange = 0.45...0.75

    /// The band for an icon: the mean colour of the coloured pixels whose hues lie within 15 degrees of the most common
    /// hue's slice, with its saturation and lightness held to a band's range. Ties go to the lower hue. Without an
    /// icon, or with too few coloured pixels, it is the dark neutral band.
    static func tint(of icon: CGImage?) -> HeaderTint {
        guard let icon, let pixels = samples(of: icon) else { return neutral(dark: true) }
        var slices = [Int](repeating: 0, count: hueSlices)
        var coloured: [(colour: RGB, slice: Int)] = []
        var opaque = 0
        for (colour, alpha) in pixels where alpha >= 0.5 {
            opaque += 1
            let chroma = max(colour.red, colour.green, colour.blue) - min(colour.red, colour.green, colour.blue)
            guard chroma >= minimumChroma else { continue }
            let slice = Int(hsl(colour).hue / (360 / Double(hueSlices))) % hueSlices
            slices[slice] += 1
            coloured.append((colour, slice))
        }
        func around(_ slice: Int) -> Set<Int> {
            [(slice + hueSlices - 1) % hueSlices, slice, (slice + 1) % hueSlices]
        }
        let peak = (0..<hueSlices).max { first, second in
            around(first).reduce(0) { $0 + slices[$1] } < around(second).reduce(0) { $0 + slices[$1] }
        } ?? 0
        let window = around(peak)
        let members = coloured.filter { window.contains($0.slice) }.map(\.colour)
        guard opaque > 0, Double(members.count) >= minimumShare * Double(opaque) else { return neutral(dark: true) }
        let count = Double(members.count)
        return band(from: RGB(red: members.reduce(0) { $0 + $1.red } / count,
                              green: members.reduce(0) { $0 + $1.green } / count,
                              blue: members.reduce(0) { $0 + $1.blue } / count))
    }

    /// A solid band in the colour's hue. Most hues are deepened until white reads on them at 5:1, a little above the
    /// 4.5:1 asked, for a band of some depth; the smaller line under the title keeps its own 4.5:1 through
    /// `secondaryText`. An orange is first drawn toward red, as the design's burnt orange #B85410 at 25 degrees is,
    /// since deepened as it is it would turn brown. A yellow keeps its lightness and takes dark text, lightened further
    /// if that is what the dark text needs.
    private static func band(from colour: RGB) -> HeaderTint {
        let (iconHue, saturation, lightness) = hsl(colour)
        let hue = oranges.contains(iconHue)
            ? burntOranges.lowerBound + (iconHue - oranges.lowerBound) / (oranges.upperBound - oranges.lowerBound)
                * (burntOranges.upperBound - burntOranges.lowerBound)
            : iconHue
        let s = min(max(saturation, saturationRange.lowerBound), saturationRange.upperBound)
        var l = min(max(lightness, lightnessRange.lowerBound), lightnessRange.upperBound)
        func shade(_ l: Double) -> RGB { rgb(hue: hue, saturation: s, lightness: l) }
        if lightHues.contains(hue) {
            while l < lightnessRange.upperBound, contrastRatio(white, shade(l)) < 4.5,
                  contrastRatio(darkShade(of: shade(l)), shade(l)) < 4.5 {
                l = min(lightnessRange.upperBound, l + 0.01)
            }
        } else {
            while l > lightnessRange.lowerBound, contrastRatio(white, shade(l)) < 5 {
                l = max(lightnessRange.lowerBound, l - 0.01)
            }
        }
        return banded(shade(l))
    }

    private static func banded(_ background: RGB) -> HeaderTint {
        HeaderTint(background: background, usesDarkText: contrastRatio(white, background) < 4.5)
    }

    /// The icon drawn at `sampleSide` pixels a side in sRGB: each pixel's colour, no longer premultiplied, and its
    /// opacity.
    private static func samples(of icon: CGImage) -> [(colour: RGB, alpha: Double)]? {
        let side = sampleSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(icon, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        return (0..<side * side).map { index in
            let alpha = Double(bytes[index * 4 + 3]) / 255
            guard alpha > 0 else { return (RGB(red: 0, green: 0, blue: 0), 0) }
            func component(_ offset: Int) -> Double { min(1, Double(bytes[index * 4 + offset]) / 255 / alpha) }
            return (RGB(red: component(0), green: component(1), blue: component(2)), alpha)
        }
    }

    // MARK: Per app

    /// Tints worked out so far, by bundle identifier.
    private static let tints = OSAllocatedUnfairLock(initialState: [String: HeaderTint]())

    /// The tint already worked out for the app. Nil while it has not been, and for a clip without a source app.
    static func cachedTint(forIconOf bundleIdentifier: String?) -> HeaderTint? {
        guard let bundleIdentifier else { return nil }
        return tints.withLock { $0[bundleIdentifier] }
    }

    /// The app's tint, taken from `icon`, the very image its card shows, when its first card is drawn, and kept by
    /// bundle identifier from then on, whatever icon comes with it later. Drawing the icon at 32 pixels a side takes
    /// about a millisecond on the main actor, once per app, so that no card is drawn neutral first and coloured a
    /// moment later. An app that cannot be found shows the generic app icon, which is grey, so its band is the dark
    /// neutral one. A clip without a source app has no icon to take a colour from: its card draws `neutral(dark:)` in
    /// its own appearance.
    @MainActor
    static func tint(forIconOf bundleIdentifier: String, icon: NSImage) -> HeaderTint {
        if let known = cachedTint(forIconOf: bundleIdentifier) { return known }
        let tint = tint(of: sampled(icon))
        tints.withLock { $0[bundleIdentifier] = tint }
        return tint
    }

    /// `icon` drawn at `sampleSide` pixels a side in sRGB.
    @MainActor
    private static func sampled(_ icon: NSImage) -> CGImage? {
        let side = sampleSide
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        return context.makeImage()
    }

    // MARK: Colour arithmetic

    private static let white = RGB(red: 1, green: 1, blue: 1)

    /// The WCAG 2 contrast ratio of two opaque colours, from 1 to 21.
    static func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ colour: RGB) -> Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
    }

    private static func blend(_ top: RGB, over bottom: RGB, opacity: Double) -> RGB {
        RGB(red: top.red * opacity + bottom.red * (1 - opacity),
            green: top.green * opacity + bottom.green * (1 - opacity),
            blue: top.blue * opacity + bottom.blue * (1 - opacity))
    }

    /// The band's hue at 9 percent lightness, at full saturation unless the band is grey.
    private static func darkShade(of colour: RGB) -> RGB {
        let (hue, saturation, _) = hsl(colour)
        return rgb(hue: hue, saturation: saturation < 0.1 ? saturation : 1, lightness: 0.09)
    }

    /// Hue in degrees from 0 up to 360; saturation and lightness from 0 to 1.
    private static func hsl(_ colour: RGB) -> (hue: Double, saturation: Double, lightness: Double) {
        let (r, g, b) = (colour.red, colour.green, colour.blue)
        let high = max(r, g, b), low = min(r, g, b)
        let lightness = (high + low) / 2
        let chroma = high - low
        guard chroma > 0 else { return (0, 0, lightness) }
        let saturation = chroma / (1 - abs(2 * lightness - 1))
        let sector: Double = if high == r {
            ((g - b) / chroma).truncatingRemainder(dividingBy: 6)
        } else if high == g {
            (b - r) / chroma + 2
        } else {
            (r - g) / chroma + 4
        }
        let hue = sector * 60
        return (hue < 0 ? hue + 360 : hue, min(1, saturation), lightness)
    }

    private static func rgb(hue: Double, saturation: Double, lightness: Double) -> RGB {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let second = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let base = lightness - chroma / 2
        let (r, g, b): (Double, Double, Double) = switch hue {
        case ..<60: (chroma, second, 0)
        case ..<120: (second, chroma, 0)
        case ..<180: (0, chroma, second)
        case ..<240: (0, second, chroma)
        case ..<300: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        return RGB(red: r + base, green: g + base, blue: b + base)
    }
}

extension HeaderTint.RGB {
    /// A colour written as 0xRRGGBB.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}
