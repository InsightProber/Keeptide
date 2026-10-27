import CoreData
import Darwin
import Foundation

// The container is fixed after initialization. Runtime state stays on the writer
// queue; managed objects stay on their writer or pinned snapshot context queue.
final class PersistenceController: @unchecked Sendable {
    private let directoryOwnership: StoreDirectoryOwnership
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
        directoryOwnership = try StoreDirectoryOwnership(directory: directory)
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
                let hasContent = try (container.managedObjectModel.entities(forConfigurationName: "CloudContent") ?? []).contains { entity in
                    guard let name = entity.name else { throw StoreError.invalidModel }
                    let existing = NSFetchRequest<NSManagedObjectID>(entityName: name)
                    existing.resultType = .managedObjectIDResultType
                    existing.fetchLimit = 1
                    existing.includesPropertyValues = false
                    return try !writer.fetch(existing).isEmpty
                }
                let safety: StoreSafetyState = hasContent ? .quarantined : .localReady
                let identity = StoreIdentity(storeID: id, generation: UUID())
                let object = NSEntityDescription.insertNewObject(forEntityName: "StoreIdentity", into: writer)
                object.setValue(id, forKey: "id")
                object.setValue(identity.generation, forKey: "generation")
                object.setValue(safety.rawValue, forKey: "safetyState")
                try writer.save()
                runtime.identity = identity
                runtime.safety = safety
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
            self.runtime.closeLeases()
            self.writer.reset()
            for store in self.container.persistentStoreCoordinator.persistentStores {
                try self.container.persistentStoreCoordinator.remove(store)
            }
            self.runtime.closed = true
            self.directoryOwnership.release()
        }
    }

    func scheduleExpiration(of snapshot: PinnedSnapshot) {
        let deadline = snapshot.deadline
        snapshot.expirationTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard let self else { return }
            try? await self.perform { _ in self.runtime.expireLeases() }
        }
    }
}

final class StoreRuntime {
    var identity = StoreIdentity(storeID: UUID(), generation: UUID())
    var safety: StoreSafetyState = .localReady
    var closed = false
    var leases: [UUID: PinnedSnapshot] = [:]
    var retiredLeases: [UUID: PinnedSnapshot] = [:]
    var usagePolicy: UsageDeduplicationPolicy?
    var localCaptureIndex: LocalCaptureCandidateIndex?
    private(set) var localCaptureIndexBuildCount = 0

    func recordLocalCaptureIndexBuild() {
        localCaptureIndexBuildCount += 1
    }

    func invalidateLeases() {
        for id in Array(leases.keys) { releaseLease(id) }
    }

    func releaseLease(_ id: UUID) {
        guard let snapshot = leases.removeValue(forKey: id) else { return }
        snapshot.expirationTask?.cancel()
        snapshot.expirationTask = nil
        if snapshot.inFlightPages > 0 {
            retiredLeases[id] = snapshot
        } else {
            let context = snapshot.context
            context.performAndWait { context.reset() }
        }
    }

    func finishPage(_ snapshot: PinnedSnapshot) {
        snapshot.inFlightPages -= 1
        if snapshot.inFlightPages == 0, retiredLeases.removeValue(forKey: snapshot.lease.leaseID) != nil {
            let context = snapshot.context
            context.performAndWait { context.reset() }
        }
    }

    func closeLeases() {
        for snapshot in Array(leases.values) + Array(retiredLeases.values) {
            snapshot.expirationTask?.cancel()
            snapshot.expirationTask = nil
            let context = snapshot.context
            context.performAndWait { context.reset() }
        }
        leases.removeAll()
        retiredLeases.removeAll()
    }

    func expireLeases() {
        let now = ContinuousClock().now
        for id in leases.filter({ $0.value.deadline <= now }).keys {
            releaseLease(id)
        }
    }
}

// Immutable context/refs may cross queues; cursors and lifecycle counters are writer-confined.
final class PinnedSnapshot: @unchecked Sendable {
    let lease: SnapshotLease
    let context: NSManagedObjectContext
    let refs: [ContentRef]
    let protectedCaptures: Set<UUID>
    let pageSize: Int
    let deadline: ContinuousClock.Instant
    var cursors: [Data: Int] = [:]
    var inFlightPages = 0
    var expirationTask: Task<Void, Never>?

    init(lease: SnapshotLease, context: NSManagedObjectContext, refs: [ContentRef],
         protectedCaptures: Set<UUID>, pageSize: Int, lifetime: TimeInterval) {
        self.lease = lease; self.context = context; self.refs = refs
        self.protectedCaptures = protectedCaptures; self.pageSize = pageSize
        deadline = ContinuousClock().now.advanced(by: .seconds(lifetime))
    }
}

// Keep the lock file after close: replacing its inode would allow two owners.
private final class StoreDirectoryOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(directory: URL) throws {
        let path = directory.resolvingSymlinksInPath().appendingPathComponent(".store-owner.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw StoreError.storeInUse }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    func release() {
        lock.withLock {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
        }
    }

    deinit { release() }
}
