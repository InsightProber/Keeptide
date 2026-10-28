import CryptoKit
import Foundation

struct ItemID: Codable, Equatable, Hashable, Sendable {
    var rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct CollectionID: Codable, Equatable, Hashable, Sendable {
    var rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct ContentVersion: Codable, Equatable, Hashable, Sendable {
    var rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum ContentFacet: String, Codable, Equatable, Hashable, Sendable {
    case history
    case memo
}

struct ContentRef: Codable, Equatable, Hashable, Sendable {
    var itemID: ItemID
    var facet: ContentFacet
    var version: ContentVersion
    var digest: Data

    init(itemID: ItemID, facet: ContentFacet, version: ContentVersion, digest: Data) {
        self.itemID = itemID
        self.facet = facet
        self.version = version
        self.digest = digest
    }
}

enum RepresentationStorage: String, Codable, Equatable, Sendable {
    case portable
    case localReference
}

struct RepresentationValue: Codable, Equatable, Sendable {
    var id: UUID
    var snapshotID: UUID
    var itemIndex: Int
    var representationIndex: Int
    var typeIdentifier: String
    var storage: RepresentationStorage
    var byteCount: Int64
    var digest: Data
    var bytes: Data?

    init(
        id: UUID = UUID(),
        snapshotID: UUID,
        itemIndex: Int,
        representationIndex: Int,
        typeIdentifier: String,
        storage: RepresentationStorage,
        byteCount: Int64,
        digest: Data,
        bytes: Data?
    ) {
        self.id = id
        self.snapshotID = snapshotID
        self.itemIndex = itemIndex
        self.representationIndex = representationIndex
        self.typeIdentifier = typeIdentifier
        self.storage = storage
        self.byteCount = byteCount
        self.digest = digest
        self.bytes = bytes
    }
}

struct CaptureValue: Codable, Equatable, Sendable {
    var id: UUID
    var manifest: CaptureManifest
    var digest: Data
    var representations: [RepresentationValue]

    init(id: UUID = UUID(), manifest: CaptureManifest, digest: Data, representations: [RepresentationValue]) {
        self.id = id
        self.manifest = manifest
        self.digest = digest
        self.representations = representations
    }
}

enum MemoBodyMode: String, Codable, Equatable, Sendable {
    case inheritedCapture
    case ownedPlainText
    case ownedMarkdown
}

struct MemoValue: Codable, Equatable, Sendable {
    var id: UUID
    var itemID: ItemID
    var title: String
    var bodyMode: MemoBodyMode
    var sourceRepresentationType: String?
    var body: Data?
    var version: ContentVersion?
    var digest: Data?
    var languageHint: String?
    var note: String
    var deletedAt: Date?
    var purgeAfter: Date?

    init(
        id: UUID = UUID(), itemID: ItemID, title: String = "", bodyMode: MemoBodyMode,
        sourceRepresentationType: String? = nil, body: Data? = nil, version: ContentVersion? = nil,
        digest: Data? = nil, languageHint: String? = nil, note: String = "",
        deletedAt: Date? = nil, purgeAfter: Date? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.title = title
        self.bodyMode = bodyMode
        self.sourceRepresentationType = sourceRepresentationType
        self.body = body
        self.version = version
        self.digest = digest
        self.languageHint = languageHint
        self.note = note
        self.deletedAt = deletedAt
        self.purgeAfter = purgeAfter
    }
}

struct ItemValue: Codable, Equatable, Sendable {
    var id: ItemID
    var createdAt: Date
    var sourceApp: String?
    var title: String
    var captureID: UUID?
    var memoID: UUID?
    var collectionID: CollectionID?
    var isFavorite: Bool
    var historyEligible: Bool
    var historyDeletedAt: Date?
    var historyPurgeAfter: Date?
    var deletedAt: Date?
    var lastCopiedAt: Date
    var copyCount: Int64

    init(
        id: ItemID = ItemID(), createdAt: Date = Date(), sourceApp: String? = nil, title: String = "",
        captureID: UUID? = nil, memoID: UUID? = nil, collectionID: CollectionID? = nil,
        isFavorite: Bool = false, historyEligible: Bool = false, historyDeletedAt: Date? = nil,
        historyPurgeAfter: Date? = nil, deletedAt: Date? = nil, lastCopiedAt: Date = Date(), copyCount: Int64 = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.title = title
        self.captureID = captureID
        self.memoID = memoID
        self.collectionID = collectionID
        self.isFavorite = isFavorite
        self.historyEligible = historyEligible
        self.historyDeletedAt = historyDeletedAt
        self.historyPurgeAfter = historyPurgeAfter
        self.deletedAt = deletedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
    }
}

struct CollectionValue: Codable, Equatable, Sendable {
    var id: CollectionID
    var name: String
    var color: String
    var sortOrder: Double
    var deletedAt: Date?

    init(id: CollectionID = CollectionID(), name: String = "", color: String = "", sortOrder: Double = 0,
         deletedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
        self.deletedAt = deletedAt
    }
}

struct ItemDeletionMarkerValue: Codable, Equatable, Sendable {
    var itemID: ItemID
    var deletedAt: Date

    init(itemID: ItemID, deletedAt: Date = Date()) {
        self.itemID = itemID
        self.deletedAt = deletedAt
    }
}

struct FacetDeletionMarkerValue: Codable, Equatable, Sendable {
    var id: UUID
    var itemID: ItemID
    var facet: ContentFacet
    var generationID: UUID
    var purgedAt: Date

    init(id: UUID = UUID(), itemID: ItemID, facet: ContentFacet, generationID: UUID, purgedAt: Date = Date()) {
        self.id = id
        self.itemID = itemID
        self.facet = facet
        self.generationID = generationID
        self.purgedAt = purgedAt
    }
}

enum ContentIntegrity: String, Codable, Equatable, Sendable {
    case complete
    case recovering
    case corrupt
    case requiresRelocation
}

struct ResolvedContent: Codable, Equatable, Sendable {
    let ref: ContentRef
    let integrity: ContentIntegrity
    let representations: [RepresentationValue]

    init(ref: ContentRef, integrity: ContentIntegrity, representations: [RepresentationValue]) {
        self.ref = ref
        self.integrity = integrity
        self.representations = integrity == .complete ? representations : []
    }

    var isActionable: Bool {
        integrity == .complete
    }

    private enum CodingKeys: String, CodingKey {
        case ref, integrity, representations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ref: try container.decode(ContentRef.self, forKey: .ref),
            integrity: try container.decode(ContentIntegrity.self, forKey: .integrity),
            representations: try container.decode([RepresentationValue].self, forKey: .representations)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(integrity, forKey: .integrity)
        try container.encode(representations, forKey: .representations)
    }
}

struct ItemSummary: Codable, Equatable, Sendable {
    var itemID: ItemID
    var title: String
    var lastCopiedAt: Date
    var history: ContentRef?
    var memo: ContentRef?
    /// Classified from the capture's representation types; payloads are not read.
    var kind: ContentKind
    var sourceApp: String?

    init(itemID: ItemID, title: String, lastCopiedAt: Date, history: ContentRef? = nil, memo: ContentRef? = nil,
         kind: ContentKind = .other, sourceApp: String? = nil) {
        self.itemID = itemID
        self.title = title
        self.lastCopiedAt = lastCopiedAt
        self.history = history
        self.memo = memo
        self.kind = kind
        self.sourceApp = sourceApp
    }
}

enum ContentDigest {
    static let byteCount = SHA256.Digest.byteCount

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

enum LocalReferencePrivacy {
    static let legacyManifestVersion = 1
    static let opaqueLocalReferenceManifestVersion = 2
    // Kept as the construction default; readers must use the predicates below
    // rather than treating this value as either a schema ceiling or an encoding flag.
    static let manifestVersion = opaqueLocalReferenceManifestVersion
    static let relocationTokenByteCount = ContentDigest.byteCount

    static func supports(manifestVersion: Int) -> Bool {
        manifestVersion == legacyManifestVersion
            || manifestVersion == opaqueLocalReferenceManifestVersion
    }

    static func usesLegacyLocalDescriptor(manifestVersion: Int) -> Bool {
        manifestVersion == legacyManifestVersion
    }

    static func usesOpaqueLocalDescriptor(manifestVersion: Int) -> Bool {
        manifestVersion == opaqueLocalReferenceManifestVersion
    }

    static func makeRelocationToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<relocationTokenByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    static func isCloudSafeDescriptor(_ representation: RepresentationValue) -> Bool {
        representation.storage == .localReference
            && representation.byteCount == 0
            && representation.digest.count == relocationTokenByteCount
            && representation.bytes == nil
    }
}
