import CoreData
import Foundation

enum PayloadReclaimerCheckpoint: Sendable {
    case afterPrepared
    case afterCloudCommitBeforePhaseRecord
    case beforeLocalCompletionSave
}

struct PayloadReclaimer: Sendable {
    typealias Checkpoint = @Sendable (PayloadReclaimerCheckpoint) throws -> Void

    private let controller: PersistenceController
    private let checkpoint: Checkpoint

    init(
        controller: PersistenceController,
        checkpoint: @escaping Checkpoint = { _ in }
    ) {
        self.controller = controller
        self.checkpoint = checkpoint
    }

    func reclaim(
        _ request: CleanupRequest,
        expecting identity: StoreIdentity,
        permit: StorePermit,
        at now: Date = Date()
    ) async throws -> CleanupIntentRecord {
        let intent = try await prepare(request, expecting: identity, permit: permit, at: now)
        try checkpoint(.afterPrepared)
        return try await resume(intent.id, expecting: identity, permit: permit, at: now)
    }

    func prepare(
        _ request: CleanupRequest,
        expecting identity: StoreIdentity,
        permit: StorePermit,
        at now: Date = Date()
    ) async throws -> CleanupIntentRecord {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
        let controller = controller
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            do {
                let cloud = CleanupCloudPlan(
                    preconditions: request.preconditions,
                    mutations: request.mutations
                )
                guard case .item(let sourceItem)? = try StoredRecords.value(
                    .item(request.target.itemID),
                    in: context
                ) else { throw StoreError.notFound }
                let retainsCaptureForInheritedMemo = try Self.retainsCaptureForInheritedMemo(
                    target: request.target,
                    item: sourceItem,
                    in: context
                )
                let usageFacets = try Self.validatePlan(
                    target: request.target,
                    cloud: cloud,
                    sourceItem: sourceItem,
                    retainsCaptureForInheritedMemo: retainsCaptureForInheritedMemo
                )
                let payloads = try Self.capturePayloadEvidence(for: cloud, in: context)
                let payload = CleanupIntentPayload(
                    target: request.target,
                    sourceItem: sourceItem,
                    retainsCaptureForInheritedMemo: retainsCaptureForInheritedMemo,
                    cloud: cloud,
                    payloads: payloads,
                    usageFacets: usageFacets
                )
                let record = try CleanupIntentStore.insert(
                    id: UUID(),
                    identity: identity,
                    payload: payload,
                    at: now,
                    in: context
                )
                try context.save()
                return record
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func resume(
        _ intentID: UUID,
        expecting identity: StoreIdentity,
        permit: StorePermit,
        at now: Date = Date()
    ) async throws -> CleanupIntentRecord {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw StoreError.invalidTransaction }
        let store = CleanupIntentStore(controller: controller)
        var intent = try await store.load(intentID, expecting: identity)
        guard intent.identity == identity else { throw StoreError.preconditionFailed }
        do {
            try Self.validateStoredIntent(intent)
        } catch {
            try await store.block(
                intentID,
                expecting: identity,
                permit: permit,
                at: now,
                includingCompleted: true
            )
            throw CleanupError.blocked
        }
        switch intent.phase {
        case .completed:
            return intent
        case .blocked:
            throw CleanupError.blocked
        case .prepared:
            if try await cloudPoststateMatches(intent, permit: permit) == false {
                do {
                    let transaction = StoreTransaction(
                        transactionID: intent.id,
                        identity: identity,
                        preconditions: intent.payload.cloud.preconditions,
                        mutations: intent.payload.cloud.mutations,
                        permit: permit
                    )
                    try await WriteCoordinator(controller: controller).validate(StoreTransaction(
                        transactionID: intent.id,
                        identity: identity,
                        preconditions: intent.payload.cloud.preconditions,
                        mutations: [],
                        permit: permit
                    ))
                    _ = try await WriteCoordinator(controller: controller).commit(transaction)
                    try checkpoint(.afterCloudCommitBeforePhaseRecord)
                } catch StoreError.preconditionFailed {
                    guard try await cloudPoststateMatches(intent, permit: permit) else {
                        try await store.block(intentID, expecting: identity, permit: permit, at: now)
                        throw CleanupError.blocked
                    }
                }
            }
            guard try await cloudPoststateMatches(intent, permit: permit) else {
                try await store.block(intentID, expecting: identity, permit: permit, at: now)
                throw CleanupError.blocked
            }
            try await markCloudCommitted(intentID, identity: identity, permit: permit, at: now)
            intent = try await store.load(intentID, expecting: identity)
        case .cloudCommitted:
            guard try await cloudPoststateMatches(intent, permit: permit) else {
                try await store.block(intentID, expecting: identity, permit: permit, at: now)
                throw CleanupError.blocked
            }
        }

        do {
            try await finishLocalCleanup(intent, permit: permit, at: now)
        } catch CleanupError.evidenceMismatch {
            try await store.block(intentID, expecting: identity, permit: permit, at: now)
            throw CleanupError.blocked
        }
        return try await store.load(intentID, expecting: identity)
    }
}

private extension PayloadReclaimer {
    static func validatePlan(
        target: CleanupTarget,
        cloud: CleanupCloudPlan,
        sourceItem currentItem: ItemValue,
        retainsCaptureForInheritedMemo: Bool
    ) throws -> [ContentFacet] {
        guard !cloud.mutations.isEmpty else { throw CleanupError.invalidPlan }
        var keys = Set<RecordKey>()
        for mutation in cloud.mutations {
            guard keys.insert(mutationKey(mutation)).inserted else { throw CleanupError.invalidPlan }
        }
        let markerValues = cloud.mutations.compactMap { mutation -> RecordValue? in
            guard case .insert(let value) = mutation else { return nil }
            switch value {
            case .itemMarker, .facetMarker: return value
            default: return nil
            }
        }
        guard markerValues.count == 1 else { throw CleanupError.invalidPlan }

        guard currentItem.id == target.itemID else { throw CleanupError.invalidPlan }
        let isHistoryTarget: Bool
        if case .facet(let identity) = target { isHistoryTarget = identity.facet == .history }
        else { isHistoryTarget = false }
        if !isHistoryTarget && retainsCaptureForInheritedMemo {
            throw CleanupError.invalidPlan
        }
        let allowed: Set<RecordKey>
        let requiredKeys: Set<RecordKey>
        let usageFacets: [ContentFacet]
        switch target {
        case .facet(let identity):
            guard case .facetMarker(let marker) = markerValues[0],
                  marker.itemID == identity.itemID,
                  marker.facet == identity.facet,
                  marker.generationID == identity.generationID else {
                throw CleanupError.invalidPlan
            }
            usageFacets = [identity.facet]
            switch identity.facet {
            case .history:
                guard currentItem.captureID == identity.generationID else { throw StoreError.preconditionFailed }
                allowed = [.item(identity.itemID), .capture(identity.generationID), .facetMarker(marker.id)]
                requiredKeys = [.item(identity.itemID), .facetMarker(marker.id)]
                var expected = currentItem
                expected.historyEligible = false
                expected.historyDeletedAt = nil
                expected.historyPurgeAfter = nil
                if retainsCaptureForInheritedMemo {
                    guard let memoID = currentItem.memoID,
                          hasRecordCAS(.memo(memoID), in: cloud.preconditions) else {
                        throw CleanupError.invalidPlan
                    }
                    guard !cloud.mutations.contains(.delete(.capture(identity.generationID))) else {
                        throw CleanupError.invalidPlan
                    }
                } else {
                    expected.captureID = nil
                }
                guard cloud.mutations.contains(.update(.item(expected))) else {
                    throw CleanupError.invalidPlan
                }
            case .memo:
                guard currentItem.memoID == identity.generationID else { throw StoreError.preconditionFailed }
                let hiddenCaptureID = permanentlyHiddenHistoryCaptureID(
                    item: currentItem,
                    preconditions: cloud.preconditions
                )
                var memoAllowed: Set<RecordKey> = [
                    .item(identity.itemID), .memo(identity.generationID), .facetMarker(marker.id),
                ]
                if let hiddenCaptureID { memoAllowed.insert(.capture(hiddenCaptureID)) }
                allowed = memoAllowed
                requiredKeys = [.item(identity.itemID), .memo(identity.generationID), .facetMarker(marker.id)]
                guard cloud.mutations.contains(where: {
                    guard case .update(.item(let item)) = $0 else { return false }
                    return memoCleanupUpdate(
                        item,
                        isAllowedFrom: currentItem,
                        detachingCapture: hiddenCaptureID
                    )
                }), cloud.mutations.contains(.delete(.memo(identity.generationID))) else {
                    throw CleanupError.invalidPlan
                }
            }

        case .item(let itemID):
            guard case .itemMarker(let marker) = markerValues[0], marker.itemID == itemID else {
                throw CleanupError.invalidPlan
            }
            usageFacets = [.history, .memo]
            var values: Set<RecordKey> = [.item(itemID), .itemMarker(itemID)]
            var required: Set<RecordKey> = [.item(itemID), .itemMarker(itemID)]
            if let memoID = currentItem.memoID {
                values.insert(.memo(memoID))
                required.insert(.memo(memoID))
            }
            if let captureID = currentItem.captureID { values.insert(.capture(captureID)) }
            allowed = values
            requiredKeys = required
            guard cloud.mutations.contains(.delete(.item(itemID))) else { throw CleanupError.invalidPlan }
        }

        guard keys.isSubset(of: allowed), requiredKeys.isSubset(of: keys) else {
            throw CleanupError.invalidPlan
        }
        for mutation in cloud.mutations {
            let key = mutationKey(mutation)
            switch mutation {
            case .insert(let value):
                guard value == markerValues[0] else { throw CleanupError.invalidPlan }
            case .update:
                guard case .item = key else { throw CleanupError.invalidPlan }
                guard hasRecordCAS(key, in: cloud.preconditions) else { throw CleanupError.invalidPlan }
            case .delete:
                guard hasRecordCAS(key, in: cloud.preconditions) else { throw CleanupError.invalidPlan }
                if case .capture(let id) = key,
                   !cloud.preconditions.contains(where: {
                       if case .referenceSet(let snapshotID, _) = $0 { return snapshotID == id }
                       return false
                   }) {
                    throw CleanupError.invalidPlan
                }
            }
        }
        return usageFacets
    }

    static func validateStoredIntent(_ intent: CleanupIntentRecord) throws {
        let expectedUsage = try validatePlan(
            target: intent.payload.target,
            cloud: intent.payload.cloud,
            sourceItem: intent.payload.sourceItem,
            retainsCaptureForInheritedMemo: intent.payload.retainsCaptureForInheritedMemo
        )
        guard expectedUsage == intent.payload.usageFacets,
              Set(intent.payload.payloads.map { $0.identity.representationID }).count
                == intent.payload.payloads.count else {
            throw CleanupError.invalidPlan
        }
        let deletedCaptures = Set(intent.payload.cloud.expectedAbsentKeys.compactMap { key -> UUID? in
            if case .capture(let id) = key { return id }
            return nil
        })
        for evidence in intent.payload.payloads {
            guard deletedCaptures.contains(evidence.identity.snapshotID),
                  evidence.cloudRepresentation.id == evidence.identity.representationID,
                  evidence.cloudRepresentation.snapshotID == evidence.identity.snapshotID,
                  evidence.cloudRepresentation.storage == .localReference,
                  try StoredRecords.canonicalDigest(evidence.cloudRepresentation)
                    == evidence.identity.cloudToken else {
                throw CleanupError.invalidPlan
            }
        }
    }

    static func retainsCaptureForInheritedMemo(
        target: CleanupTarget,
        item: ItemValue,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        guard case .facet(let identity) = target, identity.facet == .history,
              let memoID = item.memoID else { return false }
        guard case .memo(let memo)? = try StoredRecords.value(.memo(memoID), in: context),
              memo.itemID == item.id else {
            throw StoreError.corruptStore
        }
        return memo.bodyMode == .inheritedCapture
    }

    static func capturePayloadEvidence(
        for cloud: CleanupCloudPlan,
        in context: NSManagedObjectContext
    ) throws -> [CleanupPayloadEvidence] {
        var result: [CleanupPayloadEvidence] = []
        for key in cloud.expectedAbsentKeys {
            guard case .capture(let captureID) = key else { continue }
            guard case .capture(let capture)? = try StoredRecords.value(.capture(captureID), in: context) else {
                throw StoreError.notFound
            }
            for representation in capture.representations where representation.storage == .localReference {
                let request = NSFetchRequest<NSManagedObject>(entityName: "FileAccessRecord")
                request.predicate = NSPredicate(format: "id == %@", representation.id as NSUUID)
                request.fetchLimit = 2
                let rows = try context.fetch(request)
                guard rows.count <= 1 else { throw StoreError.corruptStore }
                guard let row = rows.first else { continue }
                guard row.value(forKey: "id") as? UUID == representation.id,
                      row.value(forKey: "snapshotID") as? UUID == captureID,
                      let envelope = row.value(forKey: "bytes") as? Data else {
                    throw StoreError.corruptStore
                }
                let token = try StoredRecords.canonicalDigest(representation)
                result.append(CleanupPayloadEvidence(
                    identity: CleanupPayloadIdentity(
                        representationID: representation.id,
                        snapshotID: captureID,
                        envelopeByteCount: Int64(envelope.count),
                        envelopeDigest: ContentDigest.sha256(envelope),
                        cloudToken: token
                    ),
                    cloudRepresentation: representation
                ))
            }
        }
        guard Set(result.map { $0.identity.representationID }).count == result.count else {
            throw StoreError.corruptStore
        }
        return result.sorted { $0.identity.representationID.uuidString < $1.identity.representationID.uuidString }
    }

    func cloudPoststateMatches(
        _ intent: CleanupIntentRecord,
        permit: StorePermit
    ) async throws -> Bool {
        let controller = controller
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard intent.identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            for expected in intent.payload.cloud.expectedRecords {
                guard try StoredRecords.value(expected.key, in: context) == expected else { return false }
            }
            for key in intent.payload.cloud.expectedAbsentKeys {
                guard try StoredRecords.object(key, in: context) == nil else { return false }
                if case .capture(let snapshotID) = key {
                    let representations = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
                    representations.predicate = NSPredicate(format: "snapshotID == %@", snapshotID as NSUUID)
                    guard try context.count(for: representations) == 0 else { return false }
                }
            }
            return true
        }
    }

    func markCloudCommitted(
        _ intentID: UUID,
        identity: StoreIdentity,
        permit: StorePermit,
        at now: Date
    ) async throws {
        let controller = controller
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            do {
                let current = try CleanupIntentStore.decode(id: intentID, identity: identity, in: context)
                if current.phase == .completed { return }
                try CleanupIntentStore.stagePhase(
                    id: intentID,
                    identity: identity,
                    from: [.prepared, .cloudCommitted],
                    to: .cloudCommitted,
                    at: now,
                    in: context
                )
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func finishLocalCleanup(
        _ intent: CleanupIntentRecord,
        permit: StorePermit,
        at now: Date
    ) async throws {
        let controller = controller
        let checkpoint = checkpoint
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard intent.identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.maintenance, runtime: controller.runtime, permit: permit)
            do {
                guard try Self.poststateMatches(intent.payload.cloud, in: context) else {
                    throw CleanupError.evidenceMismatch
                }
                for evidence in intent.payload.payloads {
                    let payload = evidence.identity
                    guard evidence.cloudRepresentation.id == payload.representationID,
                          evidence.cloudRepresentation.snapshotID == payload.snapshotID,
                          evidence.cloudRepresentation.storage == .localReference,
                          try StoredRecords.canonicalDigest(evidence.cloudRepresentation) == payload.cloudToken,
                          !controller.runtime.isPayloadProtected(.capture(payload.snapshotID)) else {
                        if controller.runtime.isPayloadProtected(.capture(payload.snapshotID)) {
                            throw StoreError.contentProtected
                        }
                        throw CleanupError.evidenceMismatch
                    }
                    let representation = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
                    representation.predicate = NSPredicate(format: "id == %@", payload.representationID as NSUUID)
                    guard try context.count(for: representation) == 0 else {
                        throw CleanupError.evidenceMismatch
                    }
                    let capture = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureSnapshot")
                    capture.predicate = NSPredicate(format: "id == %@", payload.snapshotID as NSUUID)
                    guard try context.count(for: capture) == 0 else { throw CleanupError.evidenceMismatch }
                    let references = NSFetchRequest<NSFetchRequestResult>(entityName: "LibraryItem")
                    references.predicate = NSPredicate(format: "captureID == %@", payload.snapshotID as NSUUID)
                    guard try context.count(for: references) == 0 else { throw CleanupError.evidenceMismatch }
                }
                let fileAccessChanged: Bool
                do {
                    fileAccessChanged = try FileAccessStore.stageExactCleanup(
                        intent.payload.payloads.map(\.identity),
                        in: context
                    )
                } catch FileAccessCleanupError.evidenceMismatch {
                    throw CleanupError.evidenceMismatch
                } catch StoreError.corruptStore {
                    throw CleanupError.evidenceMismatch
                }
                do {
                    _ = try LocalUsageStore.stageExactCleanup(
                        itemID: intent.payload.target.itemID,
                        facets: Set(intent.payload.usageFacets),
                        in: context
                    )
                } catch StoreError.corruptStore {
                    throw CleanupError.evidenceMismatch
                }
                try CleanupIntentStore.stagePhase(
                    id: intent.id,
                    identity: intent.identity,
                    from: [.cloudCommitted, .completed],
                    to: .completed,
                    at: now,
                    in: context
                )
                try checkpoint(.beforeLocalCompletionSave)
                try context.save()
                if fileAccessChanged {
                    CaptureCandidateRepository.invalidateLocalIndex(runtime: controller.runtime)
                }
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    static func poststateMatches(
        _ cloud: CleanupCloudPlan,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        for expected in cloud.expectedRecords {
            guard try StoredRecords.value(expected.key, in: context) == expected else { return false }
        }
        for key in cloud.expectedAbsentKeys {
            guard try StoredRecords.object(key, in: context) == nil else { return false }
        }
        return true
    }

    static func mutationKey(_ mutation: StoreMutation) -> RecordKey {
        switch mutation {
        case .insert(let value), .update(let value): value.key
        case .delete(let key): key
        }
    }

    static func hasRecordCAS(_ key: RecordKey, in preconditions: [StorePrecondition]) -> Bool {
        preconditions.contains {
            if case .recordUnchanged(let candidate, _) = $0 { return candidate == key }
            return false
        }
    }

    static func permanentlyHiddenHistoryCaptureID(
        item: ItemValue,
        preconditions: [StorePrecondition]
    ) -> UUID? {
        guard !item.historyEligible,
              item.historyDeletedAt == nil,
              item.historyPurgeAfter == nil,
              let captureID = item.captureID else { return nil }
        let markerID = LifecycleCleanupMarkerID.facet(
            .history(itemID: item.id, captureID: captureID)
        )
        guard preconditions.contains(.exists(.facetMarker(markerID))) else { return nil }
        return captureID
    }

    static func memoCleanupUpdate(
        _ updated: ItemValue,
        isAllowedFrom source: ItemValue,
        detachingCapture captureID: UUID?
    ) -> Bool {
        var candidates: [ItemValue] = []
        var detached = source
        detached.memoID = nil
        if let captureID {
            guard detached.captureID == captureID else { return false }
            detached.captureID = nil
        }
        candidates.append(detached)
        if detached.isFavorite {
            var clearedFavorite = detached
            clearedFavorite.isFavorite = false
            candidates.append(clearedFavorite)
        }
        if !detached.collectionIDs.isEmpty {
            var clearedCollection = detached
            clearedCollection.collectionIDs = []
            candidates.append(clearedCollection)
            if clearedCollection.isFavorite {
                clearedCollection.isFavorite = false
                candidates.append(clearedCollection)
            }
        }
        return candidates.contains(updated)
    }
}
