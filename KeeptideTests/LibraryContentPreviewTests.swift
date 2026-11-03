import XCTest
@testable import Keeptide

final class LibraryContentPreviewTests: XCTestCase {
    func testEditableInheritedURLBodyUsesSourceEditorAfterSave() {
        XCTAssertTrue(LibraryContentPresentation.showsTypedPreview(
            isReadOnly: true, hasBody: true, kind: .url
        ))
        XCTAssertFalse(LibraryContentPresentation.showsTypedPreview(
            isReadOnly: false, hasBody: true, kind: .url
        ))
        XCTAssertTrue(LibraryContentPresentation.showsTypedPreview(
            isReadOnly: false, hasBody: false, kind: .url
        ))
    }

    func testBeginningAnotherRequestDropsPreviouslyReadyContent() {
        let first = LibraryPreviewRequest(ref: ref(), kind: .url, maximumImagePixels: 1_024)
        let second = LibraryPreviewRequest(ref: ref(), kind: .image, maximumImagePixels: 2_048)
        var phase = LibraryPreviewPhase.ready(
            first,
            .url(title: "First", address: "https://example.com/first")
        )

        phase.begin(second)

        XCTAssertEqual(phase, .loading(second))
        XCTAssertNil(phase.content(for: second))
    }

    func testCompletionAcceptsOnlyTheExactCurrentReferenceAndKind() {
        let selected = ref()
        let old = LibraryPreviewRequest(ref: selected, kind: .url, maximumImagePixels: 1_024)
        let current = LibraryPreviewRequest(ref: selected, kind: .file, maximumImagePixels: 1_024)
        let stale = PreviewContent.url(title: nil, address: "https://example.com/stale")
        let loaded = PreviewContent.files([])
        var phase = LibraryPreviewPhase.loading(current)

        phase.complete(stale, for: old, current: current)
        XCTAssertEqual(phase, .loading(current))

        phase.complete(loaded, for: current, current: current)
        XCTAssertEqual(phase.content(for: current), loaded)
        XCTAssertNil(phase.content(for: old))
    }

    func testOriginalImageGenerationChangesWithoutChangingContentRequest() {
        let request = LibraryPreviewRequest(ref: ref(), kind: .image, maximumImagePixels: 1_520)

        XCTAssertNotEqual(
            LibraryOriginalPreviewRequest(preview: request, generation: 1),
            LibraryOriginalPreviewRequest(preview: request, generation: 2)
        )
    }

    private func ref() -> ContentRef {
        ContentRef(
            itemID: ItemID(),
            facet: .history,
            version: ContentVersion(),
            digest: Data(repeating: 1, count: 32)
        )
    }
}
