import Foundation

struct CaptureSnapshotValue: Codable, Equatable, Sendable {
    let items: [CapturedPasteboardItem]
    let changeCount: Int
    let sourceApp: String?
}

struct CapturedPasteboardItem: Codable, Equatable, Sendable {
    let representations: [CapturedRepresentation]
}

struct CapturedRepresentation: Codable, Equatable, Sendable {
    let typeIdentifier: String
    let bytes: Data
}

enum SnapshotReaderError: Error, Codable, Equatable {
    case readerUnavailable
    case readTimedOut
    case permissionDenied
    case emptyPasteboard
    case privacyRestricted
    case unsupportedType
    case incompleteRepresentation(itemIndex: Int, typeIdentifier: String)
    case payloadTooLarge(maximumBytes: Int)
    case changedDuringRead(expected: Int, actual: Int)
}

enum CaptureWire {
    static let maximumPayloadBytes = 50 * 1_024 * 1_024
    static let maximumResponseBytes = 64 * 1_024 * 1_024
    static let magic = Data("KPTREAD1".utf8)
    static let ownWriteTypeIdentifier = "io.github.insightprober.keeptide.own-write"
}

struct CaptureReaderReply: Codable, Sendable {
    let protocolVersion: Int
    let processID: Int32
    let snapshot: CaptureSnapshotValue?
    let failure: SnapshotReaderError?
}
