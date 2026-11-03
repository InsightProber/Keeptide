import CoreData
import Foundation

struct RawRecoveryPlanRecord: Equatable, Sendable {
    let id: UUID
    let identity: StoreIdentity
    let phase: RawRecoveryPlanPhase
    let evidence: Data
    let createdAt: Date
    let updatedAt: Date
}

enum RawRecoveryError: Error, Equatable {
    case unsupportedPlan
    case capacityExceeded
    case invalidTransition
}

struct RawRecoveryStore: Sendable {
    static let schemaVersion: Int64 = 1
    static let maximumEvidenceByteCount = 1_048_576
    static let maximumPlanCount = 128

    let controller: PersistenceController

    func record(
        evidence: Data,
        expecting identity: StoreIdentity,
        at now: Date = Date()
    ) async throws -> RecoveryPermit {
        guard !evidence.isEmpty,
              evidence.count <= Self.maximumEvidenceByteCount,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw StoreError.invalidTransaction
        }
        let planID = UUID()
        let controller = controller
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            guard controller.runtime.safety != .suspended else { throw StoreError.operationDenied }
            do {
                let count = NSFetchRequest<NSFetchRequestResult>(entityName: "RawRecoveryPlan")
                guard try context.count(for: count) < Self.maximumPlanCount else {
                    throw RawRecoveryError.capacityExceeded
                }
                let row = NSEntityDescription.insertNewObject(forEntityName: "RawRecoveryPlan", into: context)
                row.setValue(planID, forKey: "id")
                row.setValue(Self.schemaVersion, forKey: "schemaVersion")
                row.setValue(identity.storeID, forKey: "storeID")
                row.setValue(identity.generation, forKey: "generation")
                row.setValue(RawRecoveryPlanPhase.prepared.rawValue, forKey: "phase")
                row.setValue(evidence, forKey: "payload")
                row.setValue(now, forKey: "createdAt")
                row.setValue(now, forKey: "updatedAt")
                try context.save()
                return RecoveryPermit(planID: planID, identity: identity)
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func load(_ permit: RecoveryPermit) async throws -> RawRecoveryPlanRecord {
        do {
            return try await controller.perform { context in
                context.reset()
                defer { context.reset() }
                guard permit.identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
                return try Self.decode(permit, in: context)
            }
        } catch RawRecoveryError.unsupportedPlan {
            try await markUnsupportedBlocked(permit, at: Date())
            throw RawRecoveryError.unsupportedPlan
        }
    }

    func transition(
        _ permit: RecoveryPermit,
        to next: RawRecoveryPlanPhase,
        at now: Date = Date()
    ) async throws -> RawRecoveryPlanRecord {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
        let controller = controller
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard permit.identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            guard controller.runtime.safety != .suspended else { throw StoreError.operationDenied }
            do {
                let current = try Self.decode(permit, in: context)
                guard Self.allows(current.phase, next) else { throw RawRecoveryError.invalidTransition }
                if current.phase != next {
                    let row = try Self.row(id: permit.planID, in: context)
                    row.setValue(next.rawValue, forKey: "phase")
                    row.setValue(now, forKey: "updatedAt")
                    try context.save()
                }
            } catch {
                context.rollback()
                throw error
            }
        }
        return try await load(permit)
    }
}

private extension RawRecoveryStore {
    static func decode(
        _ permit: RecoveryPermit,
        in context: NSManagedObjectContext
    ) throws -> RawRecoveryPlanRecord {
        let row = try row(id: permit.planID, in: context)
        guard row.value(forKey: "id") as? UUID == permit.planID,
              row.value(forKey: "storeID") as? UUID == permit.identity.storeID,
              row.value(forKey: "generation") as? UUID == permit.identity.generation else {
            throw StoreError.preconditionFailed
        }
        guard (row.value(forKey: "schemaVersion") as? NSNumber)?.int64Value == schemaVersion,
              let rawPhase = row.value(forKey: "phase") as? String,
              let phase = RawRecoveryPlanPhase(rawValue: rawPhase),
              let evidence = row.value(forKey: "payload") as? Data,
              let createdAt = row.value(forKey: "createdAt") as? Date,
              let updatedAt = row.value(forKey: "updatedAt") as? Date,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RawRecoveryError.unsupportedPlan
        }
        return RawRecoveryPlanRecord(
            id: permit.planID,
            identity: permit.identity,
            phase: phase,
            evidence: evidence,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func row(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject {
        let request = NSFetchRequest<NSManagedObject>(entityName: "RawRecoveryPlan")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 2
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw StoreError.corruptStore }
        guard let row = rows.first else { throw StoreError.notFound }
        return row
    }

    static func allows(_ current: RawRecoveryPlanPhase, _ next: RawRecoveryPlanPhase) -> Bool {
        if current == next { return true }
        switch (current, next) {
        case (.prepared, .reconciling), (.prepared, .blocked),
             (.reconciling, .completed), (.reconciling, .blocked):
            return true
        default:
            return false
        }
    }

    func markUnsupportedBlocked(_ permit: RecoveryPermit, at now: Date) async throws {
        let controller = controller
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard permit.identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            do {
                let row = try Self.row(id: permit.planID, in: context)
                guard row.value(forKey: "storeID") as? UUID == permit.identity.storeID,
                      row.value(forKey: "generation") as? UUID == permit.identity.generation else {
                    throw StoreError.preconditionFailed
                }
                // Preserve the opaque payload exactly; only the top-level phase is fenced.
                row.setValue(RawRecoveryPlanPhase.blocked.rawValue, forKey: "phase")
                row.setValue(now, forKey: "updatedAt")
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }
}
