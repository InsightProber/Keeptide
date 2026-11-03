import CoreData
import XCTest
@testable import Keeptide

@MainActor
final class MemoIdentityTests: XCTestCase {
    func testSavingExplicitMarkdownHistoryKeepsMarkdownKindAndExactSource() async throws {
        for type in ["net.daringfireball.markdown", "text/markdown"] {
            try await withStore { controller in
                let source = "# Saved \(type)\n\n- [ ] exact  source\n"
                let capture = try ContentStoreFixtures.capture([[(type, Data(source.utf8))]])
                let item = ContentStoreFixtures.item(capture)
                try await ContentStoreFixtures.insert(item, capture, into: controller)
                let service = LibraryService(controller: controller)

                let saved = try await service.saveAsMemo(item.id).ref
                let snapshot = try await service.editingSnapshot(saved)
                let itemState = try await ContentRepository(controller: controller).recordState(.item(item.id))
                guard case .item(let storedItem) = itemState.value,
                      let memoID = storedItem.memoID else { return XCTFail("Memo was not attached") }
                let memoState = try await ContentRepository(controller: controller).recordState(.memo(memoID))
                guard case .memo(let memo) = memoState.value else { return XCTFail("Wrong record") }

                XCTAssertEqual(memo.displayKind, MemoKind.markdown.rawValue, type)
                XCTAssertEqual(memo.sourceRepresentationType, type, type)
                XCTAssertEqual(snapshot.kind, .markdown, type)
                XCTAssertEqual(snapshot.body, source, type)
            }
        }
    }

    func testSavingAHistoryItemIsIdempotentAndDoesNotCopyItsPayload() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([[
                ("public.utf8-plain-text", Data("immutable source".utf8)),
                ("public.rtf", Data("{\\rtf1 immutable source}".utf8)),
            ]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let service = LibraryService(controller: controller)

            let first = try await service.saveAsMemo(item.id)
            let second = try await service.saveAsMemo(item.id)

            guard case .created(let created) = first else { return XCTFail("First save was not created") }
            guard case .existing(let existing) = second else { return XCTFail("Second save was not idempotent") }
            let captureCount = try await count("CaptureSnapshot", in: controller)
            let representationCount = try await count("CaptureRepresentation", in: controller)
            XCTAssertEqual(created, existing)
            XCTAssertEqual(captureCount, 1)
            XCTAssertEqual(representationCount, 2)
            let itemState = try await ContentRepository(controller: controller).recordState(.item(item.id))
            guard case .item(let storedItem) = itemState.value,
                  let memoID = storedItem.memoID else { return XCTFail("Memo was not attached") }
            let memoState = try await ContentRepository(controller: controller).recordState(.memo(memoID))
            guard case .memo(let memo) = memoState.value else { return XCTFail("Wrong record") }
            XCTAssertEqual(memo.bodyMode, .inheritedCapture)
            XCTAssertNil(memo.body)
            let editingBody = try await service.editingSnapshot(existing).body
            XCTAssertEqual(editingBody, "immutable source")
        }
    }

    func testConcurrentHistorySavesConvergeOnOneMemoIdentity() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", Data("race".utf8))]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let service = LibraryService(controller: controller)

            async let left = service.saveAsMemo(item.id)
            async let right = service.saveAsMemo(item.id)
            let outcomes = try await (left, right)
            let refs = [outcomes.0.ref, outcomes.1.ref]
            let memoCount = try await count("MemoDocument", in: controller)
            let captureCount = try await count("CaptureSnapshot", in: controller)

            XCTAssertEqual(Set(refs).count, 1)
            XCTAssertEqual(memoCount, 1)
            XCTAssertEqual(captureCount, 1)
        }
    }

    func testStableManualCreationIsRetrySafeButIdenticalTextKeepsIndependentIdentity() async throws {
        try await withStore { controller in
            let service = LibraryService(controller: controller)
            let stable = MemoDraft(itemID: ItemID(), title: "Command", body: "echo safe", kind: .code,
                                   languageHint: "bash")

            let first = try await service.create(stable)
            let retry = try await service.create(stable)
            let independent = try await service.create(MemoDraft(title: stable.title, body: stable.body,
                                                                   kind: stable.kind, languageHint: "bash"))
            let firstContent = try await ContentRepository(controller: controller).read(first)

            XCTAssertEqual(first, retry)
            XCTAssertNotEqual(first.itemID, independent.itemID)
            XCTAssertEqual(firstContent.representations.first?.bytes, Data("echo safe".utf8))
            do {
                _ = try await service.create(MemoDraft(itemID: stable.itemID, title: "Different", body: "rm -i",
                                                        kind: .code, languageHint: "bash"))
                XCTFail("Stable identity collision overwrote existing content")
            } catch {
                XCTAssertEqual(error as? LibraryServiceError, .stableIdentityCollision)
            }
        }
    }

    func testFirstBodyEditUsesCopyOnWriteAndMetadataOnlyEditKeepsContentVersion() async throws {
        try await withStore { controller in
            let source = Data("original rich source".utf8)
            let capture = try ContentStoreFixtures.capture([[("public.utf8-plain-text", source)]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let service = LibraryService(controller: controller)
            let inherited = try await service.saveAsMemo(item.id).ref
            let initial = try await service.editingSnapshot(inherited)

            let changed = try await service.commit(MemoEdit(
                title: "Edited", body: "independent body", kind: .markdown, note: "note",
                expectedMemoFingerprint: initial.memoFingerprint
            ), base: inherited)
            guard case .updated(let owned) = changed else { return XCTFail("Body edit was not persisted") }
            let historyContent = try await ContentRepository(controller: controller).read(
                ContentStoreFixtures.ref(item, capture)
            )
            let memoContent = try await ContentRepository(controller: controller).read(owned)
            XCTAssertNotEqual(owned.version, inherited.version)
            XCTAssertEqual(historyContent.representations.first?.bytes, source)
            XCTAssertEqual(memoContent.representations.first?.bytes, Data("independent body".utf8))

            let metadataBase = try await service.editingSnapshot(owned)
            let metadataChange = try await service.commit(MemoEdit(
                title: "Retitled", languageHint: "swift", note: "new note",
                expectedMemoFingerprint: metadataBase.memoFingerprint
            ), base: owned)
            guard case .updated(let sameVersion) = metadataChange else {
                return XCTFail("Metadata edit was not persisted")
            }
            XCTAssertEqual(sameVersion, owned)
            let afterMetadata = try await service.editingSnapshot(sameVersion)
            XCTAssertEqual(afterMetadata.title, "Retitled")
            XCTAssertEqual(afterMetadata.note, "new note")
            XCTAssertEqual(afterMetadata.body, "independent body")
        }
    }

    func testSameBodySubmissionIsUnchangedAndExplicitDuplicateGetsIndependentIdentity() async throws {
        try await withStore { controller in
            let service = LibraryService(controller: controller)
            let original = try await service.create(MemoDraft(title: "Prompt", body: "Explain this", kind: .prompt))
            let snapshot = try await service.editingSnapshot(original)

            let result = try await service.commit(MemoEdit(
                title: snapshot.title, body: snapshot.body, kind: snapshot.kind,
                languageHint: snapshot.languageHint, note: snapshot.note,
                expectedMemoFingerprint: snapshot.memoFingerprint
            ), base: original)
            guard case .unchanged(let same) = result else { return XCTFail("Identical submission changed content") }
            XCTAssertEqual(same, original)

            let duplicate = try await service.duplicate(original)
            let duplicateContent = try await ContentRepository(controller: controller).read(duplicate)
            XCTAssertNotEqual(duplicate.itemID, original.itemID)
            XCTAssertEqual(duplicateContent.representations.first?.bytes, Data("Explain this".utf8))
        }
    }

    func testStaleEditCreatesOneStableConflictCopyAndDoesNotOverwriteWinner() async throws {
        try await withStore { controller in
            let service = LibraryService(controller: controller)
            let original = try await service.create(MemoDraft(title: "Shared", body: "base", kind: .plainText))
            let firstWindow = try await service.editingSnapshot(original)
            let secondWindow = firstWindow

            let winner = try await service.commit(MemoEdit(
                title: "Winner", body: "winner body", expectedMemoFingerprint: firstWindow.memoFingerprint
            ), base: original)
            let conflictID = ItemID()
            let staleEdit = MemoEdit(
                title: "Conflict", body: "conflict body", note: "kept",
                expectedMemoFingerprint: secondWindow.memoFingerprint, conflictItemID: conflictID
            )
            let conflict = try await service.commit(staleEdit, base: original)
            let retry = try await service.commit(staleEdit, base: original)

            guard case .updated(let winnerRef) = winner,
                  case .conflictCopy(let conflictRef) = conflict,
                  case .conflictCopy(let retryRef) = retry else { return XCTFail("Unexpected conflict outcomes") }
            let winnerBody = try await service.editingSnapshot(winnerRef).body
            let conflictBody = try await service.editingSnapshot(conflictRef).body
            XCTAssertEqual(conflictRef, retryRef)
            XCTAssertEqual(conflictRef.itemID, conflictID)
            XCTAssertEqual(winnerBody, "winner body")
            XCTAssertEqual(conflictBody, "conflict body")
        }
    }

    func testDeletedOrMismatchedContentCannotBeSavedOrEdited() async throws {
        try await withStore { controller in
            let service = LibraryService(controller: controller)
            let memo = try await service.create(MemoDraft(body: "alive"))
            let snapshot = try await service.editingSnapshot(memo)
            var wrong = memo
            wrong.digest = Data(repeating: 0x44, count: ContentDigest.byteCount)

            do {
                _ = try await service.commit(MemoEdit(
                    title: "bad", expectedMemoFingerprint: snapshot.memoFingerprint
                ), base: wrong)
                XCTFail("A mismatched reference was accepted")
            } catch {
                XCTAssertEqual(error as? StoreError, .staleReference)
            }

            let itemState = try await ContentRepository(controller: controller).recordState(.item(memo.itemID))
            guard case .item(var item) = itemState.value else { return XCTFail("Wrong item") }
            item.deletedAt = Date()
            _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
                identity: try await controller.identity(),
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: itemState.fingerprint)],
                mutations: [.update(.item(item))]
            ))
            do {
                _ = try await service.editingSnapshot(memo)
                XCTFail("Deleted content remained editable")
            } catch {
                XCTAssertEqual(error as? StoreError, .staleReference)
            }
        }
    }

    func testInheritedNonTextContentRejectsBodyEditsButMetadataConflictsKeepAStableCopy() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([[("public.png", Data([0x89, 0x50, 0x4E, 0x47]))]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let service = LibraryService(controller: controller)
            let saved = try await service.saveAsMemo(item.id).ref
            let stale = try await service.editingSnapshot(saved)
            XCTAssertNil(stale.body)

            do {
                _ = try await service.commit(MemoEdit(
                    title: "fabricated", body: "not present in the capture",
                    expectedMemoFingerprint: stale.memoFingerprint
                ), base: saved)
                XCTFail("Non-text capture was silently converted into an owned text memo")
            } catch {
                XCTAssertEqual(error as? LibraryServiceError, .contentNotEditable)
            }

            _ = try await service.commit(MemoEdit(
                title: "winner", note: "first window", expectedMemoFingerprint: stale.memoFingerprint
            ), base: saved)
            let conflictID = ItemID()
            let conflictEdit = MemoEdit(
                title: "other title", note: "second window",
                expectedMemoFingerprint: stale.memoFingerprint, conflictItemID: conflictID
            )
            let conflict = try await service.commit(conflictEdit, base: saved)
            let retry = try await service.commit(conflictEdit, base: saved)
            guard case .conflictCopy(let conflictRef) = conflict,
                  case .conflictCopy(let retryRef) = retry else {
                return XCTFail("Metadata-only conflict did not preserve an independent copy")
            }
            let conflictSnapshot = try await service.editingSnapshot(conflictRef)
            let conflictContent = try await ContentRepository(controller: controller).read(conflictRef)
            XCTAssertEqual(conflictRef, retryRef)
            XCTAssertEqual(conflictRef.itemID, conflictID)
            XCTAssertEqual(conflictSnapshot.note, "second window")
            XCTAssertEqual(conflictContent.representations, capture.representations)
        }
    }

    func testDuplicatingAnInheritedMemoSharesTheImmutableCaptureUntilCopyOnWrite() async throws {
        try await withStore { controller in
            let capture = try ContentStoreFixtures.capture([[
                ("public.utf8-plain-text", Data("rich source".utf8)),
                ("public.rtf", Data("{\\rtf1 rich source}".utf8)),
            ]])
            let item = ContentStoreFixtures.item(capture)
            try await ContentStoreFixtures.insert(item, capture, into: controller)
            let service = LibraryService(controller: controller)
            let saved = try await service.saveAsMemo(item.id).ref
            let duplicateID = ItemID()

            let duplicate = try await service.duplicate(saved, stableItemID: duplicateID)
            let retry = try await service.duplicate(saved, stableItemID: duplicateID)
            let duplicateContent = try await ContentRepository(controller: controller).read(duplicate)
            let captureCount = try await count("CaptureSnapshot", in: controller)
            let representationCount = try await count("CaptureRepresentation", in: controller)
            XCTAssertEqual(duplicate, retry)
            XCTAssertEqual(duplicate.itemID, duplicateID)
            XCTAssertEqual(duplicateContent.representations, capture.representations)
            XCTAssertEqual(captureCount, 1)
            XCTAssertEqual(representationCount, 2)

            let duplicateSnapshot = try await service.editingSnapshot(duplicate)
            let edited = try await service.commit(MemoEdit(
                title: "copy", body: "owned copy", expectedMemoFingerprint: duplicateSnapshot.memoFingerprint
            ), base: duplicate)
            let editedSnapshot = try await service.editingSnapshot(edited.ref)
            let sourceContent = try await ContentRepository(controller: controller).read(saved)
            XCTAssertEqual(editedSnapshot.body, "owned copy")
            XCTAssertEqual(sourceContent.representations, capture.representations)
        }
    }

    func testEntirelyEmptyDraftDoesNotCreateAnItem() async throws {
        try await withStore { controller in
            let service = LibraryService(controller: controller)
            for draft in [
                MemoDraft(body: ""),
                MemoDraft(title: " \n", body: "\t", note: "  "),
            ] {
                do {
                    _ = try await service.create(draft)
                    XCTFail("An entirely blank draft was persisted")
                } catch {
                    XCTAssertEqual(error as? LibraryServiceError, .invalidDraft)
                }
            }
            let itemCount = try await count("LibraryItem", in: controller)
            let memoCount = try await count("MemoDocument", in: controller)
            XCTAssertEqual(itemCount, 0)
            XCTAssertEqual(memoCount, 0)
        }
    }

    func testExplicitStoreIdentityCannotCommitAfterGenerationTransition() async throws {
        try await withStore { controller in
            let service = LibraryService(controller: controller)
            let gate = StoreSafetyGate(controller: controller)
            let originalIdentity = try await controller.identity()
            try await gate.transition(to: .quarantined, expecting: originalIdentity)
            let quarantinedIdentity = try await controller.identity()
            try await gate.transition(to: .active, expecting: quarantinedIdentity)

            do {
                _ = try await service.create(
                    MemoDraft(body: "must not cross generations"),
                    expecting: originalIdentity
                )
                XCTFail("An operation from an old store generation was committed")
            } catch {
                XCTAssertEqual(error as? StoreError, .preconditionFailed)
            }
            let items = try await ContentRepository(controller: controller).recent(limit: 10)
            XCTAssertTrue(items.isEmpty)
        }
    }

    private func withStore<T: Sendable>(
        _ body: (PersistenceController) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeeptideMemoIdentity-\(UUID().uuidString)", isDirectory: true)
        let controller = try PersistenceController(directory: directory)
        do {
            let result = try await body(controller)
            try await controller.close()
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func count(_ entity: String, in controller: PersistenceController) async throws -> Int {
        try await controller.perform { context in
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))
        }
    }
}
