import Foundation

/// Lets one reviewed command through `PasteService`'s confirmation gate, once. The service issues it with each
/// review and keeps it as the session's one pending confirmation. It applies only while the session, the content
/// read, the requested mode and the delivery are all those it was issued for.
struct CommandConfirmation: Equatable, Sendable {
    let id: UUID
    let sessionGeneration: UInt64
    /// The content that was read for the review, version and digest included.
    let ref: ContentRef
    let mode: PasteMode
    let delivery: PasteDelivery
}

/// What the confirmation card shows for a command that needs a review, and the confirmation that lets it through.
struct CommandReview: Equatable, Sendable {
    let confirmation: CommandConfirmation
    let command: TerminalCommand
    /// `<App>` for the session's target.
    let targetName: String?
    /// The request brought a confirmation that no longer applies: it was used or replaced, or the session, the
    /// content, the mode or the delivery changed.
    let isRenewal: Bool
}

/// A clip pasted into a terminal as a command: plain text, with one trailing line break removed so that
/// pasting never presses Return. Nothing else in the text is changed.
struct TerminalCommand: Equatable, Sendable {
    /// The plain text without one trailing "\n" or "\r\n". This is what is written to the clipboard.
    let text: String
    /// True when a terminal could run part of `text` as it arrives, or a reader could be misled about what it
    /// holds: a line break is left in it, or a control or invisible character. That is a control character other
    /// than a tab (U+000F, for one, runs the current line in bash and zsh), a format character such as a
    /// bidirectional override (U+202E) or a zero-width space (U+200B), or any other default-ignorable character,
    /// such as a variation selector (U+FE0F) or a Hangul filler (U+3164). The ZWJ and the variation selector in
    /// an emoji count too.
    let needsConfirmation: Bool
    /// 1 + the line break characters left in `text`.
    let lineCount: Int
    /// `text` with every control and invisible character made visible. It is for the confirmation card only,
    /// never for the clipboard.
    /// - A line break shows as `↵` before itself, a tab as `⇥` before itself.
    /// - A control character in U+0000-U+001F shows as its control picture (ESC as `␛`), U+007F as `␡`.
    /// - Any other control or invisible character shows as `⟨U+XXXX⟩`: its code point in upper-case hex with at
    ///   least four digits, such as `⟨U+202E⟩` and `⟨U+E0100⟩`.
    /// - Two keep an emoji whole and are left as they are: a ZWJ that joins two emoji, and U+FE0E or U+FE0F in
    ///   an emoji.
    let visibleText: String

    nonisolated init(plainText: String) {
        var text = plainText
        // "\r\n" is one Character, so a CRLF goes whole. A lone "\r" stays, because it is what Return sends.
        if text.last == "\n" || text.last == "\r\n" { text.removeLast() }
        let lineBreaks = text.lazy.filter(\.isNewline).count
        self.text = text
        lineCount = 1 + lineBreaks
        needsConfirmation = lineBreaks > 0 || Self.containsControlOrInvisible(text)
        // With nothing to review, the tabs are all there is to show.
        visibleText = needsConfirmation ? Self.visible(text) : text.replacing("\t", with: "⇥\t")
    }

    /// Whether `text` holds a control or invisible character other than a tab. ASCII has neither format nor
    /// default-ignorable characters, so pure ASCII is checked byte by byte without a walk through its scalars.
    private nonisolated static func containsControlOrInvisible(_ text: String) -> Bool {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            return text.utf8.contains { ($0 < 0x20 && $0 != 0x09) || $0 == 0x7F }
        }
        return text.unicodeScalars.contains { $0 != "\t" && isControlOrInvisible($0) }
    }

    /// Control characters, format characters and every other default-ignorable character: what a terminal can act
    /// on, or a reader cannot see.
    private nonisolated static func isControlOrInvisible(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format: return true
        default: return properties.isDefaultIgnorableCodePoint
        }
    }

    /// Each Character is checked in this order: a line break, then a tab, then its scalars.
    private nonisolated static func visible(_ text: String) -> String {
        var shown = ""
        for character in text {
            if character.isNewline {
                shown += "↵"
                shown.append(character)
            } else if character == "\t" {
                shown += "⇥"
                shown.append(character)
            } else if character.unicodeScalars.contains(where: isControlOrInvisible) {
                let scalars = Array(character.unicodeScalars)
                let inEmoji = isEmoji(character)
                for (index, scalar) in scalars.enumerated() {
                    if isControlOrInvisible(scalar),
                       !keepsEmojiWhole(scalar, next: scalars.dropFirst(index + 1).first, inEmoji: inEmoji) {
                        shown += symbol(for: scalar)
                    } else {
                        shown.unicodeScalars.append(scalar)
                    }
                }
            } else {
                shown.append(character)
            }
        }
        return shown
    }

    /// A Character that starts with an emoji scalar. The ASCII digits, "#" and "*" are emoji scalars too, but
    /// they read as text unless they are a keycap, so only a keycap counts.
    private nonisolated static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first, first.properties.isEmoji else { return false }
        return !first.isASCII || character.unicodeScalars.contains("\u{20E3}")
    }

    /// An invisible scalar that `visibleText` leaves as it is, so that an emoji stays whole. `next` is the scalar
    /// after it in the same Character.
    /// - A ZWJ with an emoji after it, as in a family emoji. A skin-tone modifier attaches to anything, even a
    ///   letter, so a ZWJ before one joins nothing; neither does a ZWJ at the end of a Character.
    /// - U+FE0E or U+FE0F in an emoji Character.
    private nonisolated static func keepsEmojiWhole(_ scalar: Unicode.Scalar, next: Unicode.Scalar?,
                                                    inEmoji: Bool) -> Bool {
        switch scalar {
        case "\u{200D}":
            guard let next else { return false }
            return next.properties.isEmoji && !(0x1F3FB...0x1F3FF).contains(next.value)
        case "\u{FE0E}", "\u{FE0F}":
            return inEmoji
        default:
            return false
        }
    }

    /// What `visibleText` shows for a control or invisible scalar: the control picture of U+0000-U+001F and
    /// U+007F, otherwise its code point.
    private nonisolated static func symbol(for scalar: Unicode.Scalar) -> String {
        let picture: Unicode.Scalar? = switch scalar.value {
        case 0x00...0x1F: Unicode.Scalar(0x2400 + scalar.value)
        case 0x7F: "\u{2421}"
        default: nil
        }
        if let picture { return String(picture) }
        let digits = String(scalar.value, radix: 16, uppercase: true)
        return "⟨U+" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "⟩"
    }
}
