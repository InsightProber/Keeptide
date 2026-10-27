import CoreData
import Foundation

struct WriteCoordinator: Sendable {
    let controller: PersistenceController

    func commit(_ transaction: StoreTransaction) async throws -> StoreReceipt {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard transaction.identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            controller.runtime.expireLeases()
            try StoreSafetyGate.validate(.write, runtime: controller.runtime)
            guard !transaction.mutations.isEmpty else { throw StoreError.invalidTransaction }
            for condition in transaction.preconditions { try check(condition, in: context) }
            var touched = Set<RecordKey>()
            var affectedItems = Set<ItemID>()
            var affectedMemos = Set<UUID>()
            var removed: [RecordKey] = []
            do {
                context.transactionAuthor = transaction.transactionID.uuidString
                for mutation in transaction.mutations {
                    let key: RecordKey
                    switch mutation {
                    case .insert(let value):
                        key = value.key
                        guard try StoredRecords.object(key, in: context) == nil else { throw StoreError.preconditionFailed }
                        if case .capture(let capture) = value {
                            try requireAvailableRepresentationIDs(capture, in: context)
                        }
                        if case .item(let item) = value,
                           try StoredRecords.object(.itemMarker(item.id), in: context) != nil {
                            throw StoreError.preconditionFailed
                        }
                        try validate(value, old: nil)
                        let record = NSEntityDescription.insertNewObject(forEntityName: key.entity, into: context)
                        try StoredRecords.write(value, to: record, in: context)
                        collect(value, into: &affectedItems)
                        if case .memo(let memo) = value { affectedMemos.insert(memo.id) }
                        if case .itemMarker = value { try requireMaintenance(transaction) }
                        if case .facetMarker = value { try requireMaintenance(transaction) }
                    case .update(let value):
                        key = value.key
                        try requireCAS(key, transaction: transaction)
                        guard let old = try StoredRecords.value(key, in: context),
                              let record = try StoredRecords.object(key, in: context) else { throw StoreError.preconditionFailed }
                        try validate(value, old: old)
                        try StoredRecords.write(value, to: record, in: context)
                        collect(value, into: &affectedItems)
                        if case .memo(let memo) = value { affectedMemos.insert(memo.id) }
                        if case .item(let previous) = old,
                           case .item(let updated) = value,
                           previous.memoID != updated.memoID,
                           let detachedMemo = previous.memoID {
                            affectedMemos.insert(detachedMemo)
                        }
                    case .delete(let target):
                        key = target
                        try requireCAS(key, transaction: transaction)
                        try requireMaintenance(transaction)
                        guard let old = try StoredRecords.value(key, in: context),
                              let record = try StoredRecords.object(key, in: context) else { throw StoreError.preconditionFailed }
                        switch key {
                        case .itemMarker, .facetMarker: throw StoreError.invalidTransaction
                        case .item(let id):
                            guard try StoredRecords.object(.itemMarker(id), in: context) != nil else { throw StoreError.invalidTransaction }
                        case .capture(let id):
                            guard transaction.preconditions.contains(where: {
                                if case .referenceSet(let snapshot, _) = $0 { return snapshot == id }; return false
                            }) else { throw StoreError.preconditionFailed }
                            guard !controller.runtime.leases.values.contains(where: { $0.protectedCaptures.contains(id) }) else {
                                throw StoreError.contentProtected
                            }
                            let children = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
                            children.predicate = NSPredicate(format: "snapshotID == %@", id as NSUUID)
                            try context.fetch(children).forEach(context.delete)
                        case .memo(let id):
                            if case .memo(let memo) = old {
                                guard try hasFacetMarker(itemID: memo.itemID, facet: .memo, id: id, in: context)
                                        || StoredRecords.object(.itemMarker(memo.itemID), in: context) != nil else {
                                    throw StoreError.invalidTransaction
                                }
                            }
                        case .collection: break
                        }
                        collect(old, into: &affectedItems)
                        if case .item(let item) = old, let detachedMemo = item.memoID {
                            affectedMemos.insert(detachedMemo)
                        }
                        context.delete(record)
                        removed.append(key)
                    }
                    guard touched.insert(key).inserted else { throw StoreError.invalidTransaction }
                }
                for id in affectedMemos {
                    guard let value = try StoredRecords.value(.memo(id), in: context) else { continue }
                    guard case .memo(let memo) = value,
                          case .item(let owner) = try StoredRecords.value(.item(memo.itemID), in: context),
                          owner.memoID == memo.id else {
                        throw StoreError.invalidTransaction
                    }
                }
                for id in affectedItems {
                    if case .item(let item) = try StoredRecords.value(.item(id), in: context) {
                        try validateItem(item, in: context)
                        try StoredRecords.link(item, in: context)
                    }
                }
                for key in removed { try validateRemoval(key, in: context) }
                // All mutations in this save belong to CloudContent. Local usage,
                // file access and generation changes use separate LocalState saves.
                try context.save()
                return StoreReceipt(transactionID: transaction.transactionID, identity: controller.runtime.identity,
                                    changed: touched.sorted { $0.entity + $0.id.uuidString < $1.entity + $1.id.uuidString })
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private func check(_ condition: StorePrecondition, in context: NSManagedObjectContext) throws {
        let valid: Bool
        switch condition {
        case .exists(let key): valid = try StoredRecords.object(key, in: context) != nil
        case .absent(let key): valid = try StoredRecords.object(key, in: context) == nil
        case .recordUnchanged(let key, let fingerprint):
            do {
                valid = try StoredRecords.fingerprint(key, in: context) == fingerprint
            } catch StoreError.notFound {
                valid = false
            }
        case .contentVersion(let ref):
            do {
                valid = try StoredRecords.currentRef(itemID: ref.itemID, facet: ref.facet, in: context) == ref
            } catch StoreError.notFound {
                valid = false
            }
        case .facetVisible(let id, let facet, let expected):
            let visible: Bool
            do {
                visible = try StoredRecords.currentRef(itemID: id, facet: facet, in: context) != nil
            } catch StoreError.notFound {
                visible = false
            }
            valid = visible == expected
        case .candidateSet(let fingerprint): valid = try StoredRecords.candidateFingerprint(in: context) == fingerprint
        case .referenceSet(let id, let fingerprint): valid = try StoredRecords.referenceFingerprint(snapshotID: id, in: context) == fingerprint
        }
        guard valid else { throw StoreError.preconditionFailed }
    }

    private func requireCAS(_ key: RecordKey, transaction: StoreTransaction) throws {
        guard transaction.preconditions.contains(where: {
            if case .recordUnchanged(let expected, _) = $0 { return expected == key }; return false
        }) else { throw StoreError.preconditionFailed }
    }

    private func requireAvailableRepresentationIDs(
        _ capture: CaptureValue,
        in context: NSManagedObjectContext
    ) throws {
        guard !capture.representations.isEmpty else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(
            format: "id IN %@",
            capture.representations.map(\.id) as NSArray
        )
        request.fetchLimit = 1
        guard try context.fetch(request).isEmpty else { throw StoreError.preconditionFailed }
    }

    private func requireMaintenance(_ transaction: StoreTransaction) throws {
        guard let permit = transaction.permit else { throw StoreError.operationDenied }
        try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
    }

    private func collect(_ value: RecordValue, into ids: inout Set<ItemID>) {
        switch value {
        case .item(let v): ids.insert(v.id)
        case .memo(let v): ids.insert(v.itemID)
        case .itemMarker(let v): ids.insert(v.itemID)
        case .facetMarker(let v): ids.insert(v.itemID)
        default: break
        }
    }

    private func validate(_ value: RecordValue, old: RecordValue?) throws {
        switch value {
        case .capture(let capture):
            guard old == nil else { throw StoreError.invalidTransaction }
            let localItems = Set(capture.representations.filter { $0.storage == .localReference }.map(\.itemIndex))
            let fileTypes: Set<String> = ["public.file-url", "NSFilenamesPboardType", "com.apple.pasteboard.promised-file-url"]
            for representation in capture.representations where representation.storage == .portable {
                guard !fileTypes.contains(representation.typeIdentifier), !localItems.contains(representation.itemIndex) else {
                    throw StoreError.invalidTransaction
                }
            }
        case .memo(let memo):
            if memo.bodyMode == .inheritedCapture {
                guard memo.body == nil, memo.version == nil, memo.digest == nil else { throw StoreError.invalidTransaction }
            } else {
                guard let body = memo.body, String(data: body, encoding: .utf8) != nil,
                      memo.version != nil, memo.digest == ContentDigest.sha256(body) else { throw StoreError.invalidTransaction }
                if case .memo(let previous) = old,
                   previous.body != memo.body || previous.bodyMode != memo.bodyMode {
                    guard memo.version != previous.version else { throw StoreError.invalidTransaction }
                }
            }
            if case .memo(let previous) = old {
                guard previous.itemID == memo.itemID,
                      !(previous.bodyMode != .inheritedCapture && memo.bodyMode == .inheritedCapture) else {
                    throw StoreError.invalidTransaction
                }
            }
        case .item(let item):
            guard item.copyCount >= 0 else { throw StoreError.invalidTransaction }
            if case .item(let previous) = old, let previousCapture = previous.captureID, let capture = item.captureID {
                guard previousCapture == capture else { throw StoreError.invalidTransaction }
            }
        case .collection(let value): guard value.sortOrder.isFinite else { throw StoreError.invalidTransaction }
        case .itemMarker, .facetMarker: guard old == nil else { throw StoreError.invalidTransaction }
        }
    }

    private func validateItem(_ item: ItemValue, in context: NSManagedObjectContext) throws {
        if item.historyEligible { guard item.captureID != nil else { throw StoreError.invalidTransaction } }
        if let capture = item.captureID {
            guard try StoredRecords.object(.capture(capture), in: context) != nil else { throw StoreError.invalidTransaction }
            if item.historyEligible, try hasFacetMarker(itemID: item.id, facet: .history, id: capture, in: context) {
                throw StoreError.invalidTransaction
            }
        }
        if let memoID = item.memoID {
            guard case .memo(let memo) = try StoredRecords.value(.memo(memoID), in: context), memo.itemID == item.id,
                  !(try hasFacetMarker(itemID: item.id, facet: .memo, id: memoID, in: context)) else {
                throw StoreError.invalidTransaction
            }
            if memo.bodyMode == .inheritedCapture { guard item.captureID != nil else { throw StoreError.invalidTransaction } }
        }
        if let collection = item.collectionID {
            guard item.memoID != nil, try StoredRecords.object(.collection(collection), in: context) != nil else {
                throw StoreError.invalidTransaction
            }
        }
    }

    private func hasFacetMarker(itemID: ItemID, facet: ContentFacet, id: UUID, in context: NSManagedObjectContext) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FacetDeletionMarker")
        request.predicate = NSPredicate(format: "itemID == %@ AND facet == %@ AND generationID == %@",
                                       itemID.rawValue as NSUUID, facet.rawValue, id as NSUUID)
        request.fetchLimit = 1
        return try !context.fetch(request).isEmpty
    }

    private func validateRemoval(_ key: RecordKey, in context: NSManagedObjectContext) throws {
        let attribute: String
        switch key {
        case .capture: attribute = "captureID"
        case .memo: attribute = "memoID"
        case .collection: attribute = "collectionID"
        default: return
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
        request.predicate = NSPredicate(format: "%K == %@", attribute, key.id as NSUUID)
        request.fetchLimit = 1
        guard try context.fetch(request).isEmpty else { throw StoreError.preconditionFailed }
    }
}
