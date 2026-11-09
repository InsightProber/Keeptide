import CoreData
import Foundation

enum LifecycleCleanupTrigger: Equatable, Sendable {
    case explicitUserRequest
    case deletionWindowExpired
    case naturalExpiration(RetentionPolicy)
}

enum LifecycleCleanupPlanningError: Error, Equatable {
    case explicitRequestRequired
    case deletionWindowStillOpen
    case invalidDeletionState
    case historyNotExpired
}

struct LifecycleCleanupCandidate: Equatable, Sendable {
    let target: DeletedFacetIdentity
    let trigger: LifecycleCleanupTrigger
}

enum LifecycleCleanupCandidateCursor: Equatable, Sendable {
    case natural(lastCopiedAt: Date, itemID: ItemID)
    case historyDeleted(purgeAfter: Date?, itemID: ItemID?)
    case memoDeleted(purgeAfter: Date?, memoID: UUID?)
}

struct LifecycleCleanupCandidatePage: Equatable, Sendable {
    let candidates: [LifecycleCleanupCandidate]
    let next: LifecycleCleanupCandidateCursor?
}

enum LifecycleCleanupMarkerID {
    static func facet(_ target: DeletedFacetIdentity) -> UUID {
        let seed = Data(
            "keeptide/facet-marker/v1/\(target.itemID.rawValue.uuidString)/\(target.facet.rawValue)/\(target.generationID.uuidString)".utf8
        )
        let bytes = Array(ContentDigest.sha256(seed).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Builds exact, CAS-fenced cleanup transactions. Execution is always routed
/// through PayloadReclaimer so the durable intent precedes the cloud mutation.
struct LifecycleCleanupService: Sendable {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    func purgeFacet(
        _ target: DeletedFacetIdentity,
        trigger: LifecycleCleanupTrigger,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> CleanupIntentRecord {
        let intent = try await prepareFacetPurge(
            target,
            trigger: trigger,
            at: now,
            expecting: identity,
            permit: permit
        )
        return try await resume(intent.id, at: now, expecting: identity, permit: permit)
    }

    func prepareFacetPurge(
        _ target: DeletedFacetIdentity,
        trigger: LifecycleCleanupTrigger,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> CleanupIntentRecord {
        let request = try await LifecycleCleanupPlanner(controller: controller).facetRequest(
            target,
            trigger: trigger,
            at: now,
            expecting: identity,
            permit: permit
        )
        return try await PayloadReclaimer(controller: controller).prepare(
            request,
            expecting: identity,
            permit: permit,
            at: now
        )
    }

    func purgeItem(
        _ itemID: ItemID,
        explicitlyRequested: Bool,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> CleanupIntentRecord {
        guard explicitlyRequested else { throw LifecycleCleanupPlanningError.explicitRequestRequired }
        let request = try await LifecycleCleanupPlanner(controller: controller).itemRequest(
            itemID,
            at: now,
            expecting: identity,
            permit: permit
        )
        let intent = try await PayloadReclaimer(controller: controller).prepare(
            request,
            expecting: identity,
            permit: permit,
            at: now
        )
        return try await resume(intent.id, at: now, expecting: identity, permit: permit)
    }

    func resume(
        _ intentID: UUID,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> CleanupIntentRecord {
        try await PayloadReclaimer(controller: controller).resume(
            intentID,
            expecting: identity,
            permit: permit,
            at: now
        )
    }
}

struct LifecycleCleanupPlanner: Sendable {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    /// Restart-safe discovery for already-hidden natural history and elapsed
    /// trash windows. At most `limit` store rows are examined per call; callers
    /// persist or immediately consume `next` rather than retaining an ID corpus.
    func candidates(
        policy: RetentionPolicy,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit,
        after cursor: LifecycleCleanupCandidateCursor? = nil,
        limit: Int = 128
    ) async throws -> LifecycleCleanupCandidatePage {
        guard (1...128).contains(limit) else { throw StoreError.invalidTransaction }
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try validateAccess(expecting: identity, permit: permit)
            _ = try policy.isExpired(lastCopiedAt: now, at: now)

            var candidates: [LifecycleCleanupCandidate] = []
            var budget = limit
            var stage = cursor
            while budget > 0 {
                switch stage {
                case nil:
                    let page = try naturalCandidates(
                        policy: policy,
                        at: now,
                        after: nil,
                        limit: budget,
                        in: context
                    )
                    candidates.append(contentsOf: page.candidates)
                    budget -= page.examined
                    if let next = page.next { return LifecycleCleanupCandidatePage(candidates: candidates, next: next) }
                    stage = .historyDeleted(purgeAfter: nil, itemID: nil)

                case .natural(let lastCopiedAt, let itemID):
                    let page = try naturalCandidates(
                        policy: policy,
                        at: now,
                        after: LifecycleHistoryCursor(lastCopiedAt: lastCopiedAt, itemID: itemID),
                        limit: budget,
                        in: context
                    )
                    candidates.append(contentsOf: page.candidates)
                    budget -= page.examined
                    if let next = page.next { return LifecycleCleanupCandidatePage(candidates: candidates, next: next) }
                    stage = .historyDeleted(purgeAfter: nil, itemID: nil)

                case .historyDeleted(let purgeAfter, let itemID):
                    guard (purgeAfter == nil) == (itemID == nil) else { throw StoreError.invalidToken }
                    let page = try deletedHistoryCandidates(
                        at: now,
                        after: purgeAfter.flatMap { date in itemID.map { (date, $0) } },
                        limit: budget,
                        in: context
                    )
                    candidates.append(contentsOf: page.candidates)
                    budget -= page.examined
                    if let next = page.next { return LifecycleCleanupCandidatePage(candidates: candidates, next: next) }
                    stage = .memoDeleted(purgeAfter: nil, memoID: nil)

                case .memoDeleted(let purgeAfter, let memoID):
                    guard (purgeAfter == nil) == (memoID == nil) else { throw StoreError.invalidToken }
                    let page = try deletedMemoCandidates(
                        at: now,
                        after: purgeAfter.flatMap { date in memoID.map { (date, $0) } },
                        limit: budget,
                        in: context
                    )
                    candidates.append(contentsOf: page.candidates)
                    budget -= page.examined
                    if let next = page.next { return LifecycleCleanupCandidatePage(candidates: candidates, next: next) }
                    return LifecycleCleanupCandidatePage(candidates: candidates, next: nil)
                }
            }
            return LifecycleCleanupCandidatePage(candidates: candidates, next: stage)
        }
    }

    func facetRequest(
        _ target: DeletedFacetIdentity,
        trigger: LifecycleCleanupTrigger,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> CleanupRequest {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try validateAccess(expecting: identity, permit: permit)
            guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
            let snapshot = try facetSnapshot(target, in: context)
            try validate(trigger, for: target.facet, item: snapshot.item, memo: snapshot.memo, at: now)

            let marker = FacetDeletionMarkerValue(
                id: LifecycleCleanupMarkerID.facet(target),
                itemID: target.itemID,
                facet: target.facet,
                generationID: target.generationID,
                purgedAt: now
            )
            var preconditions: [StorePrecondition] = [
                .recordUnchanged(.item(target.itemID), fingerprint: snapshot.itemFingerprint),
                .absent(.facetMarker(marker.id)),
            ]
            var mutations: [StoreMutation] = [.insert(.facetMarker(marker))]

            switch target.facet {
            case .history:
                var item = snapshot.item
                item.historyEligible = false
                item.historyDeletedAt = nil
                item.historyPurgeAfter = nil
                let memoIsInherited = snapshot.memo?.bodyMode == .inheritedCapture
                if memoIsInherited {
                    guard let memo = snapshot.memo, let memoFingerprint = snapshot.memoFingerprint else {
                        throw StoreError.corruptStore
                    }
                    preconditions.append(.recordUnchanged(.memo(memo.id), fingerprint: memoFingerprint))
                }
                if !memoIsInherited {
                    item.captureID = nil
                }
                mutations.append(.update(.item(item)))

                if !memoIsInherited, snapshot.captureReferenceCount == 1 {
                    guard let captureFingerprint = snapshot.captureFingerprint,
                          let referenceFingerprint = snapshot.referenceFingerprint else {
                        throw StoreError.corruptStore
                    }
                    guard !controller.runtime.isPayloadProtected(.capture(target.generationID)) else {
                        throw StoreError.contentProtected
                    }
                    preconditions.append(.recordUnchanged(
                        .capture(target.generationID),
                        fingerprint: captureFingerprint
                    ))
                    preconditions.append(.referenceSet(
                        snapshotID: target.generationID,
                        fingerprint: referenceFingerprint
                    ))
                    mutations.append(.delete(.capture(target.generationID)))
                }

            case .memo:
                guard let memo = snapshot.memo, let memoFingerprint = snapshot.memoFingerprint else {
                    throw StoreError.corruptStore
                }
                guard !controller.runtime.isPayloadProtected(.memo(memo.id)) else {
                    throw StoreError.contentProtected
                }
                var item = snapshot.item
                item.memoID = nil
                item.collectionIDs = []
                item.isFavorite = false
                let hiddenHistory = try permanentlyHiddenHistory(
                    item: snapshot.item,
                    in: context
                )
                if hiddenHistory != nil {
                    item.captureID = nil
                }
                preconditions.append(.recordUnchanged(.memo(memo.id), fingerprint: memoFingerprint))
                mutations.append(.update(.item(item)))
                mutations.append(.delete(.memo(memo.id)))

                if let hiddenHistory {
                    preconditions.append(.exists(.facetMarker(hiddenHistory.markerID)))
                }
                if let captureID = hiddenHistory?.captureID, snapshot.captureReferenceCount == 1 {
                    guard let captureFingerprint = snapshot.captureFingerprint,
                          let referenceFingerprint = snapshot.referenceFingerprint else {
                        throw StoreError.corruptStore
                    }
                    guard !controller.runtime.isPayloadProtected(.capture(captureID)) else {
                        throw StoreError.contentProtected
                    }
                    preconditions.append(.recordUnchanged(.capture(captureID), fingerprint: captureFingerprint))
                    preconditions.append(.referenceSet(snapshotID: captureID, fingerprint: referenceFingerprint))
                    mutations.append(.delete(.capture(captureID)))
                }
            }

            return CleanupRequest(
                target: .facet(target),
                preconditions: preconditions,
                mutations: mutations
            )
        }
    }

    func itemRequest(
        _ itemID: ItemID,
        at now: Date,
        expecting identity: StoreIdentity,
        permit: StorePermit
    ) async throws -> CleanupRequest {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try validateAccess(expecting: identity, permit: permit)
            guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
            let snapshot = try itemSnapshot(itemID, in: context)
            let marker = ItemDeletionMarkerValue(itemID: itemID, deletedAt: now)
            var preconditions: [StorePrecondition] = [
                .recordUnchanged(.item(itemID), fingerprint: snapshot.itemFingerprint),
                .absent(.itemMarker(itemID)),
            ]
            var mutations: [StoreMutation] = [.insert(.itemMarker(marker))]

            if let memo = snapshot.memo, let fingerprint = snapshot.memoFingerprint {
                guard !controller.runtime.isPayloadProtected(.memo(memo.id)) else {
                    throw StoreError.contentProtected
                }
                preconditions.append(.recordUnchanged(.memo(memo.id), fingerprint: fingerprint))
                mutations.append(.delete(.memo(memo.id)))
            }
            mutations.append(.delete(.item(itemID)))

            if let captureID = snapshot.item.captureID, snapshot.captureReferenceCount == 1 {
                guard let captureFingerprint = snapshot.captureFingerprint,
                      let referenceFingerprint = snapshot.referenceFingerprint else {
                    throw StoreError.corruptStore
                }
                guard !controller.runtime.isPayloadProtected(.capture(captureID)) else {
                    throw StoreError.contentProtected
                }
                preconditions.append(.recordUnchanged(.capture(captureID), fingerprint: captureFingerprint))
                preconditions.append(.referenceSet(snapshotID: captureID, fingerprint: referenceFingerprint))
                mutations.append(.delete(.capture(captureID)))
            }

            return CleanupRequest(
                target: .item(itemID),
                preconditions: preconditions,
                mutations: mutations
            )
        }
    }
}

private extension LifecycleCleanupPlanner {
    struct CandidateSlice {
        let candidates: [LifecycleCleanupCandidate]
        let examined: Int
        let next: LifecycleCleanupCandidateCursor?
    }

    struct Snapshot {
        let item: ItemValue
        let itemFingerprint: Data
        let memo: MemoValue?
        let memoFingerprint: Data?
        let captureFingerprint: Data?
        let referenceFingerprint: Data?
        let captureReferenceCount: Int
    }

    func validateAccess(expecting identity: StoreIdentity, permit: StorePermit) throws {
        guard controller.runtime.identity == identity else { throw StoreError.preconditionFailed }
        try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
    }

    func naturalCandidates(
        policy: RetentionPolicy,
        at now: Date,
        after cursor: LifecycleHistoryCursor?,
        limit: Int,
        in context: NSManagedObjectContext
    ) throws -> CandidateSlice {
        guard limit > 0 else { return CandidateSlice(candidates: [], examined: 0, next: nil) }
        if case .permanent = policy {
            return CandidateSlice(candidates: [], examined: 0, next: nil)
        }
        var predicates = [
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "historyEligible == NO"),
            NSPredicate(format: "historyDeletedAt == nil"),
            NSPredicate(format: "historyPurgeAfter == nil"),
            NSPredicate(format: "captureID != nil"),
        ]
        if let cursor {
            predicates.append(keysetPredicate(
                dateKey: "lastCopiedAt",
                idKey: "id",
                date: cursor.lastCopiedAt,
                id: cursor.itemID.rawValue
            ))
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "lastCopiedAt", ascending: true),
            NSSortDescriptor(key: "id", ascending: true),
        ]
        request.fetchLimit = limit
        let rows = try context.fetch(request)
        var result: [LifecycleCleanupCandidate] = []
        var reachedRetentionBoundary = false
        var last: LifecycleHistoryCursor?
        for row in rows {
            guard let rawID = row.value(forKey: "id") as? UUID,
                  let lastCopiedAt = row.value(forKey: "lastCopiedAt") as? Date else {
                throw StoreError.corruptStore
            }
            let itemID = ItemID(rawValue: rawID)
            last = LifecycleHistoryCursor(lastCopiedAt: lastCopiedAt, itemID: itemID)
            guard try policy.isExpired(lastCopiedAt: lastCopiedAt, at: now) else {
                reachedRetentionBoundary = true
                break
            }
            // A row whose item record is missing, or whose capture is gone, is left as it is: nothing of it is
            // deleted, and it does not hold up the cleanup of the rows after it. The cursor has already passed it.
            guard case .item(let item)? = try StoredRecords.value(.item(itemID), in: context),
                  let captureID = item.captureID,
                  try StoredRecords.object(.capture(captureID), in: context) != nil else { continue }
            let target = DeletedFacetIdentity.history(itemID: itemID, captureID: captureID)
            if try isCleanupVisible(target, in: context) {
                result.append(LifecycleCleanupCandidate(target: target, trigger: .naturalExpiration(policy)))
            }
        }
        let hasMore = rows.count == limit && !reachedRetentionBoundary
        let next: LifecycleCleanupCandidateCursor? = hasMore ? last.map {
            LifecycleCleanupCandidateCursor.natural(lastCopiedAt: $0.lastCopiedAt, itemID: $0.itemID)
        } : nil
        return CandidateSlice(candidates: result, examined: rows.count, next: next)
    }

    func deletedHistoryCandidates(
        at now: Date,
        after cursor: (Date, ItemID)?,
        limit: Int,
        in context: NSManagedObjectContext
    ) throws -> CandidateSlice {
        guard limit > 0 else {
            return CandidateSlice(candidates: [], examined: 0, next: .historyDeleted(purgeAfter: nil, itemID: nil))
        }
        var predicates = [
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "historyEligible == NO"),
            NSPredicate(format: "historyDeletedAt != nil"),
            NSPredicate(format: "historyPurgeAfter <= %@", now as NSDate),
            NSPredicate(format: "captureID != nil"),
        ]
        if let cursor {
            predicates.append(keysetPredicate(
                dateKey: "historyPurgeAfter", idKey: "id",
                date: cursor.0, id: cursor.1.rawValue
            ))
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryItem")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "historyPurgeAfter", ascending: true),
            NSSortDescriptor(key: "id", ascending: true),
        ]
        request.fetchLimit = limit
        let rows = try context.fetch(request)
        var result: [LifecycleCleanupCandidate] = []
        var last: (Date, ItemID)?
        for row in rows {
            guard let rawID = row.value(forKey: "id") as? UUID,
                  let purgeAfter = row.value(forKey: "historyPurgeAfter") as? Date else {
                throw StoreError.corruptStore
            }
            let itemID = ItemID(rawValue: rawID)
            last = (purgeAfter, itemID)
            // A row whose capture is gone, or whose deletion window is not a valid one that has ended, is left as it
            // is: nothing of it is deleted, and it does not hold up the cleanup of the rows after it, as with memos
            // below. The cursor has already passed it.
            guard case .item(let item)? = try StoredRecords.value(.item(itemID), in: context),
                  let captureID = item.captureID,
                  try StoredRecords.object(.capture(captureID), in: context) != nil,
                  let window = try? validatedWindow(item.historyDeletedAt, item.historyPurgeAfter),
                  try window.isPurgeEligible(at: now) else { continue }
            let target = DeletedFacetIdentity.history(itemID: itemID, captureID: captureID)
            if try isCleanupVisible(target, in: context) {
                result.append(LifecycleCleanupCandidate(target: target, trigger: .deletionWindowExpired))
            }
        }
        let next: LifecycleCleanupCandidateCursor? = rows.count == limit ? last.map {
            LifecycleCleanupCandidateCursor.historyDeleted(purgeAfter: $0.0, itemID: $0.1)
        } : nil
        return CandidateSlice(candidates: result, examined: rows.count, next: next)
    }

    func deletedMemoCandidates(
        at now: Date,
        after cursor: (Date, UUID)?,
        limit: Int,
        in context: NSManagedObjectContext
    ) throws -> CandidateSlice {
        guard limit > 0 else {
            return CandidateSlice(candidates: [], examined: 0, next: .memoDeleted(purgeAfter: nil, memoID: nil))
        }
        var predicates = [
            NSPredicate(format: "deletedAt != nil"),
            NSPredicate(format: "purgeAfter <= %@", now as NSDate),
        ]
        if let cursor {
            predicates.append(keysetPredicate(
                dateKey: "purgeAfter", idKey: "id", date: cursor.0, id: cursor.1
            ))
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "MemoDocument")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "purgeAfter", ascending: true),
            NSSortDescriptor(key: "id", ascending: true),
        ]
        request.fetchLimit = limit
        let rows = try context.fetch(request)
        var result: [LifecycleCleanupCandidate] = []
        var last: (Date, UUID)?
        for row in rows {
            guard let memoID = row.value(forKey: "id") as? UUID,
                  let rawItemID = row.value(forKey: "itemID") as? UUID,
                  let deletedAt = row.value(forKey: "deletedAt") as? Date,
                  let purgeAfter = row.value(forKey: "purgeAfter") as? Date else {
                throw StoreError.corruptStore
            }
            last = (purgeAfter, memoID)
            let itemID = ItemID(rawValue: rawItemID)
            // A memo whose deletion window is not a valid one that has ended, or whose item no longer holds it, is left
            // as it is and does not hold up the rows after it.
            guard let window = try? validatedWindow(deletedAt, purgeAfter),
                  try window.isPurgeEligible(at: now),
                  case .item(let item)? = try StoredRecords.value(.item(itemID), in: context),
                  item.deletedAt == nil,
                  item.memoID == memoID else { continue }
            let target = DeletedFacetIdentity.memo(itemID: itemID, memoID: memoID)
            if try isCleanupVisible(target, in: context) {
                result.append(LifecycleCleanupCandidate(target: target, trigger: .deletionWindowExpired))
            }
        }
        let next: LifecycleCleanupCandidateCursor? = rows.count == limit ? last.map {
            LifecycleCleanupCandidateCursor.memoDeleted(purgeAfter: $0.0, memoID: $0.1)
        } : nil
        return CandidateSlice(candidates: result, examined: rows.count, next: next)
    }

    func keysetPredicate(dateKey: String, idKey: String, date: Date, id: UUID) -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "%K > %@", dateKey, date as NSDate),
            NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", dateKey, date as NSDate),
                NSPredicate(format: "%K > %@", idKey, id as NSUUID),
            ]),
        ])
    }

    func isCleanupVisible(
        _ target: DeletedFacetIdentity,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        guard try StoredRecords.object(.itemMarker(target.itemID), in: context) == nil else { return false }
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "FacetDeletionMarker")
        request.predicate = NSPredicate(
            format: "itemID == %@ AND facet == %@ AND generationID == %@",
            target.itemID.rawValue as NSUUID,
            target.facet.rawValue,
            target.generationID as NSUUID
        )
        request.fetchLimit = 1
        return try context.count(for: request) == 0
    }

    func permanentlyHiddenHistory(
        item: ItemValue,
        in context: NSManagedObjectContext
    ) throws -> (captureID: UUID, markerID: UUID)? {
        guard !item.historyEligible,
              item.historyDeletedAt == nil,
              item.historyPurgeAfter == nil,
              let captureID = item.captureID else { return nil }
        let request = NSFetchRequest<NSManagedObject>(entityName: "FacetDeletionMarker")
        request.predicate = NSPredicate(
            format: "itemID == %@ AND facet == %@ AND generationID == %@",
            item.id.rawValue as NSUUID,
            ContentFacet.history.rawValue,
            captureID as NSUUID
        )
        request.fetchLimit = 2
        let markers = try context.fetch(request)
        guard markers.count <= 1 else { throw StoreError.corruptStore }
        guard let marker = markers.first else { return nil }
        let target = DeletedFacetIdentity.history(itemID: item.id, captureID: captureID)
        let expectedID = LifecycleCleanupMarkerID.facet(target)
        guard marker.value(forKey: "id") as? UUID == expectedID else { throw StoreError.corruptStore }
        return (captureID, expectedID)
    }

    func facetSnapshot(
        _ target: DeletedFacetIdentity,
        in context: NSManagedObjectContext
    ) throws -> Snapshot {
        let snapshot = try itemSnapshot(target.itemID, in: context)
        return try requireNoExactFacetMarker(target, snapshot: snapshot, in: context)
    }

    func requireNoExactFacetMarker(
        _ target: DeletedFacetIdentity,
        snapshot: Snapshot,
        in context: NSManagedObjectContext
    ) throws -> Snapshot {
        let marker = NSFetchRequest<NSFetchRequestResult>(entityName: "FacetDeletionMarker")
        marker.predicate = NSPredicate(
            format: "itemID == %@ AND facet == %@ AND generationID == %@",
            target.itemID.rawValue as NSUUID,
            target.facet.rawValue,
            target.generationID as NSUUID
        )
        marker.fetchLimit = 1
        guard try context.count(for: marker) == 0 else { throw StoreError.notFound }
        switch target.facet {
        case .history:
            guard snapshot.item.captureID == target.generationID,
                  snapshot.captureReferenceCount > 0,
                  snapshot.captureFingerprint != nil,
                  snapshot.referenceFingerprint != nil else {
                throw StoreError.notFound
            }
        case .memo:
            guard snapshot.item.memoID == target.generationID,
                  snapshot.memo?.id == target.generationID else {
                throw StoreError.notFound
            }
        }
        return snapshot
    }

    func itemSnapshot(_ itemID: ItemID, in context: NSManagedObjectContext) throws -> Snapshot {
        guard try StoredRecords.object(.itemMarker(itemID), in: context) == nil,
              case .item(let item)? = try StoredRecords.value(.item(itemID), in: context),
              item.deletedAt == nil else { throw StoreError.notFound }
        let itemFingerprint = try StoredRecords.fingerprint(.item(itemID), in: context)

        let memo: MemoValue?
        let memoFingerprint: Data?
        if let memoID = item.memoID {
            guard case .memo(let value)? = try StoredRecords.value(.memo(memoID), in: context),
                  value.itemID == itemID else { throw StoreError.corruptStore }
            memo = value
            memoFingerprint = try StoredRecords.fingerprint(.memo(memoID), in: context)
        } else {
            memo = nil
            memoFingerprint = nil
        }

        let captureFingerprint: Data?
        let referenceFingerprint: Data?
        let captureReferenceCount: Int
        if let captureID = item.captureID {
            guard try StoredRecords.object(.capture(captureID), in: context) != nil else {
                throw StoreError.corruptStore
            }
            captureFingerprint = try StoredRecords.fingerprint(.capture(captureID), in: context)
            referenceFingerprint = try StoredRecords.referenceFingerprint(snapshotID: captureID, in: context)
            let references = NSFetchRequest<NSFetchRequestResult>(entityName: "LibraryItem")
            references.predicate = NSPredicate(format: "captureID == %@", captureID as NSUUID)
            captureReferenceCount = try context.count(for: references)
        } else {
            captureFingerprint = nil
            referenceFingerprint = nil
            captureReferenceCount = 0
        }
        return Snapshot(
            item: item,
            itemFingerprint: itemFingerprint,
            memo: memo,
            memoFingerprint: memoFingerprint,
            captureFingerprint: captureFingerprint,
            referenceFingerprint: referenceFingerprint,
            captureReferenceCount: captureReferenceCount
        )
    }

    func validate(
        _ trigger: LifecycleCleanupTrigger,
        for facet: ContentFacet,
        item: ItemValue,
        memo: MemoValue?,
        at now: Date
    ) throws {
        let window: DeletionWindow?
        switch facet {
        case .history:
            guard !item.historyEligible else { throw LifecycleCleanupPlanningError.invalidDeletionState }
            window = try validatedWindow(item.historyDeletedAt, item.historyPurgeAfter)
        case .memo:
            guard let memo else { throw StoreError.notFound }
            window = try validatedWindow(memo.deletedAt, memo.purgeAfter)
        }

        switch trigger {
        case .explicitUserRequest:
            guard let window else { throw LifecycleCleanupPlanningError.invalidDeletionState }
            _ = try window.isPurgeEligible(at: now)
            guard now >= window.deletedAt else { throw LifecycleCleanupPlanningError.invalidDeletionState }
        case .deletionWindowExpired:
            guard let window else { throw LifecycleCleanupPlanningError.invalidDeletionState }
            guard try window.isPurgeEligible(at: now) else {
                throw LifecycleCleanupPlanningError.deletionWindowStillOpen
            }
        case .naturalExpiration(let policy):
            guard facet == .history, window == nil else {
                throw LifecycleCleanupPlanningError.invalidDeletionState
            }
            guard try policy.isExpired(lastCopiedAt: item.lastCopiedAt, at: now) else {
                throw LifecycleCleanupPlanningError.historyNotExpired
            }
        }
    }

    func validatedWindow(_ deletedAt: Date?, _ purgeAfter: Date?) throws -> DeletionWindow? {
        do { return try DeletionWindow.validated(deletedAt: deletedAt, purgeAfter: purgeAfter) }
        catch { throw StoreError.corruptStore }
    }

}
