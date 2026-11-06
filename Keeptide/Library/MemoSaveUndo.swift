import Foundation

extension LibraryService {
    func undoSaveAsMemo(_ itemID: ItemID, memoID: UUID, expectedFingerprint: Data,
                        expecting identity: StoreIdentity) async throws {
        guard try await controller.identity() == identity else { throw StoreError.preconditionFailed }
        let repository = ContentRepository(controller: controller)
        let itemState = try await repository.recordState(.item(itemID))
        let memoState = try await repository.recordState(.memo(memoID))
        guard case .item(var item) = itemState.value,
              item.deletedAt == nil, item.historyEligible, item.historyDeletedAt == nil,
              item.captureID != nil, item.memoID == memoID,
              case .memo(let memo) = memoState.value,
              memo.itemID == itemID, memo.deletedAt == nil,
              memo.bodyMode == .inheritedCapture,
              memoState.fingerprint == expectedFingerprint else { throw StoreError.preconditionFailed }
        item.memoID = nil
        // Membership and the favorite flag belong to the memo facet; without it they go too.
        item.collectionID = nil
        item.isFavorite = false
        let permit = try await StoreSafetyGate(controller: controller).permit(.maintenance)
        let marker = FacetDeletionMarkerValue(itemID: itemID, facet: .memo,
                                             generationID: memoID, purgedAt: Date())
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: identity,
            preconditions: [
                .recordUnchanged(.item(itemID), fingerprint: itemState.fingerprint),
                .recordUnchanged(.memo(memoID), fingerprint: expectedFingerprint),
                .facetVisible(itemID, .history, true),
            ],
            mutations: [.update(.item(item)), .insert(.facetMarker(marker)), .delete(.memo(memoID))],
            permit: permit
        ))
    }
}
