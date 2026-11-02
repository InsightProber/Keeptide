import XCTest
@testable import Keeptide

final class MemoSearchIntegrationTests: XCTestCase {
    func testSaveAndEditFlowThroughPersistentHistoryWithoutChangingCapture() async throws {
        let harness = try SearchHarness.make(in: self)
        let library = LibraryService(controller: harness.controller)
        let capture = try ContentStoreFixtures.capture([[ ("public.utf8-plain-text", Data("original anchor 中文".utf8)) ]])
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: harness.controller)
        try await harness.consumer.synchronize()
        let saved = try await library.saveAsMemo(item.id)
        try await harness.consumer.synchronize()
        let merged = try await harness.search("anchor")
        XCTAssertEqual(merged.totalMatches, 1)
        let memoOnly = try await harness.search("anchor", scope: .memo)
        XCTAssertEqual(memoOnly.results.first?.ref, saved.ref)
        let edit = try await library.editingSnapshot(saved.ref)
        let changed = try await library.commit(MemoEdit(title: "Edited", body: "changed anchor 备忘", note: "unique annotation",
            expectedMemoFingerprint: edit.memoFingerprint), base: saved.ref)
        try await harness.consumer.synchronize()
        let separate = try await harness.search("anchor")
        XCTAssertEqual(separate.totalMatches, 2)
        let note = try await harness.search("annotation", scope: .memo)
        XCTAssertEqual(note.results.first?.ref, changed.ref)
        let old = try await ContentRepository(controller: harness.controller).read(ContentStoreFixtures.ref(item, capture))
        XCTAssertEqual(old.representations, capture.representations)
        let actual = try harness.index.allDocuments()
        let rebuilt = try await SearchHarness.freshDocuments(for: harness.controller)
        XCTAssertEqual(Set(actual.map(\.ref)), Set(rebuilt.map(\.ref)))
    }

    func testManualSameTextMemosDoNotEnterCaptureDeduplication() async throws {
        let harness = try SearchHarness.make(in: self)
        let library = LibraryService(controller: harness.controller)
        let text = "shared synthetic prompt 中文"
        let first = try await library.create(MemoDraft(body: text, kind: .prompt))
        let second = try await library.create(MemoDraft(body: text, kind: .prompt))
        let captureService = CaptureService(controller: harness.controller)
        let snapshot = CaptureSnapshotValue(items: [CapturedPasteboardItem(representations: [
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))
        ])], changeCount: 1, sourceApp: nil)
        let captured = try await captureService.capture(snapshot)
        let repeated = try await captureService.capture(snapshot)
        XCTAssertNotEqual(first.itemID, second.itemID)
        XCTAssertNotEqual(captured.itemID, first.itemID)
        XCTAssertNotEqual(captured.itemID, second.itemID)
        XCTAssertEqual(captured.itemID, repeated.itemID)
        XCTAssertTrue(repeated.reused)
        try await harness.consumer.synchronize()
        let all = try await harness.search("中文")
        XCTAssertEqual(all.totalMatches, 3)
        let memos = try await harness.search("中文", scope: .memo)
        XCTAssertEqual(memos.totalMatches, 2)
    }

    func testConflictAndMetadataChangesAreIndexedWithoutChangingBodyVersion() async throws {
        let harness = try SearchHarness.make(in: self)
        let library = LibraryService(controller: harness.controller)
        let base = try await library.create(MemoDraft(title: "initial", body: "retained body"))
        let snapshot = try await library.editingSnapshot(base)
        let first = try await library.commit(MemoEdit(title: "winning title", note: "metadata needle",
            expectedMemoFingerprint: snapshot.memoFingerprint), base: base)
        XCTAssertEqual(first.ref.version, base.version)
        let conflict = try await library.commit(MemoEdit(title: "other window", body: "other body",
            expectedMemoFingerprint: snapshot.memoFingerprint), base: base)
        XCTAssertNotEqual(conflict.ref.itemID, base.itemID)
        try await harness.consumer.synchronize()
        let metadata = try await harness.search("needle", scope: .memo)
        let copy = try await harness.search("other", scope: .memo)
        XCTAssertEqual(metadata.results.first?.ref, first.ref)
        XCTAssertEqual(copy.results.first?.ref, conflict.ref)
    }
}
