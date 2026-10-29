import Foundation
import XCTest
@testable import Keeptide

final class ClipboardTextDecoderTests: XCTestCase {
    func testDecodeTextHonorsLargerLimitWithoutChangingPreview() {
        let bytes = Data(String(repeating: "a", count: 20_000).utf8)
        let decoded = ClipboardTextDecoder.decodeText(
            bytes, typeIdentifier: "public.utf8-plain-text", maximumBytes: 1_048_576
        )
        let representation = RepresentationValue(
            snapshotID: UUID(), itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.utf8-plain-text", storage: .portable,
            byteCount: Int64(bytes.count), digest: ContentDigest.sha256(bytes), bytes: bytes
        )

        XCTAssertEqual(decoded?.text.utf8.count, 20_000)
        XCTAssertEqual(decoded?.isTruncated, false)
        XCTAssertEqual(ClipboardTextDecoder.preview([representation])?.isTruncated, true)
        XCTAssertTrue(ClipboardTextDecoder.isTextType("PUBLIC.UTF8-PLAIN-TEXT"))
        XCTAssertFalse(ClipboardTextDecoder.isTextType("public.rtf"))
    }

    func testTitleUsesShortFirstLineWhenBoundedPrefixEndsInsideMultibyteScalar() {
        let suffix = String(repeating: "a", count: 4_088) + "🙂"
        let bytes = Data(("标题\n" + suffix).utf8)
        let items = [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: bytes),
        ])]

        XCTAssertEqual(ClipboardTextDecoder.title(items), "标题")
    }

    func testTitleRejectsNULAndWhitespaceOnlyLines() {
        let nul = [CapturedPasteboardItem(representations: [
            CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("hello\0world\nbody".utf8)
            ),
        ])]
        let whitespace = [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.plain-text", bytes: Data(" \t \nbody".utf8)),
        ])]

        XCTAssertEqual(ClipboardTextDecoder.title(nul), "helloworld")
        XCTAssertEqual(ClipboardTextDecoder.title(whitespace), "body")
    }

    func testTitleAndPreviewShareSupportedTextRepresentations() {
        for type in [
            "public.utf8-plain-text",
            "public.plain-text",
            "public.url",
            "NSStringPboardType",
        ] {
            let data = Data("same text".utf8)
            let items = [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: type, bytes: data),
            ])]
            let stored = [representation(type: type, bytes: data)]

            XCTAssertEqual(ClipboardTextDecoder.title(items), "same text", type)
            XCTAssertEqual(ClipboardTextDecoder.preview(stored)?.text, "same text", type)
        }
    }

    func testPreviewIsBoundedAndReportsTruncationWithoutSplittingUTF8() throws {
        let data = Data((String(repeating: "a", count: 8_190) + "🙂tail").utf8)
        let result = try XCTUnwrap(ClipboardTextDecoder.preview([
            representation(type: "public.utf8-plain-text", bytes: data),
        ]))

        XCTAssertTrue(result.isTruncated)
        XCTAssertLessThanOrEqual(result.text.utf8.count, 8_192)
        XCTAssertFalse(result.text.contains("�"))
    }

    func testUTF16PreviewUsesAnEvenBoundedPrefix() throws {
        let text = "中文 preview " + String(repeating: "字", count: 5_000)
        let data = try XCTUnwrap(text.data(using: .utf16LittleEndian))
        let result = try XCTUnwrap(ClipboardTextDecoder.preview([
            representation(type: "public.utf16-external-plain-text", bytes: data),
        ]))

        XCTAssertTrue(result.text.hasPrefix("中文 preview"))
        XCTAssertTrue(result.isTruncated)
        XCTAssertFalse(result.text.contains("�"))
    }

    func testUTF16TitleAndPreviewUseTheSameDecoder() throws {
        let data = try XCTUnwrap("中文标题\nbody".data(using: .utf16LittleEndian))
        let items = [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf16-plain-text", bytes: data),
        ])]
        let stored = [representation(type: "public.utf16-plain-text", bytes: data)]

        XCTAssertEqual(ClipboardTextDecoder.title(items), "中文标题")
        XCTAssertEqual(ClipboardTextDecoder.preview(stored)?.text, "中文标题\nbody")
    }

    func testLinkTitleIsReadFromTheURLNameAlone() throws {
        let url = representation(type: "public.url", bytes: Data("https://zh.wikipedia.org/wiki/剪贴板".utf8))
        let name = representation(type: "public.url-name", bytes: Data("  剪贴板 - 维基百科\n".utf8))

        // Trimmed as the link itself is, and found in any order among the representations.
        XCTAssertEqual(ClipboardTextDecoder.linkTitle([url, name]), "剪贴板 - 维基百科")
        XCTAssertEqual(ClipboardTextDecoder.linkTitle([name, url]), "剪贴板 - 维基百科")
        // A byte order mark selects UTF-16, as for any text, and NUL is dropped.
        let utf16 = Data([0xFF, 0xFE]) + (try XCTUnwrap("Page\u{0} title".data(using: .utf16LittleEndian)))
        XCTAssertEqual(ClipboardTextDecoder.linkTitle([representation(type: "PUBLIC.URL-NAME", bytes: utf16)]), "Page title")
        // No name, or one of only blanks, is no title; the URL and plain text are never taken for one.
        XCTAssertNil(ClipboardTextDecoder.linkTitle([url]))
        XCTAssertNil(ClipboardTextDecoder.linkTitle([url, representation(type: "public.url-name", bytes: Data(" \n\t".utf8))]))
        XCTAssertNil(ClipboardTextDecoder.linkTitle([representation(type: "public.utf8-plain-text", bytes: Data("Title".utf8))]))
        // Only its first 4 KB is read, as for a clip's title, and never half a character: 1,365 three-byte characters.
        let long = representation(type: "public.url-name", bytes: Data(String(repeating: "页", count: 3_000).utf8))
        XCTAssertEqual(ClipboardTextDecoder.linkTitle([long]), String(repeating: "页", count: 1_365))
        // The name is not text in its own right: titles and previews still skip it.
        XCTAssertFalse(ClipboardTextDecoder.isTextType("public.url-name"))
        XCTAssertNil(ClipboardTextDecoder.preview([name]))
    }

    private func representation(type: String, bytes: Data) -> RepresentationValue {
        RepresentationValue(
            snapshotID: UUID(),
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: type,
            storage: .portable,
            byteCount: Int64(bytes.count),
            digest: ContentDigest.sha256(bytes),
            bytes: bytes
        )
    }
}
