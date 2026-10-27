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
            let values: (refs: [ContentRef], protectedCaptures: Set<UUID>)
            do {
                values = try context.performAndWait {
                    try context.setQueryGenerationFrom(.current)
                    let values = try StoredRecords.snapshotReferences(in: context)
                    try Self.requirePrivacySafeArchive(refs: values.refs, in: context)
                    return values
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
                refs: values.refs, protectedCaptures: values.protectedCaptures,
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
                                    try Self.requirePrivacySafeArchive(records)
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

    func end(_ lease: SnapshotLease) async {
        try? await controller.perform { _ in
            guard controller.runtime.leases[lease.leaseID]?.lease == lease else { return }
            controller.runtime.releaseLease(lease.leaseID)
        }
    }
}

private extension ContentSnapshotReader {
    static func requirePrivacySafeArchive(
        refs: [ContentRef],
        in context: NSManagedObjectContext
    ) throws {
        var checkedCaptureIDs = Set<UUID>()
        for ref in refs {
            guard case .item(let item)? = try StoredRecords.value(.item(ref.itemID), in: context),
                  let captureID = item.captureID,
                  checkedCaptureIDs.insert(captureID).inserted,
                  case .capture(let capture)? = try StoredRecords.value(.capture(captureID), in: context) else {
                // Existing graph validation decides whether missing retained
                // records invalidate the later archive page.
                continue
            }
            if capture.manifest.version < LocalReferencePrivacy.manifestVersion,
               capture.representations.contains(where: { $0.storage == .localReference }) {
                throw StoreError.operationDenied
            }
        }
    }

    static func requirePrivacySafeArchive(_ records: [RecordValue]) throws {
        for case .capture(let capture) in records {
            if capture.manifest.version < LocalReferencePrivacy.manifestVersion,
               capture.representations.contains(where: { $0.storage == .localReference }) {
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
