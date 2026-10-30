import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class LocalUsageTests: XCTestCase {
    func testSuccessfulUsagePersistsAcrossReopenAndKeepsLatestEventTime() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let ref = makeRef()
        let firstEvent = Date(timeIntervalSince1970: 200)
        let olderEvent = Date(timeIntervalSince1970: 100)

        var controller: PersistenceController? = try PersistenceController(directory: directory)
        let initialController = try XCTUnwrap(controller)
        addTeardownBlock { try await initialController.close() }
        var store: LocalUsageStore? = LocalUsageStore(controller: initialController)
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
        addTeardownBlock { try await reopened.close() }
        let summaries = try await LocalUsageStore(controller: reopened).summaries(for: [ref])

        XCTAssertEqual(summaries, [
            UsageSummary(itemID: ref.itemID, facet: ref.facet, lastUsedAt: firstEvent, useCount: 2)
        ])
        try await reopened.close()
    }

    func testAllSummariesReturnsEveryPersistedSummary() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        let once = makeRef()
        let twice = makeRef()
        for ref in [once, twice, twice] {
            try await store.record(
                UseReceipt(executionID: UUID(), ref: ref, occurredAt: Date(timeIntervalSince1970: 100), outcome: .success),
                now: Date(timeIntervalSince1970: 1_000)
            )
        }

        let summaries = try await store.allSummaries().sorted { $0.useCount < $1.useCount }

        XCTAssertEqual(summaries.map(\.itemID), [once.itemID, twice.itemID])
        XCTAssertEqual(summaries.map(\.useCount), [1, 2])
    }

    func testFrequentListsClipsUsedAtLeastTwiceMostUsedFirst() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        let a = makeRef()
        let b = makeRef()
        let c = makeRef()
        // `b` was used more recently than `a`, so only the count can put `a` first.
        try await use(a, times: 3, lastAt: 300, in: store)
        try await use(b, times: 2, lastAt: 400, in: store)
        try await use(c, times: 1, lastAt: 500, in: store)

        let frequent = try await store.frequent(minimumCount: 2, since: Date(timeIntervalSince1970: 0), limit: 20)

        XCTAssertEqual(frequent.map(\.itemID), [a.itemID, b.itemID])
        XCTAssertEqual(frequent.map(\.useCount), [3, 2])
    }

    func testFrequentBreaksTiesByLastUseThenByItem() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        let id1 = ItemID(rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let id2 = ItemID(rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        let id3 = ItemID(rawValue: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003")))
        // Written highest id first, so a missing item tie-break would hand the tied pair back in the order written.
        try await use(makeRef(itemID: id3), times: 2, lastAt: 500, in: store)
        try await use(makeRef(itemID: id2), times: 2, lastAt: 400, in: store)
        try await use(makeRef(itemID: id1), times: 2, lastAt: 400, in: store)

        let frequent = try await store.frequent(minimumCount: 2, since: .distantPast, limit: 20)

        XCTAssertEqual(frequent.map(\.itemID), [id3, id1, id2])
    }

    func testFrequentKeepsOnlyClipsUsedSinceTheWindowStart() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        let a = makeRef()
        let b = makeRef()
        try await use(a, times: 2, lastAt: 1_000, in: store)
        try await use(b, times: 2, lastAt: 999, in: store)

        let frequent = try await store.frequent(minimumCount: 2, since: Date(timeIntervalSince1970: 1_000), limit: 20)

        XCTAssertEqual(frequent.map(\.itemID), [a.itemID])
    }

    func testFrequentStopsAtTheLimitAndRejectsBadArguments() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        for _ in 0..<5 { try await use(makeRef(), times: 2, lastAt: 300, in: store) }

        let three = try await store.frequent(minimumCount: 2, since: .distantPast, limit: 3)
        let none = try await store.frequent(minimumCount: 2, since: .distantPast, limit: 0)
        let most = try await store.frequent(minimumCount: 2, since: .distantPast, limit: 1_000)

        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(none, [])
        XCTAssertEqual(most.count, 5)
        for (limit, since) in [
            (-1, Date.distantPast),
            (1_001, .distantPast),
            (3, Date(timeIntervalSinceReferenceDate: .infinity)),
            (3, Date(timeIntervalSinceReferenceDate: -.infinity)),
            (3, Date(timeIntervalSinceReferenceDate: .nan)),
        ] {
            do {
                _ = try await store.frequent(minimumCount: 2, since: since, limit: limit)
                XCTFail("Accepted limit \(limit) with since \(since)")
            } catch {
                XCTAssertEqual(error as? StoreError, .invalidTransaction)
            }
        }
    }

    func testFrequentKeepsTheMostUsedWhenItStopsAtTheLimit() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        let refs = (0..<4).map { _ in makeRef() }
        // Written least used first, so a limit taken before the ranking would keep the least used.
        for (ref, times) in zip(refs, [2, 3, 4, 5]) { try await use(ref, times: times, lastAt: 300, in: store) }

        let frequent = try await store.frequent(minimumCount: 2, since: .distantPast, limit: 2)

        XCTAssertEqual(frequent.map(\.useCount), [5, 4])
        XCTAssertEqual(frequent.map(\.itemID), [refs[3].itemID, refs[2].itemID])
    }

    func testFrequentLeavesOutMemoUses() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        try await use(makeRef(facet: .memo), times: 3, lastAt: 300, in: store)
        try await use(makeRef(facet: .history), times: 2, lastAt: 300, in: store)

        let frequent = try await store.frequent(minimumCount: 2, since: .distantPast, limit: 20)

        XCTAssertEqual(frequent.map(\.facet), [.history])
    }

    func testFrequentReadsTheSameAfterReopening() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let a = makeRef()
        let expected = [
            UsageSummary(itemID: a.itemID, facet: .history, lastUsedAt: Date(timeIntervalSince1970: 300), useCount: 2)
        ]

        let initial = try PersistenceController(directory: directory)
        addTeardownBlock { try await initial.close() }
        let initialStore = LocalUsageStore(controller: initial)
        try await use(a, times: 2, lastAt: 300, in: initialStore)
        let before = try await initialStore.frequent(minimumCount: 2, since: .distantPast, limit: 20)
        try await initial.close()

        let reopened = try PersistenceController(directory: directory)
        addTeardownBlock { try await reopened.close() }
        let after = try await LocalUsageStore(controller: reopened)
            .frequent(minimumCount: 2, since: .distantPast, limit: 20)

        XCTAssertEqual(before, expected)
        XCTAssertEqual(after, expected)
        try await reopened.close()
    }

    func testFrequentReportsARowThatLostItsItemAsCorrupt() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        try await controller.perform { context in
            let row = NSEntityDescription.insertNewObject(forEntityName: "UsageSummary", into: context)
            row.setValue(UUID(), forKey: "id")
            row.setValue(ContentFacet.history.rawValue, forKey: "facet")
            row.setValue(Date(timeIntervalSince1970: 300), forKey: "lastUsedAt")
            row.setValue(Int64(2), forKey: "useCount")
            try context.save()
        }

        do {
            _ = try await store.frequent(minimumCount: 2, since: .distantPast, limit: 20)
            XCTFail("A summary without an item was listed")
        } catch {
            XCTAssertEqual(error as? StoreError, .corruptStore)
        }
    }

    func testConcurrentDuplicateExecutionCountsExactlyOnce() async throws {
        let (_, controller) = try makeStore()
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
        let (_, controller) = try makeStore()
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
        let (_, controller) = try makeStore()
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
        let (_, controller) = try makeStore()
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

    func testCapacityEvictionNeverEvictsTheReceiptBeingRecordedWhenClockMovesBackward() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(
            controller: controller,
            deduplicationLimit: 2,
            deduplicationInterval: 10_000
        )
        let ref = makeRef()
        let currentExecutionID = UUID()

        try await store.record(makeReceipt(ref: ref), now: Date(timeIntervalSince1970: 1_000))
        try await store.record(makeReceipt(ref: ref), now: Date(timeIntervalSince1970: 1_001))
        try await store.record(
            makeReceipt(id: currentExecutionID, ref: ref),
            now: Date(timeIntervalSince1970: 900)
        )
        try await store.record(
            makeReceipt(id: currentExecutionID, ref: ref),
            now: Date(timeIntervalSince1970: 900)
        )

        let summaries = try await store.summaries(for: [ref])
        XCTAssertEqual(summaries.first?.useCount, 3)
        let dedupIDs = try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "UsageExecutionDedup")
            return Set(try context.fetch(request).compactMap { $0.value(forKey: "id") as? UUID })
        }
        XCTAssertEqual(dedupIDs.count, 2)
        XCTAssertTrue(dedupIDs.contains(currentExecutionID))
        try await controller.close()
    }

    func testSummariesHandlesLargeDeduplicatedMixedFacetRequests() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)

        for (index, count) in [997, 998, 1_000, 2_000].enumerated() {
            let refs = (0..<count).map { position in
                ContentRef(
                    itemID: ItemID(),
                    facet: position.isMultiple(of: 2) ? .history : .memo,
                    version: ContentVersion(),
                    digest: Data([0x01])
                )
            }
            let first = try XCTUnwrap(refs.first)
            let last = try XCTUnwrap(refs.last)
            try await store.record(
                UseReceipt(ref: first, occurredAt: Date(timeIntervalSince1970: Double(index * 2)), outcome: .success)
            )
            try await store.record(
                UseReceipt(ref: last, occurredAt: Date(timeIntervalSince1970: Double(index * 2 + 1)), outcome: .success)
            )
            let requested = refs + Array(refs.prefix(16))

            let summaries = try await store.summaries(for: requested)

            XCTAssertEqual(summaries.map(\.itemID), [first.itemID, last.itemID], "Failed at \(count) keys")
        }
        try await controller.close()
    }

    func testFirstUsageWriteFixesThePolicyForEveryStoreInstanceOnTheController() async throws {
        let (_, controller) = try makeStore()
        let ref = makeRef()
        let first = LocalUsageStore(
            controller: controller,
            deduplicationLimit: 2,
            deduplicationInterval: 100
        )
        let conflicting = LocalUsageStore(
            controller: controller,
            deduplicationLimit: 3,
            deduplicationInterval: 100
        )
        try await first.record(makeReceipt(ref: ref), now: Date(timeIntervalSince1970: 1_000))

        do {
            try await conflicting.record(makeReceipt(ref: ref), now: Date(timeIntervalSince1970: 1_001))
            XCTFail("One controller accepted conflicting usage cleanup policies")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let summaries = try await first.summaries(for: [ref])
        XCTAssertEqual(summaries.first?.useCount, 1)
        try await controller.close()
    }

    func testFailedInitialUsageWriteDoesNotFixTheControllerPolicy() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(
            directory: directory,
            model: try modelRejectingHistoryUsageAtSave()
        )
        addTeardownBlock { try await controller.close() }
        let rejectedPolicy = LocalUsageStore(
            controller: controller,
            deduplicationLimit: 2,
            deduplicationInterval: 100
        )
        let acceptedPolicy = LocalUsageStore(
            controller: controller,
            deduplicationLimit: 3,
            deduplicationInterval: 100
        )

        do {
            try await rejectedPolicy.record(makeReceipt(ref: makeRef()))
            XCTFail("The synthetic Core Data validation failure did not reach save")
        } catch {
            let validationError = error as NSError
            XCTAssertEqual(validationError.domain, NSCocoaErrorDomain)
        }

        let memoRef = ContentRef(
            itemID: ItemID(),
            facet: .memo,
            version: ContentVersion(),
            digest: Data([0xcc])
        )
        try await acceptedPolicy.record(makeReceipt(ref: memoRef))
        let summaries = try await acceptedPolicy.summaries(for: [memoRef])
        XCTAssertEqual(summaries.first?.useCount, 1)
        try await controller.close()
    }

    func testUsageProjectionAllowsQuarantineButRejectsAStaleExpectedIdentity() async throws {
        let (_, controller) = try makeStore()
        let store = LocalUsageStore(controller: controller)
        let ref = makeRef()
        let staleIdentity = try await controller.identity()
        try await StoreSafetyGate(controller: controller).transition(to: .quarantined, expecting: staleIdentity)

        do {
            try await store.record(makeReceipt(ref: ref), expecting: staleIdentity)
            XCTFail("A projection from the previous store generation was accepted")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }

        let currentIdentity = try await controller.identity()
        try await store.record(makeReceipt(ref: ref), expecting: currentIdentity)
        let summaries = try await store.summaries(for: [ref])
        XCTAssertEqual(summaries.first?.useCount, 1)
        try await controller.close()
    }

    func testFileAccessRoundTripsExactlyAcrossReopenAndStaysInLocalState() async throws {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let value = LocalFileAccess(
            id: UUID(),
            snapshotID: UUID(),
            bytes: Data([0x00, 0x7f, 0xff]),
            bookmark: Data([0x10, 0x20, 0x30]),
            localPath: "/Synthetic Folder/$literal (copy).txt"
        )

        var controller: PersistenceController? = try PersistenceController(directory: directory)
        let openedController = try XCTUnwrap(controller)
        addTeardownBlock { try await openedController.close() }
        var store: FileAccessStore? = FileAccessStore(controller: openedController)
        let identity = try await openedController.identity()
        try await store?.put(value, expecting: identity)
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
        addTeardownBlock { try await reopened.close() }
        let reopenedValue = try await FileAccessStore(controller: reopened).read(representationID: value.id)
        XCTAssertEqual(reopenedValue, value)
        try await reopened.close()
    }

    func testFileAccessPutBeforeCaptureCommitKeepsOriginalBytesAndRemoveIsIdempotent() async throws {
        let (_, controller) = try makeStore()
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

        let identity = try await controller.identity()
        try await store.put(initial, expecting: identity)
        do {
            try await store.put(replacement, expecting: identity)
            XCTFail("Prepared local bytes were replaced before content commit")
        } catch {
            XCTAssertEqual(error as? StoreError, .preconditionFailed)
        }
        let preserved = try await store.read(representationID: id)
        XCTAssertEqual(preserved, initial)
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        try await store.remove(representationID: id, permit: permit)
        try await store.remove(representationID: id, permit: permit)
        let removed = try await store.read(representationID: id)
        XCTAssertNil(removed)
        try await controller.close()
    }

    func testFileAccessRejectsCrossSnapshotRepresentationReuseWithoutMutatingOriginal() async throws {
        let (_, controller) = try makeStore()
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
        let identity = try await controller.identity()
        try await store.put(firstAccess, expecting: identity)

        let representation = RepresentationValue(
            id: representationID,
            snapshotID: firstSnapshotID,
            itemIndex: 0,
            representationIndex: 0,
            typeIdentifier: "public.file-url",
            storage: .localReference,
            byteCount: 0,
            digest: Data(repeating: 0x65, count: 32),
            bytes: nil
        )
        let manifest = CaptureManifest(
            version: LocalReferencePrivacy.manifestVersion,
            itemCount: 1,
            entries: [ManifestEntry(representation)]
        )
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
            try await store.put(conflicting, expecting: identity)
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

    private func makeRef(itemID: ItemID = ItemID(rawValue: UUID()), facet: ContentFacet = .history) -> ContentRef {
        ContentRef(
            itemID: itemID,
            facet: facet,
            version: ContentVersion(rawValue: UUID()),
            digest: Data([0xaa, 0xbb])
        )
    }

    /// Records `times` successful uses of `ref`: the last at `lastAt` seconds since 1970, and each earlier one a second
    /// before the one that follows it.
    private func use(_ ref: ContentRef, times: Int, lastAt: TimeInterval, in store: LocalUsageStore) async throws {
        for secondsBeforeLast in (0..<times).reversed() {
            try await store.record(UseReceipt(
                ref: ref,
                occurredAt: Date(timeIntervalSince1970: lastAt - TimeInterval(secondsBeforeLast)),
                outcome: .success
            ))
        }
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

    private func makeStore() throws -> (directory: URL, controller: PersistenceController) {
        let directory = try makeStoreDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock { try await controller.close() }
        return (directory, controller)
    }

    private func modelRejectingHistoryUsageAtSave() throws -> NSManagedObjectModel {
        guard let model = try PersistenceController.loadModel().copy() as? NSManagedObjectModel,
              let facet = model.entitiesByName["UsageSummary"]?.attributesByName["facet"] else {
            throw StoreError.invalidModel
        }
        facet.setValidationPredicates(
            [NSPredicate(format: "SELF != %@", ContentFacet.history.rawValue)],
            withValidationWarnings: ["Synthetic history usage rejected at save time"]
        )
        return model
    }
}
