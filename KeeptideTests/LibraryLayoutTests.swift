import AppKit
import SwiftUI
import XCTest
@testable import Keeptide

@MainActor
final class LibraryLayoutTests: XCTestCase {
    func testLongEditableTitleAndNoteStayInsideAResizedLibraryWindow() async throws {
        try await assertEditorFitsResizedLibrary(readOnly: false)
    }

    func testLongReadOnlyCaptureTitleStaysInsideAResizedLibraryWindow() async throws {
        try await assertEditorFitsResizedLibrary(readOnly: true)
    }

    private func assertEditorFitsResizedLibrary(readOnly: Bool) async throws {
        let configuration = CaptureTestConfiguration(id: UUID())
        let title = String(repeating: "A long synthetic title should stay inside its column. ", count: 12)
        let note = readOnly ? "" : String(repeating: "Synthetic note with a long unbroken-token-", count: 14)
        let body = String(repeating: "Readable body text wraps inside the window. 中文内容也应换行。 ", count: 40)
        var historyRef: ContentRef?
        if readOnly {
            let store = try PersistenceController(directory: configuration.directory)
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(body.utf8))]])
            var item = ContentStoreFixtures.item(capture)
            item.title = title
            try await ContentStoreFixtures.insert(item, capture, into: store)
            historyRef = ContentStoreFixtures.ref(item, capture)
            try await store.close()
        }
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id)
        addTeardownBlock { @MainActor in
            await session.shutdown()
            try? FileManager.default.removeItem(at: configuration.directory)
            UserDefaults(suiteName: configuration.preferencesSuite)?
                .removePersistentDomain(forName: configuration.preferencesSuite)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }
        let ref: ContentRef
        if let historyRef {
            ref = historyRef
        } else {
            let service = try XCTUnwrap(session.libraryService)
            ref = try await service.create(MemoDraft(title: title, body: body, note: note))
        }
        let workspace = try XCTUnwrap(session.libraryWorkspace)
        await workspace.open(ref)
        let controller = LibraryWindowController(
            session: session, autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.makeKeyAndOrderFront(nil)

        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return self.views(NSTextView.self, in: window.contentView).contains {
                $0.accessibilityIdentifier() == "SnippetBodyTextView" && $0.string == body
            }
        }
        let editor = try XCTUnwrap(views(NSTextView.self, in: window.contentView).first {
            $0.accessibilityIdentifier() == "SnippetBodyTextView"
        })
        let titleField = try XCTUnwrap(views(NSTextField.self, in: window.contentView).first {
            $0.stringValue == title
        })
        // The note is in the inspector, closed until it is asked for; a clip has none.
        func noteFields() -> [NSTextField] {
            views(NSTextField.self, in: window.contentView).filter { $0.placeholderString == "Optional note" }
        }
        XCTAssertTrue(noteFields().isEmpty)
        var noteField: NSTextField?
        if !readOnly {
            // The inspector slides in from the trailing edge.
            controller.toggleInspector(nil)
            try await SearchTestSupport.waitUntil {
                window.contentView?.layoutSubtreeIfNeeded()
                guard let field = noteFields().first, let content = window.contentView else { return false }
                return field.convert(field.bounds, to: content).maxX <= content.bounds.width
            }
            noteField = noteFields().first
        }

        for width: CGFloat in [1_120, 840, 1_400, 1_120] {
            window.appearance = NSAppearance(named: width == 840 ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 740))
            // Wait for SwiftUI's resize proposal and automatic sidebar transition.
            try await SearchTestSupport.waitUntil {
                window.contentView?.layoutSubtreeIfNeeded()
                return window.contentView?.bounds.width == width
                    && (editor.enclosingScrollView?.bounds.width ?? 0) > 0
            }
            for view in [titleField, noteField, try XCTUnwrap(editor.enclosingScrollView)].compactMap({ $0 }) {
                let rect = view.convert(view.bounds, to: window.contentView)
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "\(width): \(rect)")
                XCTAssertLessThanOrEqual(rect.maxX, width, "\(width): \(rect)")
                XCTAssertGreaterThan(rect.width, 0)
            }
            XCTAssertGreaterThanOrEqual(editor.visibleRect.width, editor.bounds.width - 1)
            XCTAssertEqual(editor.string, body)
            XCTAssertEqual(titleField.stringValue, title)
            if let noteField { XCTAssertEqual(noteField.stringValue, note) }
            if readOnly, width == 840 || width == 1_400 {
                let content = try XCTUnwrap(window.contentView)
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let image = NSImage(size: content.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "History detail at \(Int(width)) points"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

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

    func testTheSidebarListsTheScopesInItsSectionOrder() {
        let prompts = CollectionID()
        let drafts = CollectionID()

        XCTAssertEqual(
            LibrarySidebar.scopes(collections: [prompts, drafts]),
            [.recentClips, .allSnippets, .favorites, .collection(prompts), .collection(drafts), .uncategorized,
             .recentlyDeleted]
        )
        // Without a collection, Unfiled would only repeat All Snippets, so it is not listed.
        XCTAssertEqual(LibrarySidebar.scopes(collections: []), [.recentClips, .allSnippets, .favorites, .recentlyDeleted])
    }

    func testListCommandsMoveAlongTheSidebarAndStopAtItsEnds() {
        let prompts = CollectionID()

        XCTAssertEqual(LibrarySidebar.scope(1, from: .favorites, collections: [prompts]), .collection(prompts))
        XCTAssertEqual(LibrarySidebar.scope(1, from: .collection(prompts), collections: [prompts]), .uncategorized)
        XCTAssertEqual(LibrarySidebar.scope(-1, from: .recentlyDeleted, collections: []), .favorites)
        XCTAssertNil(LibrarySidebar.scope(-1, from: .recentClips, collections: [prompts]))
        XCTAssertNil(LibrarySidebar.scope(1, from: .recentlyDeleted, collections: [prompts]))
    }

    func testAListThatGoesAwayLeavesForTheNearestListStillShown() {
        let prompts = CollectionID()
        let drafts = CollectionID()

        // The collection shown is gone: Unfiled while another collection remains, All Snippets otherwise.
        XCTAssertEqual(LibrarySidebar.scope(replacing: .collection(prompts), collections: [drafts]), .uncategorized)
        XCTAssertEqual(LibrarySidebar.scope(replacing: .collection(prompts), collections: []), .allSnippets)
        // Unfiled hides with the last collection.
        XCTAssertEqual(LibrarySidebar.scope(replacing: .uncategorized, collections: []), .allSnippets)
        // A list still shown stays.
        XCTAssertNil(LibrarySidebar.scope(replacing: .collection(drafts), collections: [drafts]))
        XCTAssertNil(LibrarySidebar.scope(replacing: .uncategorized, collections: [drafts]))
        XCTAssertNil(LibrarySidebar.scope(replacing: .favorites, collections: []))
    }

    func testTheScopeMenusListTheSidebarsSections() {
        let prompts = CollectionID()
        let sections = LibrarySidebar.sections(collections: [(prompts, "Prompts")])

        XCTAssertEqual(sections.map { $0.map(\.title) },
                       [["Recent Clips"], ["All Snippets", "Favorites"], ["Prompts", "Unfiled"], ["Recently Deleted"]])
        XCTAssertEqual(Array(sections.joined().map(\.scope)), LibrarySidebar.scopes(collections: [prompts]))
        XCTAssertEqual(LibrarySidebar.sections(collections: []).map { $0.map(\.title) },
                       [["Recent Clips"], ["All Snippets", "Favorites"], ["Recently Deleted"]])
    }

    func testTheWindowSubtitleElidesALongListNameInTheMiddle() {
        XCTAssertEqual(LibrarySidebar.subtitle("Immediate Scope"), "Immediate Scope")
        let long = LibrarySidebar.subtitle("Group 20 — 很长的中文名称用于验证完整筛选")
        XCTAssertEqual(long, "Group 2…于验证完整筛选")
        XCTAssertEqual(long.count, 15)
    }

    func testTheWindowSubtitleNamesTheChosenList() async throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.makeKeyAndOrderFront(nil)

        try await waitUntilLaidOut(window) { window.subtitle == "Recent Clips" }
        controller.selectNextList(nil)
        try await waitUntilLaidOut(window) { window.subtitle == "All Snippets" }
        XCTAssertEqual(window.title, "Keeptide Library")
        controller.selectPreviousList(nil)
        try await waitUntilLaidOut(window) { window.subtitle == "Recent Clips" }
    }

    func testSwiftUIsToolbarBridgeWritesTheListAsTheSubtitleToo() async throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        // SwiftUI's toolbar bridge also writes the window's subtitle, from the view's navigation subtitle, when the
        // view joins the window and as its bars change; on macOS 26 that can come after the controller's write. So
        // the bridge must write the same name: with the controller's write switched off, the subtitle still names the
        // list. (If SwiftUI ever stops writing the subtitle here, this test and the view's subtitle can go.)
        controller.commands.showListTitle = { _ in }
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.makeKeyAndOrderFront(nil)

        try await waitUntilLaidOut(window) { window.subtitle == "Recent Clips" }
        controller.selectNextList(nil)
        try await waitUntilLaidOut(window) { window.subtitle == "All Snippets" }
        XCTAssertEqual(window.title, "Keeptide Library")
    }

    func testChooseListPutsTheKeyboardOnTheSidebarWhileItShows() async throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntilLaidOut(window) { window.subtitle == "Recent Clips" }
        window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder is NSOutlineView)

        controller.chooseList(nil)

        try await waitUntilLaidOut(window) { window.firstResponder is NSOutlineView }
    }

    func testChooseListOffersTheListsUnderTheScopeMenuWhileTheSidebarIsHidden() async throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntilLaidOut(window) { window.subtitle == "Recent Clips" }
        XCTAssertNil(controller.listMenuAnchor(), "The sidebar chooses lists while it shows")

        controller.toggleLibrarySidebar(nil)

        try await waitUntilLaidOut(window) { controller.listMenuAnchor() != nil }
        XCTAssertFalse(controller.commands.sidebarIsVisible)
        // Where the help does not reach the toolbar item, the item after the sidebar button is the same menu.
        XCTAssertTrue(controller.listMenuAnchor(byHelp: false) === controller.listMenuAnchor())
        let menu = controller.makeListMenu()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Recent Clips", "All Snippets", "Favorites", "Recently Deleted", "New Collection…"])
        XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["Recent Clips"])
        // The lists share one action; each has its own identifier, or a click found by title lands on the first.
        let lists = menu.items.filter { $0.representedObject is LibraryScope }
        XCTAssertEqual(Set(lists.compactMap(\.identifier)).count, lists.count)

        // Choosing from it chooses the list, as the sidebar would.
        let favorites = try XCTUnwrap(menu.items.first { $0.title == "Favorites" })
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex(of: favorites)))
        try await waitUntilLaidOut(window) { window.subtitle == "Favorites" }
    }

    func testSearchingAgainFocusesTheSearchFieldItLeft() async throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntilLaidOut(window) { window.subtitle == "Recent Clips" }
        func searchIsFocused() -> Bool {
            guard let editor = window.firstResponder as? NSTextView else { return false }
            return editor.delegate is NSSearchField
        }

        controller.searchLibrary(nil)
        try await waitUntilLaidOut(window) { searchIsFocused() }

        // The keyboard leaves while the search stays open; asking again brings it back.
        window.makeFirstResponder(nil)
        XCTAssertFalse(searchIsFocused())
        controller.searchLibrary(nil)
        try await waitUntilLaidOut(window) { searchIsFocused() }
    }

    func testTheSidebarCannotBeLeftWithoutAList() async throws {
        let controller = LibraryWindowController(
            session: CaptureSession(), autosaveName: nil, setActivationPolicy: { _ in }
        )
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.makeKeyAndOrderFront(nil)
        var sidebar: NSOutlineView?
        try await waitUntilLaidOut(window) {
            window.contentView?.layoutSubtreeIfNeeded()
            // Before the library opens, the sidebar is the window's only outline.
            sidebar = self.views(NSOutlineView.self, in: window.contentView).first
            return sidebar?.selectedRowIndexes.isEmpty == false && window.subtitle == "Recent Clips"
        }
        let outline = try XCTUnwrap(sidebar)
        let selected = outline.selectedRowIndexes

        outline.deselectAll(nil)

        try await waitUntilLaidOut(window) { outline.selectedRowIndexes == selected }
        XCTAssertEqual(window.subtitle, "Recent Clips")
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
        XCTAssertEqual(commands.focusGeneration, 3)
        XCTAssertEqual(commands.newSnippetFocusGeneration, 2)
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

    /// Waits for `condition`, laying the window out before each check: a test host without a display does not run
    /// SwiftUI's updates on its own.
    private func waitUntilLaidOut(_ window: NSWindow, _ condition: () -> Bool) async throws {
        try await SearchTestSupport.waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return condition()
        }
    }

    private func views<View: NSView>(_ type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        return ((root as? View).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
}
