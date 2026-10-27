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

final class LocalUsageStore: @unchecked Sendable {
    private let controller: PersistenceController
    private let deduplicationLimit: Int
    private let deduplicationInterval: TimeInterval

    init(
        controller: PersistenceController,
        deduplicationLimit: Int = 4_096,
        deduplicationInterval: TimeInterval = 604_800
    ) {
        self.controller = controller
        self.deduplicationLimit = max(0, deduplicationLimit)
        self.deduplicationInterval = max(0, deduplicationInterval)
    }

    func record(_ receipt: UseReceipt, now: Date = Date()) async throws {
        guard receipt.outcome == .success else { return }
        let deduplicationLimit = deduplicationLimit
        let deduplicationInterval = deduplicationInterval

        try await controller.perform { context in
            do {
                let expiration = now.addingTimeInterval(-deduplicationInterval)
                let expiredRequest = NSFetchRequest<NSManagedObject>(entityName: "UsageExecutionDedup")
                expiredRequest.predicate = NSPredicate(format: "recordedAt <= %@", expiration as NSDate)
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

                if deduplicationLimit > 0 {
                    let dedup = NSEntityDescription.insertNewObject(
                        forEntityName: "UsageExecutionDedup",
                        into: context
                    )
                    dedup.setValue(receipt.executionID, forKey: "id")
                    dedup.setValue(now, forKey: "recordedAt")
                }

                let allDedupRequest = NSFetchRequest<NSManagedObject>(entityName: "UsageExecutionDedup")
                allDedupRequest.sortDescriptors = [NSSortDescriptor(key: "recordedAt", ascending: true)]
                let dedupRecords = try context.fetch(allDedupRequest)
                let excess = max(0, dedupRecords.count - deduplicationLimit)
                for record in dedupRecords.prefix(excess) {
                    context.delete(record)
                }

                try context.save()
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
            let request = NSFetchRequest<NSManagedObject>(entityName: "UsageSummary")
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: keys.map { key in
                NSPredicate(
                    format: "itemID == %@ AND facet == %@",
                    key.itemID.rawValue as NSUUID,
                    key.facet.rawValue
                )
            })
            let objects = try context.fetch(request)
            var summariesByKey: [UsageKey: UsageSummary] = [:]
            for object in objects {
                guard let itemID = object.value(forKey: "itemID") as? UUID,
                      let facetValue = object.value(forKey: "facet") as? String,
                      let facet = ContentFacet(rawValue: facetValue),
                      let lastUsedAt = object.value(forKey: "lastUsedAt") as? Date else {
                    throw LocalUsageStoreError.invalidSummary
                }
                let summary = UsageSummary(
                    itemID: ItemID(rawValue: itemID),
                    facet: facet,
                    lastUsedAt: lastUsedAt,
                    useCount: object.value(forKey: "useCount") as? Int64 ?? 0
                )
                summariesByKey[UsageKey(itemID: summary.itemID, facet: summary.facet)] = summary
            }
            return keys.compactMap { summariesByKey[$0] }
        }
    }
}

private struct UsageKey: Hashable, Sendable {
    let itemID: ItemID
    let facet: ContentFacet
}

private enum LocalUsageStoreError: Error {
    case invalidSummary
}
