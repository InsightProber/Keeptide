import Foundation

enum ArchiveSourceKind: String, Codable, Equatable, Sendable {
    case currentLocalSnapshot

    var publicLabel: String { "Current Local Snapshot" }
}

enum ArchiveScopeKind: String, Codable, Equatable, Sendable {
    case allVisible
    case selected

    var publicLabel: String {
        switch self {
        case .allVisible: "All Visible Content"
        case .selected: "Selected Content"
        }
    }
}

enum ArchiveFacetKind: String, Codable, Equatable, Sendable {
    case clipboardHistory
    case memo

    var publicLabel: String {
        switch self {
        case .clipboardHistory: "Clipboard History"
        case .memo: "Memo"
        }
    }
}

enum ArchiveContentKind: String, Codable, Equatable, Sendable {
    case text, markdown, url, image, fileReference, other

    var publicLabel: String {
        switch self {
        case .text: "Text"
        case .markdown: "Markdown"
        case .url: "URL"
        case .image: "Image"
        case .fileReference: "File Reference"
        case .other: "Other"
        }
    }
}

enum ArchiveAvailability: String, Codable, Equatable, Sendable {
    case complete
    case requiresFileRelocation

    var publicLabel: String {
        switch self {
        case .complete: "Complete"
        case .requiresFileRelocation: "Requires File Relocation"
        }
    }
}

enum ArchiveRepresentationStorage: String, Codable, Equatable, Sendable {
    case portable
    case localReference
}

enum ArchiveContentOriginKind: String, Codable, Equatable, Sendable {
    case capture
    case ownedPlainText
    case ownedMarkdown
}

struct ArchiveContentOrigin: Codable, Equatable, Sendable {
    var kind: ArchiveContentOriginKind
    var captureManifestVersion: Int?
    var captureItemCount: Int?
}

struct ArchiveSource: Codable, Equatable, Sendable {
    var token: ArchiveSourceKind
    var label: String
}

struct ArchiveScopeDescriptor: Codable, Equatable, Sendable {
    var kind: ArchiveScopeKind
    var label: String
    /// For `.selected`, this is the exact exported count after stable exact-ref de-duplication.
    var requestedRefCount: Int?
    var selectedRefsSHA256: String?
}

struct ArchiveFileDigest: Codable, Equatable, Sendable {
    var path: String
    var byteCount: Int64
    var sha256: String
}

struct ArchiveCollection: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var color: String
}

struct ArchiveRepresentation: Codable, Equatable, Sendable {
    var id: UUID
    var itemIndex: Int
    var representationIndex: Int
    var typeIdentifier: String
    var storage: ArchiveRepresentationStorage
    var byteCount: Int64
    /// SHA-256 of portable representation bytes. Nil for local references.
    var digestSHA256: String?
    /// Opaque 32-byte relocation token as lowercase hex. It is not an external-file digest.
    var relocationTokenHex: String?
    var payloadPath: String?
    /// Digest of the derived, human-readable file, when this representation supplies one.
    var readable: ArchiveFileDigest?
}

struct ArchiveEntry: Codable, Equatable, Sendable {
    var ordinal: Int
    var itemID: UUID
    var facet: ArchiveFacetKind
    var facetLabel: String
    var contentVersion: UUID
    var contentDigestSHA256: String
    var origin: ArchiveContentOrigin
    var contentKind: ArchiveContentKind
    var contentKindLabel: String
    var availability: ArchiveAvailability
    var availabilityLabel: String
    var title: String
    var note: String?
    var sourceApplicationIdentifier: String?
    var collection: ArchiveCollection?
    var representations: [ArchiveRepresentation]
}

struct ArchiveManifest: Codable, Equatable, Sendable {
    static let currentFormat = "com.insightprober.keeptide.local-export"
    static let currentSchemaVersion = 1
    static let currentVerifierSchemaVersion = 1

    var format: String
    var schemaVersion: Int
    var createdAt: Date
    var source: ArchiveSource
    var scope: ArchiveScopeDescriptor
    /// Per-export identity. This deliberately does not expose a persistent local-store identity.
    var exportID: UUID
    var snapshotBoundarySHA256: String
    var expectedEntryCount: Int
    var expectedRepresentationCount: Int
    var expectedPortablePayloadCount: Int
    var expectedReadableFileCount: Int
    var containsFileReferencesRequiringRelocation: Bool
    var readme: ArchiveFileDigest
    var entries: ArchiveFileDigest
    var verifierSchemaVersion: Int
}

extension ArchiveManifest {
    /// Bytes as the archive spells them: two lowercase hexadecimal digits a byte. Every digest and token the manifest
    /// and the entries record is spelled this way, and the verifier compares what it computes in the same spelling,
    /// so the writer, the export and the verifier all spell bytes here. Changing it changes the archive format.
    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct ArchiveVerification: Equatable, Sendable {
    let entryCount: Int
    let representationCount: Int
    let portablePayloadCount: Int
    let readableFileCount: Int
    let verifiedRootDigest: String
}
