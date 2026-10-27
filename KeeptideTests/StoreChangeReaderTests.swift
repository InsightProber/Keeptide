import XCTest
@testable import Keeptide

@MainActor
final class StoreChangeReaderTests: XCTestCase {
    func testReplayIdentifiesRecordsDeletedBeforeTheFirstRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let collection = CollectionValue(name: "temporary synthetic collection")
        let writer = WriteCoordinator(controller: store)
        _ = try await writer.commit(StoreTransaction(identity: try await store.identity(),
            mutations: [.insert(.collection(collection))]))
        let state = try await ContentRepository(controller: store).recordState(.collection(collection.id))
        _ = try await writer.commit(StoreTransaction(identity: try await store.identity(),
            preconditions: [.recordUnchanged(.collection(collection.id), fingerprint: state.fingerprint)],
            mutations: [.delete(.collection(collection.id))],
            permit: try await StoreSafetyGate(controller: store).permit(.maintenance)))
        let batch = try await StoreChangeReader(controller: store).read(after: nil)
        let changes = batch.transactions.flatMap(\.changes)
        XCTAssertEqual(changes.map(\.id), [collection.id.rawValue, collection.id.rawValue])
        XCTAssertEqual(changes.map(\.deleted), [false, true])
        XCTAssertEqual(Set(changes.map(\.entity)), ["Collection"])
    }

    func testLocalUsageAndFileAccessDoNotEnterContentHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try PersistenceController(directory: directory)
        addTeardownBlock { try await store.close(); try FileManager.default.removeItem(at: directory) }
        let ref = ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data([1]))
        try await LocalUsageStore(controller: store).record(UseReceipt(executionID: UUID(), ref: ref,
            occurredAt: Date(), outcome: .success))
        try await FileAccessStore(controller: store).put(LocalFileAccess(id: UUID(), snapshotID: UUID(),
            bytes: Data("synthetic-file-reference".utf8), bookmark: Data([1, 2]), localPath: "/synthetic/example"))
        let batch = try await StoreChangeReader(controller: store).read(after: nil)
        XCTAssertTrue(batch.transactions.isEmpty)
        XCTAssertNil(batch.token)
    }

    func testPersistentHistoryResumesAfterReopenAndRejectsForeignStoreAndGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: otherDirectory) }
        let store = try PersistenceController(directory: directory)
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("not in change feed".utf8))]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: store)
        let first = try await StoreChangeReader(controller: store).read(after: nil)
        XCTAssertTrue(first.transactions.flatMap(\.changes).contains { $0.id == item.id.rawValue && $0.entity == "LibraryItem" })
        let token = try XCTUnwrap(first.token)
        let empty = try await StoreChangeReader(controller: store).read(after: token)
        XCTAssertTrue(empty.transactions.isEmpty)
        try await store.close()
        let reopened = try PersistenceController(directory: directory)
        let collection = CollectionValue(name: "new")
        _ = try await WriteCoordinator(controller: reopened).commit(StoreTransaction(identity: try await reopened.identity(),
            mutations: [.insert(.collection(collection))]))
        let next = try await StoreChangeReader(controller: reopened).read(after: token)
        XCTAssertEqual(next.transactions.flatMap(\.changes).map(\.id), [collection.id.rawValue])
        XCTAssertGreaterThan(next.transactions.first!.sequence, first.transactions.last!.sequence)
        let foreign = try PersistenceController(directory: otherDirectory)
        do { _ = try await StoreChangeReader(controller: foreign).read(after: token); XCTFail("Foreign token was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        try await foreign.close()
        try await StoreSafetyGate(controller: reopened).transition(to: .active)
        do { _ = try await StoreChangeReader(controller: reopened).read(after: token); XCTFail("Old generation token was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        do { _ = try await StoreChangeReader(controller: reopened).read(after: Data([1, 2, 3])); XCTFail("Bad token was accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidToken) }
        try await reopened.close()
    }
}
