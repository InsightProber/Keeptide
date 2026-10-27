import Foundation

enum CaptureError: Error, Equatable {
    case staleSnapshot, emptySnapshot, oversized, privacyRestricted, contention
}

/// Revocation can be checked synchronously on the store queue immediately before
/// mutation, including when Pause happens while a capture is awaiting disk work.
final class CapturePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func revoke() { lock.withLock { valid = false } }
    var isValid: Bool { lock.withLock { valid } }
}

struct CaptureResult: Sendable {
    let itemID: ItemID
    let ref: ContentRef
    let reused: Bool
}

actor CaptureService {
    private let controller: PersistenceController
    private var tail: Task<CaptureResult, Error>?

    init(controller: PersistenceController) { self.controller = controller }

    func capture(_ snapshot: CaptureSnapshotValue, at date: Date = Date(),
                 permit: CapturePermit = CapturePermit(),
                 isCurrent: @escaping @Sendable () async -> Bool = { true }) async throws -> CaptureResult {
        let predecessor = tail
        let operation = Task {
            _ = try? await predecessor?.value
            return try await self.store(snapshot, at: date, permit: permit, isCurrent: isCurrent)
        }
        tail = operation
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            permit.revoke()
            operation.cancel()
        }
    }

    private func store(_ snapshot: CaptureSnapshotValue, at date: Date, permit: CapturePermit,
                       isCurrent: @escaping @Sendable () async -> Bool) async throws -> CaptureResult {
        guard !snapshot.items.isEmpty, snapshot.items.allSatisfy({ !$0.representations.isEmpty }) else {
            throw CaptureError.emptySnapshot
        }
        guard CapturePolicy.decision(typeIdentifiers: snapshot.items.flatMap { $0.representations.map(\.typeIdentifier) },
            sourceApp: snapshot.sourceApp,
            excludedSourceApps: []) == .capture else { throw CaptureError.privacyRestricted }
        guard snapshot.items.flatMap(\.representations).allSatisfy({ CapturePolicy.isSafeTypeIdentifier($0.typeIdentifier) }) else {
            throw CaptureError.privacyRestricted
        }
        var size = 0
        for item in snapshot.items {
            for representation in item.representations {
                guard representation.bytes.count <= SnapshotReader.maximumPayloadBytes - size else { throw CaptureError.oversized }
                size += representation.bytes.count
            }
        }
        guard permit.isValid, !Task.isCancelled, await isCurrent() else { throw CaptureError.staleSnapshot }
        let prepared = try Self.prepare(snapshot)
        let identity = try await controller.identity()
        let candidates = CaptureCandidateRepository(controller: controller)
        var preparedLocalRows = false
        do {
            for _ in 0..<32 {
                guard permit.isValid, !Task.isCancelled, await isCurrent() else { throw CaptureError.staleSnapshot }
                let query = try await candidates.find(snapshot, digest: prepared.capture.digest,
                                                      hasLocalReferences: !prepared.localAccess.isEmpty)
                let result: CaptureResult
                let transaction: StoreTransaction
                if let match = query.match {
                    var item = match.item
                    guard item.copyCount < Int64.max else { throw StoreError.invalidTransaction }
                    item.copyCount += 1
                    item.lastCopiedAt = max(date, item.lastCopiedAt)
                    transaction = StoreTransaction(identity: identity,
                        preconditions: [query.condition, .recordUnchanged(.item(item.id), fingerprint: match.fingerprint),
                                        .contentVersion(match.ref)], mutations: [.update(.item(item))])
                    result = CaptureResult(itemID: item.id, ref: match.ref, reused: true)
                } else {
                    if !preparedLocalRows {
                        guard permit.isValid else { throw CaptureError.staleSnapshot }
                        try await FileAccessStore(controller: controller).putPrepared(prepared.localAccess, expecting: identity)
                        preparedLocalRows = true
                    }
                    let item = ItemValue(createdAt: date, sourceApp: snapshot.sourceApp,
                        title: Self.title(snapshot, hasLocalReferences: !prepared.localAccess.isEmpty),
                        captureID: prepared.capture.id, historyEligible: true, lastCopiedAt: date, copyCount: 1)
                    transaction = StoreTransaction(identity: identity, preconditions: [query.condition],
                        mutations: [.insert(.capture(prepared.capture)), .insert(.item(item))])
                    result = CaptureResult(itemID: item.id,
                        ref: ContentRef(itemID: item.id, facet: .history,
                            version: ContentVersion(rawValue: prepared.capture.id), digest: prepared.capture.digest), reused: false)
                }
                guard permit.isValid, await isCurrent() else { throw CaptureError.staleSnapshot }
                do {
                    _ = try await WriteCoordinator(controller: controller).commit(transaction, validate: {
                        guard permit.isValid else { throw CaptureError.staleSnapshot }
                    })
                } catch StoreError.preconditionFailed {
                    // Another capture service committed after candidate lookup. Re-read
                    // and compare bytes; never treat a failed CAS as a successful copy.
                    guard try await controller.identity() == identity else { throw CaptureError.staleSnapshot }
                    continue
                }
                if result.reused, preparedLocalRows {
                    // A staging cleanup failure must not turn the committed copy into
                    // a retry and increment the user's copy count a second time.
                    try? await FileAccessStore(controller: controller).discardPrepared(
                        prepared.localAccess.map(\.id), snapshotID: prepared.capture.id, expecting: identity)
                }
                return result
            }
            throw CaptureError.contention
        } catch {
            // Remove only this attempt's uncommitted local staging; never scan or
            // delete unrelated or committed local authorization records.
            try? await FileAccessStore(controller: controller).discardPrepared(
                prepared.localAccess.map(\.id), snapshotID: prepared.capture.id, expecting: identity)
            throw error
        }
    }

    nonisolated static func matches(_ snapshot: CaptureSnapshotValue, representations: [RepresentationValue]) -> Bool {
        let flat = snapshot.items.enumerated().flatMap { itemIndex, item in
            item.representations.enumerated().map { (itemIndex, $0.offset, $0.element) }
        }
        guard flat.count == representations.count else { return false }
        return zip(flat, representations).allSatisfy { input, stored in
            input.0 == stored.itemIndex && input.1 == stored.representationIndex
                && input.2.typeIdentifier.utf8.elementsEqual(stored.typeIdentifier.utf8)
                && input.2.bytes == stored.bytes
        }
    }

    private nonisolated static func prepare(_ snapshot: CaptureSnapshotValue) throws
        -> (capture: CaptureValue, localAccess: [LocalFileAccess]) {
        let id = UUID()
        var values: [RepresentationValue] = []
        var local: [LocalFileAccess] = []
        for (itemIndex, item) in snapshot.items.enumerated() {
            // File producers can also advertise paths as text or legacy metadata.
            // Keep every representation of such an item local, preserving fidelity.
            let isFileItem = item.representations.contains {
                $0.isLocalFileReference
            }
            for (index, representation) in item.representations.enumerated() {
                let value = RepresentationValue(snapshotID: id, itemIndex: itemIndex, representationIndex: index,
                    typeIdentifier: representation.typeIdentifier, storage: isFileItem ? .localReference : .portable,
                    byteCount: isFileItem ? 0 : Int64(representation.bytes.count),
                    digest: isFileItem ? LocalReferencePrivacy.makeRelocationToken() : ContentDigest.sha256(representation.bytes),
                    bytes: isFileItem ? nil : representation.bytes)
                values.append(value)
                if isFileItem {
                    local.append(LocalFileAccess(id: value.id, snapshotID: id,
                                                 bytes: representation.bytes, bookmark: nil, localPath: nil))
                }
            }
        }
        let manifest = CaptureManifest(version: local.isEmpty ? 1 : LocalReferencePrivacy.manifestVersion,
                                       itemCount: snapshot.items.count, entries: values.map(ManifestEntry.init))
        return (CaptureValue(id: id, manifest: manifest, digest: ContentDigest.sha256(try manifest.canonicalData()),
                             representations: values), local)
    }

    private nonisolated static func title(_ snapshot: CaptureSnapshotValue, hasLocalReferences: Bool) -> String {
        guard !hasLocalReferences else { return snapshot.items.count == 1 ? "File reference" : "File references" }
        if let title = ClipboardTextDecoder.title(snapshot.items) { return title }
        return snapshot.items.count > 1 ? "Copied items" : "Copied content"
    }
}
