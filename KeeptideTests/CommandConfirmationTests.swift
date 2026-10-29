import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

/// Command mode and its confirmation through `PasteService`, with a real temporary store, a named pasteboard and a
/// fake system that posts nothing. Unless a test says otherwise, Terminal is in front, every check passes, and the
/// request asks for a paste of the original formats. The clips are the quick-access seed's synthetic commands.
@MainActor
final class CommandConfirmationTests: XCTestCase {
    private static let singleLine = "echo synthetic-beta\n"
    private static let multiLine = "set -e\necho synthetic-gamma\n"

    func testFormatIsCommandOnlyForTextInTerminals() {
        for kind in [ContentKind.text, .url] {
            XCTAssertEqual(PasteFormat.resolve(mode: .original, target: .terminal, kind: kind), .command, "\(kind)")
            XCTAssertEqual(PasteFormat.resolve(mode: .plainText, target: .terminal, kind: kind), .command, "\(kind)")
        }
        // Text reaches a terminal only as a command: images, files and other content keep their own formats
        // without their text, and their plain text is a command too.
        for kind in [ContentKind.image, .file, .other] {
            XCTAssertEqual(PasteFormat.resolve(mode: .original, target: .terminal, kind: kind), .originalWithoutText,
                           "\(kind)")
            XCTAssertEqual(PasteFormat.resolve(mode: .plainText, target: .terminal, kind: kind), .command, "\(kind)")
        }
        // Another app, or no target, gets what was asked for.
        for target in [PasteTarget.textEdit, nil] {
            for kind in [ContentKind.text, .url, .image, .file, .other] {
                XCTAssertEqual(PasteFormat.resolve(mode: .original, target: target, kind: kind), .original, "\(kind)")
                XCTAssertEqual(PasteFormat.resolve(mode: .plainText, target: target, kind: kind), .plainText,
                               "\(kind)")
            }
        }
        // Copy As-Is is the clip as captured, everywhere.
        for target in [PasteTarget.terminal, .textEdit, nil] {
            for kind in [ContentKind.text, .url, .image, .file, .other] {
                XCTAssertEqual(PasteFormat.resolve(mode: .asIs, target: target, kind: kind), .original, "\(kind)")
            }
        }
    }

    func testSingleLineCommandPastesWithoutItsTrailingNewline() async throws {
        let (fixture, ref) = try await makeFixture(Self.singleLine)
        let fake = terminal()
        let paste = fixture.service(system: fake.system)

        let outcome = await paste.execute(request(ref, paste.beginSession()))

        XCTAssertEqual(outcome, .dispatched(.terminal))
        XCTAssertEqual(fake.sent, [9])
        XCTAssertEqual(fixture.board.pasteboardItems?.count, 1)
        let item = try XCTUnwrap(fixture.board.pasteboardItems?.first)
        XCTAssertEqual(contentTypes(item), ["public.utf8-plain-text"])
        XCTAssertEqual(item.data(forType: .init("public.utf8-plain-text")), Data("echo synthetic-beta".utf8))

        // A link is a command too: its text, without the line break, and nothing else.
        let link = try await fixture.insert([[("public.url", Data("https://example.invalid/a".utf8)),
                                              ("public.utf8-plain-text", Data("https://example.invalid/a\n".utf8))]])
        let pastedLink = await paste.execute(request(link, paste.beginSession()))
        XCTAssertEqual(pastedLink, .dispatched(.terminal))
        XCTAssertEqual(fake.sent, [9, 9])
        let linkItem = try XCTUnwrap(fixture.board.pasteboardItems?.first)
        XCTAssertEqual(fixture.board.pasteboardItems?.count, 1)
        XCTAssertEqual(contentTypes(linkItem), ["public.utf8-plain-text"])
        XCTAssertEqual(linkItem.data(forType: .init("public.utf8-plain-text")), Data("https://example.invalid/a".utf8))
    }

    func testMultiLineCommandNeedsConfirmationAndNeitherSendsNorCopies() async throws {
        let (fixture, ref) = try await makeFixture(Self.multiLine)
        let fake = terminal()
        let log = ActionLog()
        let paste = fixture.service(system: fake.system, didWrite: { _ in log.writes += 1 })
        let session = paste.beginSession()
        let before = fixture.board.changeCount

        let outcome = await paste.execute(request(ref, session, dismiss: { log.dismissals += 1 }))

        let review = try XCTUnwrap(outcome.review)
        XCTAssertFalse(review.isRenewal)
        XCTAssertEqual(review.command.text, "set -e\necho synthetic-gamma")
        XCTAssertEqual(review.command.lineCount, 2)
        XCTAssertEqual(review.targetName, "Terminal")
        XCTAssertEqual(review.confirmation.delivery, .paste)
        XCTAssertEqual(review.confirmation.ref, ref)
        XCTAssertEqual(review.confirmation.mode, .original)
        XCTAssertEqual(review.confirmation.sessionGeneration, session.sessionGeneration)
        // Nothing reaches the clipboard, the panel or the target, and nothing counts as a use.
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(log.writes, 0)
        XCTAssertEqual(log.dismissals, 0)
        XCTAssertEqual(fake.sent, [])
        try await Task.sleep(for: .milliseconds(100))
        let uses = try await fixture.useCount(ref)
        XCTAssertEqual(uses, 0)
    }

    func testConfirmedCommandPastesOnceAndTheConfirmationIsSingleUse() async throws {
        let (fixture, ref) = try await makeFixture(Self.multiLine)
        let fake = terminal()
        let log = ActionLog()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let reviewed = await paste.execute(request(ref, session))
        let review = try XCTUnwrap(reviewed.review)

        let confirmed = await paste.execute(request(ref, session, confirmation: review.confirmation,
                                                    dismiss: { log.dismissals += 1 }))

        XCTAssertEqual(confirmed, .dispatched(.terminal))
        XCTAssertEqual(fake.sent, [9])
        XCTAssertEqual(log.dismissals, 1)
        XCTAssertEqual(fixture.board.string(forType: .string), "set -e\necho synthetic-gamma")

        // Used once, it no longer applies: the command is reviewed again and nothing is written or sent.
        let before = fixture.board.changeCount
        let reused = await paste.execute(request(ref, session, confirmation: review.confirmation))
        let renewed = try XCTUnwrap(reused.review)
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertNotEqual(renewed.confirmation.id, review.confirmation.id)
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [9])
    }

    func testConfirmationExpiresForAnotherClip() async throws {
        let fixture = try PasteFixture(self)
        let first = try await fixture.insert(text(Self.multiLine))
        let second = try await fixture.insert(text("set -u\necho synthetic-delta\n"))
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let reviewed = await paste.execute(request(first, session))
        let review = try XCTUnwrap(reviewed.review)
        let before = fixture.board.changeCount

        let outcome = await paste.execute(request(second, session, confirmation: review.confirmation))

        let renewed = try XCTUnwrap(outcome.review)
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertEqual(renewed.confirmation.ref, second)
        XCTAssertEqual(renewed.command.text, "set -u\necho synthetic-delta")
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
    }

    func testConfirmationExpiresWhenTheClipVersionChanges() async throws {
        let fixture = try PasteFixture(self)
        let ref = try await fixture.insert(text(Self.multiLine))
        let repository = ContentRepository(controller: fixture.controller)
        let fake = terminal()
        // Every read finds the item at a new version, as if it were edited between the review and the confirmation.
        let paste = fixture.service(system: fake.system, read: { requested in
            let stored = try await repository.read(requested)
            let edited = ContentRef(itemID: requested.itemID, facet: requested.facet, version: ContentVersion(),
                                    digest: requested.digest)
            return ResolvedContent(ref: edited, integrity: stored.integrity, representations: stored.representations)
        })
        let session = paste.beginSession()
        let reviewed = await paste.execute(request(ref, session))
        let review = try XCTUnwrap(reviewed.review)
        let before = fixture.board.changeCount

        let outcome = await paste.execute(request(ref, session, confirmation: review.confirmation))

        let renewed = try XCTUnwrap(outcome.review)
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertEqual(renewed.confirmation.ref.itemID, ref.itemID)
        XCTAssertNotEqual(renewed.confirmation.ref.version, review.confirmation.ref.version)
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
    }

    func testConfirmationExpiresInANewSession() async throws {
        let (fixture, ref) = try await makeFixture(Self.multiLine)
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let first = paste.beginSession()
        let reviewed = await paste.execute(request(ref, first))
        let review = try XCTUnwrap(reviewed.review)
        let second = paste.beginSession()
        let before = fixture.board.changeCount

        let outcome = await paste.execute(request(ref, second, confirmation: review.confirmation))

        let renewed = try XCTUnwrap(outcome.review)
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertEqual(renewed.confirmation.sessionGeneration, second.sessionGeneration)
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
    }

    func testConfirmationExpiresWhenTheModeChanges() async throws {
        let (fixture, ref) = try await makeFixture(Self.multiLine)
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let reviewed = await paste.execute(request(ref, session, mode: .original))
        let review = try XCTUnwrap(reviewed.review)
        let before = fixture.board.changeCount

        let outcome = await paste.execute(request(ref, session, mode: .plainText, confirmation: review.confirmation))

        let renewed = try XCTUnwrap(outcome.review)
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertEqual(renewed.confirmation.mode, .plainText)
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
    }

    func testConfirmedCopyNeverBecomesAPaste() async throws {
        let (fixture, ref) = try await makeFixture(Self.multiLine)
        let fake = terminal()
        fake.permitted = false
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let reviewed = await paste.execute(request(ref, session, delivery: .copy))
        let copyReview = try XCTUnwrap(reviewed.review)
        XCTAssertEqual(copyReview.confirmation.delivery, .copy)
        let before = fixture.board.changeCount

        // Access arrives and a paste is asked for with the copy's confirmation: it is reviewed again, as a paste.
        fake.permitted = true
        let outcome = await paste.execute(request(ref, session, confirmation: copyReview.confirmation))

        let renewed = try XCTUnwrap(outcome.review)
        XCTAssertTrue(renewed.isRenewal)
        XCTAssertEqual(renewed.confirmation.delivery, .paste)
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])

        // A copy confirmed as a copy is only copied, though a paste could be sent now.
        let copyAgain = await paste.execute(request(ref, session, delivery: .copy))
        let secondCopyReview = try XCTUnwrap(copyAgain.review)
        XCTAssertEqual(secondCopyReview.confirmation.delivery, .copy)
        let copied = await paste.execute(request(ref, session, delivery: .copy,
                                                 confirmation: secondCopyReview.confirmation))
        XCTAssertEqual(copied, .copied)
        XCTAssertEqual(fixture.board.string(forType: .string), "set -e\necho synthetic-gamma")
        XCTAssertEqual(fake.sent, [])
    }

    func testReturnShiftReturnAndTheMenuGiveTheSameReview() async throws {
        let (fixture, ref) = try await makeFixture(Self.multiLine)
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        // Return and the menu's first item ask for the original formats, Shift-Return for plain text.
        let original = await paste.execute(request(ref, session, mode: .original))
        let plainText = await paste.execute(request(ref, session, mode: .plainText))

        let viaReturn = try XCTUnwrap(original.review)
        let viaShiftReturn = try XCTUnwrap(plainText.review)
        XCTAssertEqual(viaReturn.command, viaShiftReturn.command)
        XCTAssertEqual(viaReturn.targetName, viaShiftReturn.targetName)
        XCTAssertEqual(viaReturn.confirmation.delivery, viaShiftReturn.confirmation.delivery)
        XCTAssertFalse(viaReturn.isRenewal)
        XCTAssertFalse(viaShiftReturn.isRenewal)
        XCTAssertEqual(fake.sent, [])
    }

    func testCopyCommandWithoutPermissionStripsAndNeedsConfirmationToo() async throws {
        let fixture = try PasteFixture(self)
        let single = try await fixture.insert(text(Self.singleLine))
        let multi = try await fixture.insert(text(Self.multiLine))
        let fake = terminal()
        fake.permitted = false
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        let copied = await paste.execute(request(single, session, delivery: .copy))
        XCTAssertEqual(copied, .copied)
        XCTAssertEqual(fixture.board.string(forType: .string), "echo synthetic-beta")

        let before = fixture.board.changeCount
        let outcome = await paste.execute(request(multi, session, delivery: .copy))
        let review = try XCTUnwrap(outcome.review)
        XCTAssertEqual(review.confirmation.delivery, .copy)
        XCTAssertEqual(fixture.board.changeCount, before)

        // A paste asked for without access is a copy too, so its review is for a copy.
        let copiedInstead = await paste.execute(request(single, session))
        XCTAssertEqual(copiedInstead, .copiedInstead(.notPermitted))
        XCTAssertEqual(fixture.board.string(forType: .string), "echo synthetic-beta")
        let pasteOutcome = await paste.execute(request(multi, session))
        let pasteReview = try XCTUnwrap(pasteOutcome.review)
        XCTAssertEqual(pasteReview.confirmation.delivery, .copy)
        XCTAssertEqual(fake.sent, [])
        // A review for a copy counts as no use either.
        try await Task.sleep(for: .milliseconds(100))
        let uses = try await fixture.useCount(multi)
        XCTAssertEqual(uses, 0)
    }

    func testCopyAsIsKeepsTheTrailingNewlineAndNeverSends() async throws {
        let fixture = try PasteFixture(self)
        let single = try await fixture.insert(text(Self.singleLine))
        let multi = try await fixture.insert(text(Self.multiLine))
        let fake = terminal()
        let log = ActionLog()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        let copied = await paste.execute(request(single, session, mode: .asIs, dismiss: { log.dismissals += 1 }))

        XCTAssertEqual(copied, .copied)
        XCTAssertEqual(fixture.board.string(forType: .string), "echo synthetic-beta\n")
        // Copied as captured, a multi-line clip is not a command, so it needs no review.
        let copiedMultiLine = await paste.execute(request(multi, session, mode: .asIs,
                                                          dismiss: { log.dismissals += 1 }))
        XCTAssertEqual(copiedMultiLine, .copied)
        XCTAssertEqual(fixture.board.string(forType: .string), "set -e\necho synthetic-gamma\n")
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.dismissals, 0)
        // A copy runs no target check: the only probe is the one that recorded the session's target.
        XCTAssertEqual(fake.probes, 1)
    }

    func testRichTextWithoutPlainTextIsRefusedInATerminal() async throws {
        let fixture = try PasteFixture(self)
        let rich = try await fixture.insert([[("public.rtf", Data(#"{\rtf1\ansi echo synthetic-beta}"#.utf8))]])
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let before = fixture.board.changeCount

        let outcome = await paste.execute(request(rich, paste.beginSession()))

        XCTAssertEqual(outcome, .refused(.noPlainText))
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])

        // The kind comes from the clip read: RTF is text, so it has to be a command, while an image is not.
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let image = try await fixture.insert([[("public.png", png)]])
        let pastedImage = await paste.execute(request(image, paste.beginSession()))
        XCTAssertEqual(pastedImage, .dispatched(.terminal))
        XCTAssertEqual(fixture.board.data(forType: .png), png)
        XCTAssertNil(fixture.board.data(forType: .string))
    }

    func testImageWithTextInATerminalNeverWritesItsText() async throws {
        let fixture = try PasteFixture(self)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let ref = try await fixture.insert([[("public.png", png),
                                             ("public.utf8-plain-text", Data(Self.multiLine.utf8))]])
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        // The original formats go without the text, so the text cannot reach the terminal unreviewed.
        let original = await paste.execute(request(ref, session, mode: .original))

        XCTAssertEqual(original, .dispatched(.terminal))
        XCTAssertEqual(fixture.board.data(forType: .png), png)
        XCTAssertEqual(textLikeTypes(on: fixture.board), [])
        XCTAssertEqual(fake.sent, [9])

        // Its plain text is a command, and this one needs a review first.
        let before = fixture.board.changeCount
        let plainText = await paste.execute(request(ref, session, mode: .plainText))
        let review = try XCTUnwrap(plainText.review)
        XCTAssertEqual(review.command.lineCount, 2)
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [9])

        // An item of text alone is left out, and the image item after it is written as the first.
        let separate = try await fixture.insert([[("public.utf8-plain-text", Data(Self.multiLine.utf8))],
                                                 [("public.png", png)]])
        let pastedSeparate = await paste.execute(request(separate, session, mode: .original))
        XCTAssertEqual(pastedSeparate, .dispatched(.terminal))
        XCTAssertEqual(fixture.board.pasteboardItems?.count, 1)
        XCTAssertEqual(fixture.board.data(forType: .png), png)
        XCTAssertEqual(textLikeTypes(on: fixture.board), [])
        XCTAssertEqual(fake.sent, [9, 9])
    }

    func testFileInATerminalKeepsOnlyItsFileURL() async throws {
        let fixture = try PasteFixture(self)
        let fileURL = Data(URL(fileURLWithPath: "/tmp/synthetic.txt").absoluteString.utf8)
        let name = Data("synthetic.txt\n".utf8)
        let file = try await capture([("public.file-url", fileURL), ("public.utf8-plain-text", name)], into: fixture)
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        let outcome = await paste.execute(request(file, session, mode: .original))

        XCTAssertEqual(outcome, .dispatched(.terminal))
        XCTAssertEqual(fixture.board.data(forType: .fileURL), fileURL)
        XCTAssertEqual(textLikeTypes(on: fixture.board), [])
        XCTAssertEqual(fake.sent, [9])

        // A file whose every format is text or a link has nothing left to paste.
        let link = try await capture([("public.url", fileURL), ("public.utf8-plain-text", name)], into: fixture)
        let before = fixture.board.changeCount
        let refused = await paste.execute(request(link, session, mode: .original))
        XCTAssertEqual(refused, .refused(.contentUnavailable))
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [9])
    }

    func testOversizedCommandIsRefusedButCopyAsIsWorks() async throws {
        let limit = 262_144
        // Two lines, so that each would need a review: "set -e", then "echo " and x's up to the byte count.
        func command(byteCount: Int) -> String { "set -e\necho " + String(repeating: "x", count: byteCount - 12) }
        let fixture = try PasteFixture(self)
        let atLimit = try await fixture.insert(text(command(byteCount: limit) + "\n"))
        let overLimit = try await fixture.insert(text(command(byteCount: limit + 1) + "\n"))
        let fake = terminal()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let reviewed = await paste.execute(request(atLimit, session))
        let review = try XCTUnwrap(reviewed.review)
        XCTAssertEqual(review.command.text.utf8.count, limit)
        let before = fixture.board.changeCount

        // Outcomes are compared with ==, so that a failure does not print 256 KiB of text.
        // One byte more is refused before any review, and the pending confirmation stays.
        let refused = await paste.execute(request(overLimit, session))
        XCTAssertTrue(refused == .refused(.commandTooLong))
        XCTAssertEqual(fixture.board.changeCount, before)
        let confirmed = await paste.execute(request(atLimit, session, confirmation: review.confirmation))
        XCTAssertTrue(confirmed == .dispatched(.terminal))
        XCTAssertEqual(fixture.board.data(forType: .string), Data(command(byteCount: limit).utf8))
        XCTAssertEqual(fake.sent, [9])

        // Copy As-Is still copies it, as captured.
        let copied = await paste.execute(request(overLimit, session, mode: .asIs))
        XCTAssertTrue(copied == .copied)
        XCTAssertEqual(fixture.board.data(forType: .string), Data((command(byteCount: limit + 1) + "\n").utf8))
        XCTAssertEqual(fake.sent, [9])
    }

    private func makeFixture(_ clip: String) async throws -> (PasteFixture, ContentRef) {
        let fixture = try PasteFixture(self)
        return (fixture, try await fixture.insert(text(clip)))
    }

    private func text(_ clip: String) -> [[(String, Data)]] {
        [[("public.utf8-plain-text", Data(clip.utf8))]]
    }

    /// Terminal in front, with every check passing.
    private func terminal() -> FakeDirectPasteSystem {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        return fake
    }

    /// Every request can hide the panel, as the panel's are.
    private func request(_ ref: ContentRef, _ session: PasteSession, mode: PasteMode = .original,
                         delivery: PasteDelivery = .paste, confirmation: CommandConfirmation? = nil,
                         dismiss: @escaping @MainActor () -> Void = {}) -> PasteRequest {
        PasteRequest(ref: ref, queryGeneration: session.queryGeneration, mode: mode, session: session,
                     delivery: delivery, dismiss: dismiss, confirmation: confirmation)
    }

    private func contentTypes(_ item: NSPasteboardItem) -> [String] {
        item.types.map(\.rawValue).filter { $0 != OwnWriteToken.typeIdentifier }
    }

    /// Types on the board that are text or a link, by the rule that classifies a clip as text.
    private func textLikeTypes(on board: NSPasteboard) -> [String] {
        (board.pasteboardItems ?? []).flatMap(contentTypes).filter {
            ClipboardTextDecoder.isTextType($0) || UTType($0)?.conforms(to: .text) == true
        }
    }

    /// One item stored as capture stores it: an item with a file reference keeps every format local.
    private func capture(_ representations: [(String, Data)], into fixture: PasteFixture) async throws -> ContentRef {
        let item = CapturedPasteboardItem(representations: representations.map {
            CapturedRepresentation(typeIdentifier: $0.0, bytes: $0.1)
        })
        let snapshot = CaptureSnapshotValue(items: [item], changeCount: 1, sourceApp: nil)
        return try await CaptureService(controller: fixture.controller).capture(snapshot).ref
    }
}

private extension PasteOutcome {
    var review: CommandReview? {
        if case .needsConfirmation(let review) = self { review } else { nil }
    }
}

/// What the panel and the clipboard saw.
@MainActor
private final class ActionLog {
    var dismissals = 0
    var writes = 0
}
