import CoreData
import Foundation
import SQLite3
import XCTest
@testable import Keeptide

/// Service-level search measurement used by `scripts/benchmark.sh` in Release.
/// This does not measure quick-access presentation or UI first-frame latency.
/// Results print as one `KEEPTIDE_SEARCH_BENCHMARK` JSON line.
final class SearchPerformanceTests: XCTestCase {
    private static let seed: UInt64 = 7
    private static let runsPerCategory = 20
    private static let firstBatchGateMilliseconds = 150.0
    private static let categories: [(name: String, queries: [String])] = [
        ("cjk3", ["剪贴板", "提示词", "并发问题"]),
        ("ascii3", ["kubectl", "status", "lsof"]),
        ("short", ["史", "贴板", "端口"]),
        ("miss", ["zzzz", "不存在的词", "qqqq"]),
    ]

    func testMeasureBuildAndQueryLatency() async throws {
        let environment = ProcessInfo.processInfo.environment
        let requestedItems = SearchFixtureLibrary.count(
            environment: "KEEPTIDE_SEARCH_BENCHMARK_COUNT", default: 2_000
        )
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        if let requestedConfiguration = environment["KEEPTIDE_BENCHMARK_CONFIGURATION"] {
            XCTAssertEqual(configuration, requestedConfiguration,
                           "Recorded benchmark configuration must match the compiled test configuration")
        }
        let harness = try SearchHarness.make(in: self)
        _ = try await SearchFixtureLibrary.populate(harness, count: requestedItems, seed: Self.seed)
        let initialItems = try await storedItemCount(harness)
        XCTAssertEqual(initialItems, requestedItems, "The measured store must contain the requested fixture")
        let clock = ContinuousClock()

        let consumer = harness.consumer
        let buildStart = clock.now
        let rebuild = Task { try await consumer.synchronize() }
        var commits: [Duration] = []
        let capture = CaptureService(controller: harness.controller)
        while harness.status.state != .ready, clock.now - buildStart < .seconds(900) {
            let started = clock.now
            _ = try await capture.capture(SearchTestSupport.snapshot("during rebuild \(commits.count)", count: commits.count + 1))
            commits.append(clock.now - started)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await rebuild.value
        let buildTime = clock.now - buildStart
        try await harness.consumer.synchronize()
        XCTAssertFalse(commits.isEmpty, "The rebuild benchmark must observe at least one successful commit latency")

        let finalItems = try await storedItemCount(harness)
        XCTAssertEqual(
            finalItems, initialItems + commits.count,
            "The measured final store count must include every successful rebuild commit"
        )
        var report: [String: Any] = [
            "schema_version": 1,
            "requested_items": requestedItems,
            "initial_items": initialItems,
            "final_items": finalItems,
            "seed": Self.seed,
            "query_runs_per_category": Self.runsPerCategory,
            "sqlite": String(cString: sqlite3_libversion()),
            "configuration": configuration,
            "commit_sha": environment["KEEPTIDE_BENCHMARK_COMMIT_SHA"] ?? "unrecorded",
            "machine": environment["KEEPTIDE_BENCHMARK_MACHINE"] ?? "unrecorded",
            "toolchain": environment["KEEPTIDE_BENCHMARK_TOOLCHAIN"] ?? "unrecorded",
            "rebuild_ms": milliseconds(buildTime),
            "index_bytes": try indexBytes(harness),
            "commits_during_rebuild": commits.count,
            "commit_latency_samples": commits.count,
            "commit_p95_ms": try percentile(commits, 0.95),
            "first_batch_gate_ms": Self.firstBatchGateMilliseconds,
            "gate_scope": "SearchService first batch only; not UI presentation latency",
        ]
        for category in Self.categories {
            var firstBatch: [Duration] = []
            var complete: [Duration] = []
            var matches = 0
            for run in 0..<Self.runsPerCategory {
                let query = category.queries[run % category.queries.count]
                let started = clock.now
                var first: Duration?
                var last: SearchPage?
                for try await page in harness.service.search(SearchRequest(query: query, generation: UInt64(run))) {
                    if first == nil { first = clock.now - started }
                    last = page
                }
                complete.append(clock.now - started)
                firstBatch.append(try XCTUnwrap(first))
                matches = max(matches, try XCTUnwrap(last).totalMatches)
            }
            let firstP95 = try percentile(firstBatch, 0.95)
            report["\(category.name)_first_p50_ms"] = try percentile(firstBatch, 0.5)
            report["\(category.name)_first_p95_ms"] = firstP95
            report["\(category.name)_full_p50_ms"] = try percentile(complete, 0.5)
            report["\(category.name)_full_p95_ms"] = try percentile(complete, 0.95)
            report["\(category.name)_max_matches"] = matches
            if category.name != "miss" { XCTAssertGreaterThan(matches, 0, category.name) }
            if configuration == "Release", environment["KEEPTIDE_BENCHMARK_CONFIGURATION"] != nil {
                XCTAssertLessThanOrEqual(
                    firstP95, Self.firstBatchGateMilliseconds,
                    "\(category.name) SearchService first batch p95; this gate does not measure UI latency"
                )
            }
        }
        report["short_sql_scan_p95_ms"] = try sqlScanP95(harness, queries: Self.categories[2].queries)

        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("KEEPTIDE_SEARCH_BENCHMARK " + String(decoding: json, as: UTF8.self))
    }

    /// The short-term scan without Swift ranking or display work.
    private func sqlScanP95(_ harness: SearchHarness, queries: [String]) throws -> Double {
        let reader = try harness.index.openReader()
        defer { reader.close() }
        var durations: [Duration] = []
        let clock = ContinuousClock()
        for run in 0..<20 {
            let started = clock.now
            _ = try reader.rows("""
                SELECT count(*) FROM doc d WHERE d.merged = 0 AND (instr(d.n_title, ?1) > 0 OR instr(d.n_body, ?1) > 0
                    OR instr(d.n_url, ?1) > 0 OR instr(d.n_note, ?1) > 0)
                """, [.text(SearchNormalizer.normalize(queries[run % queries.count]))])
            durations.append(clock.now - started)
        }
        return try percentile(durations, 0.95)
    }

    private func storedItemCount(_ harness: SearchHarness) async throws -> Int {
        try await harness.controller.perform { context in
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "LibraryItem"))
        }
    }

    private func indexBytes(_ harness: SearchHarness) throws -> Int {
        let directory = harness.directory.appendingPathComponent("Search", isDirectory: true)
        return try ["", "-wal"].reduce(0) { total, suffix in
            let url = directory.appendingPathComponent(SQLiteSearchIndex.fileName + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { return total }
            return total + (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15).rounded(toPlaces: 2)
    }

    private func percentile(_ durations: [Duration], _ fraction: Double) throws -> Double {
        guard !durations.isEmpty else { throw BenchmarkSampleError.emptyPercentile }
        let sorted = durations.sorted()
        return milliseconds(sorted[Int((Double(sorted.count - 1) * fraction).rounded())])
    }
}

private enum BenchmarkSampleError: Error {
    case emptyPercentile
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
