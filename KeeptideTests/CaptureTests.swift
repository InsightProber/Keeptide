import Foundation
import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class CaptureTests: XCTestCase {
    func testRepeatedCapturePreservesIdentityAndIncrementsCopyCountAfterReopen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        let service = CaptureService(controller: controller)
        let a = snapshot("echo hello", count: 1)
        let first = try await service.capture(a, at: Date(timeIntervalSince1970: 100))
        _ = try await service.capture(snapshot("other", count: 2), at: Date(timeIntervalSince1970: 200))
        let repeated = try await service.capture(snapshot("echo hello", count: 3), at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(first.itemID, repeated.itemID)
        XCTAssertTrue(repeated.reused)
        let state = try await ContentRepository(controller: controller).recordState(.item(first.itemID))
        guard case .item(let item) = state.value else { return XCTFail("Expected item") }
        XCTAssertEqual(item.copyCount, 2)
        XCTAssertEqual(item.lastCopiedAt, Date(timeIntervalSince1970: 300))
        try await controller.close()
        let reopened = try PersistenceController(directory: directory)
        let rows = try await ContentRepository(controller: reopened).recent(limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.itemID, first.itemID)
        let content = try await ContentRepository(controller: reopened).read(try XCTUnwrap(rows.first?.history))
        XCTAssertEqual(content.representations.first?.bytes, Data("echo hello".utf8))
        try await reopened.close()
    }

    func testConcurrentCaptureAcrossServicesDoesNotCreateDuplicateHistory() async throws {
        try await withStore { controller in
            let services = [CaptureService(controller: controller), CaptureService(controller: controller)]
            let input = self.snapshot("concurrent", count: 1)
            let ids = try await withThrowingTaskGroup(of: ItemID.self) { group in
                for index in 0..<12 {
                    let service = services[index % 2]
                    group.addTask { try await service.capture(input).itemID }
                }
                var result: [ItemID] = []
                for try await id in group { result.append(id) }
                return result
            }
            XCTAssertEqual(Set(ids).count, 1)
            let state = try await ContentRepository(controller: controller).recordState(.item(ids[0]))
            guard case .item(let item) = state.value else { return XCTFail("Expected item") }
            XCTAssertEqual(item.copyCount, 12)
        }
    }

    func testRichFormatsAndRepresentationOrderRemainDistinct() async throws {
        try await withStore { controller in
            let service = CaptureService(controller: controller)
            let text = CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("same".utf8))
            let rtf = CapturedRepresentation(typeIdentifier: "public.rtf", bytes: Data("{\\rtf1 same}".utf8))
            let inputs = [[text], [text, rtf], [rtf, text]]
            var ids = Set<ItemID>()
            for (index, values) in inputs.enumerated() {
                let result = try await service.capture(CaptureSnapshotValue(
                    items: [CapturedPasteboardItem(representations: values)], changeCount: index, sourceApp: nil))
                ids.insert(result.itemID)
            }
            XCTAssertEqual(ids.count, 3)
        }
    }

    func testHashCandidateStillRequiresExactBytes() {
        let first = snapshot("a", count: 1)
        var representation = RepresentationValue(snapshotID: UUID(), itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.utf8-plain-text", storage: .portable,
            byteCount: 1, digest: ContentDigest.sha256(Data("a".utf8)), bytes: Data("b".utf8))
        XCTAssertFalse(CaptureService.matches(first, representations: [representation]))
        representation.bytes = Data("a".utf8)
        XCTAssertTrue(CaptureService.matches(first, representations: [representation]))
    }

    func testStaleSnapshotAndRevokedPermissionNeverCommit() async throws {
        try await withStore { controller in
            let service = CaptureService(controller: controller)
            let permit = CapturePermit()
            permit.revoke()
            do {
                _ = try await service.capture(self.snapshot("private", count: 1), permit: permit)
                XCTFail("Revoked permit committed")
            } catch { XCTAssertEqual(error as? CaptureError, .staleSnapshot) }
            do {
                _ = try await service.capture(self.snapshot("stale", count: 2), isCurrent: { false })
                XCTFail("Stale snapshot committed")
            } catch { XCTAssertEqual(error as? CaptureError, .staleSnapshot) }
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testFileCaptureKeepsLocalBytesButPortableRecordsHaveNoPathVerifier() async throws {
        try await withStore { controller in
            let service = CaptureService(controller: controller)
            let path = Data("file:///Users/synthetic/private.txt".utf8)
            let input = CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: "public.file-url", bytes: path),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: path)
            ])], changeCount: 1, sourceApp: "test.source")
            let first = try await service.capture(input)
            let repeated = try await service.capture(input)
            XCTAssertEqual(first.itemID, repeated.itemID)
            let repository = ContentRepository(controller: controller)
            let content = try await repository.read(first.ref)
            XCTAssertTrue(content.isActionable)
            XCTAssertEqual(content.representations.map(\.bytes), [path, path])
            let state = try await repository.recordState(.capture(first.ref.version.rawValue))
            guard case .capture(let capture) = state.value else { return XCTFail("Expected capture") }
            XCTAssertEqual(capture.manifest.version, 2)
            for representation in capture.representations {
                XCTAssertEqual(representation.storage, .localReference)
                XCTAssertNil(representation.bytes)
                XCTAssertEqual(representation.byteCount, 0)
                XCTAssertNotEqual(representation.digest, ContentDigest.sha256(path))
            }
        }
    }

    func testPlainCommandWithPathRemainsUserAuthoredPortableText() async throws {
        try await withStore { controller in
            let text = "cat /Users/synthetic/private.txt"
            let result = try await CaptureService(controller: controller).capture(self.snapshot(text, count: 1))
            let content = try await ContentRepository(controller: controller).read(result.ref)
            XCTAssertEqual(content.representations.first?.storage, .portable)
            XCTAssertEqual(content.representations.first?.bytes, Data(text.utf8))
        }
    }

    func testSensitiveMarkerIsAlsoRejectedAtTheStorageServiceBoundary() async throws {
        try await withStore { controller in
            let input = CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: CapturePolicy.concealedType, bytes: Data()),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("synthetic secret".utf8))
            ])], changeCount: 1, sourceApp: nil)
            do {
                _ = try await CaptureService(controller: controller).capture(input)
                XCTFail("Stored sensitive content")
            } catch { XCTAssertEqual(error as? CaptureError, .privacyRestricted) }
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testRevocationAfterMutationRollsBackBeforeSaving() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([[ ("public.utf8-plain-text", Data("synthetic".utf8)) ]])
            let item = ContentStoreFixtures.item(capture)
            let probe = AuthorizationProbe()
            do {
                _ = try await WriteCoordinator(controller: controller).commit(
                    StoreTransaction(identity: try await controller.identity(),
                        mutations: [.insert(.capture(capture)), .insert(.item(item))]),
                    validate: { try probe.check() })
                XCTFail("Authorization was not checked immediately before save")
            } catch { XCTAssertEqual(error as? CaptureError, .staleSnapshot) }
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testOversizeAggregateIsRejectedWithoutPartialStore() async throws {
        try await withStore { controller in
            let part = Data(repeating: 7, count: 26 * 1024 * 1024)
            let input = CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: "public.png", bytes: part),
                CapturedRepresentation(typeIdentifier: "public.tiff", bytes: part)
            ])], changeCount: 1, sourceApp: nil)
            do {
                _ = try await CaptureService(controller: controller).capture(input)
                XCTFail("Stored oversized content")
            } catch { XCTAssertEqual(error as? CaptureError, .oversized) }
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testCancellationAfterLocalPreparationRemovesOnlyThisAttempt() async throws {
        try await withStore { controller in
            let probe = FreshnessProbe()
            let input = CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: "public.file-url", bytes: Data("file:///synthetic.txt".utf8))
            ])], changeCount: 1, sourceApp: nil)
            do {
                _ = try await CaptureService(controller: controller).capture(input, isCurrent: { await probe.check() })
                XCTFail("Stale content committed")
            } catch { XCTAssertEqual(error as? CaptureError, .staleSnapshot) }
            let count = try await controller.perform { context in
                try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "FileAccessRecord"))
            }
            XCTAssertEqual(count, 0)
            let rows = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testConcurrentLocalCaptureAndFileOrderUseExactBytes() async throws {
        try await withStore { controller in
            let a = CapturedPasteboardItem(representations: [CapturedRepresentation(typeIdentifier: "public.file-url", bytes: Data("file:///a".utf8))])
            let b = CapturedPasteboardItem(representations: [CapturedRepresentation(typeIdentifier: "public.file-url", bytes: Data("file:///b".utf8))])
            let first = CaptureService(controller: controller)
            let second = CaptureService(controller: controller)
            let input = CaptureSnapshotValue(items: [a, b], changeCount: 1, sourceApp: nil)
            async let one = first.capture(input)
            async let two = second.capture(input)
            let results = try await (one, two)
            XCTAssertEqual(results.0.itemID, results.1.itemID)
            let reversed = try await first.capture(CaptureSnapshotValue(items: [b, a], changeCount: 2, sourceApp: nil))
            XCTAssertNotEqual(reversed.itemID, results.0.itemID)
            let count = try await controller.perform { context in
                try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "FileAccessRecord"))
            }
            XCTAssertEqual(count, 4, "Failed CAS attempts must not strand raw local paths")
        }
    }

    private func snapshot(_ text: String, count: Int) -> CaptureSnapshotValue {
        CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))
        ])], changeCount: count, sourceApp: "test.source")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KeeptideCapture-\(UUID().uuidString)")
    }

    private func withStore(_ body: (PersistenceController) async throws -> Void) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try PersistenceController(directory: directory)
        do { try await body(controller) } catch {
            try await controller.close()
            throw error
        }
        try await controller.close()
    }
}

private actor FreshnessProbe {
    private var calls = 0
    func check() -> Bool { calls += 1; return calls == 1 }
}

private final class AuthorizationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func check() throws {
        try lock.withLock {
            calls += 1
            if calls > 1 { throw CaptureError.staleSnapshot }
        }
    }
}
