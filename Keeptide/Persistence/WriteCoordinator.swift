import CoreData
import Foundation

struct WriteCoordinator: Sendable {
    let controller: PersistenceController

    func commit(_ transaction: StoreTransaction, validate authorization: @escaping @Sendable () throws -> Void = {}) async throws -> StoreReceipt {
        try await controller.perform { context in
            context.reset()
            defer {
                context.transactionAuthor = nil
                context.reset()
            }
            guard transaction.identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            controller.runtime.expireLeases()
            try StoreSafetyGate.validate(.write, runtime: controller.runtime)
            guard !transaction.mutations.isEmpty else { throw StoreError.invalidTransaction }
            try validateStructure(transaction)
            for condition in transaction.preconditions {
                try check(condition, transaction: transaction, in: context)
            }
            try authorization()
            var touched = Set<RecordKey>()
            var affectedItems = Set<ItemID>()
            var affectedMemos = Set<UUID>()
            var insertedItems = Set<ItemID>()
            var previousItems: [ItemID: ItemValue] = [:]
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
                            try requirePreparedLocalReferences(capture, in: context)
                        }
                        try requireUnmarked(value, in: context)
                        try validate(value, old: nil)
                        let record = NSEntityDescription.insertNewObject(forEntityName: key.entity, into: context)
                        try StoredRecords.write(value, to: record, in: context)
                        collect(value, into: &affectedItems)
                        if case .item(let item) = value { insertedItems.insert(item.id) }
                        if case .memo(let memo) = value { affectedMemos.insert(memo.id) }
                        if case .itemMarker = value { try requireMaintenance(transaction) }
                        if case .facetMarker = value { try requireMaintenance(transaction) }
                    case .update(let value):
                        key = value.key
                        try requireCAS(key, transaction: transaction)
                        guard let old = try StoredRecords.value(key, in: context),
                              let record = try StoredRecords.object(key, in: context) else { throw StoreError.preconditionFailed }
                        try requireUnmarked(value, in: context)
                        try validate(value, old: old)
                        try StoredRecords.write(value, to: record, in: context)
                        collect(value, into: &affectedItems)
                        if case .memo(let memo) = value { affectedMemos.insert(memo.id) }
                        if case .item(let previous) = old,
                           case .item(let updated) = value {
                            previousItems[updated.id] = previous
                            if previous.memoID != updated.memoID,
                               let detachedMemo = previous.memoID {
                                affectedMemos.insert(detachedMemo)
                            }
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
                            try deleteCaptureRepresentations(id: id, capture: record, in: context)
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
                    try validateMemoOwner(id, in: context)
                }
                for id in affectedItems {
                    if case .item(let item) = try StoredRecords.value(.item(id), in: context) {
                        let changes = referenceChanges(
                            for: item,
                            previous: previousItems[id],
                            inserted: insertedItems.contains(id)
                        )
                        try validateItem(item, requiring: changes, in: context)
                        if changes.any { try StoredRecords.link(item, in: context) }
                    }
                }
                for key in removed { try validateRemoval(key, in: context) }
                // All mutations in this save belong to CloudContent. Local usage,
                // file access and generation changes use separate LocalState saves.
                try authorization()
                try context.save()
                CaptureCandidateRepository.didCommit(transaction, runtime: controller.runtime)
                return StoreReceipt(transactionID: transaction.transactionID, identity: controller.runtime.identity,
                                    changed: touched.sorted { $0.entity + $0.id.uuidString < $1.entity + $1.id.uuidString })
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private func validateStructure(_ transaction: StoreTransaction) throws {
        var keys = Set<RecordKey>()
        for mutation in transaction.mutations {
            let key: RecordKey
            switch mutation {
            case .insert(let value), .update(let value):
                key = value.key
                try validatePersistableScalars(value)
            case .delete(let target):
                key = target
            }
            guard keys.insert(key).inserted else { throw StoreError.invalidTransaction }
        }
    }

    private func check(
        _ condition: StorePrecondition,
        transaction: StoreTransaction,
        in context: NSManagedObjectContext
    ) throws {
        let valid: Bool
        switch condition {
        case .exists(let key): valid = try StoredRecords.object(key, in: context) != nil
        case .absent(let key): valid = try StoredRecords.object(key, in: context) == nil
        case .recordUnchanged(let key, let fingerprint):
            do {
                valid = try StoredRecords.fingerprint(key, in: context) == fingerprint
            } catch StoreError.notFound {
                valid = false
            } catch StoreError.corruptStore {
                guard case .capture(let id) = key,
                      transaction.mutations.contains(where: {
                          if case .delete(.capture(let deletedID)) = $0 { return deletedID == id }
                          return false
                      }) else {
                    throw StoreError.corruptStore
                }
                valid = try capturePurgeFingerprint(id: id, in: context) == fingerprint
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
        case .candidateSet(let digest, let fingerprint):
            valid = try StoredRecords.candidateFingerprint(digest: digest, in: context) == fingerprint
        case .localCaptureSet(let digest, let fingerprint):
            valid = try CaptureCandidateRepository.localFingerprint(digest: digest, in: context, runtime: controller.runtime) == fingerprint
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

    private func requirePreparedLocalReferences(
        _ capture: CaptureValue,
        in context: NSManagedObjectContext
    ) throws {
        let localReferences = capture.representations.filter { $0.storage == .localReference }
        guard !localReferences.isEmpty else { return }
        guard LocalReferencePrivacy.usesOpaqueLocalDescriptor(
            manifestVersion: capture.manifest.version
        ) else {
            throw StoreError.invalidTransaction
        }
        for representation in localReferences {
            guard try LocalFileAccessRecordReader.decodedBytes(
                for: representation,
                snapshotID: capture.id,
                manifestVersion: capture.manifest.version,
                in: context
            ) != nil else {
                throw StoreError.preconditionFailed
            }
        }
    }

    private func requireUnmarked(_ value: RecordValue, in context: NSManagedObjectContext) throws {
        let itemID: ItemID?
        switch value {
        case .item(let item): itemID = item.id
        case .memo(let memo): itemID = memo.itemID
        default: itemID = nil
        }
        if let itemID, try hasItemMarker(itemID, in: context) {
            throw StoreError.preconditionFailed
        }
    }

    private func hasItemMarker(_ itemID: ItemID, in context: NSManagedObjectContext) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ItemDeletionMarker")
        request.predicate = NSPredicate(format: "id == %@", itemID.rawValue as NSUUID)
        request.fetchLimit = 1
        return try !context.fetch(request).isEmpty
    }

    private func deleteCaptureRepresentations(
        id: UUID,
        capture: NSManagedObject,
        in context: NSManagedObjectContext
    ) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(format: "snapshotID == %@", id as NSUUID)
        var children = Dictionary(uniqueKeysWithValues: try context.fetch(request).map { ($0.objectID, $0) })
        if let related = capture.value(forKey: "representations") as? NSSet {
            for case let child as NSManagedObject in related {
                children[child.objectID] = child
            }
        }
        children.values.forEach(context.delete)
    }

    private func capturePurgeFingerprint(id: UUID, in context: NSManagedObjectContext) throws -> Data {
        guard let captureObject = try StoredRecords.object(.capture(id), in: context) else {
            throw StoreError.notFound
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(format: "snapshotID == %@", id as NSUUID)
        let attributed = try context.fetch(request)
        guard let related = captureObject.value(forKey: "representations") as? NSSet else {
            throw StoreError.corruptStore
        }
        let relatedObjects = related.compactMap { $0 as? NSManagedObject }
        guard relatedObjects.count == related.count else { throw StoreError.corruptStore }
        let attributedIDs = Set(attributed.map(\.objectID))
        let relatedIDs = Set(relatedObjects.map(\.objectID))
        guard attributedIDs.isSubset(of: relatedIDs) else { throw StoreError.corruptStore }
        let inconsistent = relatedObjects.filter { !attributedIDs.contains($0.objectID) }
        guard !inconsistent.isEmpty,
              try inconsistent.allSatisfy({ child in
                  guard let snapshot = child.value(forKey: "snapshot") as? NSManagedObject,
                        snapshot.objectID == captureObject.objectID,
                        let snapshotID = child.value(forKey: "snapshotID") as? UUID else {
                      throw StoreError.corruptStore
                  }
                  return snapshotID != id
              }),
              case .capture(let capture) = try StoredRecords.value(.capture(id), in: context) else {
            throw StoreError.corruptStore
        }
        let canonicalManifest = try capture.manifest.canonicalData()
        guard let storedManifest = captureObject.value(forKey: "manifest") as? Data,
              canonicalManifest == storedManifest,
              ContentDigest.sha256(canonicalManifest) == capture.digest,
              capture.manifest.validate(capture.representations, snapshotID: id) == .complete else {
            throw StoreError.corruptStore
        }
        let value = PurgeCaptureFingerprint(
            id: capture.id,
            digest: capture.digest,
            representations: capture.representations.map(PurgeRepresentationFingerprint.init)
        )
        return try StoredRecords.canonicalDigest(value)
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

    private func validatePersistableScalars(_ value: RecordValue) throws {
        switch value {
        case .capture(let capture):
            guard capture.representations.allSatisfy({ isLossless($0.typeIdentifier) }) else {
                throw StoreError.invalidTransaction
            }
        case .memo(let memo):
            guard [memo.title, memo.note].allSatisfy(isLossless),
                  optionalStringIsLossless(memo.sourceRepresentationType),
                  optionalStringIsLossless(memo.languageHint),
                  optionalDateIsFinite(memo.deletedAt),
                  optionalDateIsFinite(memo.purgeAfter) else {
                throw StoreError.invalidTransaction
            }
        case .item(let item):
            guard isLossless(item.title), optionalStringIsLossless(item.sourceApp),
                  dateIsFinite(item.createdAt), dateIsFinite(item.lastCopiedAt),
                  optionalDateIsFinite(item.historyDeletedAt),
                  optionalDateIsFinite(item.historyPurgeAfter),
                  optionalDateIsFinite(item.deletedAt) else {
                throw StoreError.invalidTransaction
            }
        case .collection(let collection):
            guard isLossless(collection.name), isLossless(collection.color),
                  optionalDateIsFinite(collection.deletedAt) else {
                throw StoreError.invalidTransaction
            }
        case .itemMarker(let marker):
            guard dateIsFinite(marker.deletedAt) else { throw StoreError.invalidTransaction }
        case .facetMarker(let marker):
            guard dateIsFinite(marker.purgedAt) else { throw StoreError.invalidTransaction }
        }
    }

    private func isLossless(_ value: String) -> Bool {
        !value.utf8.contains(0)
    }

    private func optionalStringIsLossless(_ value: String?) -> Bool {
        value.map(isLossless) ?? true
    }

    private func dateIsFinite(_ value: Date) -> Bool {
        value.timeIntervalSinceReferenceDate.isFinite
    }

    private func optionalDateIsFinite(_ value: Date?) -> Bool {
        value.map(dateIsFinite) ?? true
    }

    private func validate(_ value: RecordValue, old: RecordValue?) throws {
        switch value {
        case .capture(let capture):
            guard old == nil else { throw StoreError.invalidTransaction }
            let localItems = Set(capture.representations.filter { $0.storage == .localReference }.map(\.itemIndex))
            if !localItems.isEmpty {
                guard capture.representations
                        .filter({ $0.storage == .localReference })
                        .allSatisfy(LocalReferencePrivacy.isCloudSafeDescriptor) else {
                    throw StoreError.invalidTransaction
                }
            }
            for representation in capture.representations where representation.storage == .portable {
                guard !SystemFileReferenceClassifier.isLocalFileReference(
                    typeIdentifier: representation.typeIdentifier,
                    bytes: representation.bytes
                ), !localItems.contains(representation.itemIndex) else {
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
            if case .item(let previous) = old,
               previous.captureID != item.captureID,
               item.captureID != nil {
                throw StoreError.invalidTransaction
            }
        case .collection(let value): guard value.sortOrder.isFinite else { throw StoreError.invalidTransaction }
        case .itemMarker, .facetMarker: guard old == nil else { throw StoreError.invalidTransaction }
        }
    }

    private func validateMemoOwner(_ memoID: UUID, in context: NSManagedObjectContext) throws {
        guard let memo = try StoredRecords.object(.memo(memoID), in: context) else { return }
        guard let rawItemID = memo.value(forKey: "itemID") as? UUID,
              let owner = try StoredRecords.object(.item(ItemID(rawValue: rawItemID)), in: context),
              owner.value(forKey: "memoID") as? UUID == memoID else {
            throw StoreError.invalidTransaction
        }
    }

    private func referenceChanges(
        for item: ItemValue,
        previous: ItemValue?,
        inserted: Bool
    ) -> ItemReferenceChanges {
        if inserted { return .all }
        guard let previous else { return .none }
        return ItemReferenceChanges(
            capture: previous.captureID != item.captureID,
            memo: previous.memoID != item.memoID,
            collection: previous.collectionID != item.collectionID
        )
    }

    private func validateItem(
        _ item: ItemValue,
        requiring changes: ItemReferenceChanges,
        in context: NSManagedObjectContext
    ) throws {
        if item.historyEligible { guard item.captureID != nil else { throw StoreError.invalidTransaction } }
        if let capture = item.captureID {
            if changes.capture,
               try StoredRecords.object(.capture(capture), in: context) == nil {
                throw StoreError.invalidTransaction
            }
            if item.historyEligible, try hasFacetMarker(itemID: item.id, facet: .history, id: capture, in: context) {
                throw StoreError.invalidTransaction
            }
        }
        if let memoID = item.memoID {
            guard !(try hasFacetMarker(itemID: item.id, facet: .memo, id: memoID, in: context)) else {
                throw StoreError.invalidTransaction
            }
            if let memo = try StoredRecords.object(.memo(memoID), in: context) {
                guard memo.value(forKey: "itemID") as? UUID == item.id.rawValue,
                      let rawMode = memo.value(forKey: "bodyMode") as? String,
                      let mode = MemoBodyMode(rawValue: rawMode) else {
                    throw StoreError.invalidTransaction
                }
                if mode == .inheritedCapture, item.captureID == nil {
                    throw StoreError.invalidTransaction
                }
            } else if changes.memo {
                throw StoreError.invalidTransaction
            }
        }
        if let collection = item.collectionID {
            guard item.memoID != nil else { throw StoreError.invalidTransaction }
            if changes.collection,
               try StoredRecords.object(.collection(collection), in: context) == nil {
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

private struct ItemReferenceChanges {
    let capture: Bool
    let memo: Bool
    let collection: Bool

    static let all = ItemReferenceChanges(capture: true, memo: true, collection: true)
    static let none = ItemReferenceChanges(capture: false, memo: false, collection: false)

    var any: Bool {
        capture || memo || collection
    }
}

private struct PurgeCaptureFingerprint: Encodable {
    let id: UUID
    let digest: Data
    let representations: [PurgeRepresentationFingerprint]
}

private struct PurgeRepresentationFingerprint: Encodable {
    let id: UUID
    let snapshotID: UUID
    let itemIndex: Int
    let representationIndex: Int
    let typeIdentifierBytes: Data
    let storage: RepresentationStorage
    let byteCount: Int64
    let digest: Data

    init(_ value: RepresentationValue) {
        id = value.id
        snapshotID = value.snapshotID
        itemIndex = value.itemIndex
        representationIndex = value.representationIndex
        typeIdentifierBytes = Data(value.typeIdentifier.utf8)
        storage = value.storage
        byteCount = value.byteCount
        digest = value.digest
    }
}
