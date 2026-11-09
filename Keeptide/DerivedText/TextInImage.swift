import CoreGraphics
import Foundation

/// The text found in an image, as an engine reads it: paragraphs in reading order, each made of lines that know where
/// they are in the image. It lays the text out in one of two ways, and a result keeps the one it was made with:
/// - keeping line breaks, line by line as in the image;
/// - joining lines, each paragraph as running text, which is also what a translation reads.
///
/// Both put a blank line between two parts only where the image has space between them, or where the next part is
/// in another column. A part that follows on the same row, as a table's cells do, or right below, as the second line
/// of a short paragraph does when an engine makes it a paragraph of its own, is only a line break away.
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
        var text = ""
        // The last line placed, which the next part is measured against.
        var previous: CGRect?
        for paragraph in paragraphs {
            let lines = paragraph.lines.compactMap { line -> Line? in
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Line(text: trimmed, bounds: line.bounds)
            }
            guard let first = lines.first, let last = lines.last else { continue }
            let part = keepingLineBreaks
                ? lines.map(\.text).joined(separator: "\n")
                : paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let previous { text += Self.separator(after: previous, before: first.bounds) }
            text += part
            previous = last.bounds
        }
        return text
    }

    /// A line break between two lines on the same row, or between a line and the one right below it, with no more
    /// space between them than half a line; a blank line otherwise.
    private static func separator(after earlier: CGRect, before later: CGRect) -> String {
        let height = min(earlier.height, later.height)
        let overlap = min(earlier.maxY, later.maxY) - max(earlier.minY, later.minY)
        if overlap > height / 2 { return "\n" }
        let space = earlier.minY - later.maxY
        return space >= -height / 2 && space <= height / 2 ? "\n" : "\n\n"
    }
}
