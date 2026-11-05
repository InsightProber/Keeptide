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
        let noteField = try XCTUnwrap(views(NSTextField.self, in: window.contentView).first {
            $0.placeholderString == "Optional note"
        })

        for width: CGFloat in [1_120, 840, 1_400, 1_120] {
            window.appearance = NSAppearance(named: width == 840 ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 740))
            // Wait for SwiftUI's resize proposal and automatic sidebar transition.
            try await SearchTestSupport.waitUntil {
                window.contentView?.layoutSubtreeIfNeeded()
                return window.contentView?.bounds.width == width
                    && (editor.enclosingScrollView?.bounds.width ?? 0) > 0
            }
            for view in [titleField, noteField, try XCTUnwrap(editor.enclosingScrollView)] {
                let rect = view.convert(view.bounds, to: window.contentView)
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "\(width): \(rect)")
                XCTAssertLessThanOrEqual(rect.maxX, width, "\(width): \(rect)")
                XCTAssertGreaterThan(rect.width, 0)
            }
            XCTAssertGreaterThanOrEqual(editor.visibleRect.width, editor.bounds.width - 1)
            XCTAssertEqual(editor.string, body)
            XCTAssertEqual(titleField.stringValue, title)
            XCTAssertEqual(noteField.stringValue, note)
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

    private func views<View: NSView>(_ type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        return ((root as? View).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
}
