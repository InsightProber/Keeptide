import Foundation
import XCTest
@testable import Keeptide

final class SearchDocumentBuilderTests: XCTestCase {
    func testHistoryDocumentUsesFirstDecodableTextPerItemJoinedByNewline() throws {
        let second = try XCTUnwrap("second".data(using: .utf16LittleEndian))
        let input = makeInput(representations: [
            text(0, 0, "public.rtf", Data(#"{\rtf1 ignored}"#.utf8)),
            text(0, 1, "public.utf8-plain-text", Data("first".utf8)),
            text(1, 0, "public.utf16-plain-text", second),
        ])

        let documents = SearchDocumentBuilder.documents(for: input)

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.ref, input.history)
        XCTAssertEqual(documents.first?.body, "first\nsecond")
        XCTAssertEqual(documents.first?.url, "")
        XCTAssertEqual(documents.first?.kind, .text)
        XCTAssertEqual(documents.first?.bodyPartial, false)
        XCTAssertEqual(documents.first?.textUnavailable, false)
    }

    func testURLRepresentationFillsURLFieldAndKind() {
        let address = Data("https://example.com/a".utf8)
        let input = makeInput(representations: [
            text(0, 0, "public.url", address),
            text(0, 1, "public.utf8-plain-text", address),
        ])

        let document = SearchDocumentBuilder.documents(for: input).first

        XCTAssertEqual(document?.url, "https://example.com/a")
        XCTAssertEqual(document?.body, "https://example.com/a")
        XCTAssertEqual(document?.kind, .url)
    }

    func testDigestMismatchIndexesMetadataOnly() {
        let bytes = Data("secret body".utf8)
        let damaged = TextRepresentation(
            itemIndex: 0, representationIndex: 0, typeIdentifier: "public.utf8-plain-text",
            byteCount: Int64(bytes.count), digest: Data(repeating: 0, count: 32), bytes: bytes
        )
        let input = makeInput(title: "Visible title", representations: [damaged])

        let document = SearchDocumentBuilder.documents(for: input).first

        XCTAssertEqual(document?.title, "Visible title")
        XCTAssertEqual(document?.body, "")
        XCTAssertEqual(document?.url, "")
        XCTAssertEqual(document?.textUnavailable, true)
    }

    func testBodyIsCappedAtOneMebibyteOnCharacterBoundary() throws {
        let bytes = Data(String(repeating: "界", count: 400_000).utf8)
        let input = makeInput(representations: [text(0, 0, "public.utf8-plain-text", bytes)])

        let document = try XCTUnwrap(SearchDocumentBuilder.documents(for: input).first)

        XCTAssertLessThanOrEqual(document.body.utf8.count, 1_048_576)
        XCTAssertGreaterThan(document.body.utf8.count, 1_048_573)
        XCTAssertTrue(document.bodyPartial)
        XCTAssertTrue(document.body.allSatisfy { $0 == "界" })
    }

    func testInheritedMemoWithVisibleHistoryProducesMergedRows() throws {
        let collections = CollectionID.sorted([CollectionID(), CollectionID()])
        let input = makeInput(
            representations: [text(0, 0, "public.utf8-plain-text", Data("kubectl rollout restart".utf8))],
            collectionIDs: collections,
            memo: { itemID, captureID in
                MemoProjection(
                    ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(rawValue: captureID),
                                    digest: Data(repeating: 2, count: 32)),
                    memoID: UUID(), title: "部署命令", note: "prod", isInherited: true, body: nil
                )
            }
        )

        let documents = SearchDocumentBuilder.documents(for: input)
        let history = try XCTUnwrap(documents.first { $0.ref.facet == .history })
        let memo = try XCTUnwrap(documents.first { $0.ref.facet == .memo })

        XCTAssertEqual(documents.count, 2)
        XCTAssertTrue(history.savedAsMemo)
        XCTAssertFalse(history.merged)
        XCTAssertEqual(history.title, "部署命令")
        XCTAssertEqual(history.note, "prod")
        XCTAssertEqual(history.collectionIDs, [])
        XCTAssertEqual(history.body, "kubectl rollout restart")
        XCTAssertTrue(memo.merged)
        XCTAssertFalse(memo.savedAsMemo)
        XCTAssertEqual(memo.ref, input.memo?.ref)
        XCTAssertEqual(memo.collectionIDs, collections)
        XCTAssertEqual(memo.body, "kubectl rollout restart")
        XCTAssertEqual(memo.memoID, input.memo?.memoID)
    }

    func testOwnedMemoIsNotMergedAndUsesItsOwnBody() throws {
        let input = makeInput(
            title: "Item title",
            representations: [],
            types: ["public.png"],
            memo: { itemID, _ in
                MemoProjection(
                    ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(),
                                    digest: Data(repeating: 3, count: 32)),
                    memoID: UUID(), title: "", note: "", isInherited: false, body: Data("edited text".utf8)
                )
            }
        )

        let documents = SearchDocumentBuilder.documents(for: input)
        let history = try XCTUnwrap(documents.first { $0.ref.facet == .history })
        let memo = try XCTUnwrap(documents.first { $0.ref.facet == .memo })

        // An edited snippet still marks its clip's row as saved; only an inherited one lends its title and note.
        XCTAssertTrue(history.savedAsMemo)
        XCTAssertEqual(history.title, "Item title")
        XCTAssertEqual(history.kind, .image)
        XCTAssertFalse(memo.merged)
        XCTAssertEqual(memo.body, "edited text")
        XCTAssertEqual(memo.title, "Item title")
        XCTAssertEqual(memo.kind, .text)
        XCTAssertEqual(memo.url, "")
    }

    func testInheritedMemoWithoutHistoryIsNotMerged() throws {
        let input = makeInput(
            representations: [text(0, 0, "public.utf8-plain-text", Data("only memo".utf8))],
            includeHistory: false,
            memo: { itemID, captureID in
                MemoProjection(
                    ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(rawValue: captureID),
                                    digest: Data(repeating: 4, count: 32)),
                    memoID: UUID(), title: "Memo", note: "", isInherited: true, body: nil
                )
            }
        )

        let documents = SearchDocumentBuilder.documents(for: input)

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.ref.facet, .memo)
        XCTAssertEqual(documents.first?.merged, false)
        XCTAssertEqual(documents.first?.body, "only memo")
    }

    func testKindPrecedence() {
        let cases: [([String], ContentKind)] = [
            (["public.file-url", "public.png", "public.utf8-plain-text"], .file),
            (["public.png", "public.utf8-plain-text"], .image),
            (["public.url"], .url),
            (["public.utf8-plain-text"], .text),
            (["com.example.custom"], .other),
        ]
        for (types, expected) in cases {
            let input = makeInput(representations: [], types: types)
            XCTAssertEqual(SearchDocumentBuilder.documents(for: input).first?.kind, expected, "\(types)")
        }
    }

    func testNormalizedFieldsUseTheNormalizer() throws {
        let input = makeInput(
            title: "ＡＢＣ Title",
            representations: [
                text(0, 0, "public.url", Data("HTTPS://Example.COM".utf8)),
                text(0, 1, "public.utf8-plain-text", Data("Ｃａｆé body".utf8)),
            ],
            memo: { itemID, captureID in
                MemoProjection(
                    ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(rawValue: captureID),
                                    digest: Data(repeating: 5, count: 32)),
                    memoID: UUID(), title: "", note: "Ｎｏｔｅ É", isInherited: true, body: nil
                )
            }
        )

        for document in SearchDocumentBuilder.documents(for: input) {
            XCTAssertEqual(document.normalizedTitle, SearchNormalizer.normalize(document.title))
            XCTAssertEqual(document.normalizedBody, SearchNormalizer.normalize(document.body))
            XCTAssertEqual(document.normalizedURL, SearchNormalizer.normalize(document.url))
            XCTAssertEqual(document.normalizedNote, SearchNormalizer.normalize(document.note))
        }
        let history = try XCTUnwrap(SearchDocumentBuilder.documents(for: input).first { $0.ref.facet == .history })
        XCTAssertEqual(history.normalizedNote, "note e")
        XCTAssertEqual(history.normalizedURL, "https://example.com")
    }

    func testNULIsRemovedFromIndexedText() {
        let input = makeInput(representations: [text(0, 0, "public.utf8-plain-text", Data("a\0b".utf8))])

        XCTAssertEqual(SearchDocumentBuilder.documents(for: input).first?.body, "ab")
    }

    // MARK: Text recognized in an image

    func testTheTextRecognizedInAnImageIsSearchedAsItsBody() throws {
        var item = makeInput(representations: [], types: ["public.png"])
        item.recognizedText = recognized("Quarterly plan 季度计划")

        let history = try XCTUnwrap(SearchDocumentBuilder.documents(for: item).first)

        XCTAssertEqual(history.kind, .image)
        XCTAssertEqual(history.body, "Quarterly plan 季度计划")
        XCTAssertEqual(history.normalizedBody, SearchNormalizer.normalize("Quarterly plan 季度计划"))
        XCTAssertFalse(history.bodyPartial)
    }

    func testRecognizedTextFollowsTheImagesOwnText() {
        var item = makeInput(representations: [text(0, 1, "public.utf8-plain-text", Data("Screenshot 1".utf8))],
                             types: ["public.png", "public.utf8-plain-text"])
        item.recognizedText = recognized("Quarterly plan")

        XCTAssertEqual(SearchDocumentBuilder.documents(for: item).first?.body, "Screenshot 1\nQuarterly plan")
    }

    func testRecognizedTextIsCappedWithTheBody() throws {
        var item = makeInput(representations: [], types: ["public.png"])
        item.recognizedText = recognized(String(repeating: "文", count: SearchDocumentBuilder.bodyByteLimit))

        let history = try XCTUnwrap(SearchDocumentBuilder.documents(for: item).first)

        XCTAssertLessThanOrEqual(history.body.utf8.count, SearchDocumentBuilder.bodyByteLimit)
        XCTAssertTrue(history.body.allSatisfy { $0 == "文" }, "Cut on a character")
        XCTAssertTrue(history.bodyPartial)
    }

    func testOnlyAnImageSearchesRecognizedText() {
        var item = makeInput(representations: [text(0, 0, "public.utf8-plain-text", Data("Plain note".utf8))])
        item.recognizedText = recognized("Never searched")

        XCTAssertEqual(SearchDocumentBuilder.documents(for: item).first?.body, "Plain note")
    }

    func testAClipAndItsSnippetEachSearchTheirOwnRecognizedTextFirst() {
        var item = makeInput(representations: [], types: ["public.png"], memo: { itemID, captureID in
            var memo = MemoProjection(
                ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(rawValue: captureID),
                                digest: Data(repeating: 1, count: 32)),
                memoID: UUID(), title: "Snippet", note: "", isInherited: true, body: nil
            )
            memo.recognizedText = self.recognized("Snippet's own text")
            return memo
        })
        item.recognizedText = recognized("Clip's text")

        XCTAssertEqual(SearchDocumentBuilder.documents(for: item).map(\.body),
                       ["Clip's text\nSnippet's own text", "Snippet's own text\nClip's text"])
    }

    func testAClipAndTheSnippetSavedFromItShareTheTextRecognizedInEither() {
        // The clip stands for both in All, and the snippet is the same image.
        let fromSnippet = clipAndSnippet(clip: nil, snippet: "Snippet text")
        let fromClip = clipAndSnippet(clip: "Clip text", snippet: nil)

        XCTAssertEqual(SearchDocumentBuilder.documents(for: fromSnippet).map(\.body), ["Snippet text", "Snippet text"])
        XCTAssertEqual(SearchDocumentBuilder.documents(for: fromClip).map(\.body), ["Clip text", "Clip text"])
    }

    func testTheSameTextRecognizedInAClipAndItsSnippetIsSearchedOnce() {
        let item = clipAndSnippet(clip: "Quarterly plan", snippet: "Quarterly plan")

        XCTAssertEqual(SearchDocumentBuilder.documents(for: item).map(\.body), ["Quarterly plan", "Quarterly plan"])
    }

    func testALineBreakBesideChineseOrJapaneseIsLeftOutOfTheSearchedText() throws {
        XCTAssertEqual(try recognizedBody("季度\n计划"), "季度计划")
        XCTAssertEqual(try recognizedBody("かな\nカナ\n漢字"), "かなカナ漢字")
        XCTAssertEqual(try recognizedBody("第4\n季度\niPhone\n拍摄"), "第4季度iPhone拍摄", "Beside a digit or a Latin letter")
        XCTAssertEqual(try recognizedBody("「计划」\nQ4 季度：\nQ1"), "「计划」Q4 季度：Q1", "Beside their punctuation")
        XCTAssertEqual(try recognizedBody("Quarterly\nplan\n한국\n어"), "Quarterly\nplan\n한국\n어",
                       "Words written with spaces between them")
        XCTAssertEqual(try recognizedBody("计划\n\n明年"), "计划\n\n明年", "A blank line between parts")
        XCTAssertEqual(try recognizedBody("计划 \n明年"), "计划 \n明年", "A space before the break")
    }

    func testRecognizedTextThatIsDamagedOrNotUTF8IsNotSearched() {
        var damaged = makeInput(representations: [], types: ["public.png"])
        let text = recognized("Quarterly plan")
        damaged.recognizedText = RecognizedTextRow(id: text.id, source: text.source, bytes: text.bytes,
                                                   digest: Data(repeating: 0, count: 32))
        var undecodable = makeInput(representations: [], types: ["public.png"])
        let bytes = Data([0xFF, 0xFE, 0x41])
        undecodable.recognizedText = RecognizedTextRow(id: text.id, source: text.source, bytes: bytes,
                                                       digest: ContentDigest.sha256(bytes))

        XCTAssertEqual(SearchDocumentBuilder.documents(for: damaged).first?.body, "")
        XCTAssertEqual(SearchDocumentBuilder.documents(for: undecodable).first?.body, "")
    }

    /// An image clip saved as a snippet that inherits it, each with the text recognized in it, if any.
    private func clipAndSnippet(clip: String?, snippet: String?) -> SearchProjectionInput {
        var item = makeInput(representations: [], types: ["public.png"], memo: { itemID, captureID in
            var memo = MemoProjection(
                ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(rawValue: captureID),
                                digest: Data(repeating: 1, count: 32)),
                memoID: UUID(), title: "Snippet", note: "", isInherited: true, body: nil
            )
            memo.recognizedText = snippet.map(self.recognized)
            return memo
        })
        item.recognizedText = clip.map(recognized)
        return item
    }

    /// The searched body of an image with no text of its own, whose recognized text is `text`.
    private func recognizedBody(_ text: String) throws -> String {
        var item = makeInput(representations: [], types: ["public.png"])
        item.recognizedText = recognized(text)
        return try XCTUnwrap(SearchDocumentBuilder.documents(for: item).first).body
    }

    /// A kept result of recognized text, intact. The builder doesn't look at where it came from.
    private func recognized(_ text: String) -> RecognizedTextRow {
        RecognizedTextRow(id: UUID(), source: ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(),
                                                         digest: Data(repeating: 1, count: 32)),
                          bytes: Data(text.utf8), digest: ContentDigest.sha256(Data(text.utf8)))
    }

    private func text(_ item: Int, _ representation: Int, _ type: String, _ bytes: Data) -> TextRepresentation {
        TextRepresentation(
            itemIndex: item, representationIndex: representation, typeIdentifier: type,
            byteCount: Int64(bytes.count), digest: ContentDigest.sha256(bytes), bytes: bytes
        )
    }

    private func makeInput(
        title: String = "Item title",
        representations: [TextRepresentation],
        types: [String]? = nil,
        includeHistory: Bool = true,
        collectionIDs: [CollectionID] = [],
        memo: ((ItemID, UUID) -> MemoProjection)? = nil
    ) -> SearchProjectionInput {
        let itemID = ItemID()
        let captureID = UUID()
        let history = includeHistory
            ? ContentRef(itemID: itemID, facet: .history, version: ContentVersion(rawValue: captureID),
                         digest: Data(repeating: 1, count: 32))
            : nil
        return SearchProjectionInput(
            itemID: itemID, title: title, sourceApp: "test.source", collectionIDs: collectionIDs,
            lastCopiedAt: Date(timeIntervalSince1970: 100), history: history,
            memo: memo?(itemID, captureID), captureID: captureID,
            representationTypes: types ?? representations.map(\.typeIdentifier),
            hasLocalReference: false, textRepresentations: representations
        )
    }
}
