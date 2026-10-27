import CoreData
import Foundation

enum UseOutcome: String, Codable, Sendable {
    case success
    case failure
    case cancelled
}

struct UseReceipt: Codable, Equatable, Sendable {
    var executionID: UUID
    var ref: ContentRef
    var occurredAt: Date
    var outcome: UseOutcome

    init(
        executionID: UUID = UUID(),
        ref: ContentRef,
        occurredAt: Date = Date(),
        outcome: UseOutcome
    ) {
        self.executionID = executionID
        self.ref = ref
        self.occurredAt = occurredAt
        self.outcome = outcome
    }
}

struct UsageSummary: Codable, Equatable, Sendable {
    var itemID: ItemID
    var facet: ContentFacet
    var lastUsedAt: Date
    var useCount: Int64
}

struct UsageDeduplicationPolicy: Equatable, Sendable {
    let limit: Int
    let interval: TimeInterval

    init(limit: Int, interval: TimeInterval) {
        self.limit = max(0, limit)
        self.interval = interval.isFinite ? max(0, interval) : 0
    }
}

final class LocalUsageStore: @unchecked Sendable {
    private let controller: PersistenceController
    private let policy: UsageDeduplicationPolicy

    init(
        controller: PersistenceController,
        deduplicationLimit: Int = 4_096,
        deduplicationInterval: TimeInterval = 604_800
    ) {
        self.controller = controller
        policy = UsageDeduplicationPolicy(limit: deduplicationLimit, interval: deduplicationInterval)
    }

    func record(
        _ receipt: UseReceipt,
        now: Date = Date(),
        expecting expectedIdentity: StoreIdentity? = nil
    ) async throws {
        guard receipt.outcome == .success else { return }
        guard receipt.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else {
            throw StoreError.invalidTransaction
        }
        let identity: StoreIdentity
        if let expectedIdentity {
            identity = expectedIdentity
        } else {
            identity = try await controller.identity()
        }
        let policy = policy
        let controller = controller

        try await controller.perform { context in
            guard identity == controller.runtime.identity else { throw StoreError.preconditionFailed }
            try StoreSafetyGate.validate(.projection, runtime: controller.runtime)
            let shouldRegisterPolicy: Bool
            if let configured = controller.runtime.usagePolicy {
                guard configured == policy else { throw StoreError.preconditionFailed }
                shouldRegisterPolicy = false
            } else {
                shouldRegisterPolicy = true
            }
            do {
                let expiration = now.addingTimeInterval(-policy.interval)
                let expiredRequest = NSFetchRequest<NSManagedObject>(entityName: "UsageExecutionDedup")
                expiredRequest.predicate = NSPredicate(format: "recordedAt <= %@", expiration as NSDate)
                expiredRequest.fetchBatchSize = 256
                try context.fetch(expiredRequest).forEach(context.delete)

                let duplicateRequest = NSFetchRequest<NSManagedObject>(entityName: "UsageExecutionDedup")
                duplicateRequest.predicate = NSPredicate(
                    format: "id == %@ AND recordedAt > %@",
                    receipt.executionID as NSUUID,
                    expiration as NSDate
                )
                duplicateRequest.fetchLimit = 1
                if try context.fetch(duplicateRequest).isEmpty == false {
                    if context.hasChanges { try context.save() }
                    if shouldRegisterPolicy { controller.runtime.usagePolicy = policy }
                    return
                }

                let summaryRequest = NSFetchRequest<NSManagedObject>(entityName: "UsageSummary")
                summaryRequest.predicate = NSPredicate(
                    format: "itemID == %@ AND facet == %@",
                    receipt.ref.itemID.rawValue as NSUUID,
                    receipt.ref.facet.rawValue
                )
                summaryRequest.fetchLimit = 1
                let summary = try context.fetch(summaryRequest).first
                    ?? NSEntityDescription.insertNewObject(forEntityName: "UsageSummary", into: context)
                if summary.value(forKey: "id") == nil {
                    summary.setValue(UUID(), forKey: "id")
                    summary.setValue(receipt.ref.itemID.rawValue, forKey: "itemID")
                    summary.setValue(receipt.ref.facet.rawValue, forKey: "facet")
                    summary.setValue(receipt.occurredAt, forKey: "lastUsedAt")
                } else if let previous = summary.value(forKey: "lastUsedAt") as? Date,
                          previous < receipt.occurredAt {
                    summary.setValue(receipt.occurredAt, forKey: "lastUsedAt")
                }
                let previousCount = summary.value(forKey: "useCount") as? Int64 ?? 0
                if previousCount < Int64.max {
                    summary.setValue(previousCount + 1, forKey: "useCount")
                }

                if policy.limit > 0 {
                    let dedup = NSEntityDescription.insertNewObject(
                        forEntityName: "UsageExecutionDedup",
                        into: context
                    )
                    dedup.setValue(receipt.executionID, forKey: "id")
                    dedup.setValue(now, forKey: "recordedAt")
                }

                let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "UsageExecutionDedup")
                let excess = max(0, try context.count(for: countRequest) - policy.limit)
                if excess > 0 {
                    let oldestRequest = NSFetchRequest<NSManagedObject>(entityName: "UsageExecutionDedup")
                    if policy.limit > 0 {
                        oldestRequest.predicate = NSPredicate(
                            format: "id != %@",
                            receipt.executionID as NSUUID
                        )
                    }
                    oldestRequest.sortDescriptors = [
                        NSSortDescriptor(key: "recordedAt", ascending: true),
                        NSSortDescriptor(key: "id", ascending: true)
                    ]
                    oldestRequest.fetchLimit = excess
                    try context.fetch(oldestRequest).forEach(context.delete)
                }

                try context.save()
                if shouldRegisterPolicy { controller.runtime.usagePolicy = policy }
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func summaries(for refs: [ContentRef]) async throws -> [UsageSummary] {
        let keys = refs.reduce(into: [UsageKey]()) { result, ref in
            let key = UsageKey(itemID: ref.itemID, facet: ref.facet)
            if result.contains(key) == false { result.append(key) }
        }
        guard keys.isEmpty == false else { return [] }

        return try await controller.perform { context in
            var summariesByKey: [UsageKey: UsageSummary] = [:]
            let requestedKeys = Set(keys)
            for chunkStart in stride(from: 0, to: keys.count, by: 400) {
                let chunk = keys[chunkStart..<min(chunkStart + 400, keys.count)]
                let request = NSFetchRequest<NSManagedObject>(entityName: "UsageSummary")
                request.predicate = NSPredicate(
                    format: "itemID IN %@",
                    chunk.map(\.itemID.rawValue) as NSArray
                )
                request.fetchBatchSize = 400
                for object in try context.fetch(request) {
                    guard let itemID = object.value(forKey: "itemID") as? UUID,
                          let facetValue = object.value(forKey: "facet") as? String,
                          let facet = ContentFacet(rawValue: facetValue),
                          let lastUsedAt = object.value(forKey: "lastUsedAt") as? Date else {
                        throw StoreError.corruptStore
                    }
                    let key = UsageKey(itemID: ItemID(rawValue: itemID), facet: facet)
                    guard requestedKeys.contains(key) else { continue }
                    summariesByKey[key] = UsageSummary(
                        itemID: key.itemID,
                        facet: key.facet,
                        lastUsedAt: lastUsedAt,
                        useCount: object.value(forKey: "useCount") as? Int64 ?? 0
                    )
                }
            }
            return keys.compactMap { summariesByKey[$0] }
        }
    }
}

extension LocalUsageStore {
    func allSummaries() async throws -> [UsageSummary] {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            let request = NSFetchRequest<NSManagedObject>(entityName: "UsageSummary")
            request.fetchBatchSize = 400
            return try context.fetch(request).map { object in
                guard let itemID = object.value(forKey: "itemID") as? UUID,
                      let facetValue = object.value(forKey: "facet") as? String,
                      let facet = ContentFacet(rawValue: facetValue),
                      let lastUsedAt = object.value(forKey: "lastUsedAt") as? Date else {
                    throw StoreError.corruptStore
                }
                return UsageSummary(
                    itemID: ItemID(rawValue: itemID),
                    facet: facet,
                    lastUsedAt: lastUsedAt,
                    useCount: object.value(forKey: "useCount") as? Int64 ?? 0
                )
            }
        }
    }
}

private struct UsageKey: Hashable, Sendable {
    let itemID: ItemID
    let facet: ContentFacet
}
