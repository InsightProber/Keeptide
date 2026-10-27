import Foundation

enum StoreError: Error, Equatable {
    case closed, invalidModel, corruptStore, invalidTransaction, preconditionFailed
    case notFound, staleReference, invalidToken, invalidLease, snapshotUnavailable
    case contentProtected, operationDenied, storeInUse
    // Rebuild the derived projection before adopting this captured history boundary.
    case historyRequiresRebuild(checkpoint: Data?)
}

struct StoreIdentity: Codable, Equatable, Sendable {
    let storeID: UUID
    let generation: UUID
}

enum StoreSafetyState: String, Codable, Sendable {
    case localReady, active, quarantined, suspended
}

enum StoreOperation: String, Codable, Sendable {
    case write, maintenance, completeArchive, projection
}

struct StorePermit: Codable, Equatable, Sendable {
    let identity: StoreIdentity
    let operation: StoreOperation
}

enum RecordKey: Codable, Equatable, Hashable, Sendable {
    case item(ItemID), capture(UUID), memo(UUID), collection(CollectionID)
    case itemMarker(ItemID), facetMarker(UUID)

    var entity: String {
        switch self {
        case .item: "LibraryItem"
        case .capture: "CaptureSnapshot"
        case .memo: "MemoDocument"
        case .collection: "Collection"
        case .itemMarker: "ItemDeletionMarker"
        case .facetMarker: "FacetDeletionMarker"
        }
    }

    var id: UUID {
        switch self {
        case .item(let id), .itemMarker(let id): id.rawValue
        case .capture(let id), .memo(let id), .facetMarker(let id): id
        case .collection(let id): id.rawValue
        }
    }
}

enum RecordValue: Codable, Equatable, Sendable {
    case item(ItemValue), capture(CaptureValue), memo(MemoValue), collection(CollectionValue)
    case itemMarker(ItemDeletionMarkerValue), facetMarker(FacetDeletionMarkerValue)

    var key: RecordKey {
        switch self {
        case .item(let v): .item(v.id)
        case .capture(let v): .capture(v.id)
        case .memo(let v): .memo(v.id)
        case .collection(let v): .collection(v.id)
        case .itemMarker(let v): .itemMarker(v.itemID)
        case .facetMarker(let v): .facetMarker(v.id)
        }
    }
}

enum StorePrecondition: Codable, Equatable, Sendable {
    case exists(RecordKey), absent(RecordKey)
    case contentVersion(ContentRef)
    case recordUnchanged(RecordKey, fingerprint: Data)
    case facetVisible(ItemID, ContentFacet, Bool)
    case candidateSet(digest: Data, fingerprint: Data)
    case localCaptureSet(digest: Data, fingerprint: Data)
    case referenceSet(snapshotID: UUID, fingerprint: Data)
}

enum StoreMutation: Codable, Equatable, Sendable {
    case insert(RecordValue), update(RecordValue), delete(RecordKey)
}

struct StoreTransaction: Sendable {
    var transactionID = UUID()
    var identity: StoreIdentity
    var preconditions: [StorePrecondition] = []
    var mutations: [StoreMutation]
    var permit: StorePermit?
}

struct StoreReceipt: Sendable {
    let transactionID: UUID
    let identity: StoreIdentity
    let changed: [RecordKey]
}

struct SnapshotRequest: Sendable {
    var pageSize = 50
    var permit: StorePermit
    var lifetime: TimeInterval = 300
}

struct SnapshotLease: Codable, Equatable, Sendable {
    let leaseID: UUID
    let identity: StoreIdentity
    let boundary: Data
}

struct SnapshotPage: Sendable {
    let contents: [ResolvedContent]
    let next: Data?
    var portableRecords: [RecordValue] = []
}

struct StoreChange: Codable, Equatable, Sendable {
    let entity: String
    let id: UUID
    let deleted: Bool
}

struct ChangeTransaction: Codable, Sendable {
    let sequence: Int64
    let author: String?
    let changes: [StoreChange]
}

struct ChangeBatch: Sendable {
    let identity: StoreIdentity
    let transactions: [ChangeTransaction]
    let token: Data?
}
