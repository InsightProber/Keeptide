import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Keeptide

/// A strip frame in pixels, the way the strip asks for details: points times two.
private let stripFrame = CGSize(width: 328, height: 218)

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

    func testPagingStopsOnceAPageAddsNoRows() async throws {
        // A two-letter query is scanned rather than looked up, and each scan of this small index reports its
        // progress once, so the reports count the searches the state makes.
        let scans = ScanCount()
        let fixture = try makeFixture(onScanProgress: { _ in scans.increment() })
        var clips: [ItemValue] = []
        for offset in 0..<61 { clips.append(try await insert("ab \(offset)", at: Double(offset), into: fixture)) }
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        state.setQuery("ab")
        try await SearchTestSupport.waitUntil { state.phase == .results && state.selection.isComplete }
        XCTAssertEqual(state.selection.rows.count, 60)

        // The one clip left out is copied again and ranks first, so the next page holds only a clip already
        // listed, while the search still counts one match more than the list holds.
        var oldest = clips[0]
        oldest.lastCopiedAt = Date(timeIntervalSince1970: 2_000)
        try await fixture.harness.update(.item(oldest.id), to: .item(oldest))
        try await fixture.harness.consumer.synchronize()
        let searched = scans.count

        for _ in 0..<3 {
            state.loadMoreIfNeeded(visibleRow: 55)
            try await searchesFinished(in: fixture)
        }

        XCTAssertEqual(scans.count, searched + 1, "Once a page adds nothing, the same page is not asked for again")
        XCTAssertEqual(state.selection.rows.count, 60)
        state.close()
    }

    func testHasMoreRowsOnlyWhileASearchHasAnotherPage() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for offset in 0..<61 { clips.append(try await insert("ab \(offset)", at: Double(offset), into: fixture)) }
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        // Recent clips come in one read, so none follow.
        XCTAssertEqual(state.selection.rows.count, 61)
        XCTAssertFalse(state.hasMoreRows)

        // A search that matched more than its first page has another page to fetch.
        state.setQuery("ab")
        try await SearchTestSupport.waitUntil { state.phase == .results && state.selection.isComplete }
        XCTAssertEqual(state.selection.rows.count, 60)
        XCTAssertTrue(state.hasMoreRows)

        // The clip left out is copied again and ranks first, so the next page adds nothing and paging stops.
        var oldest = clips[0]
        oldest.lastCopiedAt = Date(timeIntervalSince1970: 2_000)
        try await fixture.harness.update(.item(oldest.id), to: .item(oldest))
        try await fixture.harness.consumer.synchronize()
        state.loadMoreIfNeeded(visibleRow: 55)
        try await searchesFinished(in: fixture)

        XCTAssertEqual(state.selection.rows.count, 60)
        XCTAssertFalse(state.hasMoreRows)
        state.close()
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

    func testCopyFromAClosedSessionDoesNotTouchTheReopenedPanel() async throws {
        let gate = CopyGate()
        let fixture = try makeFixture(readGate: gate)
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let copied = CallCounter()
        state.onCopied = { copied.count += 1 }
        state.open()
        try await settled(state)
        let before = fixture.board.changeCount

        let copy = Task { await state.copySelection(.original) }
        try await SearchTestSupport.waitUntil { await gate.entries == 1 }
        state.close()
        state.open()
        try await settled(state)
        await gate.open()
        await copy.value

        XCTAssertNil(state.failure)
        XCTAssertEqual(copied.count, 0)
        XCTAssertEqual(fixture.board.changeCount, before)
    }

    func testReturnWhileACopyIsInFlightIsIgnored() async throws {
        let gate = CopyGate()
        let fixture = try makeFixture(readGate: gate)
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        let first = Task { await state.copySelection(.original) }
        try await SearchTestSupport.waitUntil { await gate.entries == 1 }
        let ignored = expectation(description: "A second copy returns without waiting")
        let second = Task {
            await state.copySelection(.original)
            ignored.fulfill()
        }
        await fulfillment(of: [ignored], timeout: 2)
        await gate.open()
        await first.value
        await second.value

        let entries = await gate.entries
        XCTAssertEqual(entries, 1)
    }

    func testPreviewCollapsesWhenTheSelectionVanishes() async throws {
        let fixture = try makeFixture()
        try await insert("older", at: 1, into: fixture)
        var doomed = try await insert("doomed", at: 2, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let collapsed = CallCounter()
        state.onPreviewCollapsed = { collapsed.count += 1 }
        state.open()
        try await settled(state)
        state.togglePreview()
        try await SearchTestSupport.waitUntil { state.preview != nil }

        doomed.historyDeletedAt = Date()
        try await fixture.harness.update(.item(doomed.id), to: .item(doomed))
        state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { state.selection.selectionLost }

        XCTAssertFalse(state.isPreviewExpanded)
        XCTAssertNil(state.preview)
        XCTAssertEqual(collapsed.count, 1)
    }

    func testReopeningDoesNotShowThePreviousSessionsRows() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        state.setQuery("alpha")
        try await settled(state)
        XCTAssertEqual(state.selection.rows.map(\.title), ["alpha note"])

        state.close()
        state.open()

        XCTAssertEqual(state.selection.rows, [])
        try await settled(state)
        XCTAssertEqual(state.selection.rows.map(\.title), ["beta note", "alpha note"])
    }

    func testNonTextPreviewShowsKnownInformationWithoutReading() async throws {
        // An image is read through the preview service, so this is the case without one.
        let fixture = try makeFixture(withoutPreview: true)
        try await insert("pixel", types: [("public.png", Data([0x89, 0x50, 0x4E, 0x47]))], at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.togglePreview()

        XCTAssertEqual(state.preview, .info(kind: .image, sourceApp: "test.source"))
    }

    func testStaleUnavailableSearchDoesNotLeaveANoticeOnRecentClips() async throws {
        let fixture = try makeFixture(withoutSearch: true)
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.setQuery("a")
        state.setQuery("")
        try await SearchTestSupport.waitUntil { state.phase == .results }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(state.indexNotice)
        XCTAssertEqual(state.phase, .results)
    }

    func testFailedRefreshKeepsTheListedClips() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        let rows = state.selection.rows

        try await fixture.harness.close()
        state.recentClipsChanged()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.selection.rows, rows)
        XCTAssertEqual(state.phase, .results)
        XCTAssertFalse(state.selection.selectionLost)
    }

    func testCopyUsesTheTargetCapturedAtTheKeyPress() async throws {
        let fixture = try makeFixture()
        try await insert("older", at: 1, into: fixture)
        try await insert("newer", at: 2, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        let target = try XCTUnwrap(state.copyTarget)
        state.moveSelection(by: 1)
        await state.copy(target, mode: .original)

        XCTAssertEqual(fixture.board.string(forType: .string), "newer")
    }

    func testReopenedPanelCanCopyWhileAnOldCopyFinishes() async throws {
        let gate = CopyGate()
        let fixture = try makeFixture(readGate: gate)
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let copied = CallCounter()
        state.onCopied = { copied.count += 1 }
        state.open()
        try await settled(state)
        let old = Task { await state.copySelection(.original) }
        try await SearchTestSupport.waitUntil { await gate.entries == 1 }
        state.close()
        state.open()
        try await settled(state)

        let fresh = Task { await state.copySelection(.original) }
        try await SearchTestSupport.waitUntil { await gate.entries == 2 }
        await gate.open()
        await old.value
        await fresh.value

        XCTAssertEqual(copied.count, 1)
        XCTAssertEqual(fixture.board.string(forType: .string), "alpha note")
    }

    func testCopyRaisesTheClipInSearchRanking() async throws {
        let fixture = try makeFixture()
        try await insert("deploy two", at: 1, into: fixture)
        try await insert("deploy one", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        state.setQuery("deploy")
        try await settled(state)
        XCTAssertEqual(state.selection.rows.map(\.title), ["deploy one", "deploy two"])
        let older = try XCTUnwrap(state.selection.rows.last?.ref)

        state.moveSelection(by: 1)
        await state.copySelection(.original)
        let usage = LocalUsageStore(controller: fixture.harness.controller)
        try await SearchTestSupport.waitUntil { try await usage.summaries(for: [older]).count == 1 }
        try await fixture.harness.consumer.synchronize()
        state.close()
        state.open()
        state.setQuery("deploy")
        try await settled(state)

        XCTAssertEqual(state.selection.rows.map(\.title), ["deploy two", "deploy one"])
    }

    func testStatusExplainsAnEmptyListWhileTheIndexRebuilds() {
        XCTAssertEqual(QuickAccessStatus.empty(phase: .noResults, notice: .rebuilding),
                       QuickAccessStatus.Message(text: "No results", detail: "Index is rebuilding — results may be incomplete"))
        XCTAssertEqual(QuickAccessStatus.empty(phase: .noResults, notice: .searchUnavailable),
                       QuickAccessStatus.Message(text: "Search is unavailable — recent clips are still here", detail: nil))
        XCTAssertEqual(QuickAccessStatus.empty(phase: .noResults, notice: nil),
                       QuickAccessStatus.Message(text: "No results", detail: nil))
        XCTAssertEqual(QuickAccessStatus.empty(phase: .loading, notice: nil),
                       QuickAccessStatus.Message(text: "Searching…", detail: nil))
    }

    func testStatusLineAboveRows() {
        XCTAssertEqual(QuickAccessStatus.line(selectionLost: true, phase: .results, isComplete: false, notice: .rebuilding),
                       "The selected item is no longer in the results")
        XCTAssertEqual(QuickAccessStatus.line(selectionLost: false, phase: .results, isComplete: false, notice: nil),
                       "Searching…")
        XCTAssertEqual(QuickAccessStatus.line(selectionLost: false, phase: .loading, isComplete: true, notice: nil),
                       "Searching…")
        XCTAssertEqual(QuickAccessStatus.line(selectionLost: false, phase: .results, isComplete: true, notice: .rebuilding),
                       "Index is rebuilding — results may be incomplete")
        XCTAssertNil(QuickAccessStatus.line(selectionLost: false, phase: .results, isComplete: true, notice: nil))
    }

    func testDetailsLoadForRequestedRowsOnly() async throws {
        let gate = CopyGate()
        await gate.open()
        let fixture = try makeFixture(previewGate: gate)
        try await insert("oldest", at: 1, into: fixture)
        try await insert("middle", body: "middle body", at: 2, into: fixture)
        try await insert("newest", body: "newest body here", at: 3, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        let refs = state.selection.rows.map(\.ref)

        state.loadDetails(for: [refs[0], refs[1]], frameSize: stripFrame)
        try await SearchTestSupport.waitUntil { state.details.count == 2 }

        XCTAssertEqual(state.details[refs[0]]?.excerpt, "newest body here")
        XCTAssertEqual(state.details[refs[1]]?.characterCount, 11)
        XCTAssertNil(state.details[refs[2]])
        let reads = await gate.entries
        XCTAssertEqual(reads, 2, "The row that was not requested is never read")
    }

    func testDetailsForRowsNoLongerShownAreDropped() async throws {
        let gate = CopyGate()
        let fixture = try makeFixture(previewGate: gate)
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        let beta = try XCTUnwrap(state.selection.rows.first?.ref)
        let alpha = try XCTUnwrap(state.selection.rows.last?.ref)

        // Both reads are held while the query changes, so they finish after the alpha row has left the list.
        state.loadDetails(for: [alpha, beta], frameSize: stripFrame)
        try await SearchTestSupport.waitUntil { await gate.entries == 2 }
        state.setQuery("beta")
        try await settled(state)
        XCTAssertEqual(state.selection.rows.map(\.ref), [beta])
        await gate.open()

        // A detail belongs to its clip, not to the query it was asked for, so the row that stayed gets it.
        try await SearchTestSupport.waitUntil { state.details[beta] != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.details[alpha])
        XCTAssertEqual(Set(state.details.keys), [beta])
    }

    func testDetailsOfALoadedRowGoWhenItLeavesTheList() async throws {
        let gate = CopyGate()
        await gate.open()
        let fixture = try makeFixture(previewGate: gate)
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        let beta = try XCTUnwrap(state.selection.rows.first?.ref)
        let alpha = try XCTUnwrap(state.selection.rows.last?.ref)
        state.loadDetails(for: [alpha, beta], frameSize: stripFrame)
        try await SearchTestSupport.waitUntil { state.details.count == 2 }

        state.setQuery("beta")
        try await settled(state)

        XCTAssertEqual(Set(state.details.keys), [beta])
    }

    func testDetailsStopLoadingForRowsNoLongerRequested() async throws {
        let fixture = try makeFixture()
        try await insert("older", at: 1, into: fixture)
        try await insert("newer", at: 2, into: fixture)
        let watch = ReadWatch()
        let services = servicesHolding(watch, in: fixture)
        let state = QuickAccessState(services: { services })
        state.open()
        try await settled(state)
        let newer = try XCTUnwrap(state.selection.rows.first?.ref)
        let older = try XCTUnwrap(state.selection.rows.last?.ref)
        await watch.choose(newer)

        state.loadDetails(for: [newer], frameSize: stripFrame)
        try await SearchTestSupport.waitUntil { await watch.waiting == 1 }
        state.loadDetails(for: [older], frameSize: stripFrame)

        try await SearchTestSupport.waitUntil { await watch.cancelled == 1 }
        try await SearchTestSupport.waitUntil { state.details[older] != nil }
        XCTAssertNil(state.details[newer])
    }

    func testClosingCancelsDetailLoads() async throws {
        let fixture = try makeFixture()
        try await insert("done", at: 1, into: fixture)
        try await insert("stuck", at: 2, into: fixture)
        let watch = ReadWatch()
        let services = servicesHolding(watch, in: fixture)
        let state = QuickAccessState(services: { services })
        state.open()
        try await settled(state)
        let stuck = try XCTUnwrap(state.selection.rows.first?.ref)
        let done = try XCTUnwrap(state.selection.rows.last?.ref)
        await watch.choose(stuck)
        state.loadDetails(for: [done, stuck], frameSize: stripFrame)
        try await SearchTestSupport.waitUntil { state.details[done] != nil }
        try await SearchTestSupport.waitUntil { await watch.waiting == 1 }

        state.close()

        try await SearchTestSupport.waitUntil { await watch.cancelled == 1 }
        XCTAssertTrue(state.details.isEmpty, "Closing drops the details that were already loaded")
    }

    func testDetailsAreReadTwoAtATimeNearestTheMiddleFirst() async throws {
        let fixture = try makeFixture()
        for offset in 0..<5 { try await insert("clip \(offset)", at: Double(offset), into: fixture) }
        let gate = DetailGate()
        let repository = ContentRepository(controller: fixture.harness.controller)
        var gated = fixture.services
        gated.preview = PreviewService(read: { ref in
            await gate.enter(ref)
            return try await repository.read(ref)
        })
        let services = gated
        let state = QuickAccessState(services: { services })
        state.open()
        try await settled(state)
        let refs = state.selection.rows.map(\.ref)
        XCTAssertEqual(refs.count, 5)
        // The way the strip asks: the clip in the middle first, then outward.
        let nearestFirst = [refs[2], refs[1], refs[3], refs[0], refs[4]]

        state.loadDetails(for: nearestFirst, frameSize: stripFrame)

        // The two nearest the middle are read first.
        try await SearchTestSupport.waitUntil { await gate.started.count >= 2 }
        var started = await gate.started
        XCTAssertEqual(Set(started), Set(nearestFirst.prefix(2)))
        // Each read that returns starts the next nearest, and no other read starts meanwhile.
        for (index, next) in nearestFirst.dropFirst(2).enumerated() {
            await gate.release(started[index])
            try await SearchTestSupport.waitUntil { await gate.started.count == 3 + index }
            started = await gate.started
            XCTAssertEqual(started.last, next)
        }
        await gate.releaseAll()
        try await SearchTestSupport.waitUntil { state.details.count == 5 }
        let mostAtOnce = await gate.mostAtOnce
        XCTAssertEqual(mostAtOnce, 2, "Never more than two reads at once")
        state.close()
    }

    func testFilterRowShowsWithQueryFiltersOrWhenRevealed() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        XCTAssertFalse(state.filtersVisible, "A fresh panel keeps the filter row out of the way")

        state.setQuery("alpha")
        XCTAssertTrue(state.filtersVisible)
        state.setQuery("")
        XCTAssertFalse(state.filtersVisible)

        state.toggleKind(.text)
        XCTAssertTrue(state.filtersVisible)
        state.toggleKind(.text)
        XCTAssertFalse(state.filtersVisible)

        state.revealFilters()
        XCTAssertTrue(state.filtersVisible)
        state.toggleFiltersRevealed()
        XCTAssertFalse(state.filtersVisible)
        state.toggleFiltersRevealed()
        XCTAssertTrue(state.filtersVisible)

        // Each time the panel opens, the filter row starts hidden again.
        state.close()
        state.open()
        XCTAssertFalse(state.filtersVisible)
        try await settled(state)
    }

    func testClearingQueryAndFiltersHidesARevealedFilterRow() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        let chosen = state.selection.selection

        // A filter row brought up with nothing chosen is a layer of its own, and the list stays as it is.
        state.revealFilters()
        state.clearQueryAndFilters()

        XCTAssertFalse(state.filtersRevealed)
        XCTAssertFalse(state.filtersVisible)
        XCTAssertEqual(state.phase, .results, "Hiding an empty filter row does not search again")
        XCTAssertEqual(state.selection.selection, chosen)

        state.revealFilters()
        state.setQuery("alpha")
        state.toggleKind(.text)
        try await settled(state)
        state.clearQueryAndFilters()
        try await settled(state)

        XCTAssertFalse(state.filtersVisible)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.kinds, [])
        XCTAssertEqual(state.selection.rows.map(\.title), ["beta note", "alpha note"])
    }

    func testImagePreviewComesFromThePreviewService() async throws {
        let fixture = try makeFixture()
        try await insert("pixel", types: [("public.png", try png(width: 3000, height: 2000))], at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.togglePreview()
        try await SearchTestSupport.waitUntil { state.preview != nil }

        guard case .image(let image, let pixelSize)? = state.preview else {
            return XCTFail("Expected an image preview, got \(String(describing: state.preview))")
        }
        XCTAssertEqual(pixelSize, CGSize(width: 3000, height: 2000))
        // The picture is cut down to what the preview card can show, while its size stays the real one.
        XCTAssertEqual(max(image.width, image.height), 1520)
    }

    func testImagePreviewFallsBackToInfoWhenNothingDecodes() async throws {
        let fixture = try makeFixture()
        try await insert("pixel", types: [("public.png", Data([0x89, 0x50, 0x4E, 0x47]))], at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        state.togglePreview()
        try await SearchTestSupport.waitUntil { state.preview != nil }

        XCTAssertEqual(state.preview, .info(kind: .image, sourceApp: "test.source"))
    }

    func testEmptyStatesUseTheStripCopy() {
        XCTAssertEqual(QuickAccessStatus.empty(phase: .noContent, notice: nil),
                       QuickAccessStatus.Message(text: "No clips yet. Copy something and it shows up here.", detail: nil))
        XCTAssertEqual(QuickAccessStatus.empty(phase: .libraryUnavailable, notice: nil),
                       QuickAccessStatus.Message(text: "Library unavailable",
                                                 detail: "Recent clips appear here once the library opens."))
    }

    private struct Fixture {
        let harness: SearchHarness
        let board: NSPasteboard
        let services: QuickAccessServices
    }

    /// `onScanProgress`, when given, gets the progress of every search that scans rather than looks its terms up.
    private func makeFixture(search: SearchService? = nil, withoutSearch: Bool = false, withoutPreview: Bool = false,
                             readGate: CopyGate? = nil, previewGate: CopyGate? = nil,
                             onScanProgress: (@Sendable (Int64) -> Void)? = nil) throws -> Fixture {
        let harness = try SearchHarness.make(in: self)
        let scanning = onScanProgress.map {
            SearchService(index: harness.index, status: harness.status, onScanProgress: $0)
        }
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        let repository = ContentRepository(controller: harness.controller)
        let usage = LocalUsageStore(controller: harness.controller)
        let paste = PasteService(pasteboard: board, read: { ref in
            await readGate?.enter()
            return try await repository.read(ref)
        }, recordUse: { try await usage.record($0) }, didWrite: { _ in })
        let preview = PreviewService(read: { ref in
            await previewGate?.enter()
            return try await repository.read(ref)
        })
        let services = QuickAccessServices(repository: repository,
                                           search: withoutSearch ? nil : search ?? scanning ?? harness.service,
                                           paste: paste, preview: withoutPreview ? nil : preview)
        return Fixture(harness: harness, board: board, services: services)
    }

    /// The fixture's services, with a preview service whose read of the clip `watch` has chosen hangs.
    private func servicesHolding(_ watch: ReadWatch, in fixture: Fixture) -> QuickAccessServices {
        let repository = ContentRepository(controller: fixture.harness.controller)
        var services = fixture.services
        services.preview = PreviewService(read: { ref in
            try await watch.read(ref)
            return try await repository.read(ref)
        })
        return services
    }

    /// A synthetic PNG of the given size, drawn with Core Graphics.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
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

    /// Returns once every search asked for so far has run and handed its pages to the state. The yield lets a
    /// search the state has just asked for reach the search queue. Searches run there one at a time, so one made
    /// after it finishes after it, and resumes this test only after its pages have reached the main actor.
    private func searchesFinished(in fixture: Fixture) async throws {
        await Task.yield()
        _ = try await fixture.harness.search("settle")
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

/// Counts the scanned ranges searches report, from the search queue.
private final class ScanCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() {
        lock.withLock { value += 1 }
    }
}


/// Holds reads at their content read until the test opens it, and counts how many arrived.
private actor CopyGate {
    private(set) var entries = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entries += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Holds each read until the test releases it, and records the order the reads started in and the most that
/// were held at once.
private actor DetailGate {
    private(set) var started: [ContentRef] = []
    private(set) var mostAtOnce = 0
    private var held: [ContentRef: CheckedContinuation<Void, Never>] = [:]
    private var isOpen = false

    func enter(_ ref: ContentRef) async {
        started.append(ref)
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            held[ref] = continuation
            mostAtOnce = max(mostAtOnce, held.count)
        }
    }

    func release(_ ref: ContentRef) {
        held.removeValue(forKey: ref)?.resume()
    }

    func releaseAll() {
        isOpen = true
        held.values.forEach { $0.resume() }
        held.removeAll()
    }
}

/// Makes the read of one chosen clip wait until it is cancelled, and counts the reads that waited and
/// the ones that were cancelled while waiting.
private actor ReadWatch {
    private var chosen: ContentRef?
    private(set) var waiting = 0
    private(set) var cancelled = 0

    func choose(_ ref: ContentRef) {
        chosen = ref
    }

    func read(_ ref: ContentRef) async throws {
        guard ref == chosen else { return }
        waiting += 1
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            cancelled += 1
            throw error
        }
    }
}
