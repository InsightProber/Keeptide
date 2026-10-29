import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

final class StripFrameContentTests: XCTestCase {
    func testFramesGetAHairlineOnlyWhenTransparencyIsReduced() {
        // With Reduce Transparency the band is solid and can be the paper's very color, so a frame draws its edge.
        XCTAssertEqual(StripFrameView.paperStroke(reduceTransparency: true), 1)
        // Otherwise the glass behind the frames sets them apart, and they have no line.
        XCTAssertNil(StripFrameView.paperStroke(reduceTransparency: false))
    }

    func testFrameContentBeforeDetailsIsTitleAndSymbol() {
        let apple = makeRow(kind: .url, title: "Apple docs", savedAsMemo: true, isPartiallyIndexed: true, isTextUnavailable: true)

        let content = StripFrameContent.make(row: apple, detail: nil, cardSize: .medium)

        XCTAssertEqual(content.body, .placeholder(symbol: "link", title: "Apple docs"))
        XCTAssertNil(content.info)
        // Its text is gone, so the notice takes the placeholder's place and the memo's own title shows above it.
        XCTAssertEqual(content.memoTitle, "Apple docs")
        XCTAssertEqual(content.extraItems, 0)
        // What the row already says does not wait for the details.
        XCTAssertEqual(content.markers, [.savedAsMemo, .partiallyIndexed])
        XCTAssertTrue(content.isTextUnavailable)

        let kinds: [(kind: ContentKind, symbol: String, word: String)] = [
            (.text, "doc.text", "Text"), (.url, "link", "Link"), (.image, "photo", "Image"),
            (.file, "doc", "File"), (.other, "square.dashed", "Clip"),
        ]
        for (kind, symbol, word) in kinds {
            let untitled = StripFrameContent.make(row: makeRow(kind: kind, title: ""), detail: nil, cardSize: .large)
            XCTAssertEqual(untitled.body, .placeholder(symbol: symbol, title: "Clipboard Item"), "\(kind)")
            XCTAssertEqual(kind.accessibilityName, word)
            XCTAssertEqual(untitled.kind, kind)
        }
    }

    func testHeaderShowsTypeTimeAndMarkers() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let row = makeRow(title: "Standup", sourceApp: "com.apple.Notes", date: now.addingTimeInterval(-120),
                          savedAsMemo: true, isPartiallyIndexed: true)

        let content = StripFrameContent.make(row: row, detail: ClipDetail(excerpt: "Standup", characterCount: 7, itemCount: 3),
                                             cardSize: .medium, now: now)

        // The kind on the first line; on the second, the time and after it the marks, then how many more items.
        XCTAssertEqual(content.kind, .text)
        XCTAssertEqual(content.time, QuickAccessRowContent.time(of: row.date, relativeTo: now))
        XCTAssertEqual(content.headerLine, [
            .time(content.time), .marker(.savedAsMemo), .marker(.partiallyIndexed), .extraItems(2),
        ])
        // The band takes its colour from the app the clip came from.
        XCTAssertEqual(content.sourceApp, "com.apple.Notes")

        // Without marks the time is alone on its line.
        let plain = StripFrameContent.make(row: makeRow(date: now.addingTimeInterval(-10)), detail: nil, cardSize: .medium,
                                           now: now)
        XCTAssertEqual(plain.headerLine, [.time(plain.time)])
        XCTAssertNil(plain.sourceApp)
    }

    func testTextFramesUseTheExcerptAndSizeByLength() {
        let color = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: "#E2462A", characterCount: 7),
                                           cardSize: .medium)

        XCTAssertEqual(color.body, .text(AttributedString("#E2462A"), style: StripTextStyle(size: 20, lineHeight: 27)))
        XCTAssertEqual(color.info, "7 characters")
        XCTAssertNil(color.memoTitle)
        XCTAssertEqual(color.extraItems, 0)

        // The steps are read for the card size, and longer text is set smaller.
        let larger = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: "#E2462A", characterCount: 7),
                                            cardSize: .large)
        XCTAssertEqual(larger.body, .text(AttributedString("#E2462A"),
                                          style: StripTypography.bodyStyle(for: "#E2462A", cardSize: .large)))
        let paragraph = String(repeating: "word ", count: 40)
        let long = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: paragraph, characterCount: 300),
                                          cardSize: .medium)
        XCTAssertEqual(long.body, .text(AttributedString(paragraph), style: StripTextStyle(size: 14, lineHeight: 21)))
        XCTAssertEqual(long.info, "300 characters")

        // A text that is only blank has nothing to show, but its length is still told.
        let blank = StripFrameContent.make(row: makeRow(title: ""), detail: ClipDetail(excerpt: "", characterCount: 3),
                                           cardSize: .large)
        XCTAssertEqual(blank.body, .placeholder(symbol: "doc.text", title: "Clipboard Item"))
        XCTAssertEqual(blank.info, "3 characters")
    }

    func testSearchTextFramesUseTheSnippetWithBoldHighlights() throws {
        // Highlights count UTF-16 units, and the emoji takes two of them.
        let snippet = SearchSnippet(text: "…😀 quick brown fox", highlights: [4..<9])
        let detail = ClipDetail(excerpt: "The excerpt belongs to recent clips", characterCount: 35)

        let content = StripFrameContent.make(row: makeRow(snippet: snippet), detail: detail, cardSize: .medium)

        guard case .text(let text, let style) = content.body else { return XCTFail("Expected a text body") }
        XCTAssertEqual(String(text.characters), "…😀 quick brown fox")
        XCTAssertEqual(style, StripTextStyle(size: 20, lineHeight: 27))
        XCTAssertEqual(emphasised(text), ["quick"])
        XCTAssertEqual(content.info, "35 characters")

        // A link's title shows the words the search found in its address.
        let link = makeRow(kind: .url, snippet: SearchSnippet(text: "https://git-scm.com/docs/git-rebase", highlights: [29..<35]))
        let linkContent = StripFrameContent.make(
            row: link, detail: ClipDetail(excerpt: "https://git-scm.com/docs/git-rebase", characterCount: 35,
                                          linkTitle: "Git - git-rebase Documentation"),
            cardSize: .medium)
        guard case .link(let title) = linkContent.body else { return XCTFail("Expected a link body") }
        XCTAssertEqual(String(title.characters), "Git - git-rebase Documentation")
        XCTAssertEqual(emphasised(title), ["rebase"])
        XCTAssertEqual(linkContent.info, "git-scm.com")
        // A recent link, which has no snippet, has nothing in bold.
        let recent = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "https://git-scm.com/docs/git-rebase", characterCount: 35,
                                                         linkTitle: "Git - git-rebase Documentation"),
            cardSize: .medium)
        guard case .link(let plainTitle) = recent.body else { return XCTFail("Expected a link body") }
        XCTAssertEqual(emphasised(plainTitle), [])
    }

    func testSearchTextFramesShowTheSnippetBeforeDetailsArrive() {
        // Highlights count UTF-16 units, and the emoji takes two of them.
        let snippet = SearchSnippet(text: "…😀 quick brown fox", highlights: [4..<9])
        let row = makeRow(snippet: snippet, isPartiallyIndexed: true)

        let before = StripFrameContent.make(row: row, detail: nil, cardSize: .medium)

        // The snippet came with the search result, so it is shown at once and only the caption waits.
        guard case .text(let text, let style) = before.body else { return XCTFail("Expected a text body") }
        XCTAssertEqual(String(text.characters), "…😀 quick brown fox")
        XCTAssertEqual(style, StripTextStyle(size: 20, lineHeight: 27))
        XCTAssertEqual(emphasised(text), ["quick"])
        XCTAssertNil(before.info)
        XCTAssertEqual(before.extraItems, 0)
        XCTAssertEqual(before.markers, [.partiallyIndexed])

        // The details add the caption and change nothing else.
        let after = StripFrameContent.make(row: row, detail: ClipDetail(excerpt: "x", characterCount: 35),
                                           cardSize: .medium)
        XCTAssertEqual(after.body, before.body)
        XCTAssertEqual(after.info, "35 characters")

        // The memo title rule applies to it as to any text body: the title goes on the first line.
        let memo = StripFrameContent.make(
            row: makeRow(title: "Release checklist", snippet: SearchSnippet(text: "…notarize and ship", highlights: []),
                         savedAsMemo: true),
            detail: nil, cardSize: .medium)
        XCTAssertEqual(memo.memoTitle, "Release checklist")
        XCTAssertEqual(memo.body, .text(AttributedString("…notarize and ship"), style: StripTextStyle(size: 20, lineHeight: 27)))

        // Every other row without details keeps the placeholder, snippet or not.
        let others: [(kind: ContentKind, symbol: String)] = [(.url, "link"), (.image, "photo"), (.file, "doc"), (.other, "square.dashed")]
        for (kind, symbol) in others {
            let content = StripFrameContent.make(row: makeRow(kind: kind, title: "Other", snippet: snippet), detail: nil,
                                                 cardSize: .medium)
            XCTAssertEqual(content.body, .placeholder(symbol: symbol, title: "Other"), "\(kind)")
        }
        let recent = StripFrameContent.make(row: makeRow(title: "Recent"), detail: nil, cardSize: .medium)
        XCTAssertEqual(recent.body, .placeholder(symbol: "doc.text", title: "Recent"))
    }

    func testMemoTitleShowsOnlyWhenItIsNotTheStartOfTheBody() {
        let memo = makeRow(title: "Release checklist", savedAsMemo: true)

        // The body does not begin with the title, so the title takes the first line. The body keeps the size of its
        // own length.
        let apart = StripFrameContent.make(
            row: memo, detail: ClipDetail(excerpt: "Tag, notarize, ship", characterCount: 19), cardSize: .medium)
        XCTAssertEqual(apart.memoTitle, "Release checklist")
        XCTAssertEqual(apart.body, .text(AttributedString("Tag, notarize, ship"), style: StripTextStyle(size: 20, lineHeight: 27)))
        let longBody = String(repeating: "word ", count: 40)
        let small = StripFrameContent.make(
            row: memo, detail: ClipDetail(excerpt: longBody, characterCount: 200), cardSize: .medium)
        XCTAssertEqual(small.memoTitle, "Release checklist")
        XCTAssertEqual(small.body, .text(AttributedString(longBody), style: StripTextStyle(size: 14, lineHeight: 21)))

        // The body begins with the title: it would only repeat the first line.
        let repeated = StripFrameContent.make(
            row: memo, detail: ClipDetail(excerpt: "Release checklist\n1. Tag the build", characterCount: 34),
            cardSize: .medium)
        XCTAssertNil(repeated.memoTitle)
        XCTAssertEqual(repeated.body, .text(AttributedString("Release checklist\n1. Tag the build"),
                                            style: StripTextStyle(size: 18, lineHeight: 26)))

        // A clip that is not a saved memo has no memo title, whatever its title is.
        let plain = StripFrameContent.make(
            row: makeRow(title: "Release checklist"),
            detail: ClipDetail(excerpt: "Tag, notarize, ship", characterCount: 19), cardSize: .medium)
        XCTAssertNil(plain.memoTitle)
        // A memo without a title has nothing to show.
        let untitled = StripFrameContent.make(
            row: makeRow(title: "", savedAsMemo: true),
            detail: ClipDetail(excerpt: "Tag", characterCount: 3), cardSize: .medium)
        XCTAssertNil(untitled.memoTitle)

        // A search snippet can start in the middle of the body, so it is compared as it is shown.
        let searched = StripFrameContent.make(
            row: makeRow(title: "Release checklist", snippet: SearchSnippet(text: "…notarize and ship", highlights: []),
                         savedAsMemo: true),
            detail: ClipDetail(excerpt: "Release checklist\nTag, notarize and ship", characterCount: 40),
            cardSize: .medium)
        XCTAssertEqual(searched.memoTitle, "Release checklist")

        // A saved link's own title names it, ahead of the page's title; one titled with its address has none.
        let address = "https://developer.apple.com/documentation"
        let link = StripFrameContent.make(
            row: makeRow(kind: .url, title: "Apple docs", savedAsMemo: true),
            detail: ClipDetail(excerpt: address, characterCount: 41, linkTitle: "Documentation | Apple Developer"),
            cardSize: .medium)
        XCTAssertNil(link.memoTitle)
        XCTAssertEqual(link.body, .link(title: AttributedString("Apple docs")))
        let addressTitled = StripFrameContent.make(
            row: makeRow(kind: .url, title: address, savedAsMemo: true),
            detail: ClipDetail(excerpt: address, characterCount: 41), cardSize: .medium)
        XCTAssertNil(addressTitled.memoTitle)
        XCTAssertEqual(addressTitled.body, .link(title: AttributedString("/documentation")))
    }

    func testALinkUsesItsPageTitleWhenTheClipCarriesOne() {
        let address = "https://git-scm.com/docs/git-rebase"

        let content = StripFrameContent.make(
            row: makeRow(kind: .url, title: address),
            detail: ClipDetail(excerpt: address, characterCount: 35, linkTitle: "Git - git-rebase Documentation"),
            cardSize: .medium)

        XCTAssertEqual(content.body, .link(title: AttributedString("Git - git-rebase Documentation")))
        // The footer names the site.
        XCTAssertEqual(content.info, "git-scm.com")
        XCTAssertNil(content.memoTitle)
    }

    func testALinkWithoutATitleShowsItsDecodedPath() {
        let address = "https://developer.apple.com/documentation/appkit/nspanel"

        let content = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: address, characterCount: 56), cardSize: .medium)

        XCTAssertEqual(content.body, .link(title: AttributedString("/documentation/appkit/nspanel")))
        XCTAssertEqual(content.info, "developer.apple.com")

        // The port, query and fragment belong to the path, which reads with its escapes decoded.
        let detailed = StripFrameContent.make(
            row: makeRow(kind: .url),
            detail: ClipDetail(excerpt: "https://example.com:8443/search?q=swift%20ui&page=2#top", characterCount: 55),
            cardSize: .medium)
        XCTAssertEqual(detailed.body, .link(title: AttributedString(":8443/search?q=swift ui&page=2#top")))
        XCTAssertEqual(detailed.info, "example.com")
        // A Chinese address reads as Chinese, whether it was copied escaped or not.
        for address in ["https://zh.wikipedia.org/wiki/中文?q=测试",
                        "https://zh.wikipedia.org/wiki/%E4%B8%AD%E6%96%87?q=%E6%B5%8B%E8%AF%95"] {
            let chinese = StripFrameContent.make(
                row: makeRow(kind: .url), detail: ClipDetail(excerpt: address, characterCount: address.count),
                cardSize: .medium)
            XCTAssertEqual(chinese.body, .link(title: AttributedString("/wiki/中文?q=测试")), address)
            XCTAssertEqual(chinese.info, "zh.wikipedia.org", address)
        }
        // An escape that does not decode leaves the path as written.
        let undecodable = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "https://example.com/a%FFb?q=1", characterCount: 29),
            cardSize: .medium)
        XCTAssertEqual(undecodable.body, .link(title: AttributedString("/a%FFb?q=1")))
        // A host alone, or with only the root path, has no path to show, so the host stands in.
        let bare = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "https://example.com", characterCount: 19),
            cardSize: .medium)
        XCTAssertEqual(bare.body, .link(title: AttributedString("example.com")))
        let root = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "https://apple.com/", characterCount: 18),
            cardSize: .medium)
        XCTAssertEqual(root.body, .link(title: AttributedString("apple.com")))
        // A page title of only blanks does not count.
        let blankTitle = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: address, characterCount: 56, linkTitle: " \n"),
            cardSize: .medium)
        XCTAssertEqual(blankTitle.body, .link(title: AttributedString("/documentation/appkit/nspanel")))

        // A link that does not split into a host and the rest is set as text, and its length is told.
        let mail = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "mailto:someone@example.com", characterCount: 26),
            cardSize: .medium)
        XCTAssertEqual(mail.body, .text(AttributedString("mailto:someone@example.com"),
                                        style: StripTextStyle(size: 18, lineHeight: 26)))
        XCTAssertEqual(mail.info, "26 characters")
        // A link whose address could not be read has nothing to split.
        let unread = StripFrameContent.make(row: makeRow(kind: .url, title: "Apple docs"), detail: ClipDetail(),
                                            cardSize: .medium)
        XCTAssertEqual(unread.body, .placeholder(symbol: "link", title: "Apple docs"))
        XCTAssertNil(unread.info)
    }

    func testImageAndFileInfoAndTheMultiItemMarker() throws {
        let thumbnail = try makeImage(width: 8, height: 6)
        let photo = ClipDetail(pixelSize: CGSize(width: 4032, height: 3024), thumbnail: thumbnail, fillsFrame: true)

        let filled = StripFrameContent.make(row: makeRow(kind: .image), detail: photo, cardSize: .medium)

        XCTAssertEqual(filled.body, .image(thumbnail, fills: true))
        XCTAssertEqual(filled.info, "4032 × 3024")
        XCTAssertEqual(filled.extraItems, 0)

        // A picture shown whole keeps the shape its header gives it: ImageIO rounds the thumbnail's size,
        // which for a hairline of a picture is a very different shape.
        let hairline = ClipDetail(pixelSize: CGSize(width: 10, height: 4000), thumbnail: try makeImage(width: 9, height: 218),
                                  fillsFrame: false)
        let whole = StripFrameContent.make(row: makeRow(kind: .image), detail: hairline, cardSize: .medium)
        guard case .image(_, let fills) = whole.body else { return XCTFail("Expected an image body") }
        XCTAssertFalse(fills)
        XCTAssertEqual(whole.imageAspectRatio, 10.0 / 4000.0)
        XCTAssertEqual(whole.info, "10 × 4000")

        // Without a thumbnail the frame shows the placeholder and still tells the size.
        let undrawn = StripFrameContent.make(
            row: makeRow(kind: .image, title: "Screenshot"), detail: ClipDetail(pixelSize: CGSize(width: 4032, height: 3024)),
            cardSize: .medium)
        XCTAssertEqual(undrawn.body, .placeholder(symbol: "photo", title: "Screenshot"))
        XCTAssertEqual(undrawn.info, "4032 × 3024")

        // Files: the first name sets the icon's type, and two items are two files.
        let pair = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["a.pdf", "b.txt"], itemCount: 2),
            cardSize: .medium)
        XCTAssertEqual(pair.body, .file(name: "a.pdf", typeIdentifier: UTType.pdf.identifier))
        XCTAssertEqual(pair.info, "2 files")
        XCTAssertEqual(pair.extraItems, 1)
        let single = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["Quarterly report.pdf"]), cardSize: .medium)
        XCTAssertEqual(single.info, "PDF")
        XCTAssertEqual(single.extraItems, 0)
        // A file whose name could not be read still counts as a file.
        let partial = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["a.pdf"], itemCount: 3), cardSize: .medium)
        XCTAssertEqual(partial.body, .file(name: "a.pdf", typeIdentifier: UTType.pdf.identifier))
        XCTAssertEqual(partial.info, "3 files")
        XCTAssertEqual(partial.extraItems, 2)
        // With no name at all the frame shows the generic file icon and the title; one unread file is a "File".
        let unnamed = StripFrameContent.make(
            row: makeRow(kind: .file, title: "Contract"), detail: ClipDetail(fileNames: [], itemCount: 1),
            cardSize: .medium)
        XCTAssertEqual(unnamed.body, .file(name: "Contract", typeIdentifier: nil))
        XCTAssertEqual(unnamed.info, "File")
        let noExtension = StripFrameContent.make(
            row: makeRow(kind: .file), detail: ClipDetail(fileNames: ["README"]), cardSize: .medium)
        XCTAssertEqual(noExtension.body, .file(name: "README", typeIdentifier: nil))
        XCTAssertEqual(noExtension.info, "File")

        // Several items that are not files are counted as items, a link's among them.
        let other = StripFrameContent.make(row: makeRow(kind: .other), detail: ClipDetail(itemCount: 2),
                                           cardSize: .medium)
        XCTAssertEqual(other.info, "2 items")
        XCTAssertEqual(other.extraItems, 1)
        let texts = StripFrameContent.make(
            row: makeRow(), detail: ClipDetail(excerpt: "First", characterCount: 5, itemCount: 3), cardSize: .medium)
        XCTAssertEqual(texts.body, .text(AttributedString("First"), style: StripTextStyle(size: 20, lineHeight: 27)))
        XCTAssertEqual(texts.info, "3 items")
        XCTAssertEqual(texts.extraItems, 2)
        let links = StripFrameContent.make(
            row: makeRow(kind: .url), detail: ClipDetail(excerpt: "https://apple.com/mac", characterCount: 21, itemCount: 2),
            cardSize: .medium)
        XCTAssertEqual(links.info, "2 items")
        // One item of an unknown kind has nothing to tell.
        XCTAssertNil(StripFrameContent.make(row: makeRow(kind: .other), detail: ClipDetail(), cardSize: .medium).info)
    }

    func testMarkersAndTextUnavailable() {
        let plain = StripFrameContent.make(row: makeRow(), detail: ClipDetail(excerpt: "Plain", characterCount: 5),
                                           cardSize: .medium)
        XCTAssertEqual(plain.markers, [])
        XCTAssertFalse(plain.isTextUnavailable)

        let memo = StripFrameContent.make(row: makeRow(savedAsMemo: true), detail: ClipDetail(excerpt: "Memo", characterCount: 4),
                                          cardSize: .medium)
        XCTAssertEqual(memo.markers, [.savedAsMemo])

        let partial = StripFrameContent.make(row: makeRow(isPartiallyIndexed: true),
                                             detail: ClipDetail(excerpt: "Partial", characterCount: 7),
                                             cardSize: .medium)
        XCTAssertEqual(partial.markers, [.partiallyIndexed])

        let both = StripFrameContent.make(row: makeRow(savedAsMemo: true, isPartiallyIndexed: true),
                                          detail: ClipDetail(excerpt: "Both", characterCount: 4), cardSize: .medium)
        XCTAssertEqual(both.markers, [.savedAsMemo, .partiallyIndexed])

        // The flag is copied from the row, with the details or without them.
        let unavailable = makeRow(isTextUnavailable: true)
        XCTAssertTrue(StripFrameContent.make(row: unavailable, detail: nil, cardSize: .medium).isTextUnavailable)
        XCTAssertTrue(
            StripFrameContent.make(row: unavailable, detail: ClipDetail(), cardSize: .medium).isTextUnavailable)
        // A clip that is not a memo has no title to show over the notice.
        XCTAssertNil(StripFrameContent.make(row: unavailable, detail: ClipDetail(), cardSize: .medium).memoTitle)

        // A saved memo whose text is gone keeps its own title above the notice, before the details and after.
        let goneMemo = makeRow(title: "Standup", savedAsMemo: true, isTextUnavailable: true)
        XCTAssertEqual(StripFrameContent.make(row: goneMemo, detail: nil, cardSize: .medium).memoTitle, "Standup")
        XCTAssertEqual(StripFrameContent.make(row: goneMemo, detail: ClipDetail(), cardSize: .medium).memoTitle, "Standup")
        // One without a title has none to show.
        let untitled = makeRow(title: "", savedAsMemo: true, isTextUnavailable: true)
        XCTAssertNil(StripFrameContent.make(row: untitled, detail: ClipDetail(), cardSize: .medium).memoTitle)
    }

    func testVoiceOverNamesAClipByTheTitleItsCardShows() {
        let address = "https://git-scm.com/docs/git-rebase"
        // A link is named by its page's title, or by its path, as its card shows it, and not by its address.
        let titled = StripFrameContent.make(
            row: makeRow(kind: .url, title: address),
            detail: ClipDetail(excerpt: address, characterCount: 35, linkTitle: "Git - git-rebase Documentation"),
            cardSize: .medium)
        XCTAssertEqual(titled.accessibilityTitle, "Git - git-rebase Documentation")
        let untitled = StripFrameContent.make(
            row: makeRow(kind: .url, title: address), detail: ClipDetail(excerpt: address, characterCount: 35),
            cardSize: .medium)
        XCTAssertEqual(untitled.accessibilityTitle, "/docs/git-rebase")
        // Until the details arrive, and for every other kind, the clip's own title names it.
        XCTAssertEqual(StripFrameContent.make(row: makeRow(kind: .url, title: address), detail: nil, cardSize: .medium)
            .accessibilityTitle, address)
        XCTAssertEqual(StripFrameContent.make(row: makeRow(title: ""), detail: ClipDetail(excerpt: "Hello", characterCount: 5),
                                              cardSize: .medium).accessibilityTitle, "Clipboard Item")
    }

    /// The runs set in bold, in order.
    private func emphasised(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(text[$0.range].characters) }
    }
}

private func makeRow(
    kind: ContentKind = .text, title: String = "Synthetic title", snippet: SearchSnippet? = nil,
    sourceApp: String? = nil, date: Date = Date(timeIntervalSince1970: 1_000),
    savedAsMemo: Bool = false, isPartiallyIndexed: Bool = false, isTextUnavailable: Bool = false
) -> QuickAccessRow {
    QuickAccessRow(
        ref: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 3, count: 32)),
        title: title, snippet: snippet, kind: kind, sourceApp: sourceApp, date: date,
        savedAsMemo: savedAsMemo, isPartiallyIndexed: isPartiallyIndexed, isTextUnavailable: isTextUnavailable
    )
}

private func makeImage(width: Int, height: Int) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try XCTUnwrap(context.makeImage())
}
