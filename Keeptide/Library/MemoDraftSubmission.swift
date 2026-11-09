import Foundation

extension LibraryService {
    func submitDraft(_ draft: RecoverableDraft) async throws -> MemoCommitReceipt {
        guard draft.storeIdentity == (try await controller.identity()) else {
            throw DraftStoreError.storeIdentityMismatch
        }
        guard !draft.isComposing else { throw StoreError.operationDenied }
        let ref: ContentRef
        if let base = draft.base {
            guard base.itemID == draft.itemID,
                  let fingerprint = draft.baseMemoFingerprint,
                  draft.conflictItemID != draft.itemID else { throw StoreError.invalidTransaction }
            ref = try await commit(MemoEdit(
                title: draft.title, body: draft.body, kind: draft.kind,
                languageHint: draft.languageHint, note: draft.note,
                expectedMemoFingerprint: fingerprint, conflictItemID: draft.conflictItemID
            ), base: base, expecting: draft.storeIdentity).ref
        } else {
            guard draft.baseMemoFingerprint == nil, let body = draft.body else {
                throw LibraryServiceError.invalidDraft
            }
            ref = try await create(MemoDraft(itemID: draft.itemID, title: draft.title, body: body,
                kind: draft.kind, languageHint: draft.languageHint, note: draft.note,
                collectionIDs: draft.collectionIDs),
                expecting: draft.storeIdentity)
        }

        // Do not adopt a later window's metadata fingerprint as this draft's base.
        // A concurrent change leaves the draft recoverable for another conflict check.
        let saved = try await editingSnapshot(ref)
        guard saved.title == draft.title, saved.note == draft.note,
              saved.languageHint == draft.languageHint, saved.kind == draft.kind,
              draft.body == nil || saved.body == draft.body else {
            throw StoreError.preconditionFailed
        }
        guard draft.storeIdentity == (try await controller.identity()) else {
            throw DraftStoreError.storeIdentityMismatch
        }
        return MemoCommitReceipt(ref: ref, memoFingerprint: saved.memoFingerprint)
    }
}
