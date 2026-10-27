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

    func put(_ value: LocalFileAccess) async throws {
        try await controller.perform { context in
            do {
                let request = Self.request(representationID: value.id)
                let matches = try context.fetch(request)
                for existing in matches {
                    guard let snapshotID = existing.value(forKey: "snapshotID") as? UUID else {
                        throw FileAccessStoreError.invalidRecord
                    }
                    guard snapshotID == value.snapshotID else {
                        throw FileAccessStoreError.identityConflict
                    }
                }
                let record = matches.first
                    ?? NSEntityDescription.insertNewObject(forEntityName: "FileAccessRecord", into: context)
                for duplicate in matches.dropFirst() {
                    context.delete(duplicate)
                }
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
            request.fetchLimit = 1
            guard let record = try context.fetch(request).first else { return nil }
            guard let id = record.value(forKey: "id") as? UUID,
                  let snapshotID = record.value(forKey: "snapshotID") as? UUID,
                  let bytes = record.value(forKey: "bytes") as? Data else {
                throw FileAccessStoreError.invalidRecord
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

    func remove(representationID: UUID) async throws {
        try await controller.perform { context in
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
}

private enum FileAccessStoreError: Error {
    case invalidRecord, identityConflict
}
