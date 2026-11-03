import CoreData
import Foundation

struct CollectionDraft: Equatable, Sendable {
    var id: CollectionID
    var name: String
    var color: String

    init(id: CollectionID = CollectionID(), name: String, color: String) {
        self.id = id; self.name = name; self.color = color
    }
}

struct CollectionSnapshot: Equatable, Sendable {
    var value: CollectionValue
    var fingerprint: Data
}

struct CollectionUndoRecord: Equatable, Sendable {
    var previousValue: RecordValue
    var postMutationFingerprint: Data
}

struct CollectionUndoToken: Equatable, Sendable {
    var identity: StoreIdentity
    var records: [CollectionUndoRecord]
    var memberships: [CollectionID: Data] = [:]
}

struct CollectionChange: Equatable, Sendable {
    var affectedItems: [ItemID]
    var undoToken: CollectionUndoToken
}

enum CollectionServiceError: Error, Equatable {
    case invalidContent
    case deletedCollection
}

struct CollectionService: Sendable {
    let controller: PersistenceController

    func list(expecting expectedIdentity: StoreIdentity? = nil) async throws -> [CollectionSnapshot] {
        let identity = try await operationIdentity(expectedIdentity)
        let snapshots = try await controller.perform { context in
            context.reset(); defer { context.reset() }
            guard controller.runtime.identity == identity else { throw StoreError.preconditionFailed }
            let request = NSFetchRequest<NSManagedObject>(entityName: "Collection")
            request.predicate = NSPredicate(format: "deletedAt == nil")
            return try context.fetch(request).map { object in
                guard let rawID = object.value(forKey: "id") as? UUID else { throw StoreError.corruptStore }
                let key = RecordKey.collection(CollectionID(rawValue: rawID))
                guard case .collection(let value) = try StoredRecords.value(key, in: context) else {
                    throw StoreError.corruptStore
                }
                return CollectionSnapshot(value: value, fingerprint: try StoredRecords.fingerprint(key, in: context))
            }.sorted(by: Self.collectionOrder)
        }
        try await validateIdentity(identity)
        return snapshots
    }

    func create(_ draft: CollectionDraft, expecting expectedIdentity: StoreIdentity? = nil) async throws -> CollectionSnapshot {
        let identity = try await operationIdentity(expectedIdentity)
        if let existing = try await existingCollection(draft.id, identity: identity) {
            return try await equivalentRetry(draft, existing: existing, identity: identity)
        }
        let order = (try await list(expecting: identity).map(\.value.sortOrder).max() ?? -1) + 1
        let value = CollectionValue(id: draft.id, name: draft.name, color: draft.color, sortOrder: order)
        let key = RecordKey.collection(draft.id)
        var transaction = StoreTransaction(identity: identity, preconditions: [.absent(key)], mutations: [.insert(.collection(value))])
        transaction.receiptFingerprintKeys = [key]
        do {
            let receipt = try await writer.commit(transaction)
            return CollectionSnapshot(value: value, fingerprint: receipt.postMutationFingerprints[key]!)
        } catch StoreError.preconditionFailed {
            guard let existing = try await existingCollection(draft.id, identity: identity) else { throw StoreError.preconditionFailed }
            return try await equivalentRetry(draft, existing: existing, identity: identity)
        }
    }

    func edit(_ collection: CollectionSnapshot, name: String, color: String,
              expecting expectedIdentity: StoreIdentity? = nil) async throws -> CollectionSnapshot {
        let identity = try await operationIdentity(expectedIdentity)
        try requireActive(collection)
        var value = collection.value; value.name = name; value.color = color
        if value == collection.value { try await validate(collection, identity: identity); return collection }
        let key = RecordKey.collection(value.id)
        var transaction = StoreTransaction(identity: identity,
            preconditions: [.recordUnchanged(key, fingerprint: collection.fingerprint)],
            mutations: [.update(.collection(value))])
        transaction.receiptFingerprintKeys = [key]
        let receipt = try await writer.commit(transaction)
        return CollectionSnapshot(value: value, fingerprint: receipt.postMutationFingerprints[key]!)
    }

    func reorder(_ collections: [CollectionSnapshot],
                 expecting expectedIdentity: StoreIdentity? = nil) async throws -> [CollectionSnapshot] {
        let identity = try await operationIdentity(expectedIdentity)
        guard Set(collections.map(\.value.id)).count == collections.count else { throw StoreError.invalidTransaction }
        for value in collections { try requireActive(value) }
        let current = try await list(expecting: identity)
        guard Set(current.map(\.value.id)) == Set(collections.map(\.value.id)) else { throw StoreError.preconditionFailed }
        let currentFingerprints = Dictionary(uniqueKeysWithValues: current.map { ($0.value.id, $0.fingerprint) })
        guard collections.allSatisfy({ currentFingerprints[$0.value.id] == $0.fingerprint }) else {
            throw StoreError.preconditionFailed
        }
        let values = collections.enumerated().map { index, snapshot -> CollectionValue in
            var value = snapshot.value; value.sortOrder = Double(index); return value
        }
        let changed = zip(values, collections).filter { $0.0 != $0.1.value }
        guard !changed.isEmpty else { try await validateIdentity(identity); return collections }
        let keys = Set(changed.map { RecordKey.collection($0.0.id) })
        var transaction = StoreTransaction(identity: identity,
            preconditions: collections.map { .recordUnchanged(.collection($0.value.id), fingerprint: $0.fingerprint) },
            mutations: changed.map { .update(.collection($0.0)) })
        transaction.receiptFingerprintKeys = keys
        let receipt = try await writer.commit(transaction)
        return zip(values, collections).map { value, old in
            let key = RecordKey.collection(value.id)
            return CollectionSnapshot(value: value, fingerprint: receipt.postMutationFingerprints[key] ?? old.fingerprint)
        }
    }

    func move(_ refs: [ContentRef], to collection: CollectionSnapshot?,
              expecting expectedIdentity: StoreIdentity? = nil) async throws -> CollectionChange {
        let identity = try await operationIdentity(expectedIdentity)
        let target = try await validatedTarget(collection, identity: identity)
        let members = try await memoMembers(refs, identity: identity)
        let changed = members.filter { $0.item.collectionID != target?.value.id }
        let values = changed.map { member -> ItemValue in var item = member.item; item.collectionID = target?.value.id; return item }
        return try await commitItems(identity: identity, all: members, changed: changed, values: values, target: target)
    }

    func setFavorite(_ refs: [ContentRef], isFavorite: Bool,
                     expecting expectedIdentity: StoreIdentity? = nil) async throws -> CollectionChange {
        let identity = try await operationIdentity(expectedIdentity)
        let members = try await memoMembers(refs, identity: identity)
        let changed = members.filter { $0.item.isFavorite != isFavorite }
        let values = changed.map { member -> ItemValue in var item = member.item; item.isFavorite = isFavorite; return item }
        return try await commitItems(identity: identity, all: members, changed: changed, values: values, target: nil)
    }

    func delete(_ collection: CollectionSnapshot,
                expecting expectedIdentity: StoreIdentity? = nil) async throws -> CollectionChange {
        let identity = try await operationIdentity(expectedIdentity)
        try requireActive(collection)
        let membership = try await ContentRepository(controller: controller).collectionMembershipSnapshot(collection.value.id)
        let emptyFingerprint = try StoredRecords.canonicalDigest([String]())
        var deleted = collection.value; deleted.deletedAt = Date()
        var previous = [RecordState(value: .collection(collection.value), fingerprint: collection.fingerprint)]
        var mutations: [StoreMutation] = [.update(.collection(deleted))]
        var conditions: [StorePrecondition] = [
            .recordUnchanged(.collection(collection.value.id), fingerprint: collection.fingerprint),
            .collectionMembership(collection.value.id, fingerprint: membership.fingerprint),
        ]
        var keys: Set<RecordKey> = [.collection(collection.value.id)]
        var affected: [ItemID] = []
        for state in membership.members {
            guard case .item(var item) = state.value, item.collectionID == collection.value.id else { throw StoreError.corruptStore }
            previous.append(state); conditions.append(.recordUnchanged(.item(item.id), fingerprint: state.fingerprint))
            item.collectionID = nil; mutations.append(.update(.item(item))); keys.insert(.item(item.id)); affected.append(item.id)
        }
        var transaction = StoreTransaction(identity: identity, preconditions: conditions, mutations: mutations)
        transaction.receiptFingerprintKeys = keys
        let receipt = try await writer.commit(transaction)
        return CollectionChange(affectedItems: Self.sorted(affected), undoToken: CollectionUndoToken(
            identity: identity, records: undoRecords(previous, receipt: receipt),
            memberships: [collection.value.id: emptyFingerprint]))
    }

    func undo(_ token: CollectionUndoToken) async throws -> CollectionChange {
        let identity = try await operationIdentity(token.identity)
        guard Set(token.records.map(\.previousValue.key)).count == token.records.count else { throw StoreError.invalidToken }
        if token.records.isEmpty { try await validateIdentity(identity); return CollectionChange(affectedItems: [], undoToken: token) }
        let repository = ContentRepository(controller: controller)
        var inverse: [RecordState] = []
        for record in token.records {
            switch record.previousValue.key { case .item, .collection: break; default: throw StoreError.invalidToken }
            inverse.append(try await repository.recordState(record.previousValue.key))
        }
        let inverseMemberships = try await resultingMemberships(after: token.records.map(\.previousValue), fencedBy: token.memberships, repository: repository)
        let conditions: [StorePrecondition] = token.records.map {
            .recordUnchanged($0.previousValue.key, fingerprint: $0.postMutationFingerprint)
        } + token.memberships.map {
            StorePrecondition.collectionMembership($0.key, fingerprint: $0.value)
        }
        var transaction = StoreTransaction(identity: identity, preconditions: conditions,
            mutations: token.records.map { .update($0.previousValue) })
        transaction.receiptFingerprintKeys = Set(token.records.map(\.previousValue.key))
        let receipt = try await writer.commit(transaction)
        let affected = token.records.compactMap { if case .item(let item) = $0.previousValue { item.id } else { nil } }
        return CollectionChange(affectedItems: Self.sorted(affected), undoToken: CollectionUndoToken(
            identity: identity, records: undoRecords(inverse, receipt: receipt), memberships: inverseMemberships))
    }

    private var writer: WriteCoordinator { WriteCoordinator(controller: controller) }

    private func commitItems(identity: StoreIdentity, all: [MemoMember], changed: [MemoMember],
                             values: [ItemValue], target: CollectionSnapshot?) async throws -> CollectionChange {
        var conditions: [StorePrecondition] = all.flatMap {
            [
                StorePrecondition.recordUnchanged(.item($0.item.id), fingerprint: $0.state.fingerprint),
                StorePrecondition.contentVersion($0.ref),
            ]
        }
        if let target { conditions.append(.recordUnchanged(.collection(target.value.id), fingerprint: target.fingerprint)) }
        guard !values.isEmpty else {
            try await writer.validate(StoreTransaction(
                identity: identity,
                preconditions: conditions,
                mutations: []
            ))
            return CollectionChange(
                affectedItems: [],
                undoToken: CollectionUndoToken(identity: identity, records: [])
            )
        }
        let keys = Set(values.map { RecordKey.item($0.id) })
        var transaction = StoreTransaction(identity: identity, preconditions: conditions, mutations: values.map { .update(.item($0)) })
        transaction.receiptFingerprintKeys = keys
        let receipt = try await writer.commit(transaction)
        return CollectionChange(affectedItems: Self.sorted(values.map(\.id)), undoToken: CollectionUndoToken(
            identity: identity, records: undoRecords(changed.map(\.state), receipt: receipt)))
    }

    private func memoMembers(_ refs: [ContentRef], identity: StoreIdentity) async throws -> [MemoMember] {
        guard !refs.isEmpty, Set(refs.map(\.itemID)).count == refs.count else { throw StoreError.invalidTransaction }
        let repository = ContentRepository(controller: controller)
        var result: [MemoMember] = []
        for ref in refs {
            guard ref.facet == .memo else { throw CollectionServiceError.invalidContent }
            let state = try await repository.recordState(.item(ref.itemID))
            guard case .item(let item) = state.value, item.deletedAt == nil, let memoID = item.memoID else {
                throw CollectionServiceError.invalidContent
            }
            let memoState = try await repository.recordState(.memo(memoID))
            guard case .memo(let memo) = memoState.value, memo.itemID == item.id, memo.deletedAt == nil else {
                throw CollectionServiceError.invalidContent
            }
            guard try await repository.read(ref).integrity == .complete else { throw StoreError.staleReference }
            result.append(MemoMember(ref: ref, item: item, state: state))
        }
        try await validateIdentity(identity); return result
    }

    private func validatedTarget(_ target: CollectionSnapshot?, identity: StoreIdentity) async throws -> CollectionSnapshot? {
        guard let target else { return nil }; try requireActive(target)
        do {
            let state = try await ContentRepository(controller: controller).recordState(.collection(target.value.id))
            guard case .collection(let value) = state.value, value.deletedAt == nil else { throw CollectionServiceError.deletedCollection }
        } catch StoreError.notFound { throw CollectionServiceError.deletedCollection }
        try await validateIdentity(identity); return target
    }

    private func validate(_ snapshot: CollectionSnapshot, identity: StoreIdentity) async throws {
        let state = try await ContentRepository(controller: controller).recordState(.collection(snapshot.value.id))
        guard state.fingerprint == snapshot.fingerprint, case .collection(let value) = state.value, value.deletedAt == nil else {
            throw StoreError.preconditionFailed
        }
        try await validateIdentity(identity)
    }

    private func existingCollection(_ id: CollectionID, identity: StoreIdentity) async throws -> CollectionSnapshot? {
        do {
            let state = try await ContentRepository(controller: controller).recordState(.collection(id))
            guard case .collection(let value) = state.value else { throw StoreError.corruptStore }
            try await validateIdentity(identity); return CollectionSnapshot(value: value, fingerprint: state.fingerprint)
        } catch StoreError.notFound { try await validateIdentity(identity); return nil }
    }

    private func equivalentRetry(_ draft: CollectionDraft, existing: CollectionSnapshot,
                                 identity: StoreIdentity) async throws -> CollectionSnapshot {
        guard existing.value.deletedAt == nil, existing.value.name == draft.name, existing.value.color == draft.color else {
            throw StoreError.preconditionFailed
        }
        try await validateIdentity(identity); return existing
    }

    private func resultingMemberships(after values: [RecordValue], fencedBy memberships: [CollectionID: Data],
                                      repository: ContentRepository) async throws -> [CollectionID: Data] {
        var members: [CollectionID: Set<ItemID>] = [:]
        for (id, expected) in memberships {
            let snapshot = try await repository.collectionMembershipSnapshot(id)
            guard snapshot.fingerprint == expected else { throw StoreError.preconditionFailed }
            members[id] = Set(snapshot.members.compactMap { if case .item(let item) = $0.value { item.id } else { nil } })
        }
        for value in values {
            guard case .item(let item) = value else { continue }
            for id in memberships.keys { members[id]?.remove(item.id) }
            if let id = item.collectionID, memberships[id] != nil { members[id]?.insert(item.id) }
        }
        return try Dictionary(uniqueKeysWithValues: members.map { id, ids in
            (id, try StoredRecords.canonicalDigest(ids.map(\.rawValue.uuidString).sorted()))
        })
    }

    private func undoRecords(_ states: [RecordState], receipt: StoreReceipt) -> [CollectionUndoRecord] {
        states.map { CollectionUndoRecord(previousValue: $0.value,
            postMutationFingerprint: receipt.postMutationFingerprints[$0.value.key]!) }
    }

    private func requireActive(_ snapshot: CollectionSnapshot) throws {
        guard snapshot.value.deletedAt == nil else { throw CollectionServiceError.deletedCollection }
    }

    private func operationIdentity(_ expected: StoreIdentity?) async throws -> StoreIdentity {
        let current = try await controller.identity()
        guard expected == nil || expected == current else { throw StoreError.preconditionFailed }
        return expected ?? current
    }

    private func validateIdentity(_ expected: StoreIdentity) async throws {
        guard try await controller.identity() == expected else { throw StoreError.preconditionFailed }
    }

    private static func collectionOrder(_ lhs: CollectionSnapshot, _ rhs: CollectionSnapshot) -> Bool {
        lhs.value.sortOrder == rhs.value.sortOrder
            ? lhs.value.id.rawValue.uuidString < rhs.value.id.rawValue.uuidString
            : lhs.value.sortOrder < rhs.value.sortOrder
    }

    private static func sorted(_ ids: [ItemID]) -> [ItemID] {
        ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }
}

private struct MemoMember: Sendable {
    let ref: ContentRef
    let item: ItemValue
    let state: RecordState
}
