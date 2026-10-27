import CoreData
import Foundation

struct CaptureCandidate: Sendable {
    let item: ItemValue
    let ref: ContentRef
    let fingerprint: Data
}

struct CaptureCandidateQuery: Sendable {
    let match: CaptureCandidate?
    let condition: StorePrecondition
}

/// Writer-confined and rebuildable. Neither the local content digest nor this
/// index is persisted to CloudContent or LocalState.
struct LocalCaptureCandidateIndex {
    private(set) var snapshotIDsByDigest: [Data: Set<UUID>] = [:]
    private(set) var digestBySnapshotID: [UUID: Data] = [:]

    mutating func insert(snapshotID: UUID, digest: Data) {
        remove(snapshotID: snapshotID)
        snapshotIDsByDigest[digest, default: []].insert(snapshotID)
        digestBySnapshotID[snapshotID] = digest
    }

    mutating func remove(snapshotID: UUID) {
        guard let digest = digestBySnapshotID.removeValue(forKey: snapshotID) else { return }
        snapshotIDsByDigest[digest]?.remove(snapshotID)
        if snapshotIDsByDigest[digest]?.isEmpty == true {
            snapshotIDsByDigest.removeValue(forKey: digest)
        }
    }

    func snapshotIDs(for digest: Data) -> [UUID] {
        (snapshotIDsByDigest[digest] ?? []).sorted { $0.uuidString < $1.uuidString }
    }
}

/// Portable candidates use the persisted SHA index. File candidates use a
/// rebuildable local-only digest index and always confirm the full raw bytes.
struct CaptureCandidateRepository: Sendable {
    let controller: PersistenceController

    func find(_ snapshot: CaptureSnapshotValue, digest: Data, hasLocalReferences: Bool) async throws -> CaptureCandidateQuery {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }

            let candidateIDs: [UUID]
            let condition: StorePrecondition
            if hasLocalReferences {
                let localDigest = try Self.localDigest(snapshot)
                candidateIDs = try Self.localSnapshotIDs(
                    digest: localDigest,
                    in: context,
                    runtime: controller.runtime
                )
                condition = .localCaptureSet(
                    digest: localDigest,
                    fingerprint: try Self.localFingerprint(snapshotIDs: candidateIDs, in: context)
                )
            } else {
                let request = NSFetchRequest<NSDictionary>(entityName: "CaptureSnapshot")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["id"]
                request.predicate = NSPredicate(format: "digest == %@", digest as NSData)
                request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                candidateIDs = try context.fetch(request).map { row in
                    guard let id = row["id"] as? UUID else { throw StoreError.corruptStore }
                    return id
                }
                condition = .candidateSet(
                    digest: digest,
                    fingerprint: try StoredRecords.candidateFingerprint(digest: digest, in: context)
                )
            }

            for id in candidateIDs {
                let items = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
                items.predicate = NSPredicate(
                    format: "captureID == %@ AND historyEligible == YES AND deletedAt == nil AND historyDeletedAt == nil",
                    id as NSUUID
                )
                items.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
                for object in try context.fetch(items) {
                    guard let rawID = object.value(forKey: "id") as? UUID else {
                        throw StoreError.corruptStore
                    }
                    let itemID = ItemID(rawValue: rawID)
                    let ref: ContentRef
                    do {
                        guard let current = try StoredRecords.currentRef(
                            itemID: itemID,
                            facet: .history,
                            in: context
                        ) else { continue }
                        ref = current
                    } catch StoreError.notFound {
                        continue
                    }
                    let resolved = try StoredRecords.resolve(ref, in: context)
                    guard resolved.isActionable,
                          CaptureService.matches(snapshot, representations: resolved.representations),
                          case .item(let item) = try StoredRecords.value(.item(itemID), in: context) else {
                        continue
                    }
                    return CaptureCandidateQuery(
                        match: CaptureCandidate(
                            item: item,
                            ref: ref,
                            fingerprint: try StoredRecords.fingerprint(.item(itemID), in: context)
                        ),
                        condition: condition
                    )
                }
            }
            return CaptureCandidateQuery(match: nil, condition: condition)
        }
    }

    static func localDigest(_ snapshot: CaptureSnapshotValue) throws -> Data {
        let entries = snapshot.items.enumerated().flatMap { itemIndex, item in
            item.representations.enumerated().map { representationIndex, representation in
                LocalCaptureDigestEntry(
                    itemIndex: itemIndex,
                    representationIndex: representationIndex,
                    typeIdentifier: Data(representation.typeIdentifier.utf8),
                    byteCount: Int64(representation.bytes.count),
                    digest: ContentDigest.sha256(representation.bytes)
                )
            }
        }
        return try StoredRecords.canonicalDigest(
            LocalCaptureDigestValue(itemCount: snapshot.items.count, entries: entries)
        )
    }

    static func localFingerprint(
        digest: Data,
        in context: NSManagedObjectContext,
        runtime: StoreRuntime
    ) throws -> Data {
        try localFingerprint(
            snapshotIDs: localSnapshotIDs(digest: digest, in: context, runtime: runtime),
            in: context
        )
    }

    /// Call only after a successful CloudContent save. Cache maintenance must
    /// never turn a committed transaction into an apparent failure.
    static func didCommit(
        _ transaction: StoreTransaction,
        runtime: StoreRuntime
    ) {
        guard var index = runtime.localCaptureIndex else { return }
        let insertedLocalCaptures = transaction.mutations.compactMap { mutation -> CaptureValue? in
            guard case .insert(.capture(let capture)) = mutation,
                  capture.representations.contains(where: { $0.storage == .localReference }) else {
                return nil
            }
            return capture
        }
        let committedDigests = transaction.preconditions.compactMap { condition -> Data? in
            guard case .localCaptureSet(let digest, _) = condition else { return nil }
            return digest
        }
        guard insertedLocalCaptures.count <= 1 else {
            runtime.localCaptureIndex = nil
            return
        }
        if let capture = insertedLocalCaptures.first {
            guard committedDigests.count == 1,
                  let digest = committedDigests.first else {
                runtime.localCaptureIndex = nil
                return
            }
            index.insert(snapshotID: capture.id, digest: digest)
        }
        for mutation in transaction.mutations {
            if case .delete(.capture(let id)) = mutation {
                index.remove(snapshotID: id)
            }
        }
        runtime.localCaptureIndex = index
    }

    static func invalidateLocalIndex(runtime: StoreRuntime) {
        runtime.localCaptureIndex = nil
    }

    private static func localSnapshotIDs(
        digest: Data,
        in context: NSManagedObjectContext,
        runtime: StoreRuntime
    ) throws -> [UUID] {
        if runtime.localCaptureIndex == nil {
            runtime.localCaptureIndex = try buildLocalIndex(in: context)
            runtime.recordLocalCaptureIndexBuild()
        }
        guard let index = runtime.localCaptureIndex else { throw StoreError.corruptStore }
        return index.snapshotIDs(for: digest)
    }

    private static func buildLocalIndex(in context: NSManagedObjectContext) throws -> LocalCaptureCandidateIndex {
        let request = NSFetchRequest<NSDictionary>(entityName: "CaptureSnapshot")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        request.predicate = NSPredicate(
            format: "ANY representations.storage == %@",
            RepresentationStorage.localReference.rawValue
        )
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]

        let rows = try context.fetch(request)
        let ids = try rows.map { row -> UUID in
            guard let id = row["id"] as? UUID else { throw StoreError.corruptStore }
            return id
        }
        guard Set(ids).count == ids.count else { throw StoreError.corruptStore }

        var index = LocalCaptureCandidateIndex()
        for id in ids {
            do {
                guard let capture = try localCaptureMetadata(id: id, in: context) else { continue }
                if let digest = try localDigest(
                    manifest: capture.manifest,
                    representations: capture.representations,
                    snapshotID: id,
                    in: context
                ) {
                    index.insert(snapshotID: id, digest: digest)
                }
            } catch StoreError.notFound {
                continue
            } catch StoreError.corruptStore {
                continue
            }
        }
        return index
    }

    private static func localDigest(
        manifest: CaptureManifest,
        representations: [RepresentationValue],
        snapshotID: UUID,
        in context: NSManagedObjectContext
    ) throws -> Data? {
        guard representations.contains(where: { $0.storage == .localReference }) else {
            return nil
        }
        var entries: [LocalCaptureDigestEntry] = []
        entries.reserveCapacity(representations.count)
        for representation in representations.sorted(by: representationOrder) {
            let byteCount: Int64
            let digest: Data
            switch representation.storage {
            case .portable:
                byteCount = representation.byteCount
                digest = representation.digest
            case .localReference:
                guard let metadata = try LocalFileAccessRecordReader.indexedMetadata(
                    for: representation,
                    snapshotID: snapshotID,
                    manifestVersion: manifest.version,
                    in: context
                ) else { return nil }
                byteCount = metadata.byteCount
                digest = metadata.digest
            }
            entries.append(LocalCaptureDigestEntry(
                itemIndex: representation.itemIndex,
                representationIndex: representation.representationIndex,
                typeIdentifier: Data(representation.typeIdentifier.utf8),
                byteCount: byteCount,
                digest: digest
            ))
        }
        return try StoredRecords.canonicalDigest(
            LocalCaptureDigestValue(itemCount: manifest.itemCount, entries: entries)
        )
    }

    private static func localCaptureMetadata(
        id: UUID,
        in context: NSManagedObjectContext
    ) throws -> (manifest: CaptureManifest, representations: [RepresentationValue])? {
        let captureRequest = NSFetchRequest<NSDictionary>(entityName: "CaptureSnapshot")
        captureRequest.resultType = .dictionaryResultType
        captureRequest.propertiesToFetch = ["id", "manifest"]
        captureRequest.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        captureRequest.fetchLimit = 2
        let captures = try context.fetch(captureRequest)
        guard captures.count <= 1 else { throw StoreError.corruptStore }
        guard let capture = captures.first else { return nil }
        guard capture["id"] as? UUID == id,
              let manifestData = capture["manifest"] as? Data else {
            throw StoreError.corruptStore
        }
        let manifest: CaptureManifest
        do {
            manifest = try JSONDecoder().decode(CaptureManifest.self, from: manifestData)
            guard try manifest.canonicalData() == manifestData else { throw StoreError.corruptStore }
        } catch {
            throw StoreError.corruptStore
        }

        let representationRequest = NSFetchRequest<NSDictionary>(entityName: "CaptureRepresentation")
        representationRequest.resultType = .dictionaryResultType
        representationRequest.propertiesToFetch = [
            "id", "snapshotID", "itemIndex", "representationIndex", "typeIdentifier",
            "storage", "byteCount", "digest"
        ]
        representationRequest.predicate = NSPredicate(format: "snapshotID == %@", id as NSUUID)
        let rows = try context.fetch(representationRequest)
        let representations = try rows.map { row -> RepresentationValue in
            guard let representationID = row["id"] as? UUID,
                  let snapshotID = row["snapshotID"] as? UUID,
                  let itemIndex = row["itemIndex"] as? Int64,
                  let representationIndex = row["representationIndex"] as? Int64,
                  itemIndex >= 0, itemIndex <= Int64(Int.max),
                  representationIndex >= 0, representationIndex <= Int64(Int.max),
                  let typeIdentifier = row["typeIdentifier"] as? String,
                  let rawStorage = row["storage"] as? String,
                  let storage = RepresentationStorage(rawValue: rawStorage),
                  let byteCount = row["byteCount"] as? Int64,
                  let digest = row["digest"] as? Data else {
                throw StoreError.corruptStore
            }
            return RepresentationValue(
                id: representationID,
                snapshotID: snapshotID,
                itemIndex: Int(itemIndex),
                representationIndex: Int(representationIndex),
                typeIdentifier: typeIdentifier,
                storage: storage,
                byteCount: byteCount,
                digest: digest,
                bytes: nil
            )
        }.sorted(by: representationOrder)
        guard manifest.validate(representations, snapshotID: id) != .corrupt else {
            throw StoreError.corruptStore
        }
        return (manifest, representations)
    }

    private static func localFingerprint(
        snapshotIDs: [UUID],
        in context: NSManagedObjectContext
    ) throws -> Data {
        guard !snapshotIDs.isEmpty else { return try StoredRecords.canonicalDigest([ContentRef]()) }
        let request = NSFetchRequest<NSDictionary>(entityName: "LibraryItem")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        request.predicate = NSPredicate(
            format: "captureID IN %@ AND historyEligible == YES AND deletedAt == nil AND historyDeletedAt == nil",
            snapshotIDs as NSArray
        )
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        let refs = try context.fetch(request).compactMap { row -> ContentRef? in
            guard let id = row["id"] as? UUID else { throw StoreError.corruptStore }
            do {
                return try StoredRecords.currentRef(
                    itemID: ItemID(rawValue: id),
                    facet: .history,
                    in: context
                )
            } catch StoreError.notFound {
                return nil
            }
        }
        return try StoredRecords.canonicalDigest(refs)
    }

    private static func representationOrder(_ lhs: RepresentationValue, _ rhs: RepresentationValue) -> Bool {
        if lhs.itemIndex != rhs.itemIndex { return lhs.itemIndex < rhs.itemIndex }
        return lhs.representationIndex < rhs.representationIndex
    }

}

private struct LocalCaptureDigestValue: Codable {
    let itemCount: Int
    let entries: [LocalCaptureDigestEntry]
}

private struct LocalCaptureDigestEntry: Codable {
    let itemIndex: Int
    let representationIndex: Int
    let typeIdentifier: Data
    let byteCount: Int64
    let digest: Data
}
