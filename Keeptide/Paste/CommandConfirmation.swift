import Foundation

/// A clip pasted into a terminal as a command: plain text, with one trailing line break removed so that
/// pasting never presses Return. Nothing else in the text is changed.
struct TerminalCommand: Equatable, Sendable {
    /// The plain text without one trailing "\n" or "\r\n". This is what is written to the clipboard.
    let text: String
    /// True when a terminal could run part of `text` as it arrives: a line break is left in it, or a control
    /// character other than a tab, such as U+000F, which runs the current line in bash and zsh.
    let needsConfirmation: Bool
    /// 1 + the line break characters left in `text`.
    let lineCount: Int
    /// `text` with line breaks, tabs and control characters made visible. It is for the confirmation card
    /// only, never for the clipboard.
    let visibleText: String

    nonisolated init(plainText: String) {
        var text = plainText
        // "\r\n" is one Character, so a CRLF goes whole. A lone "\r" stays, because it is what Return sends.
        if text.last == "\n" || text.last == "\r\n" { text.removeLast() }
        let lineBreaks = text.lazy.filter(\.isNewline).count
        self.text = text
        lineCount = 1 + lineBreaks
        needsConfirmation = lineBreaks > 0 || text.unicodeScalars.contains {
            $0 != "\t" && $0.properties.generalCategory == .control
        }
        visibleText = Self.visible(text)
    }

    /// Each Character is checked in this order: a line break, then a tab, then its scalars for controls.
    private nonisolated static func visible(_ text: String) -> String {
        var visible = ""
        for character in text {
            if character.isNewline {
                visible += "↵"
                visible.append(character)
            } else if character == "\t" {
                visible += "⇥"
                visible.append(character)
            } else {
                for scalar in character.unicodeScalars {
                    if scalar.properties.generalCategory == .control {
                        visible += symbol(for: scalar)
                    } else {
                        visible.unicodeScalars.append(scalar)
                    }
                }
            }
        }
        return visible
    }

    /// The control picture of a control scalar, or its code point when it has none.
    private nonisolated static func symbol(for control: Unicode.Scalar) -> String {
        let picture: Unicode.Scalar? = switch control.value {
        case 0x00...0x1F: Unicode.Scalar(0x2400 + control.value)
        case 0x7F: "\u{2421}"
        default: nil
        }
        return picture.map { String($0) } ?? String(format: "⟨U+%04X⟩", control.value)
    }
}
