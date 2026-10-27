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

    func transition(to state: StoreSafetyState) async throws {
        try await controller.perform { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "StoreIdentity")
            guard let record = try context.fetch(request).first else { throw StoreError.corruptStore }
            let generation = UUID()
            let identity = StoreIdentity(storeID: controller.runtime.identity.storeID, generation: generation)
            do {
                record.setValue(generation, forKey: "generation")
                record.setValue(state.rawValue, forKey: "safetyState")
                try context.save()
                controller.runtime.identity = identity
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
