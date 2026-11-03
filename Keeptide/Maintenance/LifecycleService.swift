import Foundation

struct TrashFacetSnapshot: Equatable, Sendable {
    let identity: DeletedFacetIdentity
    let title: String
    let deletedAt: Date
    let purgeAfter: Date
    let canRestore: Bool
}

struct RetentionImpact: Equatable, Sendable {
    let historyCount: Int
}

struct LifecycleMutationReceipt: Sendable {
    let target: DeletedFacetIdentity
    let storeReceipt: StoreReceipt
}

struct LifecycleBatchReceipt: Sendable {
    let changed: [DeletedFacetIdentity]
    let skippedConflicts: Int
}

enum LifecycleError: Error, Equatable {
    case notRestorable
}

/// Retention and reversible deletion only. Permanent deletion is deliberately
/// absent: the cleanup-intent saga owns that later phase.
struct LifecycleService: Sendable {
    typealias Commit = @Sendable (StoreTransaction) async throws -> StoreReceipt

    private let repository: LifecycleRepository
    private let commit: Commit

    init(controller: PersistenceController) {
        repository = LifecycleRepository(controller: controller)
        commit = { transaction in
            try await WriteCoordinator(controller: controller).commit(transaction)
        }
    }

    /// Internal seam used to prove that one stale CAS does not abort or falsely
    /// succeed for the rest of a maintenance batch.
    init(controller: PersistenceController, commit: @escaping Commit) {
        repository = LifecycleRepository(controller: controller)
        self.commit = commit
    }

    func expireHistory(
        policy: RetentionPolicy,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> LifecycleBatchReceipt {
        // Validate policy and clock even when permanent retention has no work.
        if case .permanent = policy {
            _ = try policy.isExpired(lastCopiedAt: now, at: now)
            try await repository.validateMaintenance(expecting: identity, permit: permit)
            return LifecycleBatchReceipt(changed: [], skippedConflicts: 0)
        }

        var cursor: LifecycleHistoryCursor?
        var changed: [DeletedFacetIdentity] = []
        var conflictedItemIDs = Set<ItemID>()
        var skippedConflicts = 0
        while true {
            try Task.checkCancellation()
            let batch = try await repository.activeHistoryBatch(
                after: cursor,
                expecting: identity,
                permit: permit
            )
            guard let nextCursor = batch.nextCursor else { break }
            cursor = nextCursor
            var reachedRetentionBoundary = false
            for record in batch.records {
                try Task.checkCancellation()
                // A concurrently repositioned row may re-enter a later keyset
                // page. Conflicts are retryable on the next run, not within this one.
                guard !conflictedItemIDs.contains(record.item.id) else { continue }
                guard try policy.isExpired(lastCopiedAt: record.item.lastCopiedAt, at: now) else {
                    reachedRetentionBoundary = true
                    break
                }
                var item = record.item
                item.historyEligible = false
                // Natural expiration is not a manual deletion and never enters trash.
                item.historyDeletedAt = nil
                item.historyPurgeAfter = nil
                let transaction = StoreTransaction(
                    identity: identity,
                    preconditions: [
                        .recordUnchanged(.item(item.id), fingerprint: record.itemFingerprint),
                    ],
                    mutations: [.update(.item(item))],
                    permit: permit
                )
                do {
                    _ = try await commit(transaction)
                    changed.append(record.identity)
                } catch StoreError.preconditionFailed {
                    // A stale store generation/permit is not an ordinary row conflict.
                    try await repository.validateMaintenance(expecting: identity, permit: permit)
                    conflictedItemIDs.insert(record.item.id)
                    skippedConflicts += 1
                }
            }
            if reachedRetentionBoundary { break }
        }
        return LifecycleBatchReceipt(changed: changed, skippedConflicts: skippedConflicts)
    }

    func remove(
        itemID: ItemID,
        facet: ContentFacet,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> LifecycleMutationReceipt {
        try await remove(
            itemID: itemID,
            facet: facet,
            selectedRef: nil,
            at: now,
            expecting: identity,
            permit: permit
        )
    }

    /// Deletes exactly the facet generation selected by the UI. The content
    /// precondition is checked again on the writer immediately before save.
    func remove(
        ref: ContentRef,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> LifecycleMutationReceipt {
        try await remove(
            itemID: ref.itemID,
            facet: ref.facet,
            selectedRef: ref,
            at: now,
            expecting: identity,
            permit: permit
        )
    }

    private func remove(
        itemID: ItemID,
        facet: ContentFacet,
        selectedRef: ContentRef?,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> LifecycleMutationReceipt {
        if let selectedRef {
            guard selectedRef.itemID == itemID, selectedRef.facet == facet else {
                throw StoreError.invalidTransaction
            }
        }
        let window = try DeletionWindow.manual(deletedAt: now)
        let record = try await repository.activeFacet(
            itemID: itemID,
            facet: facet,
            expecting: identity,
            permit: permit
        )
        let transaction: StoreTransaction
        switch facet {
        case .history:
            var item = record.item
            item.historyEligible = false
            item.historyDeletedAt = window.deletedAt
            item.historyPurgeAfter = window.purgeAfter
            var preconditions: [StorePrecondition] = [
                .recordUnchanged(.item(itemID), fingerprint: record.itemFingerprint),
            ]
            if let selectedRef { preconditions.append(.contentVersion(selectedRef)) }
            transaction = StoreTransaction(
                identity: identity,
                preconditions: preconditions,
                mutations: [.update(.item(item))],
                permit: permit
            )
        case .memo:
            guard var memo = record.memo, let memoFingerprint = record.memoFingerprint else {
                throw StoreError.corruptStore
            }
            memo.deletedAt = window.deletedAt
            memo.purgeAfter = window.purgeAfter
            var preconditions: [StorePrecondition] = [
                .recordUnchanged(.memo(memo.id), fingerprint: memoFingerprint),
            ]
            if let selectedRef { preconditions.append(.contentVersion(selectedRef)) }
            transaction = StoreTransaction(
                identity: identity,
                preconditions: preconditions,
                mutations: [.update(.memo(memo))],
                permit: permit
            )
        }
        return LifecycleMutationReceipt(target: record.identity, storeReceipt: try await commit(transaction))
    }

    func restore(
        _ target: DeletedFacetIdentity,
        policy: RetentionPolicy,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> LifecycleMutationReceipt {
        let record = try await repository.deletedFacet(target, expecting: identity, permit: permit)
        guard let window = record.deletionWindow else { throw StoreError.corruptStore }
        let transaction: StoreTransaction
        switch target.facet {
        case .history:
            guard try policy.canRestoreHistory(
                lastCopiedAt: record.item.lastCopiedAt,
                deletedAt: window.deletedAt,
                purgeAfter: window.purgeAfter,
                at: now
            ) else { throw LifecycleError.notRestorable }
            var item = record.item
            item.historyEligible = true
            item.historyDeletedAt = nil
            item.historyPurgeAfter = nil
            transaction = StoreTransaction(
                identity: identity,
                preconditions: [.recordUnchanged(.item(item.id), fingerprint: record.itemFingerprint)],
                mutations: [.update(.item(item))],
                permit: permit
            )
        case .memo:
            guard try window.canRestore(at: now) else { throw LifecycleError.notRestorable }
            guard var memo = record.memo, let memoFingerprint = record.memoFingerprint else {
                throw StoreError.corruptStore
            }
            memo.deletedAt = nil
            memo.purgeAfter = nil
            transaction = StoreTransaction(
                identity: identity,
                preconditions: [.recordUnchanged(.memo(memo.id), fingerprint: memoFingerprint)],
                mutations: [.update(.memo(memo))],
                permit: permit
            )
        }
        return LifecycleMutationReceipt(target: target, storeReceipt: try await commit(transaction))
    }

    func trash(
        policy: RetentionPolicy,
        at now: Date,
        expecting identity: StoreIdentity
    ) async throws -> [TrashFacetSnapshot] {
        try await repository.trash(policy: policy, at: now, expecting: identity)
    }

    func retentionImpact(
        policy: RetentionPolicy,
        at now: Date,
        expecting identity: StoreIdentity
    ) async throws -> RetentionImpact {
        if case .permanent = policy {
            _ = try policy.isExpired(lastCopiedAt: now, at: now)
            // Preserve the exact-store read fence even when there is no impact.
            _ = try await repository.activeHistoryBatch(after: nil, expecting: identity, permit: nil)
            return RetentionImpact(historyCount: 0)
        }
        var cursor: LifecycleHistoryCursor?
        var count = 0
        while true {
            try Task.checkCancellation()
            let batch = try await repository.activeHistoryBatch(
                after: cursor,
                expecting: identity,
                permit: nil
            )
            guard let nextCursor = batch.nextCursor else { break }
            cursor = nextCursor
            var reachedRetentionBoundary = false
            for record in batch.records {
                if try policy.isExpired(lastCopiedAt: record.item.lastCopiedAt, at: now) {
                    count += 1
                } else {
                    reachedRetentionBoundary = true
                    break
                }
            }
            if reachedRetentionBoundary { break }
        }
        return RetentionImpact(historyCount: count)
    }
}
