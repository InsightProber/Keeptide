import CoreData
import Foundation

/// Moves each snippet's collection from where V4 kept it, the item's `collectionID` attribute, into the V5
/// `collection` relationship, so the attribute can be retired.
///
/// Reads take both until then (`StoredRecords.memberships(of:)`), so a list, a count or the search index shows the
/// same collections before, during and after a run, whichever of them comes first. Each batch commits on its own
/// through `WriteCoordinator`, under the store's write rules and with every item's fingerprint as a precondition: a
/// run that stops resumes where it left off, and running it again does nothing.
struct CollectionMembershipBackfill: Sendable {
    static let batchSize = 200

    struct Outcome: Equatable, Sendable {
        /// Items whose collection is now in the relationship.
        var moved = 0
        /// Of those, items whose old collection was dropped instead: it no longer existed or was deleted, or the
        /// item had no snippet to belong to it.
        var dropped = 0
        /// Items left as they were, because the store refused their change. Reads still see their collection, and
        /// a later run tries them again.
        var skipped = 0
    }

    let controller: PersistenceController

    /// Whether any item still keeps its collection the V4 way.
    func isNeeded() async throws -> Bool {
        try await controller.perform { context in
            context.reset(); defer { context.reset() }
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "LibraryItem")
            request.predicate = NSPredicate(format: "collectionID != nil")
            request.resultType = .managedObjectIDResultType
            request.fetchLimit = 1
            return try !context.fetch(request).isEmpty
        }
    }

    /// Runs until no item it can change keeps its collection the V4 way. It throws, leaving the rest for a later
    /// run, when the store stops taking writes: it closed or changed identity, or maintenance or recovery owns it.
    func run() async throws -> Outcome {
        let identity = try await controller.identity()
        var outcome = Outcome()
        var done = Set<UUID>()
        var skipped = Set<UUID>()
        while true {
            try Task.checkCancellation()
            let batch = try await nextBatch(excluding: skipped)
            guard !batch.isEmpty else { return outcome }
            // An item that kept its old collection after its own commit would come back for ever.
            guard batch.allSatisfy({ !done.contains($0.item.id.rawValue) }) else { throw StoreError.corruptStore }
            do {
                try await commit(batch, identity: identity)
                record(batch, into: &outcome, done: &done)
            } catch let error as StoreError where Self.isItemFailure(error) {
                // One item changed meanwhile, or cannot be written: the others still go, each on its own.
                guard try await controller.identity() == identity else { throw StoreError.preconditionFailed }
                for entry in batch {
                    do {
                        try await commit([entry], identity: identity)
                        record([entry], into: &outcome, done: &done)
                    } catch let error as StoreError where Self.isItemFailure(error) {
                        skipped.insert(entry.item.id.rawValue)
                        outcome.skipped += 1
                    }
                }
            }
        }
    }

    private struct Entry: Sendable {
        var item: ItemValue
        var fingerprint: Data
        var dropsLegacyCollection: Bool
    }

    /// The next items, in id order, that still keep a collection the V4 way, each with the value it will have.
    private func nextBatch(excluding skipped: Set<UUID>) async throws -> [Entry] {
        try await controller.perform { context in
            context.reset(); defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
            request.predicate = skipped.isEmpty
                ? NSPredicate(format: "collectionID != nil")
                : NSPredicate(format: "collectionID != nil AND NOT (id IN %@)", Array(skipped))
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = Self.batchSize
            return try context.fetch(request).map { object in
                guard let rawID = object.value(forKey: "id") as? UUID,
                      let legacy = object.value(forKey: "collectionID") as? UUID,
                      case .item(var item)? = try StoredRecords.value(.item(ItemID(rawValue: rawID)), in: context) else {
                    throw StoreError.corruptStore
                }
                let fingerprint = try StoredRecords.fingerprint(.item(item.id), in: context)
                let collection = try StoredRecords.object(.collection(CollectionID(rawValue: legacy)), in: context)
                let usable = item.memoID != nil && collection != nil && collection?.value(forKey: "deletedAt") == nil
                if !usable { item.collectionIDs.removeAll { $0.rawValue == legacy } }
                // Only a snippet belongs to collections.
                if item.memoID == nil { item.collectionIDs = [] }
                return Entry(item: item, fingerprint: fingerprint, dropsLegacyCollection: !usable)
            }
        }
    }

    /// Writes each item as it reads now: the write puts its collections in the relationship and clears the
    /// attribute. Its fingerprint stays the same unless an old collection was dropped.
    private func commit(_ batch: [Entry], identity: StoreIdentity) async throws {
        _ = try await WriteCoordinator(controller: controller).commit(StoreTransaction(
            identity: identity,
            preconditions: batch.map { .recordUnchanged(.item($0.item.id), fingerprint: $0.fingerprint) },
            mutations: batch.map { .update(.item($0.item)) }
        ))
    }

    private func record(_ batch: [Entry], into outcome: inout Outcome, done: inout Set<UUID>) {
        for entry in batch {
            done.insert(entry.item.id.rawValue)
            outcome.moved += 1
            if entry.dropsLegacyCollection { outcome.dropped += 1 }
        }
    }

    /// Failures that belong to one item of a batch, not to the store as a whole.
    private static func isItemFailure(_ error: StoreError) -> Bool {
        switch error {
        case .preconditionFailed, .invalidTransaction, .notFound, .contentProtected: true
        default: false
        }
    }
}
