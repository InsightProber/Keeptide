import Foundation
import XCTest
@testable import Keeptide

final class ClipboardTextDecoderTests: XCTestCase {
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
