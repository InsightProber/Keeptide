import Foundation

/// A clip pasted into a terminal as a command: plain text, with one trailing line break removed so that
/// pasting never presses Return. Nothing else in the text is changed.
struct TerminalCommand: Equatable, Sendable {
    /// The plain text without one trailing "\n" or "\r\n". This is what is written to the clipboard.
    let text: String
    /// True when a terminal could run part of `text` as it arrives, or a reader could be misled about what it
    /// holds: a line break is left in it, a control character other than a tab (U+000F, for one, runs the
    /// current line in bash and zsh), or a format character, category Cf, such as a bidirectional override
    /// (U+202E) or a zero-width character (U+200B, U+FEFF). A ZWJ inside an emoji is a format character too.
    let needsConfirmation: Bool
    /// 1 + the line break characters left in `text`.
    let lineCount: Int
    /// `text` with everything a reader could not see made visible. It is for the confirmation card only,
    /// never for the clipboard.
    /// - A line break shows as `↵` before itself, a tab as `⇥` before itself.
    /// - A control character in U+0000-U+001F shows as its control picture (ESC as `␛`), U+007F as `␡`.
    /// - Any other control character, and every format character, shows as `⟨U+XXXX⟩`: its code point in
    ///   upper-case hex with at least four digits, such as `⟨U+202E⟩` and `⟨U+E0041⟩`.
    /// - A ZWJ inside an emoji sequence is part of the emoji, so it is left as it is and the emoji stays whole.
    let visibleText: String

    nonisolated init(plainText: String) {
        var text = plainText
        // "\r\n" is one Character, so a CRLF goes whole. A lone "\r" stays, because it is what Return sends.
        if text.last == "\n" || text.last == "\r\n" { text.removeLast() }
        let lineBreaks = text.lazy.filter(\.isNewline).count
        self.text = text
        lineCount = 1 + lineBreaks
        needsConfirmation = lineBreaks > 0 || text.unicodeScalars.contains {
            $0 != "\t" && Self.isControlOrFormat($0)
        }
        visibleText = Self.visible(text)
    }

    /// Controls and format characters: what a terminal can act on, or a reader cannot see.
    private nonisolated static func isControlOrFormat(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format: true
        default: false
        }
    }

    /// Each Character is checked in this order: a line break, then a tab, then its scalars.
    private nonisolated static func visible(_ text: String) -> String {
        var visible = ""
        for character in text {
            if character.isNewline {
                visible += "↵"
                visible.append(character)
            } else if character == "\t" {
                visible += "⇥"
                visible.append(character)
            } else if character.unicodeScalars.contains(where: isControlOrFormat) {
                let scalars = Array(character.unicodeScalars)
                for (index, scalar) in scalars.enumerated() {
                    if isControlOrFormat(scalar), !joinsEmoji(scalar, next: scalars.dropFirst(index + 1).first) {
                        visible += symbol(for: scalar)
                    } else {
                        visible.unicodeScalars.append(scalar)
                    }
                }
            } else {
                visible.append(character)
            }
        }
        return visible
    }

    /// A ZWJ that glues emoji together, as in a family emoji. `next` is the scalar after it in the same
    /// Character. A ZWJ with no emoji after it, at the end of a Character or after a digit or a letter, joins
    /// nothing, so `visibleText` shows it.
    private nonisolated static func joinsEmoji(_ scalar: Unicode.Scalar, next: Unicode.Scalar?) -> Bool {
        scalar == "\u{200D}" && next?.properties.isEmoji == true
    }

    /// What `visibleText` shows for a control or format scalar: the control picture of U+0000-U+001F and
    /// U+007F, otherwise its code point.
    private nonisolated static func symbol(for scalar: Unicode.Scalar) -> String {
        let picture: Unicode.Scalar? = switch scalar.value {
        case 0x00...0x1F: Unicode.Scalar(0x2400 + scalar.value)
        case 0x7F: "\u{2421}"
        default: nil
        }
        return picture.map { String($0) } ?? String(format: "⟨U+%04X⟩", scalar.value)
    }
}
