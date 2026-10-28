import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class QuickAccessStateTests: XCTestCase {
    func testOpenShowsRecentHistoryNewestFirst() async throws {
        let fixture = try makeFixture()
        try await insert("oldest", at: 1, into: fixture)
        try await insert("middle", at: 2, into: fixture)
        try await insert("newest", at: 3, into: fixture)
        let state = QuickAccessState(services: { fixture.services })

        state.open()
        try await settled(state)

        XCTAssertEqual(state.selection.rows.map(\.title), ["newest", "middle", "oldest"])
        XCTAssertEqual(state.scopeTitle, "Recent Clips")
        XCTAssertEqual(state.selection.executableSelection, state.selection.rows.first?.ref)
    }

    func testWhitespaceOnlyQueryShowsRecentClips() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.setQuery("  \u{200B} ")
        try await settled(state)

        XCTAssertEqual(state.scopeTitle, "Recent Clips")
        XCTAssertEqual(state.selection.rows.map(\.title), ["beta note", "alpha note"])
    }

    func testTypingSearchesAndDropsStalePages() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.setQuery("alpha")
        state.setQuery("beta")
        try await settled(state)

        XCTAssertEqual(state.selection.rows.map(\.title), ["beta note"])
        XCTAssertEqual(state.scopeTitle, "All Content")
    }

    func testKindFilterSearchesWithEmptyQuery() async throws {
        let fixture = try makeFixture()
        let link = Data("https://example.com/synthetic".utf8)
        try await insert("plain words", at: 1, into: fixture)
        try await insert("synthetic link", types: [("public.url", link), ("public.utf8-plain-text", link)], at: 2,
                         into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.toggleKind(.url)
        try await settled(state)

        XCTAssertEqual(state.selection.rows.map(\.kind), [.url])
        XCTAssertEqual(state.scopeTitle, "All Content · Link")
    }

    func testClearQueryAndFiltersReturnsToRecent() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        state.setQuery("alpha")
        state.toggleKind(.text)
        try await settled(state)

        state.clearQueryAndFilters()
        try await settled(state)

        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.kinds, [])
        XCTAssertEqual(state.scopeTitle, "Recent Clips")
        XCTAssertEqual(state.selection.rows.map(\.title), ["beta note", "alpha note"])
    }

    func testLibraryUnavailableUntilServicesArrive() async throws {
        let fixture = try makeFixture()
        try await insert("late library", at: 1, into: fixture)
        let box = ServicesBox()
        let state = QuickAccessState(services: { box.services })

        state.open()
        XCTAssertEqual(state.phase, .libraryUnavailable)

        box.services = fixture.services
        state.servicesDidChange()
        try await settled(state)

        XCTAssertEqual(state.phase, .results)
        XCTAssertEqual(state.selection.rows.map(\.title), ["late library"])
    }

    func testSearchUnavailableKeepsRecentClipsBrowsable() async throws {
        let fixture = try makeFixture(search: SearchService(index: nil, status: SearchIndexStatus(.unavailable)))
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        XCTAssertEqual(state.selection.rows.map(\.title), ["alpha note"])
        XCTAssertNil(state.indexNotice)

        state.setQuery("alpha")
        try await settled(state)

        XCTAssertEqual(state.indexNotice, .searchUnavailable)
        XCTAssertEqual(state.selection.rows, [])
    }

    func testCopySelectionWritesTheBoardAndCallsOnCopied() async throws {
        let fixture = try makeFixture()
        try await insert("copy me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let copied = CallCounter()
        state.onCopied = { copied.count += 1 }
        state.open()
        try await settled(state)

        await state.copySelection(.original)

        XCTAssertEqual(fixture.board.string(forType: .string), "copy me")
        XCTAssertEqual(copied.count, 1)
        XCTAssertNil(state.failure)
    }

    func testCopyBeforeTheFirstPageDoesNothing() async throws {
        let fixture = try makeFixture()
        try await insert("too early", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let copied = CallCounter()
        state.onCopied = { copied.count += 1 }
        let before = fixture.board.changeCount

        state.open()
        await state.copySelection(.original)

        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(copied.count, 0)
    }

    func testClosedSessionIgnoresLatePagesAndCopies() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        let copied = CallCounter()
        state.onCopied = { copied.count += 1 }
        state.open()
        try await settled(state)
        let before = fixture.board.changeCount

        state.setQuery("alpha")
        state.close()
        try await Task.sleep(for: .milliseconds(300))
        await state.copySelection(.original)

        XCTAssertEqual(state.selection.rows.map(\.title), ["beta note", "alpha note"])
        XCTAssertNil(state.selection.executableSelection)
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(copied.count, 0)
    }

    func testRecentRefreshKeepsSelectionWhenANewClipArrives() async throws {
        let fixture = try makeFixture()
        try await insert("older", at: 1, into: fixture)
        try await insert("newer", at: 2, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        XCTAssertEqual(state.moveSelection(by: 1), .moved)
        let chosen = state.selection.selection

        try await insert("newest", at: 3, into: fixture)
        state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { state.selection.rows.count == 3 }

        XCTAssertEqual(state.selection.selection, chosen)
    }

    func testLoadMoreAppendsTheNextWindow() async throws {
        let fixture = try makeFixture()
        for offset in 0..<70 { try await insert("bulk \(offset)", at: Double(offset), into: fixture) }
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        state.setQuery("bulk")
        try await settled(state)
        XCTAssertEqual(state.selection.rows.count, 60)
        let first = state.selection.selection

        state.loadMoreIfNeeded(visibleRow: 55)
        try await SearchTestSupport.waitUntil { state.selection.rows.count == 70 }

        XCTAssertEqual(Set(state.selection.rows.map(\.ref)).count, 70)
        XCTAssertEqual(state.selection.selection, first)
    }

    func testPreviewLoadsOnlyForTheCurrentSelection() async throws {
        let fixture = try makeFixture()
        try await insert("first", body: "first body", at: 1, into: fixture)
        try await insert("second", body: "second body", at: 2, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.togglePreview()
        try await SearchTestSupport.waitUntil { state.preview == .text("second body", isTruncated: false) }
        state.moveSelection(by: 1)

        XCTAssertNil(state.preview, "A preview never shows another row's content while loading")
        try await SearchTestSupport.waitUntil { state.preview == .text("first body", isTruncated: false) }
    }

    func testPreviewDecodesAtMost256KiB() async throws {
        let fixture = try makeFixture()
        try await insert("large", body: String(repeating: "合成文本", count: 500_000), at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.togglePreview()
        try await SearchTestSupport.waitUntil { state.preview != nil }

        guard case .text(let text, let isTruncated)? = state.preview else {
            return XCTFail("Expected a text preview, got \(String(describing: state.preview))")
        }
        XCTAssertTrue(isTruncated)
        XCTAssertLessThanOrEqual(text.utf8.count, 262_144)
    }

    func testCopyOfVanishedClipKeepsPanelOpenWithReason() async throws {
        let fixture = try makeFixture()
        var item = try await insert("doomed", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let copied = CallCounter()
        state.onCopied = { copied.count += 1 }
        state.open()
        try await settled(state)
        let before = fixture.board.changeCount

        item.historyDeletedAt = Date()
        try await fixture.harness.update(.item(item.id), to: .item(item))
        await state.copySelection(.original)

        XCTAssertEqual(state.failure, .contentUnavailable)
        XCTAssertEqual(copied.count, 0)
        XCTAssertEqual(fixture.board.changeCount, before)
    }

    func testPlainTextCopyOfImageShowsReason() async throws {
        let fixture = try makeFixture()
        try await insert("pixel", types: [("public.png", Data([0x89, 0x50, 0x4E, 0x47]))], at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        await state.copySelection(.plainText)

        XCTAssertEqual(state.failure, .noPlainText)
    }

    private struct Fixture {
        let harness: SearchHarness
        let board: NSPasteboard
        let services: QuickAccessServices
    }

    private func makeFixture(search: SearchService? = nil) throws -> Fixture {
        let harness = try SearchHarness.make(in: self)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let repository = ContentRepository(controller: harness.controller)
        let usage = LocalUsageStore(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { try await repository.read($0) },
                                 recordUse: { try await usage.record($0) }, didWrite: { _ in })
        return Fixture(harness: harness, board: board,
                       services: QuickAccessServices(repository: repository, search: search ?? harness.service,
                                                     paste: paste))
    }

    @discardableResult
    private func insert(
        _ title: String, body: String? = nil, types: [(String, Data)]? = nil, at seconds: Double,
        into fixture: Fixture
    ) async throws -> ItemValue {
        let capture = try ContentStoreFixtures.capture([types ?? [("public.utf8-plain-text", Data((body ?? title).utf8))]])
        let item = ItemValue(sourceApp: "test.source", title: title, captureID: capture.id, historyEligible: true,
                             lastCopiedAt: Date(timeIntervalSince1970: 1_000 + seconds), copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: fixture.harness.controller)
        return item
    }

    /// Waits until the current generation has a page.
    private func settled(_ state: QuickAccessState) async throws {
        try await SearchTestSupport.waitUntil { state.phase != .loading }
    }
}

@MainActor
private final class ServicesBox {
    var services: QuickAccessServices?
}

@MainActor
private final class CallCounter {
    var count = 0
}
