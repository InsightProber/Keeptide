import CoreData
import Foundation
import Synchronization

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
            let values: (refs: [ContentRef], protectedPayloadRecords: Set<RecordKey>)
            do {
                values = try context.performAndWait {
                    try context.setQueryGenerationFrom(.current)
                    let visible = try StoredRecords.snapshotReferences(in: context)
                    let refs = try Self.references(for: request.scope, visible: visible.refs)
                    let protectedPayloadRecords = try Self.protectedPayloadRecords(
                        for: refs,
                        in: context
                    )
                    try Self.requirePrivacySafeArchive(refs: refs, in: context)
                    return (refs, protectedPayloadRecords)
                }
            } catch {
                context.performAndWait { context.reset() }
                throw error
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let lease = SnapshotLease(leaseID: UUID(), identity: controller.runtime.identity,
                                      boundary: ContentDigest.sha256(try encoder.encode(values.refs)))
            let snapshot = PinnedSnapshot(lease: lease, context: context,
                refs: values.refs, protectedPayloadRecords: values.protectedPayloadRecords,
                pageSize: request.pageSize, lifetime: request.lifetime)
            controller.runtime.leases[lease.leaseID] = snapshot
            controller.scheduleExpiration(of: snapshot)
            return lease
        }
    }

    func page(_ lease: SnapshotLease, after cursor: Data?) async throws -> SnapshotPage {
        try Task.checkCancellation()
        let page: SnapshotPage = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Enqueue the pinned read before releasing the writer reservation.
                // close() can then safely drain this queue before detaching stores.
                controller.writer.perform {
                    do {
                        guard !controller.runtime.closed else { throw StoreError.closed }
                        controller.runtime.expireLeases()
                        guard lease.identity == controller.runtime.identity,
                              let snapshot = controller.runtime.leases[lease.leaseID],
                              snapshot.lease == lease else { throw StoreError.invalidLease }
                        let start: Int
                        if let cursor {
                            guard let position = snapshot.cursors[cursor] else { throw StoreError.invalidToken }
                            start = position
                        } else { start = 0 }
                        let end = min(start + snapshot.pageSize, snapshot.refs.count)
                        let refs = Array(snapshot.refs[start..<end])
                        snapshot.inFlightPages += 1
                        let context = snapshot.context
                        context.perform {
                            let result = Result {
                                try autoreleasepool {
                                    // Refaulting keeps the pinned generation; reset would advance it.
                                    defer { context.refreshAllObjects() }
                                    let records = try Self.portableRecords(for: refs, in: context)
                                    let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
                                    let contents = try refs.map { try Self.archiveContent($0, records: byKey) }
                                    return SnapshotPage(contents: contents, next: nil, portableRecords: records)
                                }
                            }
                            controller.writer.perform {
                                controller.runtime.finishPage(snapshot)
                                do {
                                    guard !controller.runtime.closed else { throw StoreError.closed }
                                    controller.runtime.expireLeases()
                                    guard lease.identity == controller.runtime.identity,
                                          controller.runtime.leases[lease.leaseID] === snapshot else {
                                        throw StoreError.invalidLease
                                    }
                                    let materialized: SnapshotPage
                                    switch result {
                                    case .success(let value): materialized = value
                                    case .failure(let error):
                                        controller.runtime.releaseLease(lease.leaseID)
                                        if let storeError = error as? StoreError,
                                           storeError == .operationDenied {
                                            throw StoreError.operationDenied
                                        }
                                        throw StoreError.snapshotUnavailable
                                    }
                                    let next: Data?
                                    if end < snapshot.refs.count {
                                        if let existing = snapshot.cursors.first(where: { $0.value == end }) {
                                            next = existing.key
                                        } else {
                                            let token = Data(UUID().uuidString.utf8)
                                            snapshot.cursors[token] = end
                                            next = token
                                        }
                                    } else { next = nil }
                                    continuation.resume(returning: SnapshotPage(contents: materialized.contents,
                                        next: next, portableRecords: materialized.portableRecords))
                                } catch { continuation.resume(throwing: error) }
                            }
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            Task { await self.end(lease) }
        }
        try Task.checkCancellation()
        return page
    }

    /// The short external commit runs on the same queue as lease expiry,
    /// generation changes and store closure. The publication closure must not
    /// perform asynchronous work or call back into the store.
    func withValidatedLease<T: Sendable>(
        _ lease: SnapshotLease,
        permit: StorePermit,
        publication: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let cancellation = SnapshotPublicationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await controller.perform { _ in
                try cancellation.commit {
                    try validateOnWriterQueue(lease, permit: permit)
                    return try publication()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func validate(_ lease: SnapshotLease, permit: StorePermit) async throws {
        try await controller.perform { _ in
            try validateOnWriterQueue(lease, permit: permit)
        }
    }

    private func validateOnWriterQueue(_ lease: SnapshotLease, permit: StorePermit) throws {
        guard !controller.runtime.closed else { throw StoreError.closed }
        controller.runtime.expireLeases()
        guard lease.identity == controller.runtime.identity,
              controller.runtime.leases[lease.leaseID]?.lease == lease else {
            throw StoreError.invalidLease
        }
        try StoreSafetyGate.validate(.completeArchive, runtime: controller.runtime, permit: permit)
    }

    func end(_ lease: SnapshotLease) async {
        try? await controller.perform { _ in
            guard controller.runtime.leases[lease.leaseID]?.lease == lease else { return }
            controller.runtime.releaseLease(lease.leaseID)
        }
    }
}

private extension ContentSnapshotReader {
    struct FacetIdentity: Hashable {
        let itemID: ItemID
        let facet: ContentFacet
    }

    static func references(
        for scope: SnapshotScope,
        visible: [ContentRef]
    ) throws -> [ContentRef] {
        guard case .selected(let requested) = scope else { return visible }
        guard !requested.isEmpty else { throw StoreError.invalidTransaction }

        var selected: [ContentRef] = []
        var exactRefs = Set<ContentRef>()
        var facets: [FacetIdentity: ContentRef] = [:]
        for ref in requested {
            let identity = FacetIdentity(itemID: ref.itemID, facet: ref.facet)
            if let existing = facets[identity], existing != ref {
                throw StoreError.invalidTransaction
            }
            facets[identity] = ref
            if exactRefs.insert(ref).inserted { selected.append(ref) }
        }

        let visibleRefs = Set(visible)
        guard selected.allSatisfy(visibleRefs.contains) else {
            throw StoreError.snapshotUnavailable
        }
        return selected
    }

    static func protectedPayloadRecords(
        for refs: [ContentRef],
        in context: NSManagedObjectContext
    ) throws -> Set<RecordKey> {
        var protected = Set<RecordKey>()
        var visitedItems = Set<ItemID>()
        for ref in refs where visitedItems.insert(ref.itemID).inserted {
            guard case .item(let item)? = try StoredRecords.value(.item(ref.itemID), in: context) else {
                throw StoreError.snapshotUnavailable
            }
            if let captureID = item.captureID {
                protected.insert(.capture(captureID))
            }
            if let memoID = item.memoID {
                let request = NSFetchRequest<NSDictionary>(entityName: RecordKey.memo(memoID).entity)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["bodyMode"]
                request.predicate = NSPredicate(format: "id == %@", memoID as NSUUID)
                request.fetchLimit = 2
                let rows = try context.fetch(request)
                guard rows.count == 1,
                      let rawMode = rows[0]["bodyMode"] as? String,
                      let mode = MemoBodyMode(rawValue: rawMode) else {
                    throw StoreError.snapshotUnavailable
                }
                if mode != .inheritedCapture { protected.insert(.memo(memoID)) }
            }
        }
        return protected
    }

    static func requirePrivacySafeArchive(
        refs: [ContentRef],
        in context: NSManagedObjectContext
    ) throws {
        var checkedCaptureIDs = Set<UUID>()
        for ref in refs {
            guard case .item(let item)? = try StoredRecords.value(.item(ref.itemID), in: context),
                  let captureID = item.captureID,
                  checkedCaptureIDs.insert(captureID).inserted else {
                // Existing graph validation decides whether missing retained
                // records invalidate the later archive page.
                continue
            }
            let request = NSFetchRequest<NSDictionary>(entityName: "CaptureSnapshot")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["manifest"]
            request.predicate = NSPredicate(format: "id == %@", captureID as NSUUID)
            request.fetchLimit = 2
            let rows = try context.fetch(request)
            guard rows.count == 1,
                  let manifestData = rows[0]["manifest"] as? Data,
                  let manifest = try? JSONDecoder().decode(CaptureManifest.self, from: manifestData) else {
                continue
            }
            if LocalReferencePrivacy.usesLegacyLocalDescriptor(
                manifestVersion: manifest.version
            ), manifest.entries.contains(where: { $0.storage == .localReference }) {
                throw StoreError.operationDenied
            }
        }
    }

    // Records have already passed the same capture validation used by ordinary
    // reads. Local file bytes are deliberately absent from this portable closure.
    static func archiveContent(_ ref: ContentRef, records: [RecordKey: RecordValue]) throws -> ResolvedContent {
        guard case .item(let item)? = records[.item(ref.itemID)] else { throw StoreError.corruptStore }
        if ref.facet == .memo {
            guard let memoID = item.memoID, case .memo(let memo)? = records[.memo(memoID)] else {
                throw StoreError.corruptStore
            }
            if memo.bodyMode != .inheritedCapture {
                guard memo.version == ref.version, memo.digest == ref.digest, let body = memo.body else {
                    throw StoreError.corruptStore
                }
                let value = RepresentationValue(id: memo.id, snapshotID: memo.id, itemIndex: 0,
                    representationIndex: 0, typeIdentifier: "public.utf8-plain-text", storage: .portable,
                    byteCount: Int64(body.count), digest: ref.digest, bytes: body)
                return ResolvedContent(ref: ref, integrity: .complete, representations: [value])
            }
        }
        guard let captureID = item.captureID, case .capture(let capture)? = records[.capture(captureID)],
              ref.version.rawValue == capture.id, ref.digest == capture.digest else { throw StoreError.corruptStore }
        if capture.representations.contains(where: { $0.storage == .localReference }) {
            return ResolvedContent(ref: ref, integrity: .requiresRelocation, representations: [])
        }
        return ResolvedContent(ref: ref, integrity: .complete, representations: capture.representations)
    }

    static func portableRecords(
        for refs: [ContentRef],
        in context: NSManagedObjectContext
    ) throws -> [RecordValue] {
        var records: [RecordValue] = []
        var included = Set<RecordKey>()
        for ref in refs {
            if included.contains(.item(ref.itemID)) { continue }
            guard case .item(let item)? = try StoredRecords.value(.item(ref.itemID), in: context) else {
                throw StoreError.corruptStore
            }
            guard item.collectionIDs.isEmpty || item.memoID != nil else { throw StoreError.corruptStore }
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
            for collectionID in item.collectionIDs {
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
        guard !included.contains(.capture(captureID)) else { return }
        let capture = try StoredRecords.validatedCapture(captureID, in: context)
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

/// Cancellation wins before the commit starts; after the commit begins its
/// returned result is authoritative even if cancellation is requested.
private final class SnapshotPublicationCancellation: Sendable {
    private let cancelled = Mutex(false)

    func cancel() { cancelled.withLock { $0 = true } }

    func commit<T>(_ publication: () throws -> T) throws -> T {
        try cancelled.withLock { cancelled in
            guard !cancelled else { throw CancellationError() }
            return try publication()
        }
    }
}
