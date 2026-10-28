import Foundation
import XCTest
@testable import Keeptide

enum SearchTestSupport {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideSearch-\(UUID().uuidString)", isDirectory: true)
    }

    static func identity() -> StoreIdentity {
        StoreIdentity(storeID: UUID(), generation: UUID())
    }

    static func document(
        itemID: ItemID = ItemID(),
        facet: ContentFacet = .history,
        version: ContentVersion = ContentVersion(),
        title: String = "",
        body: String = "",
        url: String = "",
        note: String = "",
        captureID: UUID? = UUID(),
        memoID: UUID? = nil,
        merged: Bool = false,
        savedAsMemo: Bool = false,
        kind: ContentKind = .text,
        sourceApp: String? = "test.source",
        collectionID: CollectionID? = nil,
        lastCopiedAt: Date = Date(timeIntervalSince1970: 1_000),
        bodyPartial: Bool = false,
        textUnavailable: Bool = false
    ) -> SearchDocument {
        SearchDocument(
            ref: ContentRef(itemID: itemID, facet: facet, version: version, digest: Data(repeating: 7, count: 32)),
            captureID: captureID, memoID: memoID, merged: merged, savedAsMemo: savedAsMemo, kind: kind,
            sourceApp: sourceApp, collectionID: collectionID, lastCopiedAt: lastCopiedAt,
            title: title, body: body, url: url, note: note, bodyPartial: bodyPartial, textUnavailable: textUnavailable,
            normalizedTitle: SearchNormalizer.normalize(title), normalizedBody: SearchNormalizer.normalize(body),
            normalizedURL: SearchNormalizer.normalize(url), normalizedNote: SearchNormalizer.normalize(note)
        )
    }

    static func snapshot(_ text: String, count: Int) -> CaptureSnapshotValue {
        CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)),
        ])], changeCount: count, sourceApp: "test.source")
    }

    static func waitUntil(
        timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition not met within \(timeout)")
    }
}

/// A real store, index, consumer and service in one temporary directory.
struct SearchHarness {
    let directory: URL
    let controller: PersistenceController
    let index: SQLiteSearchIndex
    let status: SearchIndexStatus
    let consumer: HistoryConsumer
    let service: SearchService

    static func make(in test: XCTestCase, directory: URL? = nil, cleanUp: Bool = true) throws -> SearchHarness {
        let directory = directory ?? SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        let index = try SQLiteSearchIndex(directory: directory.appendingPathComponent("Search", isDirectory: true))
        let status = SearchIndexStatus()
        let consumer = HistoryConsumer(controller: controller, index: index, status: status, debounce: .milliseconds(20))
        let harness = SearchHarness(directory: directory, controller: controller, index: index, status: status,
                                    consumer: consumer, service: SearchService(index: index, status: status))
        if cleanUp {
            test.addTeardownBlock {
                try? await harness.close()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return harness
    }

    /// Documents a brand-new index builds from the same store, for recovery comparisons.
    static func freshDocuments(for controller: PersistenceController) async throws -> [SearchDocument] {
        let directory = SearchTestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try SQLiteSearchIndex(directory: directory)
        defer { index.close() }
        let consumer = HistoryConsumer(controller: controller, index: index, status: SearchIndexStatus())
        try await consumer.synchronize()
        await consumer.stopAndDrain()
        return try index.allDocuments()
    }

    func close() async throws {
        await consumer.stopAndDrain()
        index.close()
        try await controller.close()
    }

    func search(_ query: String, scope: SearchScope = .all, limit: Int = 200) async throws -> SearchPage {
        var last: SearchPage?
        for try await page in service.search(SearchRequest(query: query, scope: scope, generation: 1, limit: limit)) {
            last = page
        }
        return try XCTUnwrap(last)
    }

    func commit(
        _ mutations: [StoreMutation], preconditions: [StorePrecondition] = [], maintenance: Bool = false
    ) async throws {
        let permit = maintenance ? try await StoreSafetyGate(controller: controller).permit(.maintenance) : nil
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: try await controller.identity(), preconditions: preconditions, mutations: mutations, permit: permit
        ))
    }

    func update(_ key: RecordKey, to value: RecordValue) async throws {
        let state = try await ContentRepository(controller: controller).recordState(key)
        try await commit([.update(value)], preconditions: [.recordUnchanged(key, fingerprint: state.fingerprint)])
    }

    func insertItemWithOwnedMemo(text: String) async throws -> (item: ItemValue, memo: MemoValue) {
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data(text.utf8))]])
        let itemID = ItemID()
        let body = Data("memo \(text)".utf8)
        let memo = MemoValue(itemID: itemID, title: "Memo", bodyMode: .ownedPlainText, body: body,
                             version: ContentVersion(), digest: ContentDigest.sha256(body))
        let item = ItemValue(id: itemID, title: text, captureID: capture.id, memoID: memo.id,
                             historyEligible: true, copyCount: 1)
        try await commit([.insert(.capture(capture)), .insert(.memo(memo)), .insert(.item(item))])
        return (item, memo)
    }

    func insertTextItems(count: Int, prefix: String) async throws {
        for start in stride(from: 0, to: count, by: 100) {
            var mutations: [StoreMutation] = []
            for index in start..<min(start + 100, count) {
                let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("\(prefix) \(index)".utf8))]])
                mutations += [.insert(.capture(capture)), .insert(.item(ContentStoreFixtures.item(capture)))]
            }
            try await commit(mutations)
        }
    }
}
