import CoreData
import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class LocalCaptureLookupTests: XCTestCase {
    func testWarmLocalLookupSeesIncrementalCaptureWithoutAnotherFullBuildAndRebuildsAfterReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = fileSnapshot("file:///Synthetic/incremental.txt", changeCount: 1)

        var controller: PersistenceController? = try PersistenceController(directory: directory)
        let active = try XCTUnwrap(controller)
        let candidates = CaptureCandidateRepository(controller: active)
        let cold = try await candidates.find(snapshot, digest: Data(), hasLocalReferences: true)
        XCTAssertNil(cold.match)
        let coldBuildCount = try await localIndexBuildCount(active)
        XCTAssertEqual(coldBuildCount, 1)

        let captured = try await CaptureService(controller: active).capture(snapshot)
        let warm = try await candidates.find(snapshot, digest: Data(), hasLocalReferences: true)
        XCTAssertEqual(warm.match?.item.id, captured.itemID)
        let warmBuildCount = try await localIndexBuildCount(active)
        XCTAssertEqual(warmBuildCount, 1,
                       "A committed local capture should update the warm index instead of rebuilding it")

        try await active.close()
        controller = nil

        let reopened = try PersistenceController(directory: directory)
        let reopenedMatch = try await CaptureCandidateRepository(controller: reopened).find(
            snapshot,
            digest: Data(),
            hasLocalReferences: true
        )
        XCTAssertEqual(reopenedMatch.match?.item.id, captured.itemID)
        let reopenedBuildCount = try await localIndexBuildCount(reopened)
        XCTAssertEqual(reopenedBuildCount, 1,
                       "A reopened store should lazily rebuild its local-only index once")
        try await reopened.close()
    }

    func testWarmLocalBucketsKeepDifferentBytesAndItemOrderDistinct() async throws {
        try await withStore { controller in
            let first = self.fileSnapshot("file:///Synthetic/first.txt", changeCount: 1)
            let second = self.fileSnapshot("file:///Synthetic/second.txt", changeCount: 2)
            let service = CaptureService(controller: controller)
            let firstResult = try await service.capture(first)
            let secondResult = try await service.capture(second)

            let candidates = CaptureCandidateRepository(controller: controller)
            let firstMatch = try await candidates.find(first, digest: Data(), hasLocalReferences: true)
            let secondMatch = try await candidates.find(second, digest: Data(), hasLocalReferences: true)
            XCTAssertEqual(firstMatch.match?.item.id, firstResult.itemID)
            XCTAssertEqual(secondMatch.match?.item.id, secondResult.itemID)
            XCTAssertNotEqual(firstMatch.match?.item.id, secondMatch.match?.item.id)

            let firstItem = try XCTUnwrap(first.items.first)
            let secondItem = try XCTUnwrap(second.items.first)
            let ordered = CaptureSnapshotValue(
                items: [firstItem, secondItem],
                changeCount: 3,
                sourceApp: nil
            )
            let reversed = CaptureSnapshotValue(
                items: [secondItem, firstItem],
                changeCount: 4,
                sourceApp: nil
            )
            let orderedResult = try await service.capture(ordered)
            let reversedResult = try await service.capture(reversed)
            XCTAssertNotEqual(orderedResult.itemID, reversedResult.itemID)
            let buildCount = try await localIndexBuildCount(controller)
            XCTAssertEqual(buildCount, 1)
        }
    }

    func testReusingALocalCaptureKeepsTheWarmIndex() async throws {
        try await withStore { controller in
            let snapshot = self.fileSnapshot("file:///Synthetic/reuse-warm-index.txt", changeCount: 1)
            let candidates = CaptureCandidateRepository(controller: controller)
            let cold = try await candidates.find(
                snapshot,
                digest: Data(),
                hasLocalReferences: true
            )
            let coldBuildCount = try await localIndexBuildCount(controller)
            XCTAssertNil(cold.match)
            XCTAssertEqual(coldBuildCount, 1)

            let first = try await CaptureService(controller: controller).capture(snapshot)
            let reused = try await CaptureService(controller: controller).capture(snapshot)
            let reusedBuildCount = try await localIndexBuildCount(controller)
            XCTAssertTrue(reused.reused)
            XCTAssertEqual(reused.itemID, first.itemID)
            XCTAssertEqual(reusedBuildCount, 1)

            let warm = try await candidates.find(
                snapshot,
                digest: Data(),
                hasLocalReferences: true
            )
            let warmBuildCount = try await localIndexBuildCount(controller)
            XCTAssertEqual(warm.match?.item.id, first.itemID)
            XCTAssertEqual(warmBuildCount, 1)
        }
    }

    func testColdIndexSkipsDamagedCandidateWithoutBlockingOrReusingIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let damagedSnapshot = fileSnapshot("file:///Synthetic/damaged.txt", changeCount: 1)

        var controller: PersistenceController? = try PersistenceController(directory: directory)
        let initial = try XCTUnwrap(controller)
        let damaged = try await CaptureService(controller: initial).capture(damagedSnapshot)
        try await corruptLocalState(snapshotID: damaged.ref.version.rawValue, in: initial)
        try await initial.close()
        controller = nil

        let reopened = try PersistenceController(directory: directory)
        let healthySnapshot = fileSnapshot("file:///Synthetic/healthy.txt", changeCount: 2)
        let healthy = try await CaptureService(controller: reopened).capture(healthySnapshot)
        let healthyContent = try await ContentRepository(controller: reopened).read(healthy.ref)
        XCTAssertTrue(healthyContent.isActionable)

        let recaptured = try await CaptureService(controller: reopened).capture(damagedSnapshot)
        XCTAssertNotEqual(recaptured.itemID, damaged.itemID,
                          "A corrupt historical LocalState candidate must never be reused")
        let recapturedContent = try await ContentRepository(controller: reopened).read(recaptured.ref)
        XCTAssertTrue(recapturedContent.isActionable)
        let buildCount = try await localIndexBuildCount(reopened)
        XCTAssertEqual(buildCount, 1)
        try await reopened.close()
    }

    func testForgedEnvelopeMetadataCannotCauseWrongLocalCaptureReuse() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalSnapshot = fileSnapshot("file:///Synthetic/metadata-a.txt", changeCount: 1)
        let targetSnapshot = fileSnapshot("file:///Synthetic/metadata-b.txt", changeCount: 2)

        let initial = try PersistenceController(directory: directory)
        let original = try await CaptureService(controller: initial).capture(originalSnapshot)
        try await forgeEnvelopeMetadata(
            snapshotID: original.ref.version.rawValue,
            targetBytes: Data("file:///Synthetic/metadata-b.txt".utf8),
            in: initial
        )
        try await initial.close()

        let reopened = try PersistenceController(directory: directory)
        let captured = try await CaptureService(controller: reopened).capture(targetSnapshot)
        XCTAssertFalse(captured.reused)
        XCTAssertNotEqual(captured.itemID, original.itemID)
        let content = try await ContentRepository(controller: reopened).read(captured.ref)
        XCTAssertTrue(content.isActionable)
        XCTAssertEqual(content.representations.map(\.bytes), targetSnapshot.items[0].representations.map(\.bytes))
        try await reopened.close()
    }

    func testTombstonedLocalCandidateIsSkippedInsteadOfFailingTheCapture() async throws {
        try await withStore { controller in
            let snapshot = self.fileSnapshot("file:///Synthetic/tombstoned.txt", changeCount: 1)
            let first = try await CaptureService(controller: controller).capture(snapshot)
            let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                mutations: [
                    .insert(.itemMarker(ItemDeletionMarkerValue(itemID: first.itemID)))
                ],
                permit: permit
            ))

            let replacement = try await CaptureService(controller: controller).capture(snapshot)
            XCTAssertNotEqual(replacement.itemID, first.itemID)
            XCTAssertFalse(replacement.reused)
            let content = try await ContentRepository(controller: controller).read(replacement.ref)
            XCTAssertTrue(content.isActionable)
        }
    }

    func testColdIndexSkipsDuplicateLocalRowsWithoutBlockingHealthyCandidates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let damagedSnapshot = fileSnapshot("file:///Synthetic/duplicate-row.txt", changeCount: 1)
        let healthySnapshot = fileSnapshot("file:///Synthetic/healthy-row.txt", changeCount: 2)

        let initial = try PersistenceController(directory: directory)
        let damaged = try await CaptureService(controller: initial).capture(damagedSnapshot)
        let healthy = try await CaptureService(controller: initial).capture(healthySnapshot)
        try await duplicateFirstLocalRow(snapshotID: damaged.ref.version.rawValue, in: initial)
        try await initial.close()

        let reopened = try PersistenceController(directory: directory)
        let healthyMatch = try await CaptureCandidateRepository(controller: reopened).find(
            healthySnapshot,
            digest: Data(),
            hasLocalReferences: true
        )
        XCTAssertEqual(healthyMatch.match?.item.id, healthy.itemID)

        let replacement = try await CaptureService(controller: reopened).capture(damagedSnapshot)
        XCTAssertNotEqual(replacement.itemID, damaged.itemID)
        XCTAssertFalse(replacement.reused)
        try await reopened.close()
    }

    func testColdIndexSkipsCorruptEnvelopeHeaderWithoutBlockingHealthyCandidates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let damagedSnapshot = fileSnapshot("file:///Synthetic/damaged-header.txt", changeCount: 1)
        let healthySnapshot = fileSnapshot("file:///Synthetic/healthy-header.txt", changeCount: 2)

        let initial = try PersistenceController(directory: directory)
        let damaged = try await CaptureService(controller: initial).capture(damagedSnapshot)
        let healthy = try await CaptureService(controller: initial).capture(healthySnapshot)
        try await corruptFirstLocalEnvelopeHeader(snapshotID: damaged.ref.version.rawValue, in: initial)
        try await initial.close()

        let reopened = try PersistenceController(directory: directory)
        let healthyMatch = try await CaptureCandidateRepository(controller: reopened).find(
            healthySnapshot,
            digest: Data(),
            hasLocalReferences: true
        )
        XCTAssertEqual(healthyMatch.match?.item.id, healthy.itemID)

        let replacement = try await CaptureService(controller: reopened).capture(damagedSnapshot)
        XCTAssertFalse(replacement.reused)
        XCTAssertNotEqual(replacement.itemID, damaged.itemID)
        try await reopened.close()
    }

    private func fileSnapshot(_ value: String, changeCount: Int) -> CaptureSnapshotValue {
        CaptureSnapshotValue(
            items: [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: "public.file-url", bytes: Data(value.utf8)),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(value.utf8))
            ])],
            changeCount: changeCount,
            sourceApp: "test.source"
        )
    }

    private func localIndexBuildCount(_ controller: PersistenceController) async throws -> Int {
        try await controller.perform { _ in controller.runtime.localCaptureIndexBuildCount }
    }

    private func corruptLocalState(snapshotID: UUID, in controller: PersistenceController) async throws {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(format: "snapshotID == %@", snapshotID as NSUUID)
            let rows = try context.fetch(request)
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                let stored = try XCTUnwrap(row.value(forKey: "bytes") as? Data)
                var corrupted = [UInt8](stored)
                corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0xff
                row.setValue(Data(corrupted), forKey: "bytes")
            }
            try context.save()
            context.reset()
        }
    }

    private func duplicateFirstLocalRow(snapshotID: UUID, in controller: PersistenceController) async throws {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(format: "snapshotID == %@", snapshotID as NSUUID)
            let source = try XCTUnwrap(context.fetch(request).first)
            let duplicate = NSEntityDescription.insertNewObject(forEntityName: "FileAccessRecord", into: context)
            for key in ["id", "snapshotID", "bytes", "bookmark", "localPath"] {
                duplicate.setValue(source.value(forKey: key), forKey: key)
            }
            try context.save()
            context.reset()
        }
    }

    private func forgeEnvelopeMetadata(
        snapshotID: UUID,
        targetBytes: Data,
        in controller: PersistenceController
    ) async throws {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(format: "snapshotID == %@", snapshotID as NSUUID)
            let rows = try context.fetch(request)
            XCTAssertFalse(rows.isEmpty)
            let payloadDigestStart = 8 + 16 + 16 + MemoryLayout<UInt64>.size
            let payloadDigestEnd = payloadDigestStart + ContentDigest.byteCount
            let bindingDigestEnd = payloadDigestEnd + ContentDigest.byteCount
            for row in rows {
                let stored = try XCTUnwrap(row.value(forKey: "bytes") as? Data)
                var corrupted = [UInt8](stored)
                XCTAssertGreaterThanOrEqual(corrupted.count, bindingDigestEnd)
                corrupted.replaceSubrange(
                    payloadDigestStart..<payloadDigestEnd,
                    with: ContentDigest.sha256(targetBytes)
                )
                corrupted.replaceSubrange(
                    payloadDigestEnd..<bindingDigestEnd,
                    with: ContentDigest.sha256(Data(corrupted.prefix(payloadDigestEnd)))
                )
                row.setValue(Data(corrupted), forKey: "bytes")
            }
            try context.save()
            context.reset()
        }
    }

    private func corruptFirstLocalEnvelopeHeader(
        snapshotID: UUID,
        in controller: PersistenceController
    ) async throws {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
            request.predicate = NSPredicate(format: "snapshotID == %@", snapshotID as NSUUID)
            let rows = try context.fetch(request)
            XCTAssertFalse(rows.isEmpty)
            let bindingDigestOffset = 8 + 16 + 16 + MemoryLayout<UInt64>.size + ContentDigest.byteCount
            for row in rows {
                let stored = try XCTUnwrap(row.value(forKey: "bytes") as? Data)
                var corrupted = [UInt8](stored)
                XCTAssertGreaterThan(corrupted.count, bindingDigestOffset)
                corrupted[bindingDigestOffset] ^= 0xff
                row.setValue(Data(corrupted), forKey: "bytes")
            }
            try context.save()
            context.reset()
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Keeptide-LocalCaptureLookupTests-" + UUID().uuidString, isDirectory: true)
    }

    private func withStore(_ body: (PersistenceController) async throws -> Void) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        do {
            try await body(controller)
            try await controller.close()
        } catch {
            try? await controller.close()
            throw error
        }
    }
}
