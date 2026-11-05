import CoreData
import Foundation

/// One facet and every value needed to form a CAS transaction. Managed objects
/// never leave the writer context.
struct LifecycleFacetRecord: Sendable {
    let identity: DeletedFacetIdentity
    let title: String
    let item: ItemValue
    let itemFingerprint: Data
    let memo: MemoValue?
    let memoFingerprint: Data?
    let deletionWindow: DeletionWindow?
}

struct LifecycleHistoryBatch: Sendable {
    let records: [LifecycleFacetRecord]
    /// Comes from the last fetched row, including rows hidden by an exact
    /// marker, so tombstones cannot starve later eligible history.
    let nextCursor: LifecycleHistoryCursor?
}

struct LifecycleHistoryCursor: Equatable, Sendable {
    let lastCopiedAt: Date
    let itemID: ItemID
}

/// Queue-confined lifecycle reads. Each returned record was validated together
/// with its fingerprint on the store writer; mutations still carry those
/// fingerprints so a later change becomes a conflict rather than an overwrite.
struct LifecycleRepository: Sendable {
    static let batchSize = 128

    let controller: PersistenceController

    func validateMaintenance(expecting identity: StoreIdentity, permit: StorePermit) async throws {
        try await controller.perform { context in
            context.reset()
            guard controller.runtime.identity == identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
        }
    }

    func activeHistoryBatch(
        after cursor: LifecycleHistoryCursor?,
        expecting identity: StoreIdentity,
        permit: StorePermit?
    ) async throws -> LifecycleHistoryBatch {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try validateRead(expecting: identity, permit: permit)

            let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
            var predicates = [
                NSPredicate(format: "deletedAt == nil"),
                NSPredicate(format: "historyEligible == YES"),
                NSPredicate(format: "historyDeletedAt == nil"),
                NSPredicate(format: "captureID != nil"),
            ]
            if let cursor {
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "lastCopiedAt > %@", cursor.lastCopiedAt as NSDate),
                    NSCompoundPredicate(andPredicateWithSubpredicates: [
                        NSPredicate(format: "lastCopiedAt == %@", cursor.lastCopiedAt as NSDate),
                        NSPredicate(format: "id > %@", cursor.itemID.rawValue as NSUUID),
                    ]),
                ]))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [
                NSSortDescriptor(key: "lastCopiedAt", ascending: true),
                NSSortDescriptor(key: "id", ascending: true),
            ]
            request.fetchLimit = Self.batchSize
            request.fetchBatchSize = Self.batchSize
            let objects = try context.fetch(request)
            let positions = try objects.map { object -> LifecycleHistoryCursor in
                guard let rawID = object.value(forKey: "id") as? UUID else {
                    throw StoreError.corruptStore
                }
                guard let lastCopiedAt = object.value(forKey: "lastCopiedAt") as? Date else {
                    throw StoreError.corruptStore
                }
                return LifecycleHistoryCursor(lastCopiedAt: lastCopiedAt, itemID: ItemID(rawValue: rawID))
            }
            let records: [LifecycleFacetRecord] = try objects.compactMap { object -> LifecycleFacetRecord? in
                guard let rawID = object.value(forKey: "id") as? UUID,
                      case .item(let item)? = try StoredRecords.value(
                        .item(ItemID(rawValue: rawID)),
                        in: context
                      ) else { throw StoreError.corruptStore }
                guard try StoredRecords.object(.itemMarker(item.id), in: context) == nil,
                      let captureID = item.captureID,
                      try !hasFacetMarker(
                        itemID: item.id,
                        facet: .history,
                        generationID: captureID,
                        in: context
                      ) else { return nil }
                guard try StoredRecords.object(.capture(captureID), in: context) != nil else {
                    throw StoreError.corruptStore
                }
                return LifecycleFacetRecord(
                    identity: .history(itemID: item.id, captureID: captureID),
                    title: item.title,
                    item: item,
                    itemFingerprint: try StoredRecords.fingerprint(.item(item.id), in: context),
                    memo: nil,
                    memoFingerprint: nil,
                    deletionWindow: nil
                )
            }
            return LifecycleHistoryBatch(records: records, nextCursor: positions.last)
        }
    }

    func activeFacet(
        itemID: ItemID,
        facet: ContentFacet,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> LifecycleFacetRecord {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try validateRead(expecting: identity, permit: permit)
            guard case .item(let item)? = try StoredRecords.value(.item(itemID), in: context),
                  item.deletedAt == nil,
                  try StoredRecords.object(.itemMarker(itemID), in: context) == nil else {
                throw StoreError.notFound
            }
            switch facet {
            case .history:
                guard item.historyEligible,
                      item.historyDeletedAt == nil,
                      item.historyPurgeAfter == nil,
                      let captureID = item.captureID,
                      try !hasFacetMarker(
                        itemID: itemID,
                        facet: .history,
                        generationID: captureID,
                        in: context
                      ),
                      try StoredRecords.object(.capture(captureID), in: context) != nil else {
                    throw StoreError.notFound
                }
                return LifecycleFacetRecord(
                    identity: .history(itemID: itemID, captureID: captureID),
                    title: item.title,
                    item: item,
                    itemFingerprint: try StoredRecords.fingerprint(.item(itemID), in: context),
                    memo: nil,
                    memoFingerprint: nil,
                    deletionWindow: nil
                )
            case .memo:
                guard let memoID = item.memoID,
                      try !hasFacetMarker(
                        itemID: itemID,
                        facet: .memo,
                        generationID: memoID,
                        in: context
                      ),
                      case .memo(let memo)? = try StoredRecords.value(.memo(memoID), in: context),
                      memo.itemID == itemID,
                      memo.deletedAt == nil,
                      memo.purgeAfter == nil else {
                    throw StoreError.notFound
                }
                return LifecycleFacetRecord(
                    identity: .memo(itemID: itemID, memoID: memoID),
                    title: memo.title.isEmpty ? item.title : memo.title,
                    item: item,
                    itemFingerprint: try StoredRecords.fingerprint(.item(itemID), in: context),
                    memo: memo,
                    memoFingerprint: try StoredRecords.fingerprint(.memo(memoID), in: context),
                    deletionWindow: nil
                )
            }
        }
    }

    func deletedFacet(
        _ target: DeletedFacetIdentity,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> LifecycleFacetRecord {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try validateRead(expecting: identity, permit: permit)
            guard case .item(let item)? = try StoredRecords.value(.item(target.itemID), in: context),
                  item.deletedAt == nil,
                  try StoredRecords.object(.itemMarker(target.itemID), in: context) == nil else {
                throw StoreError.notFound
            }
            guard try !hasFacetMarker(
                itemID: target.itemID,
                facet: target.facet,
                generationID: target.generationID,
                in: context
            ) else { throw StoreError.notFound }

            switch target.facet {
            case .history:
                guard item.captureID == target.generationID,
                      !item.historyEligible,
                      try StoredRecords.object(.capture(target.generationID), in: context) != nil,
                      let window = try deletionWindow(
                        deletedAt: item.historyDeletedAt,
                        purgeAfter: item.historyPurgeAfter
                      ) else { throw StoreError.notFound }
                return LifecycleFacetRecord(
                    identity: target,
                    title: item.title,
                    item: item,
                    itemFingerprint: try StoredRecords.fingerprint(.item(item.id), in: context),
                    memo: nil,
                    memoFingerprint: nil,
                    deletionWindow: window
                )
            case .memo:
                guard item.memoID == target.generationID,
                      case .memo(let memo)? = try StoredRecords.value(.memo(target.generationID), in: context),
                      memo.itemID == target.itemID,
                      let window = try deletionWindow(
                        deletedAt: memo.deletedAt,
                        purgeAfter: memo.purgeAfter
                      ) else { throw StoreError.notFound }
                return LifecycleFacetRecord(
                    identity: target,
                    title: memo.title.isEmpty ? item.title : memo.title,
                    item: item,
                    itemFingerprint: try StoredRecords.fingerprint(.item(item.id), in: context),
                    memo: memo,
                    memoFingerprint: try StoredRecords.fingerprint(.memo(memo.id), in: context),
                    deletionWindow: window
                )
            }
        }
    }

    func trash(
        policy: RetentionPolicy,
        at now: Date,
        expecting identity: StoreIdentity
    ) async throws -> [TrashFacetSnapshot] {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try validateRead(expecting: identity, permit: nil)
            // Validate the clock even when there are no rows.
            _ = try policy.isExpired(lastCopiedAt: now, at: now)

            let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
            request.predicate = NSPredicate(format: "deletedAt == nil AND (historyDeletedAt != nil OR memoID != nil)")
            request.fetchBatchSize = Self.batchSize
            var result: [TrashFacetSnapshot] = []
            // A malformed row, or a malformed facet of one, is left as it is: it is not listed, nothing of it is
            // cleared, and it does not keep the rest of Recently Deleted from showing. A sound facet of the same row
            // is still listed. Any other failure, such as a fetch that fails, still ends the read.
            for object in try context.fetch(request) {
                let item: ItemValue
                do {
                    guard let rawID = object.value(forKey: "id") as? UUID,
                          case .item(let value)? = try StoredRecords.value(
                            .item(ItemID(rawValue: rawID)),
                            in: context
                          ) else { continue }
                    item = value
                } catch StoreError.corruptStore { continue }
                guard try StoredRecords.object(.itemMarker(item.id), in: context) == nil else { continue }

                do {
                    if let history = try trashedHistory(of: item, policy: policy, at: now, in: context) {
                        result.append(history)
                    }
                } catch StoreError.corruptStore {}
                do {
                    if let memo = try trashedMemo(of: item, at: now, in: context) { result.append(memo) }
                } catch StoreError.corruptStore {}
            }
            return result.sorted {
                if $0.deletedAt != $1.deletedAt { return $0.deletedAt > $1.deletedAt }
                if $0.identity.itemID != $1.identity.itemID {
                    return $0.identity.itemID.rawValue.uuidString < $1.identity.itemID.rawValue.uuidString
                }
                return $0.identity.facet.rawValue < $1.identity.facet.rawValue
            }
        }
    }

    /// The item's history as Recently Deleted lists it, or nil while it is not deleted. A deletion window that is not
    /// a valid one, or a capture that is gone, is corrupt.
    private func trashedHistory(
        of item: ItemValue,
        policy: RetentionPolicy,
        at now: Date,
        in context: NSManagedObjectContext
    ) throws -> TrashFacetSnapshot? {
        guard !item.historyEligible,
              let captureID = item.captureID,
              try !hasFacetMarker(itemID: item.id, facet: .history, generationID: captureID, in: context),
              let window = try deletionWindow(
                deletedAt: item.historyDeletedAt,
                purgeAfter: item.historyPurgeAfter
              ) else { return nil }
        guard try StoredRecords.object(.capture(captureID), in: context) != nil else {
            throw StoreError.corruptStore
        }
        return TrashFacetSnapshot(
            identity: .history(itemID: item.id, captureID: captureID),
            title: item.title,
            deletedAt: window.deletedAt,
            purgeAfter: window.purgeAfter,
            canRestore: try policy.canRestoreHistory(
                lastCopiedAt: item.lastCopiedAt,
                deletedAt: window.deletedAt,
                purgeAfter: window.purgeAfter,
                at: now
            )
        )
    }

    /// The item's snippet as Recently Deleted lists it, or nil while it is not deleted or belongs to another item. A
    /// snippet that is not there, one whose item ID or title cannot be read, or one whose deletion window is not a
    /// valid one, is corrupt.
    private func trashedMemo(
        of item: ItemValue,
        at now: Date,
        in context: NSManagedObjectContext
    ) throws -> TrashFacetSnapshot? {
        guard let memoID = item.memoID,
              try !hasFacetMarker(itemID: item.id, facet: .memo, generationID: memoID, in: context) else { return nil }
        guard let object = try StoredRecords.object(.memo(memoID), in: context) else {
            throw StoreError.corruptStore
        }
        let memoItemID = ItemID(rawValue: try required(object, "itemID"))
        guard memoItemID == item.id,
              let window = try deletionWindow(
                deletedAt: object.value(forKey: "deletedAt") as? Date,
                purgeAfter: object.value(forKey: "purgeAfter") as? Date
              ) else { return nil }
        let memoTitle: String = try required(object, "title")
        return TrashFacetSnapshot(
            identity: .memo(itemID: item.id, memoID: memoID),
            title: memoTitle.isEmpty ? item.title : memoTitle,
            deletedAt: window.deletedAt,
            purgeAfter: window.purgeAfter,
            canRestore: try window.canRestore(at: now)
        )
    }

    private func validateRead(expecting identity: StoreIdentity, permit: StorePermit?) throws {
        guard controller.runtime.identity == identity else { throw StoreError.preconditionFailed }
        if let permit {
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
        } else {
            try StoreSafetyGate.validate(.projection, runtime: controller.runtime)
        }
    }

    private func hasFacetMarker(
        itemID: ItemID,
        facet: ContentFacet,
        generationID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "FacetDeletionMarker")
        request.predicate = NSPredicate(
            format: "itemID == %@ AND facet == %@ AND generationID == %@",
            itemID.rawValue as NSUUID,
            facet.rawValue,
            generationID as NSUUID
        )
        request.fetchLimit = 1
        return try context.count(for: request) != 0
    }

    private func deletionWindow(deletedAt: Date?, purgeAfter: Date?) throws -> DeletionWindow? {
        do { return try DeletionWindow.validated(deletedAt: deletedAt, purgeAfter: purgeAfter) }
        catch { throw StoreError.corruptStore }
    }

    private func required<T>(_ object: NSManagedObject, _ key: String) throws -> T {
        guard let value = object.value(forKey: key) as? T else { throw StoreError.corruptStore }
        return value
    }
}
