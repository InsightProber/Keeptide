import Foundation
import XCTest
@testable import Keeptide

final class SearchServiceTests: XCTestCase {
    func testShortChineseQueryFindsSubstringInLongerWord() async throws {
        let service = try makeService([SearchTestSupport.document(body: "中文剪贴板")])

        for query in ["贴板", "剪贴", "板", "剪贴板"] {
            let page = try await lastPage(service, request(query))
            XCTAssertEqual(page.totalMatches, 1, query)
            XCTAssertTrue(page.isComplete, query)
        }
    }

    func testShortQueryScansEveryCandidateNotJustRecent() async throws {
        var documents = (0..<4_999).map { offset in
            SearchTestSupport.document(body: "filler text \(offset)",
                                       lastCopiedAt: Date(timeIntervalSince1970: Double(10_000 - offset)))
        }
        let oldest = SearchTestSupport.document(body: "历史贴板记录", lastCopiedAt: Date(timeIntervalSince1970: 1))
        documents.append(oldest)
        let service = try makeService(documents)

        let page = try await lastPage(service, request("贴板"))

        XCTAssertEqual(page.totalMatches, 1)
        XCTAssertEqual(page.results.map(\.ref), [oldest.ref])
    }

    func testLiteralInputsNeverActAsSyntax() async throws {
        let service = try makeService([SearchTestSupport.document(body: #"100% done_ok -- "quoted" NEAR(x) OR"#)])
        let expected: [(String, Int)] = [
            ("100%", 1), ("_ok", 1), ("%", 1), (#""quoted""#, 1), ("near(x)", 1), ("--", 1), ("OR", 1),
            ("*", 0), ("^x", 0), ("\"", 1), ("NEAR(y)", 0),
        ]

        for (query, count) in expected {
            let page = try await lastPage(service, request(query))
            XCTAssertEqual(page.totalMatches, count, query)
        }
    }

    func testEmojiAndZWJQueries() async throws {
        let service = try makeService([SearchTestSupport.document(body: "deploy 😀 done 👨‍👩‍👧 family")])

        let single = try await lastPage(service, request("😀"))
        let family = try await lastPage(service, request("👨‍👩‍👧"))

        XCTAssertEqual(single.totalMatches, 1)
        XCTAssertEqual(family.totalMatches, 1)
    }

    func testMultipleTermsMustAllMatchAcrossFields() async throws {
        let service = try makeService([SearchTestSupport.document(title: "Deploy", body: "kubectl apply")])

        let both = try await lastPage(service, request("deploy kubectl"))
        let missing = try await lastPage(service, request("deploy helm"))

        XCTAssertEqual(both.totalMatches, 1)
        XCTAssertEqual(both.results.first?.matchedFields, [.title, .body])
        XCTAssertEqual(missing.totalMatches, 0)
    }

    func testScopeFoldingAndMemoFacetBinding() async throws {
        let inherited = SearchDocumentBuilder.documents(for: input(body: "kubectl rollout restart", memo: .inherited))
        let owned = SearchDocumentBuilder.documents(for: input(body: "helm rollout history", memo: .owned("helm rollout edited")))
        let service = try makeService(inherited + owned)

        let all = try await lastPage(service, request("kubectl rollout"))
        let memo = try await lastPage(service, request("kubectl rollout", scope: .memo))
        let history = try await lastPage(service, request("kubectl rollout", scope: .history))
        let ownedAll = try await lastPage(service, request("helm rollout"))

        XCTAssertEqual(all.results.map(\.ref.facet), [.history])
        XCTAssertEqual(all.results.first?.savedAsMemo, true)
        XCTAssertEqual(memo.results.map(\.ref.facet), [.memo])
        XCTAssertEqual(history.results.map(\.ref.facet), [.history])
        XCTAssertEqual(Set(ownedAll.results.map(\.ref.facet)), [.history, .memo])
    }

    func testHugeTermListStillSearchesAndReportsTruncation() async throws {
        let service = try makeService([SearchTestSupport.document(body: (0..<100).map(String.init).joined(separator: " "))])

        let page = try await lastPage(service, request((0..<2_000).map(String.init).joined(separator: " ")))
        let normal = try await lastPage(service, request("42"))

        XCTAssertNotEqual(page.indexState, .unavailable)
        XCTAssertTrue(page.queryWasTruncated)
        XCTAssertTrue(page.isComplete)
        XCTAssertEqual(page.totalMatches, 1)
        XCTAssertFalse(normal.queryWasTruncated)
    }

    func testScanAndIndexedPathsRankIdenticalCandidatesIdentically() async throws {
        let documents = (0..<30).map { offset in
            SearchTestSupport.document(body: "abc row \(offset)",
                                       lastCopiedAt: Date(timeIntervalSince1970: Double(offset % 3)))
        }
        let usage = documents.enumerated().compactMap { offset, document -> UsageSummary? in
            offset % 4 == 0 ? usageSummary(document, count: Int64(offset % 8)) : nil
        }
        let service = try makeService(documents, usage: usage)

        let indexed = try await lastPage(service, request("abc"))
        let scanned = try await lastPage(service, request("ab"))

        XCTAssertEqual(indexed.totalMatches, 30)
        XCTAssertEqual(scanned.results.map(\.ref), indexed.results.map(\.ref))
    }

    func testInvisibleCharactersInQueryDoNotHideMatches() async throws {
        let service = try makeService([SearchTestSupport.document(body: "kubectl get pods")])

        let page = try await lastPage(service, request("\u{200B}kubectl"))

        XCTAssertEqual(page.totalMatches, 1)
    }

    func testUnavailableStatusNeverServesStaleIndexContent() async throws {
        let directory = SearchTestSupport.directory()
        let (service, _, status) = try makeService([SearchTestSupport.document(body: "deleted clip body")], in: directory)
        status.update(.unavailable)

        let page = try await lastPage(service, request("deleted"))

        XCTAssertEqual(page.results, [])
        XCTAssertEqual(page.totalMatches, 0)
        XCTAssertTrue(page.isComplete)
        XCTAssertEqual(page.indexState, .unavailable)
    }

    func testSameTextInDifferentItemsIsNotFolded() async throws {
        let first = SearchTestSupport.document(body: "echo hello")
        let second = SearchTestSupport.document(body: "echo hello")
        let service = try makeService([first, second])

        let page = try await lastPage(service, request("echo hello"))

        XCTAssertEqual(page.totalMatches, 2)
        XCTAssertEqual(Set(page.results.map(\.ref.itemID)), [first.ref.itemID, second.ref.itemID])
    }

    func testCollectionFilterReturnsOnlyMemoDocuments() async throws {
        let collection = CollectionID()
        let historyOnly = SearchTestSupport.document(body: "shared word")
        let filed = SearchTestSupport.document(facet: .memo, body: "shared word", memoID: UUID(), collectionID: collection)
        let unfiled = SearchTestSupport.document(facet: .memo, body: "shared word", memoID: UUID())
        let service = try makeService([historyOnly, filed, unfiled])

        let inCollection = try await lastPage(service, request("shared", collection: .collection(collection)))
        let uncategorized = try await lastPage(service, request("shared", collection: .uncategorized))
        let browseUncategorized = try await lastPage(service, request("", collection: .uncategorized))

        XCTAssertEqual(inCollection.results.map(\.ref), [filed.ref])
        XCTAssertEqual(uncategorized.results.map(\.ref), [unfiled.ref])
        XCTAssertEqual(browseUncategorized.results.map(\.ref), [unfiled.ref])
    }

    func testKindAndSourceFilters() async throws {
        let text = SearchTestSupport.document(body: "release notes", kind: .text, sourceApp: "com.apple.Notes")
        let link = SearchTestSupport.document(body: "release page", kind: .url, sourceApp: "com.apple.Safari")
        let image = SearchTestSupport.document(title: "release screenshot", kind: .image, sourceApp: "com.apple.Terminal")
        let service = try makeService([text, link, image])

        let urls = try await lastPage(service, request("release", kinds: [.url]))
        let terminal = try await lastPage(service, request("release", sourceApp: "com.apple.Terminal"))

        XCTAssertEqual(urls.results.map(\.ref), [link.ref])
        XCTAssertEqual(terminal.results.map(\.ref), [image.ref])
    }

    func testRelevanceTiersOrderResults() async throws {
        let documents = [
            SearchTestSupport.document(title: "Network", body: "port then lsof"),
            SearchTestSupport.document(title: "Network", body: "use lsof port 8080"),
            SearchTestSupport.document(title: "port: lsof"),
            SearchTestSupport.document(title: "lsof port usage"),
            SearchTestSupport.document(title: "lsof port"),
        ]
        let service = try makeService(documents)

        let page = try await lastPage(service, request("lsof port"))

        XCTAssertEqual(page.results.map(\.relevance),
                       [.exactMatch, .titlePrefix, .titleContainsAll, .contiguousPhrase, .allTermsAnywhere])
        XCTAssertEqual(page.results.map(\.ref), documents.reversed().map(\.ref))
    }

    func testUsageOrdersWithinTierButNeverAcrossTiers() async throws {
        let rarelyUsed = SearchTestSupport.document(body: "deploy script x")
        let oftenUsed = SearchTestSupport.document(body: "deploy script y")
        let heavilyUsedWeak = SearchTestSupport.document(body: "redeploy later")
        let exactUnused = SearchTestSupport.document(title: "deploy")
        let usage = [
            usageSummary(rarelyUsed, count: 1),
            usageSummary(oftenUsed, count: 5),
            usageSummary(heavilyUsedWeak, count: 100),
        ]
        let service = try makeService([rarelyUsed, oftenUsed, heavilyUsedWeak, exactUnused], usage: usage)

        let page = try await lastPage(service, request("deploy"))

        XCTAssertEqual(page.results.map(\.ref), [exactUnused.ref, heavilyUsedWeak.ref, oftenUsed.ref, rarelyUsed.ref])
    }

    func testPagingWindowsConcatenateToFullRanking() async throws {
        let service = try makeService((0..<25).map { SearchTestSupport.document(body: "page item \($0)") })

        let full = try await lastPage(service, request("page", limit: 1_000))
        var windows: [ContentRef] = []
        for offset in stride(from: 0, to: 30, by: 10) {
            let page = try await lastPage(service, request("page", offset: offset, limit: 10))
            XCTAssertEqual(page.totalMatches, 25)
            windows += page.results.map(\.ref)
        }

        XCTAssertEqual(full.results.count, 25)
        XCTAssertEqual(windows, full.results.map(\.ref))
        for invalid in [request("page", limit: 0), request("page", limit: 1_001), request("page", offset: -1)] {
            do {
                _ = try await lastPage(service, invalid)
                XCTFail("Invalid paging was accepted")
            } catch {
                XCTAssertEqual(error as? SearchError, .invalidRequest)
            }
        }
    }

    func testSnippetComesFromOriginalTextAroundMatch() async throws {
        let body = String(repeating: "filler ", count: 800) + "The Quick Brown FOX jumps over"
        let service = try makeService([SearchTestSupport.document(body: body)])

        let page = try await lastPage(service, request("brown fox"))
        let snippet = try XCTUnwrap(page.results.first?.snippet)
        let text = snippet.text as NSString

        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertTrue(snippet.text.contains("Brown FOX"))
        XCTAssertEqual(snippet.highlights.map { text.substring(with: NSRange($0)) }, ["Brown", "FOX"])
    }

    func testTitleOnlyMatchFallsBackToBodyStart() async throws {
        let service = try makeService([SearchTestSupport.document(title: "Release checklist", body: "\nline one\nline two")])

        let result = try await lastPage(service, request("checklist")).results.first

        XCTAssertEqual(result?.snippet?.text, "line one")
        XCTAssertEqual(result?.snippet?.highlights, [])
        XCTAssertEqual(result?.matchedFields, [.title])
    }

    func testPartiallyIndexedResultIsFlagged() async throws {
        let service = try makeService([SearchTestSupport.document(body: "partial body", bodyPartial: true)])

        let result = try await lastPage(service, request("partial")).results.first

        XCTAssertEqual(result?.isPartiallyIndexed, true)
    }

    func testCancellationStopsShortScanAndNextSearchSucceeds() async throws {
        let progress = ScanProgress()
        let service = try makeService((0..<30_000).map { SearchTestSupport.document(body: "row \($0) 贴板") },
                                      chunk: 100, onScanProgress: { _ in progress.record() })
        let query = request("贴板")
        let consumer = Task { () -> [SearchPage] in
            var pages: [SearchPage] = []
            for try await page in service.search(query) {
                pages.append(page)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return pages
        }

        let received = try await consumer.value
        try await SearchTestSupport.waitUntil { progress.isIdle(for: .milliseconds(200)) }
        let scannedRanges = progress.count
        let fresh = try await lastPage(service, query)

        XCTAssertEqual(received.count, 1)
        XCTAssertLessThan(scannedRanges, 300, "30,000 rows in ranges of 100 must stop well before the end")
        XCTAssertEqual(fresh.totalMatches, 30_000)
        XCTAssertTrue(fresh.isComplete)
    }

    func testShortScanEmitsIncrementalPagesBeforeCompletion() async throws {
        let service = try makeService((0..<1_000).map { SearchTestSupport.document(body: "chunk \($0) 贴板") },
                                      chunk: 100)

        var pages: [SearchPage] = []
        for try await page in service.search(request("贴板")) { pages.append(page) }

        XCTAssertEqual(pages.first?.isComplete, false)
        XCTAssertEqual(pages.last?.isComplete, true)
        XCTAssertEqual(pages.last?.totalMatches, 1_000)
    }

    func testWhitespaceOnlyQueryBrowsesWithFilters() async throws {
        let older = SearchTestSupport.document(facet: .memo, title: "older", memoID: UUID(),
                                               lastCopiedAt: Date(timeIntervalSince1970: 10))
        let newer = SearchTestSupport.document(facet: .memo, title: "newer", memoID: UUID(),
                                               lastCopiedAt: Date(timeIntervalSince1970: 20))
        let history = SearchTestSupport.document(title: "history", lastCopiedAt: Date(timeIntervalSince1970: 30))
        let service = try makeService([older, newer, history])

        let page = try await lastPage(service, request("  \u{3000}\n", scope: .memo))
        let invisible = try await lastPage(service, request("\u{200B}\u{FEFF}", scope: .memo))

        XCTAssertEqual(page.results.map(\.ref), [newer.ref, older.ref])
        XCTAssertTrue(page.isComplete)
        XCTAssertEqual(page.totalMatches, 2)
        XCTAssertEqual(invisible.results.map(\.ref), [newer.ref, older.ref])
    }

    func testIndexStateAndGenerationAreReportedOnEveryPage() async throws {
        let directory = SearchTestSupport.directory()
        let (service, index, status) = try makeService([SearchTestSupport.document(body: "state body")], in: directory)
        status.update(.rebuilding)

        let rebuilding = try await lastPage(service, request("state", generation: 42))
        index.close()
        try FileManager.default.removeItem(at: directory)
        let missing = try await lastPage(service, request("state", generation: 43))
        let absent = try await lastPage(SearchService(index: nil, status: SearchIndexStatus(.ready)), request("state"))

        XCTAssertEqual(rebuilding.indexState, .rebuilding)
        XCTAssertEqual(rebuilding.generation, 42)
        XCTAssertEqual(rebuilding.totalMatches, 1)
        XCTAssertEqual(missing.indexState, .unavailable)
        XCTAssertEqual(missing.generation, 43)
        XCTAssertEqual(missing.results, [])
        XCTAssertTrue(missing.isComplete)
        XCTAssertEqual(absent.indexState, .unavailable)
    }

    // MARK: - Helpers

    private enum MemoKind {
        case inherited
        case owned(String)
    }

    private func input(body: String, memo: MemoKind) -> SearchProjectionInput {
        let itemID = ItemID()
        let captureID = UUID()
        let bytes = Data(body.utf8)
        let memoProjection: MemoProjection
        switch memo {
        case .inherited:
            memoProjection = MemoProjection(
                ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(rawValue: captureID),
                                digest: Data(repeating: 1, count: 32)),
                memoID: UUID(), title: "Saved", note: "", isInherited: true, body: nil
            )
        case .owned(let text):
            memoProjection = MemoProjection(
                ref: ContentRef(itemID: itemID, facet: .memo, version: ContentVersion(),
                                digest: Data(repeating: 2, count: 32)),
                memoID: UUID(), title: "Edited", note: "", isInherited: false, body: Data(text.utf8)
            )
        }
        return SearchProjectionInput(
            itemID: itemID, title: "Captured", sourceApp: "test.source", collectionID: nil,
            lastCopiedAt: Date(timeIntervalSince1970: 100),
            history: ContentRef(itemID: itemID, facet: .history, version: ContentVersion(rawValue: captureID),
                                digest: Data(repeating: 1, count: 32)),
            memo: memoProjection, captureID: captureID, representationTypes: ["public.utf8-plain-text"],
            hasLocalReference: false,
            textRepresentations: [TextRepresentation(
                itemIndex: 0, representationIndex: 0, typeIdentifier: "public.utf8-plain-text",
                byteCount: Int64(bytes.count), digest: ContentDigest.sha256(bytes), bytes: bytes
            )]
        )
    }

    private func usageSummary(_ document: SearchDocument, count: Int64) -> UsageSummary {
        UsageSummary(itemID: document.ref.itemID, facet: document.ref.facet,
                     lastUsedAt: Date(timeIntervalSince1970: 50), useCount: count)
    }

    private func request(
        _ query: String, scope: SearchScope = .all, kinds: Set<ContentKind> = [],
        collection: CollectionFilter? = nil, sourceApp: String? = nil, generation: UInt64 = 1,
        offset: Int = 0, limit: Int = 200
    ) -> SearchRequest {
        SearchRequest(query: query, scope: scope, kinds: kinds, collection: collection, sourceApp: sourceApp,
                      generation: generation, offset: offset, limit: limit)
    }

    private func makeService(
        _ documents: [SearchDocument], usage: [UsageSummary] = [], chunk: Int = 8_192,
        onScanProgress: (@Sendable (Int64) -> Void)? = nil
    ) throws -> SearchService {
        try makeService(documents, usage: usage, chunk: chunk, onScanProgress: onScanProgress,
                        in: SearchTestSupport.directory()).0
    }

    private func makeService(
        _ documents: [SearchDocument], usage: [UsageSummary] = [], chunk: Int = 8_192,
        onScanProgress: (@Sendable (Int64) -> Void)? = nil, in directory: URL
    ) throws -> (SearchService, SQLiteSearchIndex, SearchIndexStatus) {
        let index = try SQLiteSearchIndex(directory: directory)
        addTeardownBlock {
            index.close()
            try? FileManager.default.removeItem(at: directory)
        }
        try index.reset(identity: SearchTestSupport.identity())
        let changes = Dictionary(grouping: documents, by: \.ref.itemID.rawValue).map { itemID, documents in
            IndexedItemChange(itemID: ItemID(rawValue: itemID), documents: documents)
        }
        try index.apply(changes, sequence: 1, checkpoint: .keep)
        try index.finishBuild(checkpoint: nil)
        try index.replaceUsage(usage)
        let status = SearchIndexStatus(.ready)
        return (SearchService(index: index, status: status, scanChunkSize: chunk, onScanProgress: onScanProgress),
                index, status)
    }

    private func lastPage(_ service: SearchService, _ request: SearchRequest) async throws -> SearchPage {
        var last: SearchPage?
        for try await page in service.search(request) { last = page }
        return try XCTUnwrap(last)
    }
}

/// Counts scanned ranges and when the last one finished.
private final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges = 0
    private var last = ContinuousClock.now

    var count: Int { lock.withLock { ranges } }

    func record() {
        lock.withLock {
            ranges += 1
            last = ContinuousClock.now
        }
    }

    func isIdle(for duration: Duration) -> Bool {
        lock.withLock { ContinuousClock.now - last >= duration }
    }
}
