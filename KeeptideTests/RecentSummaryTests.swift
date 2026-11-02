import XCTest
@testable import Keeptide

final class RecentSummaryTests: XCTestCase {
    private struct Fixture {
        let title: String
        let sourceApp: String
        let kind: ContentKind
    }

    private let fixtures = [
        Fixture(title: "Synthetic text", sourceApp: "test.text", kind: .text),
        Fixture(title: "Synthetic link", sourceApp: "test.link", kind: .url),
        Fixture(title: "Synthetic image", sourceApp: "test.image", kind: .image),
        Fixture(title: "Synthetic file", sourceApp: "test.file", kind: .file),
    ]

    func testRecentSummariesCarryKindAndSourceApp() async throws {
        let harness = try SearchHarness.make(in: self)
        try await insertFixtures(into: harness.controller)

        let summaries = try await ContentRepository(controller: harness.controller).recent(limit: 10)

        assertFixtures(summaries)
    }

    func testRecentSummaryFieldsSurviveReopen() async throws {
        let harness = try SearchHarness.make(in: self)
        try await insertFixtures(into: harness.controller)
        try await harness.close()

        let reopened = try PersistenceController(directory: harness.directory)
        let summaries = try await ContentRepository(controller: reopened).recent(limit: 10)
        try await reopened.close()

        assertFixtures(summaries)
    }

    func testRecentKindMatchesSearchProjectionKind() async throws {
        let harness = try SearchHarness.make(in: self)
        try await insertFixtures(into: harness.controller)
        try await harness.consumer.synchronize()

        var last: SearchPage?
        for try await page in harness.service.search(SearchRequest(query: "", generation: 1)) { last = page }
        let indexed = Dictionary(uniqueKeysWithValues: try XCTUnwrap(last).results.map { ($0.ref.itemID, $0.kind) })
        let summaries = try await ContentRepository(controller: harness.controller).recent(limit: 10)

        XCTAssertEqual(summaries.count, fixtures.count)
        for summary in summaries {
            XCTAssertEqual(indexed[summary.itemID], summary.kind, summary.title)
        }
    }

    func testSummariesForItemIDsFollowTheAskedOrderAndLeaveOutWhatCannotShow() async throws {
        let harness = try SearchHarness.make(in: self)
        // A comes before C when the store is read in the order written, by recency or by id, so only the asked order
        // can put C first.
        let a = try await insertTextClip("Synthetic A", number: 1, lastCopiedAt: 4_000, into: harness.controller)
        var b = try await insertTextClip("Synthetic B", number: 2, lastCopiedAt: 3_000, into: harness.controller)
        let c = try await insertTextClip("Synthetic C", number: 3, lastCopiedAt: 2_000, into: harness.controller)
        var d = try await insertTextClip("Synthetic D", number: 4, lastCopiedAt: 1_000, into: harness.controller)
        b.deletedAt = Date()
        try await harness.update(.item(b.id), to: .item(b))
        d.historyDeletedAt = Date()
        try await harness.update(.item(d.id), to: .item(d))
        let repository = ContentRepository(controller: harness.controller)

        let summaries = try await repository.summaries(for: [c.id, b.id, a.id, d.id, ItemID(), c.id])
        let none = try await repository.summaries(for: [])

        XCTAssertEqual(summaries.map(\.itemID), [c.id, a.id])
        XCTAssertEqual(summaries.compactMap(\.history).map(\.itemID), [c.id, a.id])
        XCTAssertEqual(summaries.map(\.kind), [.text, .text])
        XCTAssertEqual(none, [])
    }

    func testSummariesForItemIDsSpanEveryBatchInTheAskedOrder() async throws {
        let harness = try SearchHarness.make(in: self)
        try await harness.insertTextItems(count: 450, prefix: "Synthetic")
        let repository = ContentRepository(controller: harness.controller)
        let recent = try await repository.recent(limit: 1_000)
        XCTAssertEqual(recent.count, 450)

        let summaries = try await repository.summaries(for: recent.reversed().map(\.itemID))

        XCTAssertEqual(summaries, Array(recent.reversed()))
    }

    func testSummariesForItemIDsStillShowAnItemWhoseHistoryIsGoneButWhoseMemoRemains() async throws {
        let harness = try SearchHarness.make(in: self)
        var item = try await harness.insertItemWithOwnedMemo(text: "Synthetic memo").item
        item.historyDeletedAt = Date()
        try await harness.update(.item(item.id), to: .item(item))

        let summaries = try await ContentRepository(controller: harness.controller).summaries(for: [item.id])

        XCTAssertEqual(summaries.map(\.itemID), [item.id])
        XCTAssertNil(summaries.first?.history)
        XCTAssertNotNil(summaries.first?.memo)
    }

    func testSummariesForItemIDsReadTheSameAfterReopen() async throws {
        let harness = try SearchHarness.make(in: self)
        try await insertFixtures(into: harness.controller)
        let recent = try await ContentRepository(controller: harness.controller).recent(limit: 10)
        try await harness.close()

        let reopened = try PersistenceController(directory: harness.directory)
        let summaries = try await ContentRepository(controller: reopened)
            .summaries(for: recent.reversed().map(\.itemID))
        try await reopened.close()

        XCTAssertEqual(summaries, Array(recent.reversed()))
        assertFixtures(summaries)
    }

    private func insertTextClip(
        _ text: String, number: Int, lastCopiedAt: TimeInterval, into controller: PersistenceController
    ) async throws -> ItemValue {
        let itemID = ItemID(rawValue: try XCTUnwrap(
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))
        ))
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let item = ItemValue(id: itemID, title: text, captureID: capture.id, historyEligible: true,
                             lastCopiedAt: Date(timeIntervalSince1970: lastCopiedAt), copyCount: 1)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return item
    }

    private func insertFixtures(into controller: PersistenceController) async throws {
        let link = Data("https://example.com/synthetic".utf8)
        for (offset, fixture) in fixtures.enumerated() {
            let capture = switch fixture.kind {
            case .text: try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("Synthetic text body".utf8))]])
            case .url: try ContentStoreFixtures.capture([[("public.url", link), ("public.utf8-plain-text", link)]])
            case .image: try ContentStoreFixtures.capture([[("public.png", Data([0x89, 0x50, 0x4E, 0x47]))]])
            case .file, .other: try ContentStoreFixtures.localReferenceCapture()
            }
            let item = ItemValue(sourceApp: fixture.sourceApp, title: fixture.title, captureID: capture.id,
                                 historyEligible: true, lastCopiedAt: Date(timeIntervalSince1970: 2_000 + Double(offset)),
                                 copyCount: 1)
            if fixture.kind == .file {
                try await ContentStoreFixtures.insertLocalReference(item, capture, into: controller)
            } else {
                try await ContentStoreFixtures.insert(item, capture, into: controller)
            }
        }
    }

    private func assertFixtures(_ summaries: [ItemSummary], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(summaries.count, fixtures.count, file: file, line: line)
        let byTitle = Dictionary(uniqueKeysWithValues: summaries.map { ($0.title, $0) })
        for fixture in fixtures {
            XCTAssertEqual(byTitle[fixture.title]?.kind, fixture.kind, fixture.title, file: file, line: line)
            XCTAssertEqual(byTitle[fixture.title]?.sourceApp, fixture.sourceApp, fixture.title, file: file, line: line)
        }
    }
}
