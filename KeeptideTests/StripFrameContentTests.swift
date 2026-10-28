import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

final class StripFrameContentTests: XCTestCase {
    func testFrameContentBeforeDetailsIsTitleAndSymbol() {
        let apple = makeRow(kind: .url, title: "Apple docs", savedAsMemo: true, isPartiallyIndexed: true, isTextUnavailable: true)

        let content = StripFrameContent.make(row: apple, detail: nil, density: .nine)

        XCTAssertEqual(content.body, .placeholder(symbol: "link", title: "Apple docs"))
        XCTAssertNil(content.info)
        // The title is the placeholder's own text, so it is not shown a second time as a memo title.
        XCTAssertNil(content.memoTitle)
        XCTAssertEqual(content.extraItems, 0)
        // What the row already says does not wait for the details.
        XCTAssertEqual(content.markers, [.savedAsMemo, .partiallyIndexed])
        XCTAssertTrue(content.isTextUnavailable)

        let kinds: [(kind: ContentKind, symbol: String, word: String)] = [
            (.text, "doc.text", "Text"), (.url, "link", "Link"), (.image, "photo", "Image"),
            (.file, "doc", "File"), (.other, "square.dashed", "Clip"),
        ]
        for (kind, symbol, word) in kinds {
            let untitled = StripFrameContent.make(row: makeRow(kind: kind, title: ""), detail: nil, density: .seven)
            XCTAssertEqual(untitled.body, .placeholder(symbol: symbol, title: "Clipboard Item"), "\(kind)")
            XCTAssertEqual(kind.accessibilityName, word)
        }
    }

    func testTextFramesUseTheExcerptAndSizeByLength() {
        let color = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: "#E2462A", characterCount: 7),
                                           density: .seven)

        XCTAssertEqual(color.body, .text(AttributedString("#E2462A"), size: 22))
        XCTAssertEqual(color.info, "7 characters")
        XCTAssertNil(color.memoTitle)
        XCTAssertEqual(color.extraItems, 0)

        // The table is read for the density, and longer text is set smaller.
        let denser = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: "#E2462A", characterCount: 7),
                                            density: .nine)
        XCTAssertEqual(denser.body, .text(AttributedString("#E2462A"), size: 19))
        let paragraph = String(repeating: "word ", count: 40)
        let long = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: paragraph, characterCount: 300),
                                          density: .seven)
        XCTAssertEqual(long.body, .text(AttributedString(paragraph), size: 13))
        XCTAssertEqual(long.info, "300 characters")

        // A text that is only blank has nothing to show, but its length is still told.
        let blank = StripFrameContent.make(row: makeRow(title: ""), detail: ClipDetail(excerpt: "", characterCount: 3),
                                           density: .seven)
        XCTAssertEqual(blank.body, .placeholder(symbol: "doc.text", title: "Clipboard Item"))
        XCTAssertEqual(blank.info, "3 characters")
    }

    func testSearchTextFramesUseTheSnippetWithBoldHighlights() {
        // Highlights count UTF-16 units, and the emoji takes two of them.
        let snippet = SearchSnippet(text: "…😀 quick brown fox", highlights: [4..<9])
        let detail = ClipDetail(excerpt: "The excerpt belongs to recent clips", characterCount: 35)

        let content = StripFrameContent.make(row: makeRow(snippet: snippet), detail: detail, density: .nine)

        guard case .text(let text, let size) = content.body else { return XCTFail("Expected a text body") }
        XCTAssertEqual(String(text.characters), "…😀 quick brown fox")
        XCTAssertEqual(size, 15)
        var emphasised: [String] = []
        for run in text.runs where run.inlinePresentationIntent == .stronglyEmphasized {
            emphasised.append(String(text[run.range].characters))
        }
        XCTAssertEqual(emphasised, ["quick"])
        XCTAssertEqual(content.info, "35 characters")

        // Only text frames show a snippet: a link is shown as it is for a recent clip.
        let link = makeRow(kind: .url, snippet: SearchSnippet(text: "…developer", highlights: [1..<10]))
        let linkContent = StripFrameContent.make(
            row: link, detail: ClipDetail(excerpt: "https://developer.apple.com/", characterCount: 28), density: .nine)
        XCTAssertEqual(linkContent.body, .link(host: "developer.apple.com", rest: "/"))
    }

    func testMemoTitleShowsOnlyWhenItIsNotTheStartOfTheBody() {
        let memo = makeRow(title: "Release checklist", savedAsMemo: true)

        // The body does not begin with the title. 17 characters set the title at 17 pt, so the body is
        // set at the next size down, 14 pt, instead of the 17 pt its own length would give.
        let apart = StripFrameContent.make(
            row: memo, detail: ClipDetail(excerpt: "Tag, notarize, ship", characterCount: 19), density: .seven)
        XCTAssertEqual(apart.memoTitle, "Release checklist")
        XCTAssertEqual(apart.body, .text(AttributedString("Tag, notarize, ship"), size: 14))
        // A body that is smaller than the cap anyway is left alone.
        let longBody = String(repeating: "word ", count: 40)
        let small = StripFrameContent.make(
            row: memo, detail: ClipDetail(excerpt: longBody, characterCount: 200), density: .seven)
        XCTAssertEqual(small.memoTitle, "Release checklist")
        XCTAssertEqual(small.body, .text(AttributedString(longBody), size: 13))
        // A short title is set at 22 pt, so the cap is 17 pt.
        let short = StripFrameContent.make(
            row: makeRow(title: "Notes", savedAsMemo: true),
            detail: ClipDetail(excerpt: "Ship it", characterCount: 7), density: .seven)
        XCTAssertEqual(short.memoTitle, "Notes")
        XCTAssertEqual(short.body, .text(AttributedString("Ship it"), size: 17))

        // The body begins with the title: it would only repeat the first line. Sizes follow the length.
        let repeated = StripFrameContent.make(
            row: memo, detail: ClipDetail(excerpt: "Release checklist\n1. Tag the build", characterCount: 34),
            density: .seven)
        XCTAssertNil(repeated.memoTitle)
        XCTAssertEqual(repeated.body, .text(AttributedString("Release checklist\n1. Tag the build"), size: 17))

        // A clip that is not a saved memo has no memo title, whatever its title is.
        let plain = StripFrameContent.make(
            row: makeRow(title: "Release checklist"),
            detail: ClipDetail(excerpt: "Tag, notarize, ship", characterCount: 19), density: .seven)
        XCTAssertNil(plain.memoTitle)
        // A memo without a title has nothing to show.
        let untitled = StripFrameContent.make(
            row: makeRow(title: "", savedAsMemo: true),
            detail: ClipDetail(excerpt: "Tag", characterCount: 3), density: .seven)
        XCTAssertNil(untitled.memoTitle)

        // A search snippet can start in the middle of the body, so it is compared as it is shown.
        let searched = StripFrameContent.make(
            row: makeRow(title: "Release checklist", snippet: SearchSnippet(text: "…notarize and ship", highlights: []),
                         savedAsMemo: true),
            detail: ClipDetail(excerpt: "Release checklist\nTag, notarize and ship", characterCount: 40), density: .seven)
        XCTAssertEqual(searched.memoTitle, "Release checklist")

        // A link has a body too: its address.
        let address = "https://developer.apple.com/documentation"
        let link = StripFrameContent.make(
            row: makeRow(kind: .url, title: "Apple docs", savedAsMemo: true),
            detail: ClipDetail(excerpt: address, characterCount: 41), density: .nine)
        XCTAssertEqual(link.memoTitle, "Apple docs")
        XCTAssertEqual(link.body, .link(host: "developer.apple.com", rest: "/documentation"))
        let addressTitled = StripFrameContent.make(
            row: makeRow(kind: .url, title: address, savedAsMemo: true),
            detail: ClipDetail(excerpt: address, characterCount: 41), density: .nine)
        XCTAssertNil(addressTitled.memoTitle)
    }

    func testLinkFramesSplitHostAndRest() {
        let address = "https://developer.apple.com/documentation/appkit/nspanel"

        let content = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: address, characterCount: 56), density: .nine)

        XCTAssertEqual(content.body, .link(host: "developer.apple.com", rest: "/documentation/appkit/nspanel"))
        XCTAssertEqual(content.info, "56 characters")

        // The port, query and fragment belong to the rest, as written.
        let detailed = StripFrameContent.make(
            row: makeRow(kind: .url),
            detail: ClipDetail(excerpt: "https://example.com:8443/search?q=swift%20ui&page=2#top", characterCount: 55),
            density: .nine)
        XCTAssertEqual(detailed.body, .link(host: "example.com", rest: ":8443/search?q=swift%20ui&page=2#top"))
        // A host alone has no rest.
        let bare = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "https://example.com", characterCount: 19), density: .nine)
        XCTAssertEqual(bare.body, .link(host: "example.com", rest: ""))

        // A link that does not split into a host and the rest is set as text.
        let mail = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "mailto:someone@example.com", characterCount: 26),
            density: .nine)
        XCTAssertEqual(mail.body, .text(AttributedString("mailto:someone@example.com"), size: 15))
        XCTAssertEqual(mail.info, "26 characters")
        // A link whose address could not be read has nothing to split.
        let unread = StripFrameContent.make(row: makeRow(kind: .url, title: "Apple docs"), detail: ClipDetail(), density: .nine)
        XCTAssertEqual(unread.body, .placeholder(symbol: "link", title: "Apple docs"))
        XCTAssertNil(unread.info)
    }

    func testImageAndFileInfoAndTheMultiItemMarker() throws {
        let thumbnail = try makeImage(width: 8, height: 6)
        let photo = ClipDetail(pixelSize: CGSize(width: 4032, height: 3024), thumbnail: thumbnail, fillsFrame: true)

        let filled = StripFrameContent.make(row: makeRow(kind: .image), detail: photo, density: .nine)

        XCTAssertEqual(filled.body, .image(thumbnail, fills: true))
        XCTAssertEqual(filled.info, "4032 × 3024")
        XCTAssertEqual(filled.extraItems, 0)

        // A picture shown whole keeps the shape its header gives it: ImageIO rounds the thumbnail's size,
        // which for a hairline of a picture is a very different shape.
        let hairline = ClipDetail(pixelSize: CGSize(width: 10, height: 4000), thumbnail: try makeImage(width: 9, height: 218),
                                  fillsFrame: false)
        let whole = StripFrameContent.make(row: makeRow(kind: .image), detail: hairline, density: .nine)
        guard case .image(_, let fills) = whole.body else { return XCTFail("Expected an image body") }
        XCTAssertFalse(fills)
        XCTAssertEqual(whole.imageAspectRatio, 10.0 / 4000.0)
        XCTAssertEqual(whole.info, "10 × 4000")

        // Without a thumbnail the frame shows the placeholder and still tells the size.
        let undrawn = StripFrameContent.make(
            row: makeRow(kind: .image, title: "Screenshot"), detail: ClipDetail(pixelSize: CGSize(width: 4032, height: 3024)),
            density: .nine)
        XCTAssertEqual(undrawn.body, .placeholder(symbol: "photo", title: "Screenshot"))
        XCTAssertEqual(undrawn.info, "4032 × 3024")

        // Files: the first name sets the icon's type, and two items are two files.
        let pair = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["a.pdf", "b.txt"], itemCount: 2), density: .nine)
        XCTAssertEqual(pair.body, .file(name: "a.pdf", typeIdentifier: UTType.pdf.identifier))
        XCTAssertEqual(pair.info, "2 files")
        XCTAssertEqual(pair.extraItems, 1)
        let single = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["Quarterly report.pdf"]), density: .nine)
        XCTAssertEqual(single.info, "PDF")
        XCTAssertEqual(single.extraItems, 0)
        // A file whose name could not be read still counts as a file.
        let partial = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["a.pdf"], itemCount: 3), density: .nine)
        XCTAssertEqual(partial.body, .file(name: "a.pdf", typeIdentifier: UTType.pdf.identifier))
        XCTAssertEqual(partial.info, "3 files")
        XCTAssertEqual(partial.extraItems, 2)
        // With no name at all the frame shows the generic file icon and the title; one unread file is a "File".
        let unnamed = StripFrameContent.make(
            row: makeRow(kind: .file, title: "Contract"), detail: ClipDetail(fileNames: [], itemCount: 1), density: .nine)
        XCTAssertEqual(unnamed.body, .file(name: "Contract", typeIdentifier: nil))
        XCTAssertEqual(unnamed.info, "File")
        let noExtension = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["README"]), density: .nine)
        XCTAssertEqual(noExtension.body, .file(name: "README", typeIdentifier: nil))
        XCTAssertEqual(noExtension.info, "File")

        // Several items that are not files are counted as items.
        let other = StripFrameContent.make(row: makeRow(kind: .other), detail: ClipDetail(itemCount: 2), density: .nine)
        XCTAssertEqual(other.info, "2 items")
        XCTAssertEqual(other.extraItems, 1)
        let texts = StripFrameContent.make(
            row: makeRow(), detail: ClipDetail(excerpt: "First", characterCount: 5, itemCount: 3), density: .nine)
        XCTAssertEqual(texts.body, .text(AttributedString("First"), size: 19))
        XCTAssertEqual(texts.info, "3 items")
        XCTAssertEqual(texts.extraItems, 2)
        // One item of an unknown kind has nothing to tell.
        XCTAssertNil(StripFrameContent.make(row: makeRow(kind: .other), detail: ClipDetail(), density: .nine).info)
    }

    func testMarkersAndTextUnavailable() {
        let plain = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: "Plain", characterCount: 5), density: .nine)
        XCTAssertEqual(plain.markers, [])
        XCTAssertFalse(plain.isTextUnavailable)

        let memo = StripFrameContent.make(row: makeRow(savedAsMemo: true), detail: ClipDetail(excerpt: "Memo", characterCount: 4),
                                          density: .nine)
        XCTAssertEqual(memo.markers, [.savedAsMemo])

        let partial = StripFrameContent.make(row: makeRow(isPartiallyIndexed: true),
                                             detail: ClipDetail(excerpt: "Partial", characterCount: 7), density: .nine)
        XCTAssertEqual(partial.markers, [.partiallyIndexed])

        let both = StripFrameContent.make(row: makeRow(savedAsMemo: true, isPartiallyIndexed: true),
                                          detail: ClipDetail(excerpt: "Both", characterCount: 4), density: .nine)
        XCTAssertEqual(both.markers, [.savedAsMemo, .partiallyIndexed])

        // The flag is copied from the row, with the details or without them.
        let unavailable = makeRow(isTextUnavailable: true)
        XCTAssertTrue(StripFrameContent.make(row: unavailable, detail: nil, density: .nine).isTextUnavailable)
        XCTAssertTrue(StripFrameContent.make(row: unavailable, detail: ClipDetail(), density: .nine).isTextUnavailable)
    }
}

private func makeRow(
    kind: ContentKind = .text, title: String = "Synthetic title", snippet: SearchSnippet? = nil,
    savedAsMemo: Bool = false, isPartiallyIndexed: Bool = false, isTextUnavailable: Bool = false
) -> QuickAccessRow {
    QuickAccessRow(
        ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 3, count: 32)),
        title: title, snippet: snippet, kind: kind, sourceApp: nil, date: Date(timeIntervalSince1970: 1_000),
        savedAsMemo: savedAsMemo, isPartiallyIndexed: isPartiallyIndexed, isTextUnavailable: isTextUnavailable
    )
}

private func makeImage(width: Int, height: Int) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try XCTUnwrap(context.makeImage())
}
