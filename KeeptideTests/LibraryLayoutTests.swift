import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

@MainActor
final class LibraryLayoutTests: XCTestCase {
    func testAutomaticSidebarUsesHysteresisNearTheCollapseThreshold() {
        XCTAssertEqual(
            LibraryLayoutPolicy.sidebarVisibility(
                width: 959, preference: .automatic, current: .visible
            ),
            .hidden
        )
        XCTAssertEqual(
            LibraryLayoutPolicy.sidebarVisibility(
                width: 1_001, preference: .automatic, current: .hidden
            ),
            .hidden
        )
        XCTAssertEqual(
            LibraryLayoutPolicy.sidebarVisibility(
                width: 1_041, preference: .automatic, current: .hidden
            ),
            .visible
        )
        XCTAssertEqual(
            LibraryLayoutPolicy.sidebarVisibility(
                width: 1_001, preference: .automatic, current: .visible
            ),
            .visible
        )
    }

    func testExplicitSidebarPreferenceWinsOverAutomaticWidthAdvice() {
        XCTAssertEqual(
            LibraryLayoutPolicy.sidebarVisibility(width: 840, preference: .shown, current: .hidden),
            .visible
        )
        XCTAssertEqual(
            LibraryLayoutPolicy.sidebarVisibility(width: 1_120, preference: .hidden, current: .visible),
            .hidden
        )
    }

    func testCurrentLibrarySectionsDoNotAdvertiseFutureCollectionsOrTrash() {
        XCTAssertEqual(LibrarySection.allCases, [.recentClips, .allSnippets, .uncategorized])
        XCTAssertEqual(LibrarySection.allSnippets.scope, .allSnippets)
        XCTAssertEqual(LibrarySection.uncategorized.scope, .uncategorized)
    }

    func testLibraryEnablesOnlyToolbarSceneBridging() throws {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let content = try XCTUnwrap(controller.contentViewController)
        let hosting = try XCTUnwrap(content.children.first as? NSHostingController<LibraryView>)

        XCTAssertEqual(hosting.sceneBridgingOptions, .toolbars)
        XCTAssertEqual(controller.window?.title, "Keeptide Library")
        XCTAssertEqual(controller.window?.contentView?.frame.size, NSSize(width: 1_120, height: 740))
    }

    func testWindowCommandsAreForwardedAsMonotonicRequests() throws {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let commands = controller.commands

        controller.newDocument(nil)
        controller.newDocument(nil)
        controller.saveDocument(nil)
        controller.copyEntireItem(nil)
        controller.searchLibrary(nil)

        XCTAssertEqual(commands.newSnippetRequest, 2)
        XCTAssertEqual(commands.saveRequest, 1)
        XCTAssertEqual(commands.copyRequest, 1)
        XCTAssertEqual(commands.searchRequest, 1)
        XCTAssertEqual(controller.window?.contentMinSize, NSSize(width: 840, height: 560))
    }

    func testOpeningAReferenceCarriesTheExactContentIdentity() {
        let controller = LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        let ref = ContentRef(
            itemID: ItemID(), facet: .memo, version: ContentVersion(),
            digest: Data(repeating: 4, count: 32)
        )

        controller.open(ref)

        XCTAssertEqual(controller.commands.openRequest?.ref, ref)
        XCTAssertEqual(controller.commands.openRequest?.generation, 1)
    }
}
