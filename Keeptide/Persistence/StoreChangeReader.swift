import CoreData
import Foundation

struct StoreChangeReader: Sendable {
    private static let transactionPageSize = 128

    let controller: PersistenceController

    func read(after token: Data?) async throws -> ChangeBatch {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            let identity = controller.runtime.identity
            let cursor = try Self.decode(token, identity: identity)
            let transactions = try Self.fetchTransactionPage(
                after: cursor,
                from: controller.contentStore,
                in: context
            )
            let records = try Self.records(
                for: transactions,
                identity: identity,
                store: controller.contentStore,
                in: context
            )
            let changes: [ChangeTransaction] = zip(transactions, records).compactMap { pair in
                let (transaction, transactionRecords) = pair
                guard transactionRecords.isEmpty == false else { return nil }
                return ChangeTransaction(
                    sequence: transaction.transactionNumber,
                    author: transaction.author,
                    changes: transactionRecords
                )
            }
            let next = try transactions.last.map { try Self.checkpoint($0, identity: identity) } ?? token
            return ChangeBatch(identity: identity, transactions: changes, token: next)
        }
    }

    private static func decode(_ token: Data?, identity: StoreIdentity) throws -> HistoryCursor {
        guard let token else { return HistoryCursor(token: nil, transactionNumber: 0) }
        guard token.count < 1_048_576,
              let envelope = try? JSONDecoder().decode(HistoryCheckpoint.self, from: token),
              envelope.version == 2,
              envelope.identity == identity,
              envelope.transactionNumber >= 0,
              let decoded = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: NSPersistentHistoryToken.self,
                  from: envelope.token
              ) else {
            throw StoreError.invalidToken
        }
        return HistoryCursor(token: decoded, transactionNumber: envelope.transactionNumber)
    }

    private static func fetchTransactionPage(
        after cursor: HistoryCursor,
        from store: NSPersistentStore,
        in context: NSManagedObjectContext
    ) throws -> [NSPersistentHistoryTransaction] {
        let (entity, numberProperty) = try historyTransactionMetadata(in: context)
        if let token = cursor.token {
            try validateCursor(
                token: token,
                transactionNumber: cursor.transactionNumber,
                entity: entity,
                numberProperty: numberProperty,
                store: store,
                context: context
            )
        }
        guard try hasHistory(after: cursor.token, in: store, context: context) else { return [] }
        let firstNumber = try nextTransactionNumber(
            after: cursor.transactionNumber,
            entity: entity,
            numberProperty: numberProperty,
            store: store,
            context: context
        )
        guard firstNumber > 0,
              firstNumber <= Int64.max - Int64(transactionPageSize - 1) else {
            throw StoreError.corruptStore
        }
        let lowerBound = firstNumber - 1
        let upperBound = firstNumber + Int64(transactionPageSize - 1)
        let page = try transactions(
            after: lowerBound,
            through: upperBound,
            resultType: .transactionsAndChanges,
            entity: entity,
            numberProperty: numberProperty,
            store: store,
            context: context
        ).sorted { $0.transactionNumber < $1.transactionNumber }
        guard !page.isEmpty,
              page.count <= transactionPageSize,
              zip(page, page.dropFirst()).allSatisfy({ $0.0.transactionNumber < $0.1.transactionNumber }),
              page.allSatisfy({ lowerBound < $0.transactionNumber && $0.transactionNumber <= upperBound }) else {
            throw StoreError.corruptStore
        }
        return page
    }

    private static func historyTransactionMetadata(
        in context: NSManagedObjectContext
    ) throws -> (NSEntityDescription, NSPropertyDescription) {
        guard let entity = NSPersistentHistoryTransaction.entityDescription(with: context),
              let numberProperty = entity.propertiesByName["transactionNumber"] else {
            throw StoreError.corruptStore
        }
        return (entity, numberProperty)
    }

    private static func validateCursor(
        token: NSPersistentHistoryToken,
        transactionNumber: Int64,
        entity: NSEntityDescription,
        numberProperty: NSPropertyDescription,
        store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws {
        guard transactionNumber > 0 else { throw StoreError.invalidToken }
        let matches = try transactions(
            after: transactionNumber - 1,
            through: transactionNumber,
            resultType: .transactionsOnly,
            entity: entity,
            numberProperty: numberProperty,
            store: store,
            context: context
        )
        guard matches.count == 1, matches[0].token.isEqual(token) else {
            throw StoreError.invalidToken
        }
    }

    private static func nextTransactionNumber(
        after lowerBound: Int64,
        entity: NSEntityDescription,
        numberProperty: NSPropertyDescription,
        store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws -> Int64 {
        var distance = Int64(transactionPageSize)
        var upperBound: Int64
        while true {
            guard lowerBound <= Int64.max - distance else { throw StoreError.corruptStore }
            upperBound = lowerBound + distance
            if try historyCount(
                after: lowerBound,
                through: upperBound,
                entity: entity,
                numberProperty: numberProperty,
                store: store,
                context: context
            ) > 0 {
                break
            }
            guard distance <= Int64.max / 2 else { throw StoreError.corruptStore }
            distance *= 2
        }

        var emptyThrough = lowerBound
        var populatedThrough = upperBound
        while populatedThrough - emptyThrough > 1 {
            let midpoint = emptyThrough + (populatedThrough - emptyThrough) / 2
            if try historyCount(
                after: lowerBound,
                through: midpoint,
                entity: entity,
                numberProperty: numberProperty,
                store: store,
                context: context
            ) > 0 {
                populatedThrough = midpoint
            } else {
                emptyThrough = midpoint
            }
        }
        return populatedThrough
    }

    private static func historyCount(
        after lowerBound: Int64,
        through upperBound: Int64,
        entity: NSEntityDescription,
        numberProperty: NSPropertyDescription,
        store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws -> Int {
        let request = historyRequest(
            after: lowerBound,
            through: upperBound,
            resultType: .count,
            entity: entity,
            numberProperty: numberProperty,
            store: store
        )
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let count = result.result as? Int else {
            throw StoreError.corruptStore
        }
        return count
    }

    private static func transactions(
        after lowerBound: Int64,
        through upperBound: Int64,
        resultType: NSPersistentHistoryResultType,
        entity: NSEntityDescription,
        numberProperty: NSPropertyDescription,
        store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws -> [NSPersistentHistoryTransaction] {
        let request = historyRequest(
            after: lowerBound,
            through: upperBound,
            resultType: resultType,
            entity: entity,
            numberProperty: numberProperty,
            store: store
        )
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction] else {
            throw StoreError.corruptStore
        }
        return transactions
    }

    private static func historyRequest(
        after lowerBound: Int64,
        through upperBound: Int64,
        resultType: NSPersistentHistoryResultType,
        entity: NSEntityDescription,
        numberProperty: NSPropertyDescription,
        store: NSPersistentStore
    ) -> NSPersistentHistoryChangeRequest {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>()
        fetchRequest.entity = entity
        fetchRequest.predicate = NSPredicate(
            format: "%K > %@ AND %K <= %@",
            numberProperty.name,
            NSNumber(value: lowerBound),
            numberProperty.name,
            NSNumber(value: upperBound)
        )
        let request = NSPersistentHistoryChangeRequest.fetchHistory(withFetch: fetchRequest)
        request.affectedStores = [store]
        request.resultType = resultType
        return request
    }

    private static func hasHistory(
        after token: NSPersistentHistoryToken?,
        in store: NSPersistentStore,
        context: NSManagedObjectContext
    ) throws -> Bool {
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
        request.affectedStores = [store]
        request.resultType = .count
        guard let result = try context.execute(request) as? NSPersistentHistoryResult,
              let count = result.result as? Int else {
            throw StoreError.corruptStore
        }
        return count > 0
    }

    private static func records(
        for transactions: [NSPersistentHistoryTransaction],
        identity: StoreIdentity,
        store: NSPersistentStore,
        in context: NSManagedObjectContext
    ) throws -> [[StoreChange]] {
        let allChanges = transactions.flatMap { $0.changes ?? [] }
        var idsByObjectID: [NSManagedObjectID: UUID] = [:]
        for change in allChanges where change.changeType == .delete {
            if let id = change.tombstone?["id"] as? UUID {
                idsByObjectID[change.changedObjectID] = id
            }
        }

        let unresolved = allChanges.filter {
            !isInverseOnlyUpdate($0) && idsByObjectID[$0.changedObjectID] == nil
        }
        let grouped = Dictionary(grouping: unresolved, by: { $0.changedObjectID.entity.name })
        for (entityName, changes) in grouped {
            guard let entityName else {
                try throwRebuildRequired(at: transaction(containing: changes[0], in: transactions), identity: identity)
            }
            let fetched = try fetchIDs(
                entityName: entityName,
                objectIDs: Set(changes.map(\.changedObjectID)),
                in: context
            )
            idsByObjectID.merge(fetched) { existing, _ in existing }
        }

        let missingObjectIDs = Set(unresolved.map(\.changedObjectID)).subtracting(idsByObjectID.keys)
        if !missingObjectIDs.isEmpty, let last = transactions.last {
            let futureDeletionIDs = try futureDeletionIDs(
                for: missingObjectIDs,
                after: last,
                from: store,
                in: context
            )
            idsByObjectID.merge(futureDeletionIDs) { existing, _ in existing }
        }

        return try transactions.map { transaction in
            try (transaction.changes ?? []).compactMap { change in
                guard !isInverseOnlyUpdate(change) else { return nil }
                let objectID = change.changedObjectID
                guard let entity = objectID.entity.name,
                      let id = idsByObjectID[objectID] else {
                    try throwRebuildRequired(at: transaction, identity: identity)
                }
                return StoreChange(entity: entity, id: id, deleted: change.changeType == .delete)
            }
        }
    }

    /// A prior insert or update may no longer have a live row when replay starts.
    /// In that exceptional case, stream later history pages until their delete
    /// tombstones recover the logical IDs. Normal reads retain only one page;
    /// recovery work may scan farther but never accumulates the full history.
    private static func futureDeletionIDs(
        for objectIDs: Set<NSManagedObjectID>,
        after transaction: NSPersistentHistoryTransaction,
        from store: NSPersistentStore,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObjectID: UUID] {
        var remaining = objectIDs
        var ids: [NSManagedObjectID: UUID] = [:]
        var previous = transaction
        while !remaining.isEmpty {
            let page = try fetchTransactionPage(
                after: HistoryCursor(token: previous.token, transactionNumber: previous.transactionNumber),
                from: store,
                in: context
            )
            guard let first = page.first, let last = page.last else { break }
            guard previous.transactionNumber < first.transactionNumber else {
                throw StoreError.corruptStore
            }
            for change in page.flatMap({ $0.changes ?? [] })
            where change.changeType == .delete && remaining.contains(change.changedObjectID) {
                guard let id = change.tombstone?["id"] as? UUID else { continue }
                ids[change.changedObjectID] = id
                remaining.remove(change.changedObjectID)
            }
            previous = last
        }
        return ids
    }

    private static func fetchIDs(
        entityName: String,
        objectIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) throws -> [NSManagedObjectID: UUID] {
        guard objectIDs.isEmpty == false else { return [:] }
        let objectID = NSExpressionDescription()
        objectID.name = "objectID"
        objectID.expression = NSExpression.expressionForEvaluatedObject()
        objectID.expressionResultType = .objectIDAttributeType
        let request = NSFetchRequest<NSDictionary>(entityName: entityName)
        request.predicate = NSPredicate(format: "SELF IN %@", Array(objectIDs))
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id", objectID]
        request.fetchBatchSize = 256
        return try context.fetch(request).reduce(into: [:]) { result, row in
            guard let managedObjectID = row["objectID"] as? NSManagedObjectID,
                  let id = row["id"] as? UUID else { return }
            result[managedObjectID] = id
        }
    }

    private static func isInverseOnlyUpdate(_ change: NSPersistentHistoryChange) -> Bool {
        guard change.changeType == .update,
              let properties = change.updatedProperties,
              properties.isEmpty == false else { return false }
        return properties.allSatisfy { $0 is NSRelationshipDescription }
    }

    private static func transaction(
        containing change: NSPersistentHistoryChange,
        in transactions: [NSPersistentHistoryTransaction]
    ) -> NSPersistentHistoryTransaction {
        change.transaction ?? transactions[transactions.count - 1]
    }

    private static func throwRebuildRequired(
        at transaction: NSPersistentHistoryTransaction,
        identity: StoreIdentity
    ) throws -> Never {
        throw StoreError.historyRequiresRebuild(
            checkpoint: try checkpoint(transaction, identity: identity)
        )
    }

    private static func checkpoint(
        _ transaction: NSPersistentHistoryTransaction,
        identity: StoreIdentity
    ) throws -> Data {
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: transaction.token,
            requiringSecureCoding: true
        )
        return try JSONEncoder().encode(
            HistoryCheckpoint(
                version: 2,
                identity: identity,
                token: archived,
                transactionNumber: transaction.transactionNumber
            )
        )
    }
}

private struct HistoryCursor {
    let token: NSPersistentHistoryToken?
    let transactionNumber: Int64
}

private struct HistoryCheckpoint: Codable {
    let version: Int
    let identity: StoreIdentity
    let token: Data
    let transactionNumber: Int64
}
