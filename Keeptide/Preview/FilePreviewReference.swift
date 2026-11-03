import Foundation

/// A validated local-only handle to one unambiguous file representation.
/// Local paths and bookmarks must never be copied into portable exports or logs.
struct FilePreviewReference: Equatable, Sendable {
    let ref: ContentRef
    let representationID: UUID
    let snapshotID: UUID
    let itemIndex: Int
    let representationIndex: Int
    let typeIdentifier: String
    let descriptorByteCount: Int64
    let descriptorDigest: Data
    let bindingSupport: FilePreviewBindingSupport
    let displayName: String?
    let localAccess: LocalFileAccess?
}

enum FilePreviewBindingSupport: String, Equatable, Sendable {
    case supportedFileURL
    case missingLegacyDescriptor
    case unsupportedCompound
}

enum FilePreviewReferenceError: Error, Equatable {
    case contentUnavailable(ContentIntegrity)
    case unsupportedRepresentationLayout
    case unsupportedLegacyRelocation
    case invalidSelectedFile
    case differentFileReference
}
