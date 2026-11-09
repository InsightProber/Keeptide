import CoreGraphics
import Foundation

/// The text found in an image, as an engine reads it: paragraphs in reading order, each made of lines that know where
/// they are in the image. It lays the text out in one of two ways, and a result keeps the one it was made with:
/// - keeping line breaks, line by line as in the image;
/// - joining lines, each paragraph as running text, which is also what a translation reads.
///
/// Both put a blank line between two parts only where the image sets them apart: by more space than its lines
/// usually have between them, or by putting the next part in another column. A part that follows on the same row,
/// as a table's cells do, or as the next line down, as the second line of a short paragraph does when an engine
/// makes it a paragraph of its own, is only a line break away.
struct TextInImage: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var text: String
        /// Where the line is, normalized to the image with the origin at the lower left, as Vision gives it.
        var bounds: CGRect
    }

    struct Paragraph: Equatable, Sendable {
        var lines: [Line]
        /// The paragraph's lines as running text, as the engine joined them: a word hyphenated across two lines is
        /// whole again, lines of Chinese or Japanese join without a space, and a line that stands on its own, such as
        /// a list item, keeps its break.
        var transcript: String
    }

    var paragraphs: [Paragraph]

    func text(keepingLineBreaks: Bool) -> String {
        let parts = paragraphs.compactMap(Part.init)
        let spacing = Spacing(parts)
        var text = ""
        // The last line placed, which the next part is measured against.
        var previous: Line?
        for part in parts {
            let body = keepingLineBreaks ? part.lines.map(\.text).joined(separator: "\n") : part.transcript
            guard !body.isEmpty else { continue }
            if let previous { text += spacing.separator(after: previous.bounds, before: part.lines[0].bounds) }
            text += body
            previous = part.lines.last
        }
        return text
    }
}

/// A paragraph without its blank lines, trimmed. A paragraph with no text in its lines is left out.
private struct Part {
    let lines: [TextInImage.Line]
    let transcript: String

    init?(_ paragraph: TextInImage.Paragraph) {
        lines = paragraph.lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TextInImage.Line(text: text, bounds: line.bounds)
        }
        guard !lines.isEmpty else { return nil }
        transcript = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How far apart this image's lines usually are. Boxes follow the letters, from ascenders or the height of a small
/// letter down to descenders or the baseline, so the space between two boxes says little; the distance between their
/// middles, against the image's usual distance, tells the space between two paragraphs from the spacing of the lines.
private struct Spacing {
    /// The usual distance between the middles of a line and the next one down: within paragraphs of more than one
    /// line where there are any, since a paragraph's lines are evenly spaced, and otherwise between paragraphs.
    let pitch: CGFloat?
    /// The usual height of a line's box.
    let lineHeight: CGFloat

    init(_ parts: [Part]) {
        lineHeight = Self.median(parts.flatMap { $0.lines.map(\.bounds.height) }) ?? 0
        let within = parts.flatMap { part in
            zip(part.lines, part.lines.dropFirst()).compactMap { Self.pitch(from: $0.bounds, to: $1.bounds) }
        }
        let between = zip(parts, parts.dropFirst()).compactMap { earlier, later in
            earlier.lines.last.flatMap { Self.pitch(from: $0.bounds, to: later.lines[0].bounds) }
        }
        pitch = Self.median(within.isEmpty ? between : within)
    }

    /// A line break between a line and one on the same row, or the next line down; a blank line when the next part
    /// is farther down than lines usually are, or in another column.
    func separator(after earlier: CGRect, before later: CGRect) -> String {
        if Self.overlap(earlier, later) > min(earlier.height, later.height) / 2 { return "\n" }
        guard let distance = Self.pitch(from: earlier, to: later) else { return "\n\n" }
        // Lines in a paragraph vary by about a sixth of their spacing with their letters; the space between paragraphs
        // adds half a line or more. Without any lines to compare with, about twice a line's height apart is a gap.
        let limit = pitch.map { $0 * 1.4 } ?? lineHeight * 2.2
        return distance > limit ? "\n\n" : "\n"
    }

    /// How far the middle of `later` is below the middle of `earlier`, when `later` is the next line down in the same
    /// column: below it rather than on its row, and overlapping it from side to side. Nil otherwise.
    static func pitch(from earlier: CGRect, to later: CGRect) -> CGFloat? {
        guard overlap(earlier, later) <= min(earlier.height, later.height) / 2, later.midY < earlier.midY,
              min(earlier.maxX, later.maxX) > max(earlier.minX, later.minX) else { return nil }
        return earlier.midY - later.midY
    }

    /// How much two boxes share from top to bottom; negative when there is space between them.
    static func overlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        min(first.maxY, second.maxY) - max(first.minY, second.minY)
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
