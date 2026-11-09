import CoreGraphics

/// Reading a tall image in strips. Vision reads text only down to a size set against the region it reads, so in one
/// pass over a long screenshot it misses much of the text, or all of it, without saying so.
///
/// The strips run top down, each starting at the highest paragraph that the one above didn't hold whole, so that every
/// paragraph comes whole from one strip, joined as the engine joins it. A piece of a line that a strip's top edge cuts
/// is left out, since the strip above holds that line whole. A paragraph taller than a strip comes in parts, each the
/// lines one strip holds whole, kept line by line.
enum StripReading {
    /// The height of a strip in pixels, for an image `width` pixels wide: about square, from 1,200 to 1,800 pixels, so
    /// that text is about as large against a strip as it is against a Mac's or a phone's whole screen.
    static func stripHeight(forWidth width: Int) -> Int {
        min(max(width, 1_200), 1_800)
    }

    /// The strips' height as a fraction of the image's, or nil for an image short enough to read whole.
    static func stripFraction(width: Int, height: Int) -> CGFloat? {
        let strip = stripHeight(forWidth: width)
        guard height > strip + strip / 4 else { return nil }
        return CGFloat(strip) / CGFloat(height)
    }

    /// Reads an image in strips `stripFraction` of its height, top down. `read` recognizes the paragraphs between two
    /// heights of the image, in its normalized coordinates with the origin at the lower left.
    static func read(stripFraction: CGFloat,
                     _ read: (_ bottom: CGFloat, _ top: CGFloat) async throws -> [TextInImage.Paragraph])
        async throws -> [TextInImage.Paragraph] {
        var kept: [TextInImage.Paragraph] = []
        var top: CGFloat = 1
        while true {
            let bottom = max(0, top - stripFraction)
            let found = try await read(bottom, top)
            try Task.checkCancellation()
            // Lines already kept that reach into this strip, whose pieces it may hold.
            let above = kept.flatMap(\.lines).filter { $0.bounds.minY < top }
            let fresh = found.compactMap { leavingOut(above, from: $0) }
            guard bottom > 0 else { return kept + fresh }
            // A paragraph that reaches this low may go on below the strip.
            let edge = bottom + stripFraction * 0.15
            var cut: [TextInImage.Paragraph] = []
            for paragraph in fresh {
                if paragraph.lines.allSatisfy({ $0.bounds.minY >= edge }) { kept.append(paragraph) }
                else { cut.append(paragraph) }
            }
            guard let highest = cut.max(by: { Self.top(of: $0) < Self.top(of: $1) }) else {
                top = edge
                continue
            }
            // The next strip starts half a line above the highest paragraph not held whole.
            let next = Self.top(of: highest) + highest.lines[0].bounds.height / 2
            if next < top - stripFraction * 0.05 {
                top = next
                continue
            }
            // That paragraph starts at this strip's top and goes on past it: keep the lines this strip holds whole,
            // and go on half a line above the last of them.
            let held = highest.lines.filter { $0.bounds.minY >= edge }
            guard let last = held.last else {
                top = edge
                continue
            }
            kept.append(TextInImage.Paragraph(lines: held, transcript: held.map(\.text).joined(separator: "\n")))
            top = last.bounds.minY + last.bounds.height / 2
        }
    }

    private static func top(of paragraph: TextInImage.Paragraph) -> CGFloat {
        paragraph.lines.map(\.bounds.maxY).max() ?? 0
    }

    /// `paragraph` without the pieces of lines already kept. A paragraph that loses some lines is joined line by
    /// line, since its transcript holds them all; one that loses them all is left out.
    private static func leavingOut(_ kept: [TextInImage.Line],
                                   from paragraph: TextInImage.Paragraph) -> TextInImage.Paragraph? {
        let lines = paragraph.lines.filter { line in !kept.contains { overlaps($0.bounds, line.bounds) } }
        if lines.count == paragraph.lines.count { return paragraph }
        guard !lines.isEmpty else { return nil }
        return TextInImage.Paragraph(lines: lines, transcript: lines.map(\.text).joined(separator: "\n"))
    }

    /// Whether two boxes share more than half of the smaller one's height and width.
    private static func overlaps(_ first: CGRect, _ second: CGRect) -> Bool {
        let shared = first.intersection(second)
        guard !shared.isNull else { return false }
        return shared.height > min(first.height, second.height) / 2 && shared.width > min(first.width, second.width) / 2
    }
}
