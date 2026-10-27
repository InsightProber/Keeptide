import CoreData
import Foundation

struct LocalFileAccess: Codable, Equatable, Sendable {
    var id: UUID
    var snapshotID: UUID
    var bytes: Data
    var bookmark: Data?
    var localPath: String?
}

final class FileAccessStore: @unchecked Sendable {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    func put(_ value: LocalFileAccess, expecting identity: StoreIdentity) async throws {
        guard value.localPath?.utf8.contains(0) != true else {
            throw StoreError.invalidTransaction
        }
        let controller = controller
        try await controller.perform { context in
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.write, runtime: controller.runtime)
            do {
                let request = Self.request(representationID: value.id)
                let matches = try context.fetch(request)
                guard matches.count <= 1 else { throw StoreError.corruptStore }
                for existing in matches {
                    guard let snapshotID = existing.value(forKey: "snapshotID") as? UUID else {
                        throw StoreError.corruptStore
                    }
                    guard snapshotID == value.snapshotID else {
                        throw StoreError.preconditionFailed
                    }
                }
                let committed = try Self.committedRepresentation(id: value.id, in: context)
                if let committed {
                    guard committed.snapshotID == value.snapshotID,
                          committed.byteCount == value.bytes.count,
                          committed.digest == ContentDigest.sha256(value.bytes) else {
                        throw StoreError.preconditionFailed
                    }
                    if let existing = matches.first {
                        guard let existingBytes = existing.value(forKey: "bytes") as? Data else {
                            throw StoreError.corruptStore
                        }
                        guard existingBytes.count == committed.byteCount,
                              ContentDigest.sha256(existingBytes) == committed.digest else {
                            throw StoreError.corruptStore
                        }
                        guard existingBytes == value.bytes else { throw StoreError.preconditionFailed }
                    }
                }
                let record = matches.first
                    ?? NSEntityDescription.insertNewObject(forEntityName: "FileAccessRecord", into: context)
                record.setValue(value.id, forKey: "id")
                record.setValue(value.snapshotID, forKey: "snapshotID")
                record.setValue(value.bytes, forKey: "bytes")
                record.setValue(value.bookmark, forKey: "bookmark")
                record.setValue(value.localPath, forKey: "localPath")
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func read(representationID: UUID) async throws -> LocalFileAccess? {
        return try await controller.perform { context throws -> LocalFileAccess? in
            let request = Self.request(representationID: representationID)
            request.fetchLimit = 2
            let matches = try context.fetch(request)
            guard matches.count <= 1 else { throw StoreError.corruptStore }
            guard let record = matches.first else { return nil }
            guard let id = record.value(forKey: "id") as? UUID,
                  let snapshotID = record.value(forKey: "snapshotID") as? UUID,
                  let bytes = record.value(forKey: "bytes") as? Data else {
                throw StoreError.corruptStore
            }
            return LocalFileAccess(
                id: id,
                snapshotID: snapshotID,
                bytes: bytes,
                bookmark: record.value(forKey: "bookmark") as? Data,
                localPath: record.value(forKey: "localPath") as? String
            )
        }
    }

    func remove(representationID: UUID, permit: StorePermit) async throws {
        let controller = controller
        try await controller.perform { context in
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            do {
                let matches = try context.fetch(Self.request(representationID: representationID))
                matches.forEach(context.delete)
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private static func request(representationID: UUID) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
        request.predicate = NSPredicate(format: "id == %@", representationID as NSUUID)
        return request
    }

    private static func committedRepresentation(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> (snapshotID: UUID, byteCount: Int, digest: Data)? {
        let request = NSFetchRequest<NSDictionary>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["snapshotID", "storage", "byteCount", "digest"]
        request.fetchLimit = 2
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw StoreError.corruptStore }
        guard let row = rows.first else { return nil }
        guard let snapshotID = row["snapshotID"] as? UUID,
              row["storage"] as? String == RepresentationStorage.localReference.rawValue,
              let byteCount = row["byteCount"] as? Int64,
              byteCount >= 0,
              byteCount <= Int64(Int.max),
              let digest = row["digest"] as? Data else {
            throw StoreError.corruptStore
        }
        return (snapshotID, Int(byteCount), digest)
    }
}
