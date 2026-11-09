import XCTest
@testable import Keeptide

final class MemoSaveUndoTests: XCTestCase {
    func testUndoAfterSavingIntoACollectionAsFavoriteClearsBothFields() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideMemoSaveUndo-\(UUID().uuidString)", isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let repository = ContentRepository(controller: controller)
        let collection = try await CollectionService(controller: controller)
            .create(CollectionDraft(name: "Prompts", color: "blue"))
        let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("keep this".utf8))]])
        let clip = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(clip, capture, into: controller)
        let library = LibraryService(controller: controller)
        let identity = try await controller.identity()
        let saved = try await library.saveAsMemo(clip.id, collectionIDs: [collection.value.id], isFavorite: true).ref
        let snapshot = try await library.editingSnapshot(saved)
        guard case .item(let before) = try await repository.recordState(.item(clip.id)).value else {
            return XCTFail("Missing item")
        }
        XCTAssertEqual(before.collectionIDs, [collection.value.id])
        XCTAssertTrue(before.isFavorite)

        try await library.undoSaveAsMemo(
            clip.id, memoID: snapshot.memoID, expectedFingerprint: snapshot.memoFingerprint, expecting: identity
        )

        guard case .item(let after) = try await repository.recordState(.item(clip.id)).value else {
            return XCTFail("Missing item after undo")
        }
        XCTAssertNil(after.memoID)
        XCTAssertEqual(after.collectionIDs, [])
        XCTAssertFalse(after.isFavorite)
        let history = try await repository.read(ContentStoreFixtures.ref(clip, capture))
        XCTAssertEqual(history.integrity, .complete)
        let membership = try await repository.collectionMembershipSnapshot(collection.value.id)
        XCTAssertTrue(membership.members.isEmpty)
    }
}
