import CoreData
import Foundation

struct StoreSafetyGate: Sendable {
    let controller: PersistenceController

    func permit(_ operation: StoreOperation) async throws -> StorePermit {
        try await controller.perform { _ in
            try Self.validate(operation, runtime: controller.runtime)
            return StorePermit(identity: controller.runtime.identity, operation: operation)
        }
    }

    func transition(to state: StoreSafetyState, expecting identity: StoreIdentity) async throws {
        try await controller.perform { context in
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            context.reset()
            defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "StoreIdentity")
            request.fetchLimit = 2
            let records = try context.fetch(request)
            guard records.count == 1, let record = records.first,
                  record.value(forKey: "id") as? UUID == identity.storeID,
                  record.value(forKey: "generation") as? UUID == identity.generation,
                  record.value(forKey: "safetyState") as? String == controller.runtime.safety.rawValue else {
                throw StoreError.corruptStore
            }
            guard state != controller.runtime.safety else { return }
            // A suspended binding must pass through quarantine before activation.
            if controller.runtime.safety == .suspended, state != .quarantined { throw StoreError.operationDenied }
            if state == .localReady { throw StoreError.operationDenied }
            let generation = UUID()
            let next = StoreIdentity(storeID: identity.storeID, generation: generation)
            do {
                record.setValue(generation, forKey: "generation")
                record.setValue(state.rawValue, forKey: "safetyState")
                try context.save()
                controller.runtime.identity = next
                controller.runtime.safety = state
                controller.runtime.invalidateLeases()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    static func validate(_ operation: StoreOperation, runtime: StoreRuntime, permit: StorePermit? = nil) throws {
        if let permit {
            guard permit.identity == runtime.identity, permit.operation == operation else { throw StoreError.preconditionFailed }
        }
        guard operation == .projection || runtime.safety == .localReady || runtime.safety == .active else {
            throw StoreError.operationDenied
        }
    }
}
