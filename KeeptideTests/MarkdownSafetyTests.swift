import Foundation
import XCTest
@testable import Keeptide

final class MarkdownSafetyTests: XCTestCase {
    func testParsesTheSupportedBlockSubsetWithoutChangingSource() {
        let source = """
        # 标题🙂

        第一段 with [Apple](https://apple.com/design/)

        - alpha
        - beta

        > local quote
        """

        let document = MarkdownRenderer.parse(source)

        XCTAssertEqual(document.copySource, source)
        XCTAssertEqual(document.externalResources, [])
        XCTAssertEqual(document.blocks, [
            .heading(level: 1, content: [.text("标题🙂")]),
            .paragraph([
                .text("第一段 with "),
                .link(label: "Apple", destination: URL(string: "https://apple.com/design/")),
            ]),
            .unorderedList([
                MarkdownListItem(checkState: .none, content: [.text("alpha")]),
                MarkdownListItem(checkState: .none, content: [.text("beta")]),
            ]),
            .quote([.text("local quote")]),
        ])
    }

    func testCodeFencePreservesUnicodeWhitespaceAndLanguageHintExactly() {
        let source = """
        ```bash
        printf '你好🙂\\n'
        \tindent stays
        ```
        """

        let document = MarkdownRenderer.parse(source)

        XCTAssertEqual(document.blocks, [
            .codeBlock(language: "bash", source: "printf '你好🙂\\n'\n\tindent stays"),
        ])
        XCTAssertEqual(document.copySource, source)
    }

    func testUncheckedTaskIsNeverPromotedToCompleted() {
        let document = MarkdownRenderer.parse("- [ ] review before running\n- [x] already reviewed")

        XCTAssertEqual(document.blocks, [
            .unorderedList([
                MarkdownListItem(checkState: .unchecked, content: [.text("review before running")]),
                MarkdownListItem(checkState: .checked, content: [.text("already reviewed")]),
            ]),
        ])
    }

    func testHTMLRemoteImagesAndUnsafeLinksRemainInertAndVisible() {
        let source = """
        prefix <script src="https://tracker.invalid/a.js">[steal](https://tracker.invalid/run)</script>

        ![pixel](https://tracker.invalid/pixel.png)

        [run](javascript:alert(1)) and [file](file:///private/tmp/secret)
        """

        let document = MarkdownRenderer.parse(source)

        XCTAssertEqual(document.externalResources, [])
        XCTAssertEqual(document.blocks, [
            .paragraph([.text("prefix <script src=\"https://tracker.invalid/a.js\">[steal](https://tracker.invalid/run)</script>")]),
            .paragraph([.text("![pixel](https://tracker.invalid/pixel.png)")]),
            .paragraph([
                .link(label: "run", destination: nil),
                .text(" and "),
                .link(label: "file", destination: nil),
            ]),
        ])
        XCTAssertEqual(document.copySource, source)
    }

    func testOnlyExplicitWebAndMailLinksBecomeActionable() {
        let source = "[web](https://example.com) [mail](mailto:dev@example.com) [relative](notes/today) [hostless](https:run)"

        XCTAssertEqual(MarkdownRenderer.parse(source).blocks, [
            .paragraph([
                .link(label: "web", destination: URL(string: "https://example.com")),
                .text(" "),
                .link(label: "mail", destination: URL(string: "mailto:dev@example.com")),
                .text(" "),
                .link(label: "relative", destination: nil),
                .text(" "),
                .link(label: "hostless", destination: nil),
            ]),
        ])
    }

    func testOrderedListPreservesItsStartingNumberAndTaskState() {
        let document = MarkdownRenderer.parse("3. third\n4. [ ] still pending")

        XCTAssertEqual(document.blocks, [
            .orderedList(start: 3, items: [
                MarkdownListItem(checkState: .none, content: [.text("third")]),
                MarkdownListItem(checkState: .unchecked, content: [.text("still pending")]),
            ]),
        ])
    }

    func testUnterminatedConstructsRemainLiteralInsteadOfDroppingContent() {
        let source = "```swift\nlet value = [unsafe](javascript:run("

        let document = MarkdownRenderer.parse(source)

        XCTAssertEqual(document.blocks, [.paragraph([.text(source)])])
        XCTAssertEqual(document.copySource, source)
        XCTAssertEqual(document.externalResources, [])
    }

    func testLargeLiteralInputRemainsOneCompleteParagraph() {
        let source = String(repeating: "长文本🙂<tag> ", count: 20_000)

        XCTAssertEqual(MarkdownRenderer.parse(source).blocks, [.paragraph([.text(source)])])
    }

    func testManyUnterminatedLinkOpenersStayComplete() {
        let source = String(repeating: "[", count: 50_000)

        XCTAssertEqual(MarkdownRenderer.parse(source).blocks, [.paragraph([.text(source)])])
    }
}
