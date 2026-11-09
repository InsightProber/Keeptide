import AppKit
import XCTest
@testable import Keeptide

/// Renders the library window over a synthetic library for a visual review, as attachments of the test result. Like
/// the quick-access snapshots it runs only when `KEEPTIDE_SNAPSHOT_DIR` is set, passed on from
/// `TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR`; otherwise it is skipped.
@MainActor
final class LibrarySnapshotTests: XCTestCase {
    /// A snippet in two collections is one row in each of them, and one row in All Snippets with both dots.
    func testRenderASnippetInTwoCollections() async throws {
        guard let folder = ProcessInfo.processInfo.environment["KEEPTIDE_SNAPSHOT_DIR"], !folder.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_KEEPTIDE_SNAPSHOT_DIR to render the library")
        }
        let configuration = CaptureTestConfiguration(id: UUID())
        let session = CaptureSession()
        await session.initialize(testSessionID: configuration.id, seedSyntheticClips: true, seedSyntheticSnippets: true)
        addTeardownBlock { @MainActor in
            await session.shutdown()
            try? FileManager.default.removeItem(at: configuration.directory)
            UserDefaults(suiteName: configuration.preferencesSuite)?
                .removePersistentDomain(forName: configuration.preferencesSuite)
            NSPasteboard(name: .init(configuration.pasteboardName)).releaseGlobally()
        }
        let workspace = try XCTUnwrap(session.libraryWorkspace)
        await workspace.refreshCollections()
        let prompts = try XCTUnwrap(workspace.collections.first { $0.value.name == "Prompts" })
        let shell = try XCTUnwrap(workspace.collections.first { $0.value.name == "Shell" })
        await workspace.setScope(.collection(shell.value.id))
        try await SearchTestSupport.waitUntil(timeout: .seconds(10)) {
            workspace.entries.contains { $0.title == "List open ports" }
        }
        let ports = try XCTUnwrap(workspace.entries.first { $0.title == "List open ports" })
        await workspace.add([ports.ref], to: prompts)

        let controller = LibraryWindowController(session: session, autosaveName: nil, setActivationPolicy: { _ in })
        let window = try XCTUnwrap(controller.window)
        addTeardownBlock { @MainActor in window.close() }
        window.setContentSize(NSSize(width: 1_120, height: 620))
        window.makeKeyAndOrderFront(nil)
        let lists: [(String, LibraryScope)] = [
            ("all-snippets", .allSnippets), ("prompts", .collection(prompts.value.id)),
            ("shell", .collection(shell.value.id)),
        ]
        for (name, scope) in lists {
            controller.commands.requestList(scope)
            try await SearchTestSupport.waitUntil(timeout: .seconds(10)) {
                workspace.scope == scope && !workspace.isLoading
                    && workspace.entries.contains { $0.title == "List open ports" }
            }
            // Let the list draw what it now holds.
            try await Task.sleep(for: .milliseconds(800))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "library-two-collections-\(name).png"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
