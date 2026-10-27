import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class LocalUsageTests: XCTestCase {
    func testSuccessfulUsagePersistsAcrossReopenAndKeepsLatestEventTime() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ref = makeRef()
        let firstEvent = Date(timeIntervalSince1970: 200)
        let olderEvent = Date(timeIntervalSince1970: 100)

        var controller: PersistenceController? = try PersistenceController(directory: directory)
        var store: LocalUsageStore? = LocalUsageStore(controller: try XCTUnwrap(controller))
        try await store?.record(
            UseReceipt(executionID: UUID(), ref: ref, occurredAt: firstEvent, outcome: .success),
            now: Date(timeIntervalSince1970: 1_000)
        )
        try await store?.record(
            UseReceipt(executionID: UUID(), ref: ref, occurredAt: olderEvent, outcome: .success),
            now: Date(timeIntervalSince1970: 1_001)
        )
        try await controller?.close()
        store = nil
        controller = nil

        let reopened = try PersistenceController(directory: directory)
        let summaries = try await LocalUsageStore(controller: reopened).summaries(for: [ref])

        XCTAssertEqual(summaries, [
            UsageSummary(itemID: ref.itemID, facet: ref.facet, lastUsedAt: firstEvent, useCount: 2)
        ])
        try await reopened.close()
    }

    func testConcurrentDuplicateExecutionCountsExactlyOnce() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        let store = LocalUsageStore(controller: controller)
        let ref = makeRef()
        let receipt = UseReceipt(
            executionID: UUID(),
            ref: ref,
            occurredAt: Date(timeIntervalSince1970: 250),
            outcome: .success
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await store.record(receipt, now: Date(timeIntervalSince1970: 1_000))
                }
            }
            try await group.waitForAll()
        }

        let summaries = try await store.summaries(for: [ref])
        XCTAssertEqual(summaries.first?.useCount, 1)
        try await controller.close()
    }

    func testFailureAndCancellationDoNotCreateUsageOrDedupRecords() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        let store = LocalUsageStore(controller: controller)
        let ref = makeRef()

        try await store.record(UseReceipt(ref: ref, outcome: .failure))
        try await store.record(UseReceipt(ref: ref, outcome: .cancelled))

        let summaries = try await store.summaries(for: [ref])
        XCTAssertEqual(summaries, [])
        let dedupCount = try await controller.perform { context in
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "UsageExecutionDedup"))
        }
        XCTAssertEqual(dedupCount, 0)
        try await controller.close()
    }

    func testExpiredExecutionCanCountAgain() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        let store = LocalUsageStore(controller: controller, deduplicationInterval: 10)
        let ref = makeRef()
        let receipt = UseReceipt(
            executionID: UUID(),
            ref: ref,
            occurredAt: Date(timeIntervalSince1970: 250),
            outcome: .success
        )

        try await store.record(receipt, now: Date(timeIntervalSince1970: 1_000))
        try await store.record(receipt, now: Date(timeIntervalSince1970: 1_011))

        let summaries = try await store.summaries(for: [ref])
        XCTAssertEqual(summaries.first?.useCount, 2)
        try await controller.close()
    }

    func testCapacityEvictionBoundsDedupAndAllowsEvictedExecutionToCountAgain() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        let store = LocalUsageStore(
            controller: controller,
            deduplicationLimit: 2,
            deduplicationInterval: 10_000
        )
        let ref = makeRef()
        let oldestID = UUID()

        try await store.record(makeReceipt(id: oldestID, ref: ref), now: Date(timeIntervalSince1970: 1_000))
        try await store.record(makeReceipt(ref: ref), now: Date(timeIntervalSince1970: 1_001))
        try await store.record(makeReceipt(ref: ref), now: Date(timeIntervalSince1970: 1_002))
        try await store.record(makeReceipt(id: oldestID, ref: ref), now: Date(timeIntervalSince1970: 1_003))

        let summaries = try await store.summaries(for: [ref])
        XCTAssertEqual(summaries.first?.useCount, 4)
        let dedupCount = try await controller.perform { context in
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "UsageExecutionDedup"))
        }
        XCTAssertEqual(dedupCount, 2)
        try await controller.close()
    }

    func testFileAccessRoundTripsExactlyAcrossReopenAndStaysInLocalState() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = LocalFileAccess(
            id: UUID(),
            snapshotID: UUID(),
            bytes: Data([0x00, 0x7f, 0xff]),
            bookmark: Data([0x10, 0x20, 0x30]),
            localPath: "/Synthetic Folder/$literal (copy).txt"
        )

        var controller: PersistenceController? = try PersistenceController(directory: directory)
        var store: FileAccessStore? = FileAccessStore(controller: try XCTUnwrap(controller))
        try await store?.put(value)
        let configuration = try await controller?.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.fetchLimit = 1
            return try context.fetch(request).first?.objectID.persistentStore?.configurationName
        }
        XCTAssertEqual(configuration, "LocalState")
        try await controller?.close()
        store = nil
        controller = nil

        let reopened = try PersistenceController(directory: directory)
        let reopenedValue = try await FileAccessStore(controller: reopened).read(representationID: value.id)
        XCTAssertEqual(reopenedValue, value)
        try await reopened.close()
    }

    func testFileAccessPutReplacesExistingLocalAuthorizationAndRemoveIsIdempotent() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        let store = FileAccessStore(controller: controller)
        let id = UUID()
        let initial = LocalFileAccess(
            id: id,
            snapshotID: UUID(),
            bytes: Data([1]),
            bookmark: Data([2]),
            localPath: "/Synthetic/first"
        )
        let replacement = LocalFileAccess(
            id: id,
            snapshotID: initial.snapshotID,
            bytes: Data([3, 4]),
            bookmark: nil,
            localPath: "/Synthetic/second; keep exactly"
        )

        try await store.put(initial)
        try await store.put(replacement)
        let replaced = try await store.read(representationID: id)
        XCTAssertEqual(replaced, replacement)
        try await store.remove(representationID: id)
        try await store.remove(representationID: id)
        let removed = try await store.read(representationID: id)
        XCTAssertNil(removed)
        try await controller.close()
    }

    func testFileAccessRejectsCrossSnapshotRepresentationReuseWithoutMutatingOriginal() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        let store = FileAccessStore(controller: controller)
        let representationID = UUID()
        let firstSnapshotID = UUID()
        let firstBytes = Data("first snapshot bytes".utf8)
        let firstAccess = LocalFileAccess(
            id: representationID,
            snapshotID: firstSnapshotID,
            bytes: firstBytes,
            bookmark: Data([0x01]),
            localPath: "/Synthetic/first"
        )
        try await store.put(firstAccess)

        let representation = RepresentationValue(
            id: representationID,
            snapshotID: firstSnapshotID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: Int64(firstBytes.count),
            digest: ContentDigest.sha256(firstBytes),
            bytes: nil
        )
        let manifest = CaptureManifest(itemCount: 1, entries: [ManifestEntry(representation)])
        let capture = CaptureValue(
            id: firstSnapshotID,
            manifest: manifest,
            digest: ContentDigest.sha256(try manifest.canonicalData()),
            representations: [representation]
        )
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: controller)

        let conflicting = LocalFileAccess(
            id: representationID,
            snapshotID: UUID(),
            bytes: Data("second snapshot bytes".utf8),
            bookmark: Data([0x02]),
            localPath: "/Synthetic/second"
        )
        do {
            try await store.put(conflicting)
            XCTFail("A representation ID was rebound to a different snapshot")
        } catch {
            // The identity conflict must be rejected before any existing row is changed.
        }

        let storedAfterConflict = try await store.read(representationID: representationID)
        XCTAssertEqual(storedAfterConflict, firstAccess)
        let resolved = try await ContentRepository(controller: controller).read(
            ContentStoreFixtures.ref(item, capture)
        )
        XCTAssertEqual(resolved.integrity, .complete)
        XCTAssertEqual(resolved.representations.first?.bytes, firstBytes)
        try await controller.close()
    }

    private func makeRef() -> ContentRef {
        ContentRef(
            itemID: ItemID(rawValue: UUID()),
            facet: .history,
            version: ContentVersion(rawValue: UUID()),
            digest: Data([0xaa, 0xbb])
        )
    }

    private func makeReceipt(id: UUID = UUID(), ref: ContentRef) -> UseReceipt {
        UseReceipt(
            executionID: id,
            ref: ref,
            occurredAt: Date(timeIntervalSince1970: 250),
            outcome: .success
        )
    }

    private func makeStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-LocalUsageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
