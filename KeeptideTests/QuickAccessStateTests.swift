import AppKit
import CoreGraphics
import ImageIO
import Observation
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
        state.onCompleted = { _ in copied.count += 1 }
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
        state.onCompleted = { _ in copied.count += 1 }
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
        state.onCompleted = { _ in copied.count += 1 }
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
        state.onCompleted = { _ in copied.count += 1 }
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
        state.onCompleted = { _ in copied.count += 1 }
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
        state.onCompleted = { _ in copied.count += 1 }
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
        XCTAssertEqual(QuickAccessStatus.line(selectionLost: true, phase: .results, isComplete: false),
                       "The selected item is no longer in the results")
        XCTAssertEqual(QuickAccessStatus.line(selectionLost: false, phase: .results, isComplete: false), "Searching…")
        XCTAssertEqual(QuickAccessStatus.line(selectionLost: false, phase: .loading, isComplete: true), "Searching…")
        // With nothing else to say, the toolbar shows Return's hint; a rebuilding index is told under the rows.
        XCTAssertNil(QuickAccessStatus.line(selectionLost: false, phase: .results, isComplete: true))
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

    func testTheSearchIsOpenWhileItHasAQueryOrOnceUnfolded() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        XCTAssertFalse(state.isSearchExpanded, "The panel opens with the search folded")

        // A query holds the search open; without one it folds again.
        state.setQuery("alpha")
        XCTAssertTrue(state.isSearchExpanded)
        state.setQuery("")
        XCTAssertFalse(state.isSearchExpanded)

        // A filter alone does not open it.
        state.toggleKind(.text)
        XCTAssertFalse(state.isSearchExpanded)
        state.toggleKind(.text)

        // Unfolded by hand, it stays open with or without a query, until it is folded.
        state.unfoldSearch()
        XCTAssertTrue(state.isSearchExpanded)
        state.setQuery("alpha")
        state.setQuery("")
        XCTAssertTrue(state.isSearchExpanded)
        state.foldSearch()
        XCTAssertFalse(state.isSearchExpanded)

        // Each time the panel opens, the search starts folded again.
        state.unfoldSearch()
        state.close()
        state.open()
        XCTAssertFalse(state.isSearchExpanded)
        try await settled(state)
    }

    func testClearingQueryAndFiltersFoldsTheSearch() async throws {
        let fixture = try makeFixture()
        try await insert("alpha note", at: 1, into: fixture)
        try await insert("beta note", at: 2, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        let chosen = state.selection.selection

        // Folding an open search with nothing in it does not search again.
        state.unfoldSearch()
        state.foldSearch()
        XCTAssertEqual(state.phase, .results, "Folding an empty search does not search again")
        XCTAssertEqual(state.selection.selection, chosen)

        state.unfoldSearch()
        state.setQuery("alpha")
        state.toggleKind(.text)
        try await settled(state)
        state.clearQueryAndFilters()
        try await settled(state)

        XCTAssertFalse(state.isSearchExpanded)
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

    // MARK: The frequent wing

    func testOpeningListsTheFrequentWingBeforeTheRecentClips() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for index in 0..<8 { clips.append(try await insert("c\(index)", at: Double(index), into: fixture)) }
        let now = Date()
        try await use(clips[0], times: 5, lastAt: now - 3_600, in: fixture)
        try await use(clips[1], times: 3, lastAt: now - 3_600, in: fixture)
        try await use(clips[2], times: 3, lastAt: now - 7_200, in: fixture)
        try await use(clips[3], times: 1, lastAt: now, in: fixture)
        try await use(clips[4], times: 4, lastAt: now - 91 * 86_400, in: fixture)
        try await use(clips[7], times: 9, lastAt: now, in: fixture)
        let state = QuickAccessState(services: { fixture.services })

        state.open(frequentWingFirstScreen: 3)
        try await settled(state)

        // c7 is used most, but it is among the first three recent clips; c3 was used once, and c4 not for 91 days.
        XCTAssertEqual(state.selection.rows.map(\.title), ["c0", "c1", "c2", "c7", "c6", "c5", "c4", "c3", "c2", "c1", "c0"])
        XCTAssertEqual(state.selection.rows.prefix(3).map(\.frequentUses), [5, 3, 3])
        XCTAssertEqual(state.selection.frequentCount, 3)
        // The newest recent clip is selected, after the wing.
        XCTAssertEqual(state.selection.selectedRow?.title, "c7")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, false)
        XCTAssertEqual(state.selection.executableSelection, state.selection.rows[3].ref)
        XCTAssertEqual(state.moveSelection(by: -1), .moved)
        XCTAssertEqual(state.selection.selectedID, state.selection.rows[2].id)
    }

    func testTheWingTakesTwentyAndSkipsWhatCannotShowWithoutRefilling() async throws {
        let fixture = try makeFixture()
        var used: [ItemValue] = []
        for index in 0..<23 { used.append(try await insert("f\(index)", at: Double(index), into: fixture)) }
        for index in 0..<5 { try await insert("n\(index)", at: Double(100 + index), into: fixture) }
        let now = Date()
        for (index, clip) in used.enumerated() {
            try await use(clip, times: 2, lastAt: now - Double(index + 1) * 60, in: fixture)
        }
        // f3 leaves the history after its uses were counted.
        var gone = used[3]
        gone.historyDeletedAt = Date()
        try await fixture.harness.update(.item(gone.id), to: .item(gone))
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })

        state.open(frequentWingFirstScreen: 5)
        try await settled(state)

        // The first twenty ranks, without f3, which cannot show; f20 does not take its place.
        XCTAssertEqual(wing(state), (0..<20).filter { $0 != 3 }.map { "f\($0)" })

        // A type filter takes twenty again, from every candidate that matches it: f20 comes in, f21 and f22 do not.
        state.toggleKind(.text)
        try await settled(state)
        XCTAssertEqual(wing(state), (0...20).filter { $0 != 3 }.map { "f\($0)" })
    }

    func testATypeFilterFiltersBothWingsAndTakesTwentyAgain() async throws {
        let fixture = try makeFixture()
        var texts: [ItemValue] = []
        for index in 0..<20 { texts.append(try await insert("t\(index)", at: Double(index), into: fixture)) }
        var links: [ItemValue] = []
        for index in 0..<2 {
            links.append(try await insert("l\(index)", types: link("https://example.com/synthetic-l\(index)"),
                                          at: Double(20 + index), into: fixture))
        }
        for index in 0..<5 {
            try await insert("m\(index)", types: link("https://example.com/synthetic-m\(index)"), at: Double(30 + index),
                             into: fixture)
        }
        for index in 0..<5 { try await insert("n\(index)", at: Double(40 + index), into: fixture) }
        try await fixture.harness.consumer.synchronize()
        let now = Date()
        for (index, clip) in texts.enumerated() {
            try await use(clip, times: 2, lastAt: now - Double(index + 1) * 60, in: fixture)
        }
        for (index, clip) in links.enumerated() {
            try await use(clip, times: 2, lastAt: now - Double(31 + index) * 60, in: fixture)
        }
        let state = QuickAccessState(services: { fixture.services })
        state.open(frequentWingFirstScreen: 5)
        try await settled(state)
        XCTAssertEqual(wing(state), (0..<20).map { "t\($0)" })

        state.toggleKind(.url)
        try await settled(state)

        // l0 and l1 rank 21st and 22nd, so only a filter brings them into the wing. Neither is among the first five
        // links, so each is listed in both wings.
        XCTAssertEqual(state.selection.rows.map(\.title), ["l0", "l1", "m4", "m3", "m2", "m1", "m0", "l1", "l0"])
        XCTAssertEqual(state.selection.selectedRow?.title, "m4")
    }

    func testAQueryHidesTheWingAndClearingBringsTheSameWingBack() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for index in 0..<8 { clips.append(try await insert("c\(index)", at: Double(index), into: fixture)) }
        // The index has the clips but not their uses, so c0 is the last result for "c": no wing hides among the first.
        try await fixture.harness.consumer.synchronize()
        try await use(clips[0], times: 2, lastAt: Date(), in: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open(frequentWingFirstScreen: 3)
        try await settled(state)
        XCTAssertEqual(wing(state), ["c0"])

        state.setQuery("c")
        try await SearchTestSupport.waitUntil { state.phase == .results && state.selection.isComplete }
        XCTAssertEqual(state.selection.rows.count, 8)
        XCTAssertFalse(state.selection.rows.contains { $0.isFrequent })

        // A use recorded while the panel is open changes nothing until it opens again (c3 is off the first screen).
        try await use(clips[3], times: 4, lastAt: Date(), in: fixture)
        state.setQuery("  ")
        try await settled(state)
        XCTAssertEqual(wing(state), ["c0"])
        state.clearQueryAndFilters()
        try await settled(state)
        XCTAssertEqual(wing(state), ["c0"])
    }

    func testWithoutAFirstScreenThereIsNoWing() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for index in 0..<4 { clips.append(try await insert("c\(index)", at: Double(index), into: fixture)) }
        try await use(clips[0], times: 2, lastAt: Date(), in: fixture)
        let state = QuickAccessState(services: { fixture.services })

        state.open()
        try await settled(state)

        XCTAssertEqual(state.selection.rows.count, 4)
        XCTAssertEqual(state.selection.frequentCount, 0)
    }

    func testAFailedFrequentReadStillListsRecentClips() async throws {
        let usage = FailingUsage()
        let fixture = try makeFixture(usage: usage)
        for index in 0..<4 { try await insert("c\(index)", at: Double(index), into: fixture) }
        let state = QuickAccessState(services: { fixture.services })

        state.open(frequentWingFirstScreen: 3)
        try await settled(state)

        let calls = await usage.calls
        XCTAssertEqual(calls, 1, "The read was asked for, and failed")
        XCTAssertEqual(state.selection.rows.map(\.title), ["c3", "c2", "c1", "c0"])
        XCTAssertEqual(state.phase, .results)
    }

    func testTheFrequentReadAsksForTwoUsesInNinetyDaysOncePerOpening() async throws {
        let usage = RecordingUsage()
        let fixture = try makeFixture(usage: usage)
        for index in 0..<4 { try await insert("c\(index)", at: Double(index), into: fixture) }
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })

        // The first page waits for the read, so once it is listed the read has been asked for.
        state.open(frequentWingFirstScreen: 3)
        try await settled(state)
        var calls = await usage.calls
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.minimumCount, 2)
        XCTAssertEqual(call.limit, 200)
        XCTAssertEqual(call.since.timeIntervalSinceNow, -7_776_000, accuracy: 5)

        // Nothing after the opening reads it again. Each step is waited for, so a read it asked for would be counted.
        try await insert("c4", at: 4, into: fixture)
        state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { state.selection.rows.count == 5 }
        state.setQuery("c")
        try await SearchTestSupport.waitUntil { state.phase == .results && state.selection.isComplete }
        state.clearQueryAndFilters()
        try await settled(state)
        state.toggleKind(.text)
        try await settled(state)
        calls = await usage.calls
        XCTAssertEqual(calls.count, 1)

        state.close()
        state.open(frequentWingFirstScreen: 3)
        try await settled(state)
        calls = await usage.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testFilterPagingCountsOnlyTheRecentRows() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for offset in 0..<70 { clips.append(try await insert("bulk \(offset)", at: Double(offset), into: fixture)) }
        try await fixture.harness.consumer.synchronize()
        let now = Date()
        try await use(clips[0], times: 2, lastAt: now - 120, in: fixture)
        try await use(clips[1], times: 2, lastAt: now - 60, in: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open(frequentWingFirstScreen: 5)
        try await settled(state)
        state.toggleKind(.text)
        try await settled(state)
        XCTAssertEqual(state.selection.rows.count, 62)
        XCTAssertTrue(state.hasMoreRows)

        state.loadMoreIfNeeded(visibleRow: 61)
        try await SearchTestSupport.waitUntil { state.selection.rows.count == 72 }

        let recent = state.selection.rows.filter { !$0.isFrequent }
        XCTAssertEqual(Set(recent.map(\.ref)).count, 70)
        XCTAssertEqual(state.selection.frequentCount, 2)
        XCTAssertFalse(state.hasMoreRows)
    }

    func testTheWingIsNoPartOfTheMatchesAFilterHasListed() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for offset in 0..<61 { clips.append(try await insert("bulk \(offset)", at: Double(offset), into: fixture)) }
        try await fixture.harness.consumer.synchronize()
        let now = Date()
        try await use(clips[0], times: 2, lastAt: now - 120, in: fixture)
        try await use(clips[1], times: 2, lastAt: now - 60, in: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open(frequentWingFirstScreen: 5)
        try await settled(state)
        state.toggleKind(.text)
        try await settled(state)

        // Sixty-two rows are listed, but only sixty of the sixty-one matches: one more is to come.
        XCTAssertEqual(state.selection.rows.count, 62)
        XCTAssertTrue(state.hasMoreRows)
        state.loadMoreIfNeeded(visibleRow: 61)
        try await SearchTestSupport.waitUntil { state.selection.rows.count == 63 }
        XCTAssertEqual(state.selection.rows.last?.title, "bulk 0")
        XCTAssertFalse(state.hasMoreRows)
    }

    func testARefreshListsTheOpeningsCandidatesAgainstTheNewFirstScreen() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for index in 0..<6 { clips.append(try await insert("c\(index)", at: Double(index), into: fixture)) }
        let now = Date()
        try await use(clips[0], times: 3, lastAt: now, in: fixture)
        try await use(clips[3], times: 2, lastAt: now, in: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open(frequentWingFirstScreen: 3)
        try await settled(state)
        // c3 is the last of the first three recent clips, so the wing leaves it out.
        XCTAssertEqual(wing(state), ["c0"])

        // c1 is used most from now on, which the panel does not read again; three newer clips push c3 off the first
        // screen.
        try await use(clips[1], times: 4, lastAt: now, in: fixture)
        for index in 0..<3 { try await insert("n\(index)", at: Double(10 + index), into: fixture) }
        state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { state.selection.rows.contains { $0.title == "n2" } }

        XCTAssertEqual(wing(state), ["c0", "c3"])
        XCTAssertEqual(state.selection.rows.prefix(2).map(\.frequentUses), [3, 2])
        // The refresh keeps the clip selected as the panel opened.
        XCTAssertEqual(state.selection.selectedRow?.title, "c5")
        XCTAssertEqual(state.selection.selectedRow?.isFrequent, false)
    }

    func testAFilterThatMatchesNoRecentClipListsNoWing() async throws {
        let fixture = try makeFixture()
        for index in 0..<4 { try await insert("c\(index)", at: Double(index), into: fixture) }
        try await fixture.harness.consumer.synchronize()
        // A link used twice, and a newer clip, neither of which the index has taken in yet.
        let frequent = try await insert("l0", types: link("https://example.com/synthetic-frequent"), at: 10,
                                        into: fixture)
        try await insert("c4", at: 11, into: fixture)
        try await use(frequent, times: 2, lastAt: Date(), in: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open(frequentWingFirstScreen: 1)
        try await settled(state)
        XCTAssertEqual(state.selection.rows.map(\.title), ["l0", "c4", "l0", "c3", "c2", "c1", "c0"])

        state.toggleKind(.url)
        try await settled(state)

        // The index finds no link, and a wing over no recent rows is not listed, though the link is a frequent one.
        XCTAssertEqual(state.selection.rows, [])
        XCTAssertEqual(state.phase, .noResults)
    }

    func testASearchThatCannotRunListsNoWing() async throws {
        let fixture = try makeFixture(withoutSearch: true)
        var clips: [ItemValue] = []
        for index in 0..<4 { clips.append(try await insert("c\(index)", at: Double(index), into: fixture)) }
        try await use(clips[0], times: 2, lastAt: Date(), in: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open(frequentWingFirstScreen: 3)
        try await settled(state)
        XCTAssertEqual(wing(state), ["c0"])

        state.toggleKind(.text)
        try await settled(state)

        XCTAssertEqual(state.selection.rows, [])
        XCTAssertEqual(state.indexNotice, .searchUnavailable)
        XCTAssertEqual(state.phase, .noResults)
    }

    func testAReadStillRunningWhenThePanelClosesNeverShows() async throws {
        let usage = HeldUsage(holding: [1, 2, 3])
        let fixture = try makeFixture(usage: usage)
        var clips: [ItemValue] = []
        for index in 0..<5 { clips.append(try await insert("c\(index)", at: Double(index), into: fixture)) }
        let now = Date()
        // The first opening's read finds c0, and the second's c1.
        await usage.reply([
            [UsageSummary(itemID: clips[0].id, facet: .history, lastUsedAt: now, useCount: 5)],
            [UsageSummary(itemID: clips[1].id, facet: .history, lastUsedAt: now, useCount: 3)],
        ])
        let state = QuickAccessState(services: { fixture.services })

        state.open(frequentWingFirstScreen: 2)
        try await SearchTestSupport.waitUntil { await usage.calls == 1 }
        // The recent clips are read on the store's one queue, so a read made after them returns after them. The first
        // page still waits for the wing, so the two show together.
        _ = try await fixture.services.repository.recent(limit: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.selection.rows, [])
        XCTAssertEqual(state.phase, .loading)

        // The panel closes and opens again while the first read is held, and that read comes back first: what it
        // found goes nowhere, and the second opening still waits for its own.
        state.close()
        state.open(frequentWingFirstScreen: 2)
        try await SearchTestSupport.waitUntil { await usage.calls == 2 }
        await usage.release(1)
        try await SearchTestSupport.waitUntil { await usage.returned == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.selection.rows, [])
        XCTAssertEqual(state.phase, .loading)
        var cancelled = await usage.returnedCancelled
        XCTAssertEqual(cancelled, 1, "Closing cancelled the first read")
        await usage.release(2)
        try await settled(state)
        XCTAssertEqual(wing(state), ["c1"])
        // Nor does the first read show later: a refresh lists the wing this opening read.
        try await insert("c5", at: 5, into: fixture)
        state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { state.selection.rows.contains { $0.title == "c5" } }
        XCTAssertEqual(wing(state), ["c1"])

        // A read still held when the panel closes is cancelled, with no opening after it.
        state.close()
        state.open(frequentWingFirstScreen: 2)
        try await SearchTestSupport.waitUntil { await usage.calls == 3 }
        state.close()
        await usage.release(3)
        try await SearchTestSupport.waitUntil { await usage.returned == 3 }
        cancelled = await usage.returnedCancelled
        XCTAssertEqual(cancelled, 2)
    }

    func testAServicesChangeReadsTheWingAgain() async throws {
        let fixture = try makeFixture()
        var clips: [ItemValue] = []
        for index in 0..<5 { clips.append(try await insert("c\(index)", at: Double(index), into: fixture)) }
        try await use(clips[0], times: 2, lastAt: Date(), in: fixture)
        let box = ServicesBox()
        let state = QuickAccessState(services: { box.services })

        // The panel opens before the library: there is nothing to list or read.
        state.open(frequentWingFirstScreen: 2)
        XCTAssertEqual(state.phase, .libraryUnavailable)
        // The library opens, which starts a session, and the session reads the wing.
        box.services = fixture.services
        state.servicesDidChange()
        try await settled(state)
        XCTAssertEqual(wing(state), ["c0"])

        // Each services change starts a session, which reads the uses recorded since.
        try await use(clips[1], times: 3, lastAt: Date(), in: fixture)
        state.servicesDidChange()
        try await settled(state)
        XCTAssertEqual(wing(state), ["c1", "c0"])
    }

    // MARK: Direct paste

    func testOpeningRecordsTheTargetAndOffersPaste() async throws {
        let fake = FakeDirectPasteSystem()
        let fixture = try makeFixture(system: fake.system)
        try await insert("paste me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })

        state.open()
        try await settled(state)

        XCTAssertEqual(state.pasteTarget, .textEdit)
        XCTAssertEqual(state.directPaste, .paste(.textEdit))
        XCTAssertEqual(state.preferredDelivery, .paste)
        XCTAssertEqual(state.actions.primaryTitle, "Paste into TextEdit")
        // Opening only asks what the system allows: it never asks for access.
        XCTAssertEqual(fake.accessRequests, 0)
        XCTAssertEqual(fake.settingsOpened, 0)

        // The target goes with the session.
        state.close()
        XCTAssertNil(state.pasteTarget)
        XCTAssertNil(state.directPaste)
        XCTAssertEqual(state.preferredDelivery, .copy)
    }

    func testServicesChangingKeepsTheTargetRecordedAtOpen() async throws {
        let fake = FakeDirectPasteSystem()
        let fixture = try makeFixture(system: fake.system)
        try await insert("paste me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)

        // The library reopens while Notes is in front: the session keeps TextEdit, and the checks find it gone.
        fake.front = .notes
        state.servicesDidChange()
        try await settled(state)

        XCTAssertEqual(state.pasteTarget, .textEdit)
        XCTAssertEqual(state.directPaste, .copy(.targetChanged))
        XCTAssertEqual(state.preferredDelivery, .copy)
        XCTAssertEqual(state.actions.primaryTitle, "Copy")
    }

    func testAPanelOpenedBeforeTheLibraryOnlyCopies() async throws {
        let fake = FakeDirectPasteSystem()
        let fixture = try makeFixture(system: fake.system)
        try await insert("late library", at: 1, into: fixture)
        let box = ServicesBox()
        let state = QuickAccessState(services: { box.services })

        state.open()
        XCTAssertNil(state.pasteTarget)
        XCTAssertNil(state.directPaste)

        box.services = fixture.services
        state.servicesDidChange()
        try await settled(state)

        // The front window is read only as the panel opens, and then there was no library to read it for.
        XCTAssertNil(state.pasteTarget)
        XCTAssertEqual(state.directPaste, .copy(.noTarget))
        XCTAssertEqual(state.preferredDelivery, .copy)
        XCTAssertEqual(state.actions.primaryTitle, "Copy")
        XCTAssertEqual(fake.probes, 0)
    }

    func testReturnPastesAndReportsDispatchedAfterHiding() async throws {
        let fake = FakeDirectPasteSystem()
        let fixture = try makeFixture(system: fake.system)
        try await insert("paste me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        fake.onSend = { events.dismissalsAtSend = events.dismissals }
        state.open()
        try await settled(state)

        try await pressReturn(state)

        XCTAssertEqual(events.completions, [.dispatched])
        XCTAssertEqual(events.dismissals, 1)
        XCTAssertEqual(events.dismissalsAtSend, 1)
        XCTAssertEqual(fake.sent, [9])
        XCTAssertEqual(fixture.board.string(forType: .string), "paste me")
    }

    func testACopyCaptionNeverTurnsIntoAPaste() async throws {
        let fake = FakeDirectPasteSystem()
        fake.permitted = false
        let fixture = try makeFixture(system: fake.system)
        try await insert("copy me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        XCTAssertEqual(state.directPaste, .copy(.notPermitted))
        XCTAssertEqual(state.actions.primaryTitle, "Copy")
        XCTAssertTrue(state.actions.offersEnableDirectPaste)

        // Enable Direct Paste… is granted before Return.
        fake.grantsOnRequest = true
        fake.permitted = true
        state.requestDirectPasteAccess()
        XCTAssertEqual(fake.accessRequests, 1)
        try await pressReturn(state)

        XCTAssertEqual(events.completions, [.copied])
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(events.dismissals, 0)
        XCTAssertEqual(fixture.board.string(forType: .string), "copy me")
    }

    func testAMultiLineCommandOpensAReviewThatConfirmPastes() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let fixture = try makeFixture(system: fake.system)
        try await insert("gamma", body: Self.multiLine, at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        XCTAssertEqual(state.actions.primaryTitle, "Paste Command")
        let before = fixture.board.changeCount

        try await pressReturn(state)

        let review = try XCTUnwrap(state.commandReview)
        XCTAssertEqual(review.command.text, "set -e\necho synthetic-gamma")
        XCTAssertEqual(review.confirmation.delivery, .paste)
        XCTAssertEqual(QuickAccessActions.confirmTitle(for: review), "Confirm Paste into Terminal")
        XCTAssertEqual(events.reviewChanges, 1)
        XCTAssertEqual(events.completions, [])
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])

        await state.confirmCommand()

        XCTAssertEqual(events.completions, [.dispatched])
        XCTAssertNil(state.commandReview)
        XCTAssertEqual(fake.sent, [9])
        XCTAssertEqual(events.dismissals, 1)
        XCTAssertEqual(fixture.board.string(forType: .string), "set -e\necho synthetic-gamma")
    }

    func testAConfirmedCopyReviewSaysWhyItDidNotPaste() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let fixture = try makeFixture(system: fake.system)
        try await insert("gamma", body: Self.multiLine, at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        XCTAssertEqual(state.actions.primaryTitle, "Paste Command")

        // Secure input comes on before Return, so the command is reviewed for a copy.
        fake.secureInput = true
        try await pressReturn(state)
        let review = try XCTUnwrap(state.commandReview)
        XCTAssertEqual(QuickAccessActions.confirmTitle(for: review), "Confirm Copy Command")

        await state.confirmCommand()

        // Confirming asks again for the paste Return asked for, so the copy comes back with its reason.
        XCTAssertEqual(events.completions, [.copiedInstead(.secureInput)])
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(events.dismissals, 0)
        XCTAssertEqual(fixture.board.string(forType: .string), "set -e\necho synthetic-gamma")
    }

    func testAConfirmedCopyReviewNeverPastes() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let fixture = try makeFixture(system: fake.system)
        try await insert("gamma", body: Self.multiLine, at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        fake.secureInput = true
        try await pressReturn(state)
        XCTAssertEqual(state.commandReview?.confirmation.delivery, .copy)
        let before = fixture.board.changeCount

        // Secure input goes off before the copy is confirmed: a paste could be sent now, but none was confirmed.
        fake.secureInput = false
        await state.confirmCommand()

        let renewal = try XCTUnwrap(state.commandReview)
        XCTAssertTrue(renewal.isRenewal)
        XCTAssertEqual(QuickAccessActions.confirmTitle(for: renewal), "Confirm Paste into Terminal")
        XCTAssertEqual(events.reviewChanges, 2)
        XCTAssertEqual(events.completions, [])
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(events.dismissals, 0)
        XCTAssertEqual(fixture.board.changeCount, before)
    }

    func testMovingOrLosingTheSelectionDropsTheReview() async throws {
        let gate = CopyGate()
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let fixture = try makeFixture(readGate: gate, system: fake.system)
        try await insert("gamma", body: Self.multiLine, at: 1, into: fixture)
        var delta = try await insert("delta", body: "set -u\necho synthetic-delta\n", at: 2, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        XCTAssertEqual(state.selection.rows.map(\.title), ["delta", "gamma"])
        let before = fixture.board.changeCount

        // A review that comes back after the selection moved on is not shown.
        let held = try XCTUnwrap(state.copyTarget)
        let late = Task { await state.act(on: held, mode: .original, delivery: state.preferredDelivery) }
        try await SearchTestSupport.waitUntil { await gate.entries == 1 }
        state.moveSelection(by: 1)
        await gate.open()
        await late.value
        XCTAssertNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 0)

        // Moving to another clip drops the review of the one selected before.
        try await pressReturn(state)
        XCTAssertEqual(state.commandReview?.command.text, "set -e\necho synthetic-gamma")
        XCTAssertEqual(events.reviewChanges, 1)
        state.moveSelection(by: -1)
        XCTAssertNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 2)

        // A selected clip that leaves the list takes its review along.
        try await pressReturn(state)
        XCTAssertEqual(state.commandReview?.command.text, "set -u\necho synthetic-delta")
        XCTAssertEqual(events.reviewChanges, 3)
        delta.historyDeletedAt = Date()
        try await fixture.harness.update(.item(delta.id), to: .item(delta))
        state.recentClipsChanged()
        try await SearchTestSupport.waitUntil { state.selection.selectionLost }
        XCTAssertNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 4)

        // With no review left, confirming does nothing; nothing was written or sent along the way.
        await state.confirmCommand()
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(events.completions, [])
    }

    func testANewQueryOrClosingDropsTheReview() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let fixture = try makeFixture(system: fake.system)
        try await insert("gamma", body: Self.multiLine, at: 1, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        let reviewed = state.selection.selection
        try await pressReturn(state)
        XCTAssertNotNil(state.commandReview)

        // The query finds the same clip, which stays selected, but the review was made under the query before.
        state.setQuery("gamma")
        XCTAssertNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 2)
        try await SearchTestSupport.waitUntil { state.phase == .results && state.selection.isComplete }
        XCTAssertEqual(state.selection.selection, reviewed)
        XCTAssertNil(state.commandReview)

        try await pressReturn(state)
        XCTAssertNotNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 3)
        state.close()
        XCTAssertNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 4)
        XCTAssertEqual(fake.sent, [])
    }

    func testCancellingTheReviewSendsAndCopiesNothing() async throws {
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let fixture = try makeFixture(system: fake.system)
        try await insert("gamma", body: Self.multiLine, at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        let target = try XCTUnwrap(state.copyTarget)
        let before = fixture.board.changeCount
        await state.act(on: target, mode: .original, delivery: state.preferredDelivery)
        XCTAssertNotNil(state.commandReview)

        state.cancelCommandReview()

        XCTAssertNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 2)
        // The confirmation went with the card.
        await state.confirmCommand()
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(events.dismissals, 0)
        XCTAssertEqual(events.completions, [])
        try await Task.sleep(for: .milliseconds(100))
        let uses = try await LocalUsageStore(controller: fixture.harness.controller).summaries(for: [target.ref])
        XCTAssertEqual(uses.first?.useCount ?? 0, 0)
    }

    func testASearchThatFailsAfterItsPagesDropsTheReview() async throws {
        let gate = CopyGate()
        let fake = FakeDirectPasteSystem()
        fake.front = .terminal
        let fixture = try makeFixture(system: fake.system)
        try await insert("gamma", body: Self.multiLine, at: 1, into: fixture)
        try await fixture.harness.consumer.synchronize()
        let services = QuickAccessServices(
            repository: fixture.services.repository,
            search: SearchFailingAfterItsPages(pages: fixture.harness.service, failure: gate),
            paste: fixture.services.paste, preview: fixture.services.preview)
        let state = QuickAccessState(services: { services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        state.setQuery("gamma")
        try await SearchTestSupport.waitUntil { state.phase == .results && state.selection.isComplete }
        try await pressReturn(state)
        XCTAssertNotNil(state.commandReview)
        let before = fixture.board.changeCount

        // The search has handed over its pages, and then it fails.
        try await SearchTestSupport.waitUntil { await gate.entries == 1 }
        await gate.open()
        try await SearchTestSupport.waitUntil { state.indexNotice == .searchUnavailable }

        XCTAssertNil(state.commandReview)
        XCTAssertEqual(events.reviewChanges, 2)
        await state.confirmCommand()
        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(events.completions, [])
    }

    func testAfterAskingForAccessTheNextShowingSaysToReopenKeeptide() async throws {
        let fake = FakeDirectPasteSystem()
        fake.permitted = false
        let fixture = try makeFixture(system: fake.system)
        try await insert("copy me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        state.open()
        try await settled(state)
        XCTAssertEqual(state.directPaste, .copy(.notPermitted))
        XCTAssertNil(state.actions.hint)

        // Access is granted in System Settings, which this run of Keeptide cannot see yet.
        state.requestDirectPasteAccess()
        state.close()
        state.open()
        try await settled(state)

        XCTAssertEqual(fake.accessRequests, 1)
        XCTAssertEqual(state.directPaste, .copy(.notPermitted))
        XCTAssertEqual(state.actions.hint, "Reopen Keeptide to finish turning on direct paste")
        XCTAssertTrue(state.actions.offersEnableDirectPaste)
    }

    func testAShowingThatOpenedAsCopyOnlyCopiesWhateverItIsAsked() async throws {
        let fake = FakeDirectPasteSystem()
        fake.permitted = false
        let fixture = try makeFixture(system: fake.system)
        try await insert("copy me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let events = PasteEvents(state)
        state.open()
        try await settled(state)
        XCTAssertEqual(state.preferredDelivery, .copy)

        // Access arrives, and a caller asks for a paste the toolbar never offered.
        fake.permitted = true
        let target = try XCTUnwrap(state.copyTarget)
        await state.act(on: target, mode: .original, delivery: .paste)

        XCTAssertEqual(events.completions, [.copied])
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(events.dismissals, 0)
        XCTAssertEqual(fixture.board.string(forType: .string), "copy me")
    }

    func testAViewOfOnlyThePasteTargetFollowsIt() async throws {
        let fake = FakeDirectPasteSystem()
        let fixture = try makeFixture(system: fake.system)
        try await insert("paste me", at: 1, into: fixture)
        let state = QuickAccessState(services: { fixture.services })
        let changes = CallCounter()

        withObservationTracking { _ = state.pasteTarget } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }
        state.open()
        XCTAssertEqual(changes.count, 1, "Opening records the target")
        XCTAssertEqual(state.pasteTarget, .textEdit)
        try await settled(state)

        withObservationTracking { _ = state.pasteTarget } onChange: {
            MainActor.assumeIsolated { changes.count += 1 }
        }
        state.close()
        XCTAssertEqual(changes.count, 2, "Closing gives the target up")
        XCTAssertNil(state.pasteTarget)
    }

    /// The quick-access seed's multi-line command.
    private static let multiLine = "set -e\necho synthetic-gamma\n"

    private struct Fixture {
        let harness: SearchHarness
        let board: NSPasteboard
        let services: QuickAccessServices
    }

    /// `onScanProgress`, when given, gets the progress of every search that scans rather than looks its terms up.
    /// `system` and `directPasteOnlyTo` go to the paste service; by default it has no target and only copies.
    /// The frequent wing reads the store's uses, or `usage` in their place.
    private func makeFixture(search: SearchService? = nil, withoutSearch: Bool = false, withoutPreview: Bool = false,
                             readGate: CopyGate? = nil, previewGate: CopyGate? = nil,
                             onScanProgress: (@Sendable (Int64) -> Void)? = nil,
                             system: DirectPasteSystem = .unavailable,
                             directPasteOnlyTo: String? = nil,
                             usage standIn: (any QuickAccessUsage)? = nil) throws -> Fixture {
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
        }, recordUse: { try await usage.record($0) }, didWrite: { _ in }, system: system,
           directPasteOnlyTo: directPasteOnlyTo)
        // A paste request the panel could not hide for stops a debug build; here it fails the test instead.
        paste.reportProgrammingError = { XCTFail("Programming error: \($0)") }
        let preview = PreviewService(read: { ref in
            await previewGate?.enter()
            return try await repository.read(ref)
        })
        let services = QuickAccessServices(repository: repository,
                                           search: withoutSearch ? nil : search ?? scanning ?? harness.service,
                                           paste: paste, preview: withoutPreview ? nil : preview,
                                           usage: standIn ?? usage)
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

    /// Records `times` successful uses of `item`'s clip in the fixture's store: the last at `lastAt`, and each earlier
    /// one a second before the one after it.
    private func use(_ item: ItemValue, times: Int, lastAt: Date, in fixture: Fixture) async throws {
        let listed = try await fixture.services.repository.recent(limit: 1000)
        let ref = try XCTUnwrap(listed.first { $0.itemID == item.id }?.history, "\(item.title) is not listed")
        let usage = LocalUsageStore(controller: fixture.harness.controller)
        for secondsBeforeLast in (0..<times).reversed() {
            try await usage.record(UseReceipt(ref: ref, occurredAt: lastAt - TimeInterval(secondsBeforeLast),
                                              outcome: .success))
        }
    }

    /// A link clip: its address as a URL and as plain text.
    private func link(_ address: String) -> [(String, Data)] {
        let data = Data(address.utf8)
        return [("public.url", data), ("public.utf8-plain-text", data)]
    }

    /// The titles of the frequent wing's rows, in order.
    private func wing(_ state: QuickAccessState) -> [String] {
        state.selection.rows.prefix { $0.isFrequent }.map(\.title)
    }

    /// Waits until the current generation has a page.
    private func settled(_ state: QuickAccessState) async throws {
        try await SearchTestSupport.waitUntil { state.phase != .loading }
    }

    /// Return, as the panel sends it: the selected clip's original formats, delivered as the toolbar said.
    private func pressReturn(_ state: QuickAccessState) async throws {
        let target = try XCTUnwrap(state.copyTarget)
        await state.act(on: target, mode: .original, delivery: state.preferredDelivery)
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

/// What the panel would see of a state's actions: each completion, each change of the command review, and each time
/// the state hides the panel for a paste. It takes the state's callbacks.
@MainActor
private final class PasteEvents {
    var completions: [QuickAccessCompletion] = []
    var reviewChanges = 0
    var dismissals = 0
    /// How many times the panel had hidden when ⌘V was sent.
    var dismissalsAtSend: Int?

    init(_ state: QuickAccessState) {
        state.onCompleted = { [weak self] in self?.completions.append($0) }
        state.onCommandReviewChanged = { [weak self] in self?.reviewChanges += 1 }
        state.dismissForPaste = { [weak self] in self?.dismissals += 1 }
    }
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


/// The fixture's search, except that each search, once it has handed over its pages, waits at `failure` and then
/// fails, as a search may after it has shown pages.
private struct SearchFailingAfterItsPages: QuickAccessSearch {
    let pages: SearchService
    let failure: CopyGate

    func search(_ request: SearchRequest) -> AsyncThrowingStream<SearchPage, Error> {
        AsyncThrowingStream { continuation in
            let search = Task {
                do {
                    for try await page in pages.search(request) { continuation.yield(page) }
                    await failure.enter()
                    continuation.finish(throwing: SearchIndexError.closed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in search.cancel() }
        }
    }
}

/// A read of the frequent clips that always fails, and counts how often it was asked.
private actor FailingUsage: QuickAccessUsage {
    private(set) var calls = 0

    func frequent(minimumCount: Int64, since: Date, limit: Int) async throws -> [UsageSummary] {
        calls += 1
        throw StoreError.closed
    }
}

/// Records each read of the frequent clips, and finds none.
private actor RecordingUsage: QuickAccessUsage {
    struct Call {
        let minimumCount: Int64
        let since: Date
        let limit: Int
    }

    private(set) var calls: [Call] = []

    func frequent(minimumCount: Int64, since: Date, limit: Int) async throws -> [UsageSummary] {
        calls.append(Call(minimumCount: minimumCount, since: since, limit: limit))
        return []
    }
}

/// Answers each read of the frequent clips with the next of `replies`, or with none once they run out, and holds the
/// reads `holding` numbers, counted from 1, until the test releases each. Counts the reads that arrived, those that
/// came back, and those that came back cancelled.
private actor HeldUsage: QuickAccessUsage {
    private let holding: Set<Int>
    private var replies: [[UsageSummary]] = []
    private(set) var calls = 0
    private(set) var returned = 0
    private(set) var returnedCancelled = 0
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []

    init(holding: Set<Int>) {
        self.holding = holding
    }

    func reply(_ replies: [[UsageSummary]]) {
        self.replies = replies
    }

    func frequent(minimumCount: Int64, since: Date, limit: Int) async throws -> [UsageSummary] {
        calls += 1
        let call = calls
        let reply = replies.isEmpty ? [] : replies.removeFirst()
        if holding.contains(call), !released.contains(call) {
            await withCheckedContinuation { held[call] = $0 }
        }
        returned += 1
        if Task.isCancelled { returnedCancelled += 1 }
        return reply
    }

    func release(_ call: Int) {
        released.insert(call)
        held.removeValue(forKey: call)?.resume()
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
