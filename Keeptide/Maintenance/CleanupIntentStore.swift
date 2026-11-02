import CoreData
import Foundation

enum CleanupTarget: Codable, Equatable, Hashable, Sendable {
    case facet(DeletedFacetIdentity)
    case item(ItemID)

    var itemID: ItemID {
        switch self {
        case .facet(let identity): identity.itemID
        case .item(let itemID): itemID
        }
    }
}

struct CleanupRequest: Sendable {
    let target: CleanupTarget
    let preconditions: [StorePrecondition]
    let mutations: [StoreMutation]

    init(
        target: CleanupTarget,
        preconditions: [StorePrecondition],
        mutations: [StoreMutation]
    ) {
        self.target = target
        self.preconditions = preconditions
        self.mutations = mutations
    }
}

struct CleanupPayloadEvidence: Codable, Equatable, Sendable {
    let identity: CleanupPayloadIdentity
    let cloudRepresentation: RepresentationValue
}

struct CleanupCloudPlan: Codable, Equatable, Sendable {
    let preconditions: [StorePrecondition]
    let mutations: [StoreMutation]

    var expectedRecords: [RecordValue] {
        mutations.compactMap { mutation in
            switch mutation {
            case .insert(let value), .update(let value): value
            case .delete: nil
            }
        }
    }

    var expectedAbsentKeys: [RecordKey] {
        mutations.compactMap { mutation in
            if case .delete(let key) = mutation { return key }
            return nil
        }
    }
}

struct CleanupIntentPayload: Codable, Equatable, Sendable {
    let target: CleanupTarget
    let sourceItem: ItemValue
    let retainsCaptureForInheritedMemo: Bool
    let cloud: CleanupCloudPlan
    let payloads: [CleanupPayloadEvidence]
    let usageFacets: [ContentFacet]
}

struct CleanupIntentRecord: Equatable, Sendable {
    let id: UUID
    let identity: StoreIdentity
    let phase: CleanupIntentPhase
    let payload: CleanupIntentPayload
    let createdAt: Date
    let updatedAt: Date
}

enum CleanupError: Error, Equatable {
    case invalidPlan
    case unsupportedIntent
    case blocked
    case evidenceMismatch
}

struct CleanupIntentStore: Sendable {
    static let schemaVersion: Int64 = 1

    let controller: PersistenceController

    func load(_ id: UUID, expecting identity: StoreIdentity) async throws -> CleanupIntentRecord {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            return try Self.decode(id: id, identity: identity, in: context)
        }
    }

    func pendingIDs(
        expecting identity: StoreIdentity,
        permit: StorePermit,
        afterID: UUID? = nil,
        limit: Int = 128
    ) async throws -> [UUID] {
        guard (1...128).contains(limit) else { throw StoreError.invalidTransaction }
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            let request = NSFetchRequest<NSDictionary>(entityName: "CleanupIntent")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            var predicates = [
                NSPredicate(format: "storeID == %@", identity.storeID as NSUUID),
                NSPredicate(format: "generation == %@", identity.generation as NSUUID),
                Self.nonterminalPhasePredicate,
            ]
            if let afterID {
                predicates.append(NSPredicate(format: "id > %@", afterID as NSUUID))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = limit
            return try context.fetch(request).map { row in
                guard let id = row["id"] as? UUID else { throw StoreError.corruptStore }
                return id
            }
        }
    }

    func block(
        _ id: UUID,
        expecting identity: StoreIdentity,
        permit: StorePermit,
        at now: Date,
        includingCompleted: Bool = false
    ) async throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            do {
                let row = try Self.row(id: id, in: context)
                guard row.value(forKey: "storeID") as? UUID == identity.storeID,
                      row.value(forKey: "generation") as? UUID == identity.generation else {
                    throw StoreError.preconditionFailed
                }
                if includingCompleted
                    || row.value(forKey: "phase") as? String != CleanupIntentPhase.completed.rawValue {
                    row.setValue(CleanupIntentPhase.blocked.rawValue, forKey: "phase")
                    row.setValue(now, forKey: "updatedAt")
                    try context.save()
                }
            } catch {
                context.rollback()
                throw error
            }
        }
    }

}

extension CleanupIntentStore {
    /// Store-wide CloudContent fence. A prepared/cloud-committed (or unknown
    /// nonterminal) intent owns writes for its exact store generation until it
    /// completes or is explicitly blocked.
    static func validateCloudWriteFence(
        _ transaction: StoreTransaction,
        validationOnly: Bool,
        in context: NSManagedObjectContext
    ) throws {
        let rows = try activeRows(identity: transaction.identity, in: context)
        guard !rows.isEmpty else { return }
        let intents: [CleanupIntentRecord]
        do {
            intents = try rows.map { row in
                guard let id = row.value(forKey: "id") as? UUID else { throw StoreError.corruptStore }
                return try decode(id: id, identity: transaction.identity, in: context)
            }
        } catch CleanupError.unsupportedIntent {
            // A newer or unknown durable plan may already have changed CloudContent.
            // Keep it fenced and surface a permanent safe pause instead of retrying.
            throw StoreError.operationDenied
        }
        guard let permit = transaction.permit,
              permit.identity == transaction.identity,
              permit.operation == .maintenance,
              let intent = intents.first(where: { $0.id == transaction.transactionID }) else {
            throw StoreError.maintenanceInProgress
        }
        guard intent.phase == .prepared || intent.phase == .cloudCommitted,
              transaction.preconditions == intent.payload.cloud.preconditions,
              validationOnly
                ? transaction.mutations.isEmpty
                : transaction.mutations == intent.payload.cloud.mutations else {
            throw StoreError.maintenanceInProgress
        }
    }

    static func hasActiveIntent(
        identity: StoreIdentity,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        try !activeRows(identity: identity, in: context).isEmpty
    }

    private static func activeRows(
        identity: StoreIdentity,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "storeID == %@", identity.storeID as NSUUID),
            NSPredicate(format: "generation == %@", identity.generation as NSUUID),
            nonterminalPhasePredicate,
        ])
        request.fetchBatchSize = 128
        request.fetchLimit = 129
        let rows = try context.fetch(request)
        guard rows.count <= 128 else { throw StoreError.operationDenied }
        return rows
    }

    private static var nonterminalPhasePredicate: NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "phase == nil"),
            NSPredicate(
                format: "NOT (phase IN %@)",
                [CleanupIntentPhase.completed.rawValue, CleanupIntentPhase.blocked.rawValue]
            ),
        ])
    }

    static func insert(
        id: UUID,
        identity: StoreIdentity,
        payload: CleanupIntentPayload,
        at now: Date,
        in context: NSManagedObjectContext
    ) throws -> CleanupIntentRecord {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
        guard try !hasActiveIntent(identity: identity, in: context) else {
            throw StoreError.maintenanceInProgress
        }
        let encoded = try canonicalData(payload)
        let existing = NSFetchRequest<NSFetchRequestResult>(entityName: "CleanupIntent")
        existing.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        existing.fetchLimit = 1
        guard try context.count(for: existing) == 0 else { throw StoreError.preconditionFailed }
        let row = NSEntityDescription.insertNewObject(forEntityName: "CleanupIntent", into: context)
        row.setValue(id, forKey: "id")
        row.setValue(schemaVersion, forKey: "schemaVersion")
        row.setValue(identity.storeID, forKey: "storeID")
        row.setValue(identity.generation, forKey: "generation")
        row.setValue(CleanupIntentPhase.prepared.rawValue, forKey: "phase")
        row.setValue(encoded, forKey: "payload")
        row.setValue(now, forKey: "createdAt")
        row.setValue(now, forKey: "updatedAt")
        return CleanupIntentRecord(
            id: id,
            identity: identity,
            phase: .prepared,
            payload: payload,
            createdAt: now,
            updatedAt: now
        )
    }

    static func decode(
        id: UUID,
        identity: StoreIdentity,
        in context: NSManagedObjectContext
    ) throws -> CleanupIntentRecord {
        let row = try row(id: id, in: context)
        guard row.value(forKey: "id") as? UUID == id,
              row.value(forKey: "storeID") as? UUID == identity.storeID,
              row.value(forKey: "generation") as? UUID == identity.generation else {
            throw StoreError.preconditionFailed
        }
        guard (row.value(forKey: "schemaVersion") as? NSNumber)?.int64Value == schemaVersion,
              let rawPhase = row.value(forKey: "phase") as? String,
              let phase = CleanupIntentPhase(rawValue: rawPhase),
              let bytes = row.value(forKey: "payload") as? Data,
              let createdAt = row.value(forKey: "createdAt") as? Date,
              let updatedAt = row.value(forKey: "updatedAt") as? Date,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              let payload = try? JSONDecoder().decode(CleanupIntentPayload.self, from: bytes) else {
            throw CleanupError.unsupportedIntent
        }
        return CleanupIntentRecord(
            id: id,
            identity: identity,
            phase: phase,
            payload: payload,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func stagePhase(
        id: UUID,
        identity: StoreIdentity,
        from expected: Set<CleanupIntentPhase>,
        to phase: CleanupIntentPhase,
        at now: Date,
        in context: NSManagedObjectContext
    ) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
        let row = try row(id: id, in: context)
        guard row.value(forKey: "storeID") as? UUID == identity.storeID,
              row.value(forKey: "generation") as? UUID == identity.generation,
              (row.value(forKey: "schemaVersion") as? NSNumber)?.int64Value == schemaVersion,
              let raw = row.value(forKey: "phase") as? String,
              let current = CleanupIntentPhase(rawValue: raw),
              expected.contains(current) else {
            throw StoreError.preconditionFailed
        }
        row.setValue(phase.rawValue, forKey: "phase")
        row.setValue(now, forKey: "updatedAt")
    }

    static func row(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CleanupIntent")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 2
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw StoreError.corruptStore }
        guard let row = rows.first else { throw StoreError.notFound }
        return row
    }

    static func canonicalData(_ payload: CleanupIntentPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}
