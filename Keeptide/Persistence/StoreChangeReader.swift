import CoreData
import Foundation

struct StoreChangeReader: Sendable {
    let controller: PersistenceController

    func read(after token: Data?) async throws -> ChangeBatch {
        try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            let identity = controller.runtime.identity
            let historyToken: NSPersistentHistoryToken?
            if let token {
                guard token.count < 1_048_576,
                      let envelope = try? JSONDecoder().decode(HistoryCheckpoint.self, from: token),
                      envelope.version == 1, envelope.identity == identity,
                      let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self,
                                                                          from: envelope.token) else {
                    throw StoreError.invalidToken
                }
                historyToken = decoded
            } else { historyToken = nil }
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: historyToken)
            request.affectedStores = [controller.contentStore]
            request.resultType = .transactionsAndChanges
            guard let result = try context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction] else {
                throw StoreError.corruptStore
            }
            // Earlier insert/update objects may already be deleted. Preserved IDs
            // in deletion tombstones keep replay identities independent of faults.
            var deletedIDs: [NSManagedObjectID: UUID] = [:]
            for change in transactions.flatMap({ $0.changes ?? [] }) where change.changeType == .delete {
                if let id = change.tombstone?["id"] as? UUID { deletedIDs[change.changedObjectID] = id }
            }
            let changes = try transactions.map { transaction in
                let records = try (transaction.changes ?? []).map { change -> StoreChange in
                    let objectID = change.changedObjectID
                    let id = deletedIDs[objectID]
                        ?? (try? context.existingObject(with: objectID).value(forKey: "id") as? UUID)
                    guard let id, let entity = objectID.entity.name else { throw StoreError.invalidToken }
                    return StoreChange(entity: entity, id: id, deleted: change.changeType == .delete)
                }
                return ChangeTransaction(sequence: transaction.transactionNumber, author: transaction.author, changes: records)
            }
            let next: Data?
            if let last = transactions.last {
                let archived = try NSKeyedArchiver.archivedData(withRootObject: last.token, requiringSecureCoding: true)
                next = try JSONEncoder().encode(HistoryCheckpoint(version: 1, identity: identity, token: archived))
            } else { next = token }
            return ChangeBatch(identity: identity, transactions: changes, token: next)
        }
    }
}

private struct HistoryCheckpoint: Codable {
    let version: Int
    let identity: StoreIdentity
    let token: Data
}
