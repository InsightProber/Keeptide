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
                    guard let ref = try StoredRecords.currentRef(itemID: itemID, facet: .history, in: context) else {
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
        return try canonicalDigest(
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
        _ mutations: [StoreMutation],
        in context: NSManagedObjectContext,
        runtime: StoreRuntime
    ) {
        guard var index = runtime.localCaptureIndex else { return }
        do {
            for mutation in mutations {
                switch mutation {
                case .insert(.capture(let capture)), .update(.capture(let capture)):
                    index.remove(snapshotID: capture.id)
                    if let digest = try localDigest(capture, in: context) {
                        index.insert(snapshotID: capture.id, digest: digest)
                    }
                case .delete(.capture(let id)):
                    index.remove(snapshotID: id)
                default:
                    continue
                }
            }
            runtime.localCaptureIndex = index
        } catch {
            runtime.localCaptureIndex = nil
        }
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
                guard case .capture(let capture) = try StoredRecords.value(.capture(id), in: context) else {
                    continue
                }
                if let digest = try localDigest(capture, in: context) {
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
        _ capture: CaptureValue,
        in context: NSManagedObjectContext
    ) throws -> Data? {
        guard capture.representations.contains(where: { $0.storage == .localReference }) else {
            return nil
        }
        var entries: [LocalCaptureDigestEntry] = []
        entries.reserveCapacity(capture.representations.count)
        for representation in capture.representations.sorted(by: representationOrder) {
            let bytes: Data
            switch representation.storage {
            case .portable:
                guard let portable = representation.bytes else { throw StoreError.corruptStore }
                bytes = portable
            case .localReference:
                let request = NSFetchRequest<NSDictionary>(entityName: "FileAccessRecord")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["id", "snapshotID", "bytes"]
                request.predicate = NSPredicate(format: "id == %@", representation.id as NSUUID)
                request.fetchLimit = 2
                let rows = try context.fetch(request)
                guard rows.count <= 1 else { throw LocalCaptureIndexBuildError.duplicateRepresentationID }
                guard let row = rows.first else { return nil }
                guard row["id"] as? UUID == representation.id,
                      row["snapshotID"] as? UUID == capture.id,
                      let stored = row["bytes"] as? Data else {
                    throw StoreError.corruptStore
                }
                if capture.manifest.version == 1 {
                    guard representation.byteCount >= 0,
                          representation.byteCount <= Int64(Int.max) else {
                        throw StoreError.corruptStore
                    }
                    bytes = try LocalFileAccessEnvelope.decodeLegacyVerified(
                        stored,
                        byteCount: Int(representation.byteCount),
                        digest: representation.digest
                    )
                } else {
                    guard capture.manifest.version == LocalReferencePrivacy.manifestVersion else {
                        throw StoreError.corruptStore
                    }
                    bytes = try LocalFileAccessEnvelope.decode(
                        stored,
                        representationID: representation.id,
                        snapshotID: capture.id
                    )
                }
            }
            entries.append(LocalCaptureDigestEntry(
                itemIndex: representation.itemIndex,
                representationIndex: representation.representationIndex,
                typeIdentifier: Data(representation.typeIdentifier.utf8),
                byteCount: Int64(bytes.count),
                digest: ContentDigest.sha256(bytes)
            ))
        }
        return try canonicalDigest(
            LocalCaptureDigestValue(itemCount: capture.manifest.itemCount, entries: entries)
        )
    }

    private static func localFingerprint(
        snapshotIDs: [UUID],
        in context: NSManagedObjectContext
    ) throws -> Data {
        guard !snapshotIDs.isEmpty else { return try canonicalDigest([ContentRef]()) }
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
            return try StoredRecords.currentRef(itemID: ItemID(rawValue: id), facet: .history, in: context)
        }
        return try canonicalDigest(refs)
    }

    private static func representationOrder(_ lhs: RepresentationValue, _ rhs: RepresentationValue) -> Bool {
        if lhs.itemIndex != rhs.itemIndex { return lhs.itemIndex < rhs.itemIndex }
        return lhs.representationIndex < rhs.representationIndex
    }

    private static func canonicalDigest<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate
        return ContentDigest.sha256(try encoder.encode(value))
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

private enum LocalCaptureIndexBuildError: Error {
    case duplicateRepresentationID
}
