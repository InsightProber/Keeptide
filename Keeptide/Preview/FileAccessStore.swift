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
        try await putPrepared([value], expecting: identity)
    }

    func putPrepared(_ values: [LocalFileAccess], expecting identity: StoreIdentity) async throws {
        guard !values.isEmpty else { return }
        let identifiers = values.map(\.id)
        guard Set(identifiers).count == identifiers.count,
              values.allSatisfy({ $0.localPath?.utf8.contains(0) != true }) else {
            throw StoreError.invalidTransaction
        }
        let controller = controller
        try await controller.perform { context in
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.write, runtime: controller.runtime)
            do {
                var restoresCommittedLocalState = false
                for value in values {
                    restoresCommittedLocalState = try Self.stage(value, in: context)
                        || restoresCommittedLocalState
                }
                if context.hasChanges {
                    try context.save()
                    if restoresCommittedLocalState {
                        CaptureCandidateRepository.invalidateLocalIndex(runtime: controller.runtime)
                    }
                }
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
                  let persistedBytes = record.value(forKey: "bytes") as? Data else {
                throw StoreError.corruptStore
            }
            let committed = try Self.committedRepresentation(id: id, in: context)
            return LocalFileAccess(
                id: id,
                snapshotID: snapshotID,
                bytes: try Self.decodeLocalBytes(
                    persistedBytes,
                    representationID: id,
                    snapshotID: snapshotID,
                    committed: committed
                ),
                bookmark: record.value(forKey: "bookmark") as? Data,
                localPath: record.value(forKey: "localPath") as? String
            )
        }
    }

    func discardPrepared(
        _ representationIDs: [UUID],
        snapshotID: UUID,
        expecting identity: StoreIdentity
    ) async throws {
        let uniqueIDs = Set(representationIDs)
        guard uniqueIDs.count == representationIDs.count else {
            throw StoreError.invalidTransaction
        }
        let controller = controller
        try await controller.perform { context in
            // This is not general maintenance. The immutable snapshot/representation
            // IDs are an abort capability for rows staged by one capture attempt.
            // A generation transition may quarantine that same physical store before
            // the attempt can roll back, but an identity from another store must never
            // delete rows in the newly bound store.
            guard identity.storeID == controller.runtime.identity.storeID else {
                throw StoreError.preconditionFailed
            }
            guard !uniqueIDs.isEmpty else { return }
            do {
                let committed = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
                committed.predicate = NSPredicate(format: "id IN %@", Array(uniqueIDs) as NSArray)
                committed.fetchLimit = 1
                guard try context.count(for: committed) == 0 else {
                    throw StoreError.preconditionFailed
                }

                let prepared = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
                prepared.predicate = NSPredicate(format: "id IN %@", Array(uniqueIDs) as NSArray)
                let rows = try context.fetch(prepared)
                guard rows.count <= uniqueIDs.count else { throw StoreError.corruptStore }
                for row in rows {
                    guard let id = row.value(forKey: "id") as? UUID,
                          uniqueIDs.contains(id),
                          row.value(forKey: "snapshotID") as? UUID == snapshotID else {
                        throw StoreError.preconditionFailed
                    }
                }
                rows.forEach(context.delete)
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func remove(representationID: UUID, permit: StorePermit) async throws {
        let controller = controller
        try await controller.perform { context in
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            do {
                let matches = try context.fetch(Self.request(representationID: representationID))
                matches.forEach(context.delete)
                if context.hasChanges {
                    try context.save()
                    CaptureCandidateRepository.invalidateLocalIndex(runtime: controller.runtime)
                }
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

    private static func stage(
        _ value: LocalFileAccess,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = request(representationID: value.id)
        request.fetchLimit = 2
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
        let committed = try committedRepresentation(id: value.id, in: context)
        if let committed {
            guard committed.snapshotID == value.snapshotID else {
                throw StoreError.preconditionFailed
            }
            if LocalReferencePrivacy.usesLegacyLocalDescriptor(
                manifestVersion: committed.manifestVersion
            ) {
                guard committed.byteCount == value.bytes.count,
                      committed.digest == ContentDigest.sha256(value.bytes) else {
                    throw StoreError.preconditionFailed
                }
            } else {
                guard LocalReferencePrivacy.usesOpaqueLocalDescriptor(
                        manifestVersion: committed.manifestVersion
                      ),
                      committed.byteCount == 0,
                      committed.digest.count == LocalReferencePrivacy.relocationTokenByteCount else {
                    throw StoreError.corruptStore
                }
            }
        }
        if let existing = matches.first {
            guard let persistedBytes = existing.value(forKey: "bytes") as? Data else {
                throw StoreError.corruptStore
            }
            let existingBytes = try decodeLocalBytes(
                persistedBytes,
                representationID: value.id,
                snapshotID: value.snapshotID,
                committed: committed
            )
            guard existingBytes == value.bytes else { throw StoreError.preconditionFailed }
        } else if let committed,
                  LocalReferencePrivacy.usesOpaqueLocalDescriptor(
                    manifestVersion: committed.manifestVersion
                  ) {
            // A restored opaque descriptor cannot prove caller-provided bytes are
            // the original local reference. A dedicated relocation flow must bind it.
            throw StoreError.preconditionFailed
        }
        let record = matches.first
            ?? NSEntityDescription.insertNewObject(forEntityName: "FileAccessRecord", into: context)
        record.setValue(value.id, forKey: "id")
        record.setValue(value.snapshotID, forKey: "snapshotID")
        let persistedBytes: Data
        if let committed,
           LocalReferencePrivacy.usesLegacyLocalDescriptor(
            manifestVersion: committed.manifestVersion
           ) {
            persistedBytes = value.bytes
        } else {
            persistedBytes = LocalFileAccessEnvelope.encode(
                value.bytes,
                representationID: value.id,
                snapshotID: value.snapshotID
            )
        }
        record.setValue(persistedBytes, forKey: "bytes")
        record.setValue(value.bookmark, forKey: "bookmark")
        record.setValue(value.localPath, forKey: "localPath")
        return committed != nil && matches.isEmpty
    }

    private static func committedRepresentation(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> (snapshotID: UUID, byteCount: Int, digest: Data, manifestVersion: Int)? {
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
        let captureRequest = NSFetchRequest<NSDictionary>(entityName: "CaptureSnapshot")
        captureRequest.predicate = NSPredicate(format: "id == %@", snapshotID as NSUUID)
        captureRequest.resultType = .dictionaryResultType
        captureRequest.propertiesToFetch = ["manifest"]
        captureRequest.fetchLimit = 2
        let captures = try context.fetch(captureRequest)
        guard captures.count == 1,
              let manifestData = captures[0]["manifest"] as? Data else {
            throw StoreError.corruptStore
        }
        let manifest: CaptureManifest
        do {
            manifest = try JSONDecoder().decode(CaptureManifest.self, from: manifestData)
        } catch {
            throw StoreError.corruptStore
        }
        return (snapshotID, Int(byteCount), digest, manifest.version)
    }

    private static func decodeLocalBytes(
        _ persisted: Data,
        representationID: UUID,
        snapshotID: UUID,
        committed: (snapshotID: UUID, byteCount: Int, digest: Data, manifestVersion: Int)?
    ) throws -> Data {
        guard let committed else {
            return try LocalFileAccessEnvelope.decode(
                persisted,
                representationID: representationID,
                snapshotID: snapshotID
            )
        }
        guard committed.snapshotID == snapshotID else { throw StoreError.corruptStore }
        if LocalReferencePrivacy.usesLegacyLocalDescriptor(
            manifestVersion: committed.manifestVersion
        ) {
            return try LocalFileAccessEnvelope.decodeLegacyVerified(
                persisted,
                byteCount: committed.byteCount,
                digest: committed.digest
            )
        }
        guard LocalReferencePrivacy.usesOpaqueLocalDescriptor(
            manifestVersion: committed.manifestVersion
        ) else {
            throw StoreError.corruptStore
        }
        return try LocalFileAccessEnvelope.decode(
            persisted,
            representationID: representationID,
            snapshotID: snapshotID
        )
    }
}

enum LocalFileAccessRecordReader {
    struct IndexedMetadata {
        let byteCount: Int64
        let digest: Data
    }

    static func decodedBytes(
        for representation: RepresentationValue,
        snapshotID: UUID,
        manifestVersion: Int,
        in context: NSManagedObjectContext
    ) throws -> Data? {
        let request = NSFetchRequest<NSDictionary>(entityName: "FileAccessRecord")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id", "snapshotID", "bytes"]
        request.predicate = NSPredicate(format: "id == %@", representation.id as NSUUID)
        request.fetchLimit = 2
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw StoreError.corruptStore }
        guard let row = rows.first else { return nil }
        guard row["id"] as? UUID == representation.id,
              row["snapshotID"] as? UUID == snapshotID,
              let persisted = row["bytes"] as? Data else {
            throw StoreError.corruptStore
        }
        if LocalReferencePrivacy.usesLegacyLocalDescriptor(manifestVersion: manifestVersion) {
            guard representation.byteCount >= 0,
                  representation.byteCount <= Int64(Int.max) else {
                throw StoreError.corruptStore
            }
            return try LocalFileAccessEnvelope.decodeLegacyVerified(
                persisted,
                byteCount: Int(representation.byteCount),
                digest: representation.digest
            )
        }
        guard LocalReferencePrivacy.usesOpaqueLocalDescriptor(
            manifestVersion: manifestVersion
        ) else { throw StoreError.corruptStore }
        return try LocalFileAccessEnvelope.decode(
            persisted,
            representationID: representation.id,
            snapshotID: snapshotID
        )
    }

    static func indexedMetadata(
        for representation: RepresentationValue,
        snapshotID: UUID,
        manifestVersion: Int,
        in context: NSManagedObjectContext
    ) throws -> IndexedMetadata? {
        let request = NSFetchRequest<NSDictionary>(entityName: "FileAccessRecord")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id", "snapshotID", "bytes"]
        request.predicate = NSPredicate(format: "id == %@", representation.id as NSUUID)
        request.fetchLimit = 2
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw StoreError.corruptStore }
        guard let row = rows.first else { return nil }
        guard row["id"] as? UUID == representation.id,
              row["snapshotID"] as? UUID == snapshotID,
              let persisted = row["bytes"] as? Data else {
            throw StoreError.corruptStore
        }
        if LocalReferencePrivacy.usesLegacyLocalDescriptor(manifestVersion: manifestVersion) {
            guard representation.byteCount >= 0,
                  representation.byteCount <= Int64(Int.max),
                  persisted.count == Int(representation.byteCount) else {
                throw StoreError.corruptStore
            }
            return IndexedMetadata(byteCount: representation.byteCount, digest: representation.digest)
        }
        guard LocalReferencePrivacy.usesOpaqueLocalDescriptor(
            manifestVersion: manifestVersion
        ) else { throw StoreError.corruptStore }
        let metadata = try LocalFileAccessEnvelope.indexedMetadata(
            persisted,
            representationID: representation.id,
            snapshotID: snapshotID
        )
        return IndexedMetadata(byteCount: metadata.byteCount, digest: metadata.digest)
    }
}

enum LocalFileAccessEnvelope {
    struct IndexedMetadata {
        let byteCount: Int64
        let digest: Data
    }

    private static let magic = Data([0x4b, 0x50, 0x54, 0x4c, 0x46, 0x41, 0x30, 0x32]) // KPTLFA02
    private static let identifierByteCount = 16
    private static let lengthByteCount = MemoryLayout<UInt64>.size
    private static let digestByteCount = ContentDigest.byteCount
    private static let headerByteCount = magic.count
        + (identifierByteCount * 2)
        + lengthByteCount
        + (digestByteCount * 2)

    static func encode(_ bytes: Data, representationID: UUID, snapshotID: UUID) -> Data {
        var result = magic
        result.append(uuidBytes(representationID))
        result.append(uuidBytes(snapshotID))
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(ContentDigest.sha256(bytes))
        let bindingDigest = ContentDigest.sha256(result)
        result.append(bindingDigest)
        result.append(bytes)
        return result
    }

    static func decode(_ stored: Data, representationID: UUID, snapshotID: UUID) throws -> Data {
        let metadata = try indexedMetadata(
            stored,
            representationID: representationID,
            snapshotID: snapshotID
        )
        let payload = stored.suffix(from: headerByteCount)
        guard ContentDigest.sha256(Data(payload)) == metadata.digest else {
            throw StoreError.corruptStore
        }
        return Data(payload)
    }

    static func indexedMetadata(
        _ stored: Data,
        representationID: UUID,
        snapshotID: UUID
    ) throws -> IndexedMetadata {
        guard stored.starts(with: magic) else { throw StoreError.corruptStore }
        guard stored.count >= headerByteCount else { throw StoreError.corruptStore }
        let representationStart = magic.count
        let representationEnd = representationStart + identifierByteCount
        let snapshotEnd = representationEnd + identifierByteCount
        guard Data(stored[representationStart..<representationEnd]) == uuidBytes(representationID),
              Data(stored[representationEnd..<snapshotEnd]) == uuidBytes(snapshotID) else {
            throw StoreError.corruptStore
        }
        let lengthRange = snapshotEnd..<(snapshotEnd + lengthByteCount)
        var declaredLength: UInt64 = 0
        for byte in stored[lengthRange] {
            declaredLength = (declaredLength << 8) | UInt64(byte)
        }
        guard declaredLength <= UInt64(Int.max) else { throw StoreError.corruptStore }
        let payloadDigestStart = lengthRange.upperBound
        let payloadDigestEnd = payloadDigestStart + digestByteCount
        let bindingDigestEnd = payloadDigestEnd + digestByteCount
        guard stored.count == bindingDigestEnd + Int(declaredLength),
              Data(stored[payloadDigestEnd..<bindingDigestEnd])
                == ContentDigest.sha256(Data(stored.prefix(payloadDigestEnd))) else {
            throw StoreError.corruptStore
        }
        return IndexedMetadata(
            byteCount: Int64(declaredLength),
            digest: Data(stored[payloadDigestStart..<payloadDigestEnd])
        )
    }

    static func decodeLegacyVerified(_ stored: Data, byteCount: Int, digest: Data) throws -> Data {
        guard stored.count == byteCount, ContentDigest.sha256(stored) == digest else {
            throw StoreError.corruptStore
        }
        return stored
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}
