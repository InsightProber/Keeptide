import AppKit
import XCTest
@testable import Keeptide

final class MemoTextExtractorTests: XCTestCase {
    func testExplicitMarkdownTypesPreserveExactUTF8Source() throws {
        let source = "# 标题\n\n- [ ] keep  two spaces  \n`echo $HOME`\n"

        for type in ["net.daringfireball.markdown", "text/markdown"] {
            let extracted = try XCTUnwrap(MemoTextExtractor.editableText(from: resolved([
                representation(0, type, Data(source.utf8)),
                representation(1, "public.utf8-plain-text", Data("fallback".utf8)),
            ])))

            XCTAssertEqual(extracted.text, source, type)
            XCTAssertEqual(extracted.sourceRepresentationType, type, type)
            XCTAssertTrue(ContentKind.isMarkdown(type), type)
        }
        XCTAssertFalse(ContentKind.isMarkdown("public.utf8-plain-text"))
        XCTAssertFalse(ContentKind.isMarkdown("public.html"))
    }

    func testInvalidUTF8MarkdownDoesNotBecomeEditableSource() throws {
        for type in ["net.daringfireball.markdown", "text/markdown"] {
            XCTAssertNil(try MemoTextExtractor.editableText(from: resolved([
                representation(0, type, Data([0xC3, 0x28])),
            ])), type)
        }
    }

    func testPlainTextWinsOverRTFAndHTMLAndIsNeverPreviewTruncated() throws {
        let text = String(repeating: "完整正文🙂", count: 2_000)
        let content = resolved([
            representation(2, "public.html", Data("<p>html</p>".utf8)),
            representation(1, "public.rtf", Data(#"{\rtf1 rtf}"#.utf8)),
            representation(0, "public.utf8-plain-text", Data(text.utf8)),
        ])

        let extracted = try XCTUnwrap(MemoTextExtractor.editableText(from: content))

        XCTAssertEqual(extracted.text, text)
        XCTAssertEqual(extracted.sourceRepresentationType, "public.utf8-plain-text")
    }

    func testInvalidPlainTextFallsBackToRTF() throws {
        let rtf = try XCTUnwrap(NSAttributedString(string: "RTF 正文").data(
            from: NSRange(location: 0, length: 6),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))
        let content = resolved([
            representation(0, "public.utf8-plain-text", Data([0xC3, 0x28])),
            representation(1, "public.rtf", rtf),
        ])

        let extracted = try XCTUnwrap(MemoTextExtractor.editableText(from: content))

        XCTAssertEqual(extracted.text, "RTF 正文")
        XCTAssertEqual(extracted.sourceRepresentationType, "public.rtf")
    }

    func testUTF16PlainTextWithBOMRemainsComplete() throws {
        let text = "中文命令\n" + String(repeating: "字", count: 12_000)
        var bytes = Data([0xFF, 0xFE])
        bytes.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))

        let extracted = try XCTUnwrap(MemoTextExtractor.editableText(from: resolved([
            representation(0, "public.utf16-plain-text", bytes),
        ])))

        XCTAssertEqual(extracted.text, text)
        XCTAssertEqual(extracted.sourceRepresentationType, "public.utf16-plain-text")
    }

    func testRTFWithAnAttachmentIsNotFlattenedIntoEditableText() throws {
        // RTF represents embedded objects in the imported string with U+FFFC. Even if an importer
        // does not attach an NSTextAttachment attribute, dropping that scalar would silently join
        // the text on either side of non-text content.
        let rtf = Data(#"{\rtf1 before \u-4? after}"#.utf8)

        XCTAssertNil(try MemoTextExtractor.editableText(from: resolved([
            representation(0, "public.rtf", rtf),
        ])))
    }

    func testSafeHTMLExtractsBlockBreaksAndEntitiesWithoutUsingAWebView() throws {
        let html = "<h1>Title &amp; one</h1><p class='lead'>First<br>Second &#x1F642;</p><ul><li>A</li><li><a href='https://example.invalid/?x=>'>B&nbsp;C</a></li></ul>"

        let extracted = try XCTUnwrap(MemoTextExtractor.editableText(from: resolved([
            representation(0, "public.html", Data(html.utf8)),
        ])))

        XCTAssertEqual(extracted.text, "Title & one\nFirst\nSecond 🙂\nA\nB C")
        XCTAssertEqual(extracted.sourceRepresentationType, "public.html")
    }

    func testUnsafeOrAmbiguousHTMLIsRejectedRatherThanExecutedOrSilentlyLost() throws {
        for html in [
            #"<p>safe</p><script src="https://example.invalid/x.js">steal()</script>"#,
            #"<style>@import "https://example.invalid/x.css"</style><p>safe</p>"#,
            #"<img src="https://example.invalid/tracker.png"><p>safe</p>"#,
            "<p>unknown &madeup; entity</p>",
            "<marquee>unsupported structure</marquee>",
            "<p>mismatched</div>",
            "<p>unclosed",
        ] {
            XCTAssertNil(try MemoTextExtractor.editableText(from: resolved([
                representation(0, "public.html", Data(html.utf8)),
            ])), html)
        }
    }

    func testMultiplePasteboardItemsAndNonTextContentAreNotEditable() throws {
        let multiple = resolved([
            representation(0, "public.utf8-plain-text", Data("first".utf8), item: 0),
            representation(0, "public.utf8-plain-text", Data("second".utf8), item: 1),
        ])
        let image = resolved([representation(0, "public.png", Data([0x89, 0x50, 0x4E, 0x47]))])
        let recovering = ResolvedContent(ref: ref(), integrity: .recovering, representations: [])

        XCTAssertNil(try MemoTextExtractor.editableText(from: multiple))
        XCTAssertNil(try MemoTextExtractor.editableText(from: image))
        XCTAssertNil(try MemoTextExtractor.editableText(from: recovering))
    }

    private func resolved(_ representations: [RepresentationValue]) -> ResolvedContent {
        ResolvedContent(ref: ref(), integrity: .complete, representations: representations)
    }

    private func ref() -> ContentRef {
        ContentRef(itemID: ItemID(), facet: .memo, version: ContentVersion(), digest: Data(repeating: 7, count: 32))
    }

    private func representation(
        _ order: Int,
        _ type: String,
        _ bytes: Data,
        item: Int = 0
    ) -> RepresentationValue {
        RepresentationValue(
            snapshotID: UUID(), itemIndex: item, representationIndex: order,
            typeIdentifier: type, storage: .portable,
            byteCount: Int64(bytes.count), digest: ContentDigest.sha256(bytes), bytes: bytes
        )
    }
}
