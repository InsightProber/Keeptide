import Foundation
import XCTest
@testable import Keeptide

/// Compares ranked search with a brute-force reading of every indexed document.
/// Set TEST_RUNNER_KEEPTIDE_SEARCH_ORACLE_COUNT to change the library size.
final class SearchOracleTests: XCTestCase {
    private static let queries = [
        "剪", "板", "史", "令", "贴板", "历史", "命令", "端口", "剪贴板", "提示词", "并发问题", "配置日志",
        "g", "ku", "de", "kubectl", "status", "lsof", "KUBECTL", "ｋｕｂｅｃｔｌ", "example.com", "-i :",
        ":8", "/", "git status", "部署 端口", "kubectl 日志", "edited", "screenshot", "lsof review",
        "zzzz", "不存在的词", "prompt 中文", "release cache", "server 恢复", "a", "o 史",
    ]

    func testRankedResultsMatchBruteForceOracle() async throws {
        let count = SearchFixtureLibrary.count(environment: "KEEPTIDE_SEARCH_ORACLE_COUNT", default: 2_000)
        let harness = try SearchHarness.make(in: self)
        let manifest = try await SearchFixtureLibrary.populate(harness, count: count, seed: 20_261_027)
        try await harness.consumer.synchronize()
        let documents = try harness.index.allDocuments()

        XCTAssertEqual(Set(documents.map { SearchFixtureLibrary.key($0.ref) }), manifest.visible)
        for scope in [SearchScope.all, .history, .memo] {
            for query in Self.queries {
                let ranked = try await allResults(harness, query, scope: scope)
                let expected = oracle(documents, query: query, scope: scope)
                XCTAssertEqual(Set(ranked.results.map { SearchFixtureLibrary.key($0.ref) }), expected,
                               "\(scope) \(query)")
                XCTAssertEqual(ranked.total, expected.count, "\(scope) \(query)")
                XCTAssertEqual(ranked.results.map(\.relevance), ranked.results.map(\.relevance).sorted(),
                               "\(scope) \(query)")
            }
        }
    }

    private func allResults(
        _ harness: SearchHarness, _ query: String, scope: SearchScope
    ) async throws -> (results: [SearchResult], total: Int) {
        var results: [SearchResult] = []
        var total = 0
        repeat {
            var last: SearchPage?
            let request = SearchRequest(query: query, scope: scope, generation: 1, offset: results.count, limit: 1_000)
            for try await page in harness.service.search(request) { last = page }
            let page = try XCTUnwrap(last)
            XCTAssertTrue(page.isComplete)
            total = page.totalMatches
            results += page.results
            if page.results.isEmpty { break }
        } while results.count < total
        return (results, total)
    }

    private func oracle(_ documents: [SearchDocument], query: String, scope: SearchScope) -> Set<String> {
        let terms = ParsedQuery(query).terms
        return Set(documents.filter { document in
            switch scope {
            case .all: if document.merged { return false }
            case .history: if document.ref.facet != .history { return false }
            case .memo: if document.ref.facet != .memo { return false }
            }
            let fields = [document.normalizedTitle, document.normalizedBody, document.normalizedURL, document.normalizedNote]
            return terms.allSatisfy { term in fields.contains { $0.contains(term) } }
        }.map { SearchFixtureLibrary.key($0.ref) })
    }
}
