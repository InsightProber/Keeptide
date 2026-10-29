import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class TerminalCommandTests: XCTestCase {
    func testOnlyOneTrailingLineBreakIsRemoved() {
        // CRLF is one Character, so it goes whole.
        for input in ["ls\n", "ls\r\n", "ls"] {
            let command = TerminalCommand(plainText: input)
            XCTAssertEqual(command.text, "ls", input.debugDescription)
            XCTAssertFalse(command.needsConfirmation, input.debugDescription)
            XCTAssertEqual(command.lineCount, 1, input.debugDescription)
        }
        // A second break is not removed, and it is a line break the user has to review.
        for (input, left) in [("ls\n\n", "ls\n"), ("ls\r\n\r\n", "ls\r\n"), ("ls\n\r\n", "ls\n")] {
            let command = TerminalCommand(plainText: input)
            XCTAssertEqual(command.text, left, input.debugDescription)
            XCTAssertTrue(command.needsConfirmation, input.debugDescription)
            XCTAssertEqual(command.lineCount, 2, input.debugDescription)
        }
        // Only "\n" and "\r\n" count as the trailing break. A lone CR is what Return sends, so it stays,
        // and so do LF CR and the Unicode separators.
        for input in ["ls\r", "ls\n\r", "ls\u{2028}", "ls\u{2029}", "ls\u{85}"] {
            let command = TerminalCommand(plainText: input)
            XCTAssertEqual(Array(command.text.utf8), Array(input.utf8), input.debugDescription)
            XCTAssertTrue(command.needsConfirmation, input.debugDescription)
            XCTAssertGreaterThan(command.lineCount, 1, input.debugDescription)
        }
        // A command that is nothing but its line break is empty, and an empty one stays empty.
        for input in ["\n", "\r\n", ""] {
            let command = TerminalCommand(plainText: input)
            XCTAssertEqual(command.text, "", input.debugDescription)
            XCTAssertFalse(command.needsConfirmation, input.debugDescription)
            XCTAssertEqual(command.lineCount, 1, input.debugDescription)
        }
        // Nothing else is rewritten, byte for byte: spaces, quotes, paths, tabs, composed and decomposed text.
        let untouched = ["  ls -la  ", "cd '/Users/Synthetic/My Folder' && ls \"$HOME\"",
                         "\techo\t中文  ", "e\u{301}cho \u{E9}"]
        for input in untouched {
            for suffix in ["", "\n"] {
                let command = TerminalCommand(plainText: input + suffix)
                XCTAssertEqual(Array(command.text.utf8), Array(input.utf8), input.debugDescription)
            }
        }
    }

    func testInnerLineBreaksNeedConfirmation() {
        let script = TerminalCommand(plainText: "set -e\necho synthetic-gamma\n")
        XCTAssertEqual(script.text, "set -e\necho synthetic-gamma")
        XCTAssertTrue(script.needsConfirmation)
        XCTAssertEqual(script.lineCount, 2)
        // Every Character.isNewline counts as one break: a lone CR, VT, FF, NEL and the Unicode separators.
        // CRLF is one Character, so it is one break.
        for lineBreak in ["\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let command = TerminalCommand(plainText: "a\(lineBreak)b")
            XCTAssertTrue(command.needsConfirmation, lineBreak.debugDescription)
            XCTAssertEqual(command.lineCount, 2, lineBreak.debugDescription)
        }
        XCTAssertTrue(TerminalCommand(plainText: "a\rb").needsConfirmation)
        XCTAssertTrue(TerminalCommand(plainText: "a\u{2028}b").needsConfirmation)
        XCTAssertEqual(TerminalCommand(plainText: "a\nb\r\nc\rd\u{2028}e\n").lineCount, 5)
    }

    func testControlCharactersAndOtherBreaksNeedConfirmation() {
        // U+000F runs the current line in bash and zsh, and ESC [ 201 ~ ends a bracketed paste early.
        for input in ["echo hi\u{0F}", "echo \u{1B}[201~"] {
            let command = TerminalCommand(plainText: input)
            XCTAssertTrue(command.needsConfirmation, input.debugDescription)
            XCTAssertEqual(command.lineCount, 1, input.debugDescription)
            XCTAssertEqual(command.text, input)
        }
        let tab = TerminalCommand(plainText: "printf 'a\tb'")
        XCTAssertFalse(tab.needsConfirmation)
        XCTAssertEqual(tab.lineCount, 1)
        // Every other C0 and C1 control character needs it. Only the line breaks among them add a line.
        let lineBreaks: Set<UInt8> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85]
        for value in Array(UInt8(0x00)...0x1F) + Array(UInt8(0x7F)...0x9F) where value != 0x09 {
            let input = "a" + String(Unicode.Scalar(value)) + "b"
            let command = TerminalCommand(plainText: input)
            XCTAssertTrue(command.needsConfirmation, input.debugDescription)
            XCTAssertEqual(command.lineCount, lineBreaks.contains(value) ? 2 : 1, input.debugDescription)
        }
        // Printable ASCII, CJK, emoji, flags and combining sequences are neither controls nor format characters.
        let printable = String((UInt8(0x20)...0x7E).map { Character(Unicode.Scalar($0)) })
        for input in [printable, "echo 你好 \u{1F600} e\u{301} \u{1F1E8}\u{1F1F3}"] {
            let command = TerminalCommand(plainText: input + "\n")
            XCTAssertFalse(command.needsConfirmation, input.debugDescription)
            XCTAssertEqual(command.lineCount, 1, input.debugDescription)
        }
        // Format characters (category Cf) are invisible, so a command can look harmless and run something else.
        // Each one needs a review, like a control character: bidirectional overrides, embeddings and isolates,
        // direction marks, zero-width characters, a BOM in the middle of the text, a soft hyphen and a tag character.
        let formats = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}",
                       "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}", "\u{200B}", "\u{200C}", "\u{200D}",
                       "\u{2060}", "\u{FEFF}", "\u{AD}", "\u{E0041}"]
        for format in formats {
            let middle = "echo a" + format + "b"
            for input in [middle, format + "ls", "ls" + format + "\n"] {
                let command = TerminalCommand(plainText: input)
                XCTAssertTrue(command.needsConfirmation, input.debugDescription)
                XCTAssertEqual(command.lineCount, 1, input.debugDescription)
            }
            XCTAssertEqual(Array(TerminalCommand(plainText: middle).text.utf8), Array(middle.utf8))
        }
        // That includes a ZWJ inside an emoji sequence: a terminal command rarely holds emoji.
        XCTAssertTrue(TerminalCommand(plainText: "\u{1F468}\u{200D}\u{1F469}").needsConfirmation)
    }

    func testVisibleTextShowsBreaksTabsAndControls() {
        let command = TerminalCommand(plainText: "a\tb\nc\u{1B}\u{7F}\u{85}d\n")
        XCTAssertEqual(command.visibleText, "a⇥\tb↵\nc␛␡↵\u{85}d")
        // The display never changes what is written.
        XCTAssertEqual(command.text, "a\tb\nc\u{1B}\u{7F}\u{85}d")
        // A break is one symbol before itself, whatever its length: CRLF, a lone CR and U+2028 included.
        XCTAssertEqual(TerminalCommand(plainText: "a\r\nb\rc\u{2028}d").visibleText, "a↵\r\nb↵\rc↵\u{2028}d")
        // The other U+0000-U+001F characters become the control picture U+2400 plus their value.
        XCTAssertEqual(TerminalCommand(plainText: "\u{00}\u{01}\u{0F}\u{1F}").visibleText,
                       "\u{2400}\u{2401}\u{240F}\u{241F}")
        // The other control characters show their code point.
        XCTAssertEqual(TerminalCommand(plainText: "\u{80}\u{9F}").visibleText, "⟨U+0080⟩⟨U+009F⟩")
        // Text with nothing to show is unchanged, and the one trailing break never gets a symbol.
        XCTAssertEqual(TerminalCommand(plainText: "echo 你好 e\u{301}\n").visibleText, "echo 你好 e\u{301}")
        // Format characters are invisible, so each shows its code point: upper-case hex, at least four digits.
        let tokens = [("\u{202E}", "⟨U+202E⟩"), ("\u{200B}", "⟨U+200B⟩"), ("\u{200C}", "⟨U+200C⟩"),
                      ("\u{FEFF}", "⟨U+FEFF⟩"), ("\u{AD}", "⟨U+00AD⟩"), ("\u{E0041}", "⟨U+E0041⟩")]
        for (format, token) in tokens {
            XCTAssertEqual(TerminalCommand(plainText: "a" + format + "b").visibleText, "a" + token + "b", token)
        }
        // A ZWJ that joins emoji is part of the emoji, so it stays and the emoji stays whole. It is still a
        // format character, so the command needs a review.
        let family = TerminalCommand(plainText: "家庭\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\n")
        XCTAssertEqual(family.text.count, 3, "two ideographs and one emoji Character")
        XCTAssertTrue(family.needsConfirmation)
        XCTAssertEqual(Array(family.visibleText.unicodeScalars), Array(family.text.unicodeScalars))
        let nurse = TerminalCommand(plainText: "\u{1F469}\u{1F3FD}\u{200D}\u{2695}\u{FE0F}")
        XCTAssertEqual(Array(nurse.visibleText.unicodeScalars), Array(nurse.text.unicodeScalars))
        // Every other format character is shown, even where it sits in a Character with an emoji: a ZWJ after a
        // digit or a letter, a ZWJ with no emoji after it, a ZWNJ, and a prepended mark that joins the emoji.
        XCTAssertEqual(TerminalCommand(plainText: "1\u{200D}2").visibleText, "1⟨U+200D⟩2")
        XCTAssertEqual(TerminalCommand(plainText: "a\u{200D}b\u{1F468}\u{200D}").visibleText,
                       "a⟨U+200D⟩b\u{1F468}⟨U+200D⟩")
        XCTAssertEqual(TerminalCommand(plainText: "\u{1F600}\u{200C}").visibleText, "\u{1F600}⟨U+200C⟩")
        XCTAssertEqual(TerminalCommand(plainText: "\u{600}\u{1F600}").visibleText, "⟨U+0600⟩\u{1F600}")
        // A ZWJ inside a script's conjunct is not an emoji ZWJ.
        XCTAssertEqual(TerminalCommand(plainText: "\u{915}\u{94D}\u{200D}\u{937}").visibleText,
                       "\u{915}\u{94D}⟨U+200D⟩\u{937}")
        // A command that needs no review still shows its tabs, in ASCII and in any other text.
        XCTAssertEqual(TerminalCommand(plainText: "printf 'a\tb'\n").visibleText, "printf 'a⇥\tb'")
        XCTAssertEqual(TerminalCommand(plainText: "\techo\t中文").visibleText, "⇥\techo⇥\t中文")
    }

    func testInvisibleCharactersNeedConfirmationAndShowTheirCodePoint() {
        // Every default-ignorable character is invisible, whatever its category, so it can hide in a word or a
        // file name: variation selectors, Hangul fillers, the combining grapheme joiner, Mongolian free variation
        // selectors and Khmer inherent vowels.
        let invisible = [("\u{FE0F}", "⟨U+FE0F⟩"), ("\u{FE0E}", "⟨U+FE0E⟩"), ("\u{FE00}", "⟨U+FE00⟩"),
                         ("\u{E0100}", "⟨U+E0100⟩"), ("\u{3164}", "⟨U+3164⟩"), ("\u{FFA0}", "⟨U+FFA0⟩"),
                         ("\u{34F}", "⟨U+034F⟩"), ("\u{180B}", "⟨U+180B⟩"), ("\u{17B4}", "⟨U+17B4⟩")]
        for (scalar, token) in invisible {
            let command = TerminalCommand(plainText: "echo a" + scalar + "b\n")
            XCTAssertTrue(command.needsConfirmation, token)
            XCTAssertEqual(command.lineCount, 1, token)
            XCTAssertEqual(command.visibleText, "echo a" + token + "b", token)
            XCTAssertEqual(Array(command.text.unicodeScalars), Array(("echo a" + scalar + "b").unicodeScalars), token)
        }
    }

    func testEmojiStayWholeButStillNeedConfirmation() {
        // A ZWJ that joins two emoji, and U+FE0E or U+FE0F in an emoji, are left as they are so that the emoji
        // stays whole. They are still invisible, so the command needs a review.
        for emoji in ["\u{1F469}\u{200D}\u{1F4BB}", "\u{2764}\u{FE0F}", "\u{1F600}\u{FE0E}", "1\u{FE0F}\u{20E3}"] {
            let command = TerminalCommand(plainText: "echo " + emoji + "\n")
            XCTAssertTrue(command.needsConfirmation, emoji.debugDescription)
            XCTAssertEqual(Array(command.visibleText.unicodeScalars), Array(("echo " + emoji).unicodeScalars),
                           emoji.debugDescription)
        }
        // A skin-tone modifier attaches to whatever comes before it, so a ZWJ before one joins nothing and shows.
        XCTAssertEqual(TerminalCommand(plainText: "a\u{200D}\u{1F3FB}").visibleText, "a⟨U+200D⟩\u{1F3FB}")
        XCTAssertEqual(TerminalCommand(plainText: "\u{1F469}\u{200D}\u{1F3FB}").visibleText,
                       "\u{1F469}⟨U+200D⟩\u{1F3FB}")
        // Any other variation selector shows, even in an emoji.
        XCTAssertEqual(TerminalCommand(plainText: "\u{2764}\u{FE00}").visibleText, "\u{2764}⟨U+FE00⟩")
        // A digit is an emoji only in a keycap, so a selector after a digit in a word shows.
        XCTAssertEqual(TerminalCommand(plainText: "cd build1\u{FE0F}").visibleText, "cd build1⟨U+FE0F⟩")
        // An emoji with nothing invisible in it needs no review.
        XCTAssertFalse(TerminalCommand(plainText: "echo \u{1F600}\u{1F44B}\u{1F3FB}\n").needsConfirmation)
    }

    func testPrepareCommandWritesOnlyTheCommandText() throws {
        let board = makeBoard()
        let rtf = Data("{\\rtf1\\ansi echo x}".utf8)
        let rich = try content([[("public.rtf", rtf), ("public.utf8-plain-text", Data("echo x\n".utf8))]])

        let (prepared, command) = try PasteboardWriter.prepareCommand(rich)
        let token = try PasteboardWriter(pasteboard: board).write(prepared)

        XCTAssertEqual(command, TerminalCommand(plainText: "echo x\n"))
        XCTAssertEqual(command.text, "echo x")
        XCTAssertFalse(command.needsConfirmation)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        let item = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertEqual(item.types.map(\.rawValue).filter { $0 != OwnWriteToken.typeIdentifier },
                       ["public.utf8-plain-text"])
        XCTAssertEqual(item.data(forType: .init("public.utf8-plain-text")), Data("echo x".utf8))
        XCTAssertTrue(token.matches(pasteboard: board))

        // The board gets the text itself. The visible symbols are for the confirmation card only.
        let raw = "a\tb\nc\u{1B}d\r\n"
        let (preparedRaw, rawCommand) = try PasteboardWriter.prepareCommand(
            content([[("public.utf8-plain-text", Data(raw.utf8))]]))
        _ = try PasteboardWriter(pasteboard: board).write(preparedRaw)
        XCTAssertTrue(rawCommand.needsConfirmation)
        XCTAssertEqual(rawCommand.lineCount, 2)
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.pasteboardItems?.first?.data(forType: .init("public.utf8-plain-text")),
                       Data("a\tb\nc\u{1B}d".utf8))

        // The decoder drops a leading BOM only. A U+FEFF in the middle of the text reaches the command as a
        // format character, so it is kept and the command needs a review.
        let (preparedBOM, bomCommand) = try PasteboardWriter.prepareCommand(
            content([[("public.utf8-plain-text", Data("echo \u{FEFF}x\n".utf8))]]))
        _ = try PasteboardWriter(pasteboard: board).write(preparedBOM)
        XCTAssertEqual(Array(bomCommand.text.utf8), Array("echo \u{FEFF}x".utf8))
        XCTAssertTrue(bomCommand.needsConfirmation)
        XCTAssertEqual(board.pasteboardItems?.first?.data(forType: .init("public.utf8-plain-text")),
                       Data("echo \u{FEFF}x".utf8))

        // Several items become one command, and the line between them needs a review.
        let joined = try PasteboardWriter.prepareCommand(content([
            [("public.utf8-plain-text", Data("first\n".utf8))],
            [("public.utf8-plain-text", Data("second\n".utf8))],
        ])).1
        XCTAssertEqual(joined.text, "first\n\nsecond")
        XCTAssertTrue(joined.needsConfirmation)
        XCTAssertEqual(joined.lineCount, 3)

        // Without text, or with nothing left after the line break, there is no command.
        assertRefused(try content([[("public.utf8-plain-text", Data("\n".utf8))]]), .noPlainText)
        assertRefused(try content([[("public.utf8-plain-text", Data("\r\n".utf8))]]), .noPlainText)
        assertRefused(try content([[("public.png", Data([0x89, 0x50, 0x4E, 0x47]))]]), .noPlainText)
        // The rest of preparePlainText's rules and errors apply.
        let tampered = rich.representations.map { value -> RepresentationValue in
            var value = value
            if value.typeIdentifier == "public.utf8-plain-text" { value.digest = Data(repeating: 0, count: 32) }
            return value
        }
        assertRefused(ResolvedContent(ref: rich.ref, integrity: .complete, representations: tampered),
                      .invalidRepresentationBytes(itemIndex: 0, representationIndex: 1))
        assertRefused(ResolvedContent(ref: rich.ref, integrity: .corrupt, representations: rich.representations),
                      .nonActionableContent)
    }

    private func assertRefused(_ content: ResolvedContent, _ expected: PasteboardWriterError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PasteboardWriter.prepareCommand(content), file: file, line: line) { error in
            XCTAssertEqual(error as? PasteboardWriterError, expected, file: file, line: line)
        }
    }

    private func content(_ items: [[(String, Data)]]) throws -> ResolvedContent {
        let capture = try ContentStoreFixtures.capture(items)
        let item = ContentStoreFixtures.item(capture)
        return ResolvedContent(ref: ContentStoreFixtures.ref(item, capture), integrity: .complete,
                               representations: capture.representations)
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        return board
    }
}
