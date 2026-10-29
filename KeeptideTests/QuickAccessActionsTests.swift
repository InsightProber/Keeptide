import XCTest
@testable import Keeptide

/// What quick access offers for the selected clip, and what it says when an action ends, word for word.
@MainActor
final class QuickAccessActionsTests: XCTestCase {
    private static let kinds: [ContentKind?] = [.text, .url, .image, .file, .other, nil]
    /// In a terminal's session, the one item that copies a clip whole: Return keeps its text out or makes it a
    /// command.
    private static let copyAsIs = (title: "Copy As-Is", mode: PasteMode.asIs)
    /// The same for a command, whose trailing line break it keeps.
    private static let copyCommandAsIs = (title: "Copy As-Is (Keeps Trailing Newline)", mode: PasteMode.asIs)

    func testPasteTitlesNameTheTargetApp() {
        // Outside a terminal, every kind pastes the same way.
        for kind in Self.kinds {
            assertActions(.make(target: .textEdit, availability: .paste(.textEdit), kind: kind),
                          primary: "Paste into TextEdit", plainText: "Paste as Plain Text",
                          copyOnly: ("Copy", .original), "\(String(describing: kind))")
        }
        XCTAssertEqual(QuickAccessActions.make(target: .notes, availability: .paste(.notes), kind: .text).primaryTitle,
                       "Paste into Notes")
    }

    func testTerminalTextUsesCommandTitlesAndCopyAsIs() {
        // Return and ⇧Return paste the same command, so there is no plain-text item; only Copy As-Is keeps the clip
        // as captured.
        for kind in [ContentKind.text, .url] {
            assertActions(.make(target: .terminal, availability: .paste(.terminal), kind: kind),
                          primary: "Paste Command", plainText: nil, copyOnly: Self.copyCommandAsIs, "\(kind)")
        }
    }

    func testTerminalWithoutPermissionCopiesCommandsAndOffersEnable() {
        for kind in [ContentKind.text, .url] {
            assertActions(.make(target: .terminal, availability: .copy(.notPermitted), kind: kind),
                          primary: "Copy Command", plainText: nil, copyOnly: Self.copyCommandAsIs, enable: true,
                          "\(kind)")
        }
        // A terminal's image, file or other clip is copied like any other clip's, and Copy As-Is still copies it
        // whole.
        for kind in [ContentKind.image, .file, .other] {
            assertActions(.make(target: .terminal, availability: .copy(.notPermitted), kind: kind),
                          primary: "Copy", plainText: "Copy as Plain Text", copyOnly: Self.copyAsIs, enable: true,
                          "\(kind)")
        }
    }

    func testTerminalImagesPasteNormally() {
        // Return keeps only images and file references here, and plain text is a command, so only Copy As-Is copies
        // the clip whole.
        for kind in [ContentKind.image, .file, .other] {
            assertActions(.make(target: .terminal, availability: .paste(.terminal), kind: kind),
                          primary: "Paste into Terminal", plainText: "Paste as Plain Text", copyOnly: Self.copyAsIs,
                          "\(kind)")
        }
    }

    func testNoTargetKeepsThe06cMenu() {
        for kind in Self.kinds {
            for availability in [nil, DirectPasteAvailability.copy(.noTarget)] {
                assertActions(.make(target: nil, availability: availability, kind: kind),
                              primary: "Copy", plainText: "Copy as Plain Text", copyOnly: nil,
                              "\(String(describing: kind)), \(String(describing: availability))")
            }
            // A target is no use without a library to check it with, or with checks that found no target.
            for target in [PasteTarget.textEdit, .terminal] {
                for availability in [nil, DirectPasteAvailability.copy(.noTarget)] {
                    assertActions(.make(target: target, availability: availability, kind: kind),
                                  primary: "Copy", plainText: "Copy as Plain Text", copyOnly: nil,
                                  "\(target.name), \(String(describing: kind)), \(String(describing: availability))")
                }
            }
        }
    }

    func testCopyReasonsTheUserCanActOnShowAHint() {
        let reasons: [(DirectPasteFallback, hint: String?)] = [
            (.secureInput, "Secure input is on"),
            (.cannotSendKeystroke, "⌘V isn't on this keyboard layout"),
            (.testSessionTarget, "Test sessions paste only into the system test host"),
            // The menu offers Enable Direct Paste… instead.
            (.notPermitted, nil),
            (.targetChanged, nil),
        ]
        for (reason, hint) in reasons {
            assertActions(.make(target: .textEdit, availability: .copy(reason), kind: .text),
                          primary: "Copy", plainText: "Copy as Plain Text", copyOnly: nil,
                          enable: reason == .notPermitted, hint: hint, "\(reason)")
            assertActions(.make(target: .terminal, availability: .copy(reason), kind: .image),
                          primary: "Copy", plainText: "Copy as Plain Text", copyOnly: Self.copyAsIs,
                          enable: reason == .notPermitted, hint: hint, "terminal image, \(reason)")
            // A terminal's command gives the same reasons.
            assertActions(.make(target: .terminal, availability: .copy(reason), kind: .text),
                          primary: "Copy Command", plainText: nil, copyOnly: Self.copyCommandAsIs,
                          enable: reason == .notPermitted, hint: hint, "terminal text, \(reason)")
        }
    }

    func testAfterAskingForAccessTheHintSaysToReopenKeeptide() {
        // Access granted in System Settings reaches Keeptide only once it reopens, so the panel says so.
        for (target, kind) in [(PasteTarget.textEdit, ContentKind.text), (.terminal, .image), (.terminal, .text)] {
            let asked = QuickAccessActions.make(target: target, availability: .copy(.notPermitted), kind: kind,
                                                accessRequested: true)
            XCTAssertEqual(asked.hint, "Reopen Keeptide to finish turning on direct paste", "\(target.name), \(kind)")
            XCTAssertTrue(asked.offersEnableDirectPaste, "\(target.name), \(kind)")
            let notAsked = QuickAccessActions.make(target: target, availability: .copy(.notPermitted), kind: kind,
                                                   accessRequested: false)
            XCTAssertNil(notAsked.hint, "\(target.name), \(kind)")
        }
        // Asking changes nothing for the other reasons.
        XCTAssertEqual(QuickAccessActions.make(target: .textEdit, availability: .copy(.secureInput), kind: .text,
                                               accessRequested: true).hint, "Secure input is on")
        XCTAssertNil(QuickAccessActions.make(target: .textEdit, availability: .copy(.targetChanged), kind: .text,
                                             accessRequested: true).hint)
        XCTAssertNil(QuickAccessActions.make(target: .textEdit, availability: .paste(.textEdit), kind: .text,
                                             accessRequested: true).hint)
    }

    func testConfirmTitlesFollowTheReviewDelivery() {
        XCTAssertEqual(QuickAccessActions.confirmTitle(for: review(delivery: .paste, targetName: "Terminal")),
                       "Confirm Paste into Terminal")
        XCTAssertEqual(QuickAccessActions.confirmTitle(for: review(delivery: .copy, targetName: "Terminal")),
                       "Confirm Copy Command")
        XCTAssertEqual(QuickAccessActions.confirmTitle(for: review(delivery: .copy, targetName: nil)),
                       "Confirm Copy Command")
    }

    func testToastsSayWhyAPasteBecameACopy() {
        let expected: [(QuickAccessCompletion, String?)] = [
            (.copied, "Copied — press ⌘V to paste"),
            (.copiedInstead(.targetChanged), "The window changed — copied instead. Press ⌘V to paste."),
            (.copiedInstead(.notPermitted), "Direct paste is off — copied instead. Press ⌘V to paste."),
            (.copiedInstead(.secureInput), "Secure input is on — copied instead. Press ⌘V to paste."),
            (.copiedInstead(.cannotSendKeystroke), "Couldn't send ⌘V — copied instead. Press ⌘V to paste."),
            (.copiedInstead(.testSessionTarget), "Test sessions paste only into the system test host — copied instead."),
            // The panel asks for a paste only with a target, so a copy without one has only the copy to tell.
            (.copiedInstead(.noTarget), "Copied — press ⌘V to paste"),
            // ⌘V does not prove that the target pasted, so nothing is said.
            (.dispatched, nil),
        ]
        for (completion, message) in expected {
            XCTAssertEqual(completion.toastMessage, message, "\(completion)")
        }
    }

    func testRefusalsThatCopyAsIsGetsRoundSayWhereToFindIt() {
        // A terminal takes reviewed text, images and file references; for anything else, and for a command too long to
        // review whole, only Copy As-Is in the menu copies the clip.
        XCTAssertEqual(PasteRefusal.terminalCannotTake.message,
                       "A terminal can't take this item. Use Copy As-Is in the ⌘K menu.")
        XCTAssertEqual(PasteRefusal.commandTooLong.message, "Too long to review — use Copy As-Is in the ⌘K menu")
        // A plain-text copy of a picture or a file still says what the clip lacks.
        XCTAssertEqual(PasteRefusal.noPlainText.message, "This item has no plain text.")
    }

    func testTheReviewCardSaysWhatToCheck() {
        let twoLines = review(delivery: .paste, targetName: "Terminal")
        XCTAssertEqual(CommandReviewView.title(for: twoLines), "Review this 2-line command")
        XCTAssertEqual(CommandReviewView.explanation(for: twoLines),
                       "A terminal can run each line as soon as it arrives. Check every line.")
        XCTAssertEqual(CommandReviewView.title(for: review(of: "a\nb\rc\u{2028}d\n")), "Review this 4-line command")
        // One line that still needs a review holds a character a terminal acts on, or one nobody can see.
        for command in ["echo synthetic\u{0F}", "echo \u{200B}synthetic"] {
            let oneLine = review(of: command)
            XCTAssertEqual(CommandReviewView.title(for: oneLine), "Review this command", command)
            XCTAssertEqual(CommandReviewView.explanation(for: oneLine),
                           "It contains control or invisible characters a terminal can act on.", command)
        }
        XCTAssertEqual(CommandReviewView.renewalNotice, "The content or target changed. Review it and confirm again.")
    }

    /// Checks what shows; the copy-only mode only when the item is offered.
    private func assertActions(_ actions: QuickAccessActions, primary: String, plainText: String?,
                               copyOnly: (title: String, mode: PasteMode)?, enable: Bool = false, hint: String? = nil,
                               _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actions.primaryTitle, primary, message, file: file, line: line)
        XCTAssertEqual(actions.plainTextTitle, plainText, message, file: file, line: line)
        XCTAssertEqual(actions.copyOnlyTitle, copyOnly?.title, message, file: file, line: line)
        if let copyOnly { XCTAssertEqual(actions.copyOnlyMode, copyOnly.mode, message, file: file, line: line) }
        XCTAssertEqual(actions.offersEnableDirectPaste, enable, message, file: file, line: line)
        XCTAssertEqual(actions.hint, hint, message, file: file, line: line)
    }

    private func review(delivery: PasteDelivery, targetName: String?) -> CommandReview {
        review(of: "set -e\necho synthetic-gamma\n", delivery: delivery, targetName: targetName)
    }

    private func review(of command: String, delivery: PasteDelivery = .paste,
                        targetName: String? = "Terminal") -> CommandReview {
        let ref = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                             digest: Data(repeating: 0, count: 32))
        return CommandReview(
            confirmation: CommandConfirmation(id: UUID(), sessionGeneration: 1, ref: ref, mode: .original,
                                              delivery: delivery),
            command: TerminalCommand(plainText: command), targetName: targetName, isRenewal: false)
    }
}
