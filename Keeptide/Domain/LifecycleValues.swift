import Foundation

/// A deletion target is one exact facet generation. Memo generations are memo IDs,
/// not mutable body versions.
struct DeletedFacetIdentity: Codable, Equatable, Hashable, Sendable {
    let itemID: ItemID
    let facet: ContentFacet
    let generationID: UUID

    static func history(itemID: ItemID, captureID: UUID) -> DeletedFacetIdentity {
        DeletedFacetIdentity(itemID: itemID, facet: .history, generationID: captureID)
    }

    static func memo(itemID: ItemID, memoID: UUID) -> DeletedFacetIdentity {
        DeletedFacetIdentity(itemID: itemID, facet: .memo, generationID: memoID)
    }
}

/// Exact local payload evidence captured before cloud deletion. Cleanup code must
/// match every field again before removing the corresponding local envelope.
struct CleanupPayloadIdentity: Codable, Equatable, Hashable, Sendable {
    let representationID: UUID
    let snapshotID: UUID
    let envelopeByteCount: Int64
    let envelopeDigest: Data
    let cloudToken: Data

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum CleanupIntentPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case prepared
    case cloudCommitted
    case completed
    case blocked
}

enum RawRecoveryPlanPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case prepared
    case reconciling
    case completed
    case blocked
}

/// Raw reconciliation authority is scoped to one durable plan and one store
/// generation. It is not accepted by ordinary typed writes.
struct RecoveryPermit: Codable, Equatable, Sendable {
    let planID: UUID
    let identity: StoreIdentity
}
