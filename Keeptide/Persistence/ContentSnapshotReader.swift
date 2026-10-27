import CoreData
import Foundation

struct ContentSnapshotReader: Sendable {
    let controller: PersistenceController

    func begin(_ request: SnapshotRequest) async throws -> SnapshotLease {
        guard (1...1000).contains(request.pageSize), request.lifetime.isFinite,
              request.lifetime > 0, request.lifetime <= 3600 else { throw StoreError.invalidTransaction }
        return try await controller.perform { _ in
            try StoreSafetyGate.validate(.completeArchive, runtime: controller.runtime, permit: request.permit)
            controller.runtime.expireLeases()
            let context = controller.container.newBackgroundContext()
            context.undoManager = nil
            let values = try context.performAndWait { () throws -> ([ContentRef], Set<UUID>) in
                try context.setQueryGenerationFrom(.current)
                // The first fetch materializes the query-generation boundary while
                // the common writer queue prevents an intervening local commit.
                return try Self.visibleReferences(in: context)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let lease = SnapshotLease(leaseID: UUID(), identity: controller.runtime.identity,
                                      boundary: ContentDigest.sha256(try encoder.encode(values.0)))
            controller.runtime.leases[lease.leaseID] = PinnedSnapshot(lease: lease, context: context,
                refs: values.0, protectedCaptures: values.1, pageSize: request.pageSize, lifetime: request.lifetime)
            return lease
        }
    }

    func page(_ lease: SnapshotLease, after cursor: Data?) async throws -> SnapshotPage {
        try await controller.perform { _ in
            controller.runtime.expireLeases()
            guard lease.identity == controller.runtime.identity,
                  let snapshot = controller.runtime.leases[lease.leaseID], snapshot.lease == lease else {
                throw StoreError.invalidLease
            }
            let start: Int
            if let cursor {
                guard let position = snapshot.cursors[cursor] else { throw StoreError.invalidToken }
                start = position
            } else { start = 0 }
            let end = min(start + snapshot.pageSize, snapshot.refs.count)
            let pinnedContext = snapshot.context
            let refs = Array(snapshot.refs[start..<end])
            let pageValues: ([ResolvedContent], [RecordValue])
            do {
                pageValues = try pinnedContext.performAndWait {
                    let resolved = try refs.map { try StoredRecords.resolve($0, in: pinnedContext) }
                    let contents = try resolved.map(Self.archiveContent)
                    let records = try Self.portableRecords(for: refs, in: pinnedContext)
                    return (contents, records)
                }
            } catch {
                pinnedContext.performAndWait { pinnedContext.reset() }
                controller.runtime.leases.removeValue(forKey: lease.leaseID)
                throw StoreError.snapshotUnavailable
            }
            let next: Data?
            if end < snapshot.refs.count {
                if let existing = snapshot.cursors.first(where: { $0.value == end }) { next = existing.key }
                else {
                    let token = Data(UUID().uuidString.utf8)
                    snapshot.cursors[token] = end
                    next = token
                }
            } else { next = nil }
            return SnapshotPage(contents: pageValues.0, next: next, portableRecords: pageValues.1)
        }
    }

    func end(_ lease: SnapshotLease) async {
        try? await controller.perform { _ in
            guard let snapshot = controller.runtime.leases[lease.leaseID], snapshot.lease == lease else { return }
            let pinnedContext = snapshot.context
            pinnedContext.performAndWait { pinnedContext.reset() }
            controller.runtime.leases.removeValue(forKey: lease.leaseID)
        }
    }
}

private extension ContentSnapshotReader {
    static func visibleReferences(
        in context: NSManagedObjectContext
    ) throws -> ([ContentRef], Set<UUID>) {
        let itemRequest = NSFetchRequest<NSDictionary>(entityName: "LibraryItem")
        itemRequest.resultType = .dictionaryResultType
        itemRequest.propertiesToFetch = [
            "id", "captureID", "memoID", "historyEligible", "historyDeletedAt", "deletedAt"
        ]
        itemRequest.sortDescriptors = [
            NSSortDescriptor(key: "lastCopiedAt", ascending: false),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        itemRequest.includesPendingChanges = false
        let items = try context.fetch(itemRequest)
        let protectedCaptures = Set(items.compactMap { $0["captureID"] as? UUID })

        let itemMarkerRequest = NSFetchRequest<NSDictionary>(entityName: "ItemDeletionMarker")
        itemMarkerRequest.resultType = .dictionaryResultType
        itemMarkerRequest.propertiesToFetch = ["id"]
        itemMarkerRequest.includesPendingChanges = false
        let itemMarkers = Set(try context.fetch(itemMarkerRequest).compactMap { $0["id"] as? UUID })

        let facetMarkerRequest = NSFetchRequest<NSDictionary>(entityName: "FacetDeletionMarker")
        facetMarkerRequest.resultType = .dictionaryResultType
        facetMarkerRequest.propertiesToFetch = ["itemID", "facet", "generationID"]
        facetMarkerRequest.includesPendingChanges = false
        let facetMarkers = Set(try context.fetch(facetMarkerRequest).compactMap { row -> VisibleFacet? in
            guard let itemID = row["itemID"] as? UUID,
                  let rawFacet = row["facet"] as? String,
                  let facet = ContentFacet(rawValue: rawFacet),
                  let generationID = row["generationID"] as? UUID else { return nil }
            return VisibleFacet(itemID: itemID, facet: facet, generationID: generationID)
        })

        var refs: [ContentRef] = []
        for item in items {
            guard let rawItemID = item["id"] as? UUID else { throw StoreError.corruptStore }
            guard item["deletedAt"] == nil, !itemMarkers.contains(rawItemID) else { continue }
            let itemID = ItemID(rawValue: rawItemID)

            let historyEligible = (item["historyEligible"] as? NSNumber)?.boolValue == true
            if historyEligible, item["historyDeletedAt"] == nil {
                guard let captureID = item["captureID"] as? UUID else { throw StoreError.corruptStore }
                let historyMarked = facetMarkers.contains(VisibleFacet(
                    itemID: rawItemID,
                    facet: .history,
                    generationID: captureID
                ))
                if !historyMarked {
                    do {
                        guard let ref = try StoredRecords.currentRef(itemID: itemID, facet: .history, in: context) else {
                            throw StoreError.corruptStore
                        }
                        refs.append(ref)
                    } catch StoreError.notFound {
                        throw StoreError.corruptStore
                    }
                }
            }

            if let memoID = item["memoID"] as? UUID {
                let memoMarked = facetMarkers.contains(VisibleFacet(
                    itemID: rawItemID,
                    facet: .memo,
                    generationID: memoID
                ))
                guard !memoMarked else { continue }
                do {
                    if let ref = try StoredRecords.currentRef(itemID: itemID, facet: .memo, in: context) {
                        refs.append(ref)
                    } else {
                        throw StoreError.corruptStore
                    }
                } catch StoreError.notFound {
                    // Soft-deleted memo facets are intentionally absent.
                    continue
                }
            }
        }
        return (refs, protectedCaptures)
    }

    static func archiveContent(_ resolved: ResolvedContent) throws -> ResolvedContent {
        switch resolved.integrity {
        case .complete:
            if resolved.representations.contains(where: { $0.storage == .localReference }) {
                return ResolvedContent(ref: resolved.ref, integrity: .requiresRelocation, representations: [])
            }
            return resolved
        case .requiresRelocation:
            return ResolvedContent(ref: resolved.ref, integrity: .requiresRelocation, representations: [])
        case .recovering, .corrupt:
            throw StoreError.corruptStore
        }
    }

    static func portableRecords(
        for refs: [ContentRef],
        in context: NSManagedObjectContext
    ) throws -> [RecordValue] {
        var records: [RecordValue] = []
        var included = Set<RecordKey>()
        for ref in refs {
            guard case .item(let item)? = try StoredRecords.value(.item(ref.itemID), in: context) else {
                throw StoreError.corruptStore
            }
            guard item.collectionID == nil || item.memoID != nil else { throw StoreError.corruptStore }
            append(.item(item), to: &records, included: &included)

            if let captureID = item.captureID {
                try appendCapture(captureID, to: &records, included: &included, in: context)
            }
            if let memoID = item.memoID {
                guard case .memo(let memo)? = try StoredRecords.value(.memo(memoID), in: context),
                      memo.itemID == item.id else {
                    throw StoreError.corruptStore
                }
                try validateArchivedMemo(memo, retainedCaptureID: item.captureID)
                append(.memo(memo), to: &records, included: &included)
            }
            if let collectionID = item.collectionID {
                guard case .collection(let collection)? = try StoredRecords.value(
                    .collection(collectionID),
                    in: context
                ) else {
                    throw StoreError.corruptStore
                }
                append(.collection(collection), to: &records, included: &included)
            }
        }
        return records
    }

    static func validateArchivedMemo(
        _ memo: MemoValue,
        retainedCaptureID: UUID?
    ) throws {
        switch memo.bodyMode {
        case .inheritedCapture:
            guard retainedCaptureID != nil,
                  memo.body == nil,
                  memo.version == nil,
                  memo.digest == nil else {
                throw StoreError.corruptStore
            }
        case .ownedPlainText, .ownedMarkdown:
            guard let body = memo.body,
                  String(data: body, encoding: .utf8) != nil,
                  memo.version != nil,
                  memo.digest == ContentDigest.sha256(body) else {
                throw StoreError.corruptStore
            }
        }
    }

    static func appendCapture(
        _ captureID: UUID,
        to records: inout [RecordValue],
        included: inout Set<RecordKey>,
        in context: NSManagedObjectContext
    ) throws {
        guard case .capture(let capture)? = try StoredRecords.value(.capture(captureID), in: context),
              ContentDigest.sha256(try capture.manifest.canonicalData()) == capture.digest,
              capture.manifest.validate(capture.representations, snapshotID: capture.id) == .complete else {
            throw StoreError.corruptStore
        }
        append(.capture(capture), to: &records, included: &included)
    }

    static func append(
        _ record: RecordValue,
        to records: inout [RecordValue],
        included: inout Set<RecordKey>
    ) {
        guard included.insert(record.key).inserted else { return }
        records.append(record)
    }
}

private struct VisibleFacet: Hashable {
    let itemID: UUID
    let facet: ContentFacet
    let generationID: UUID
}
