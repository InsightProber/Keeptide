import CoreData
import Foundation

// The container is fixed after initialization. Mutable state and every managed
// object are confined to writer.perform; only Sendable values leave that queue.
final class PersistenceController: @unchecked Sendable {
    let container: NSPersistentContainer
    let writer: NSManagedObjectContext
    let contentStore: NSPersistentStore
    let localStore: NSPersistentStore
    let runtime = StoreRuntime()

    static func loadModel() throws -> NSManagedObjectModel {
        guard let url = Bundle(for: PersistenceController.self).url(forResource: "Keeptide", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else { throw StoreError.invalidModel }
        return model
    }

    init(directory: URL, model: NSManagedObjectModel? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        container = NSPersistentContainer(name: "Keeptide", managedObjectModel: try model ?? Self.loadModel())
        let coordinator = container.persistentStoreCoordinator
        let common: [AnyHashable: Any] = [NSMigratePersistentStoresAutomaticallyOption: true,
                                         NSInferMappingModelAutomaticallyOption: true]
        var contentOptions = common
        contentOptions[NSPersistentHistoryTrackingKey] = true
        contentStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType,
            configurationName: "CloudContent", at: directory.appendingPathComponent("Content.sqlite"), options: contentOptions)
        do {
            localStore = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType,
                configurationName: "LocalState", at: directory.appendingPathComponent("Local.sqlite"), options: common)
        } catch {
            try? coordinator.remove(contentStore)
            throw error
        }
        writer = container.newBackgroundContext()
        writer.undoManager = nil
        writer.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        try writer.performAndWait {
            guard let id = UUID(uuidString: contentStore.identifier),
                  NSEntityDescription.entity(forEntityName: "StoreIdentity", in: writer) != nil else {
                throw StoreError.invalidModel
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: "StoreIdentity")
            request.fetchLimit = 2
            let identities = try writer.fetch(request)
            guard identities.count <= 1 else { throw StoreError.corruptStore }
            if let object = identities.first {
                guard object.value(forKey: "id") as? UUID == id,
                      let generation = object.value(forKey: "generation") as? UUID,
                      let rawState = object.value(forKey: "safetyState") as? String,
                      let safety = StoreSafetyState(rawValue: rawState) else { throw StoreError.corruptStore }
                runtime.identity = StoreIdentity(storeID: id, generation: generation)
                runtime.safety = safety
            } else {
                let identity = StoreIdentity(storeID: id, generation: UUID())
                let object = NSEntityDescription.insertNewObject(forEntityName: "StoreIdentity", into: writer)
                object.setValue(id, forKey: "id")
                object.setValue(identity.generation, forKey: "generation")
                object.setValue(StoreSafetyState.localReady.rawValue, forKey: "safetyState")
                try writer.save()
                runtime.identity = identity
            }
            writer.reset()
        }
    }

    func perform<T: Sendable>(_ work: @escaping @Sendable (NSManagedObjectContext) throws -> T) async throws -> T {
        try await writer.perform {
            guard !self.runtime.closed else { throw StoreError.closed }
            return try work(self.writer)
        }
    }

    func identity() async throws -> StoreIdentity {
        try await perform { _ in self.runtime.identity }
    }

    func close() async throws {
        try await writer.perform {
            guard !self.runtime.closed else { return }
            self.runtime.invalidateLeases()
            self.writer.reset()
            for store in self.container.persistentStoreCoordinator.persistentStores {
                try self.container.persistentStoreCoordinator.remove(store)
            }
            self.runtime.closed = true
        }
    }
}

final class StoreRuntime {
    var identity = StoreIdentity(storeID: UUID(), generation: UUID())
    var safety: StoreSafetyState = .localReady
    var closed = false
    var leases: [UUID: PinnedSnapshot] = [:]

    func invalidateLeases() {
        for lease in leases.values {
            let context = lease.context
            context.performAndWait { context.reset() }
        }
        leases.removeAll()
    }

    func expireLeases() {
        let now = ContinuousClock().now
        for id in leases.filter({ $0.value.deadline <= now }).keys {
            if let expired = leases.removeValue(forKey: id) {
                let context = expired.context
                context.performAndWait { context.reset() }
            }
        }
    }
}

final class PinnedSnapshot {
    let lease: SnapshotLease
    let context: NSManagedObjectContext
    let refs: [ContentRef]
    let protectedCaptures: Set<UUID>
    let pageSize: Int
    let deadline: ContinuousClock.Instant
    var cursors: [Data: Int] = [:]

    init(lease: SnapshotLease, context: NSManagedObjectContext, refs: [ContentRef],
         protectedCaptures: Set<UUID>, pageSize: Int, lifetime: TimeInterval) {
        self.lease = lease; self.context = context; self.refs = refs
        self.protectedCaptures = protectedCaptures; self.pageSize = pageSize
        deadline = ContinuousClock().now.advanced(by: .seconds(lifetime))
    }
}
