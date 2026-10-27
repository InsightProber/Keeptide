import AppKit
import Foundation

struct CaptureSnapshotValue: Equatable, Sendable {
    let items: [CapturedPasteboardItem]
    let changeCount: Int
    let sourceApp: String?
}

struct CapturedPasteboardItem: Equatable, Sendable {
    let representations: [CapturedRepresentation]
}

struct CapturedRepresentation: Equatable, Sendable {
    let typeIdentifier: String
    let bytes: Data

    var isLocalFileReference: Bool {
        SystemFileReferenceClassifier.isLocalFileReference(
            typeIdentifier: typeIdentifier,
            bytes: bytes
        )
    }
}

enum SnapshotReaderError: Error, Equatable {
    case permissionDenied
    case emptyPasteboard
    case privacyRestricted
    case unsupportedType
    case incompleteRepresentation(itemIndex: Int, typeIdentifier: String)
    case payloadTooLarge(maximumBytes: Int)
    case changedDuringRead(expected: Int, actual: Int)
}

@MainActor
protocol SnapshotReading: AnyObject {
    var changeCount: Int { get }
    func read(sourceApp: String?) throws -> CaptureSnapshotValue
    func readAsynchronously(sourceApp: String?) async throws -> CaptureSnapshotValue
}

extension SnapshotReading {
    func readAsynchronously(sourceApp: String?) async throws -> CaptureSnapshotValue {
        try read(sourceApp: sourceApp)
    }
}

@MainActor
final class SnapshotReader: SnapshotReading {
    nonisolated static let maximumPayloadBytes = 50 * 1_024 * 1_024

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    // The production path creates and consumes live AppKit handles on one serial
    // executor. Only immutable values cross back to the UI. A slow provider cannot
    // block the recording controls; cancellation is checked before persistence.
    nonisolated private static let readQueue = DispatchQueue(label: "io.github.insightprober.Keeptide.capture-read", qos: .utility)

    func readAsynchronously(sourceApp: String?) async throws -> CaptureSnapshotValue {
        let name = pasteboard.name.rawValue
        return try await withCheckedThrowingContinuation { continuation in
            Self.readQueue.async {
                let result: Result<CaptureSnapshotValue, Error> = autoreleasepool {
                    Result { try Self.materialize(pasteboard: NSPasteboard(name: .init(name)), sourceApp: sourceApp) }
                }
                continuation.resume(with: result)
            }
        }
    }

    func read(sourceApp: String?) throws -> CaptureSnapshotValue {
        try Self.materialize(pasteboard: pasteboard, sourceApp: sourceApp)
    }

    nonisolated private static func materialize(pasteboard: NSPasteboard, sourceApp: String?) throws -> CaptureSnapshotValue {
        if pasteboard.accessBehavior == .alwaysDeny {
            throw SnapshotReaderError.permissionDenied
        }

        let initialChangeCount = pasteboard.changeCount
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            throw SnapshotReaderError.emptyPasteboard
        }

        let allTypeIdentifiers = pasteboardItems.flatMap { item in
            item.types.map(\.rawValue)
        }
        guard allTypeIdentifiers.allSatisfy(CapturePolicy.isSafeTypeIdentifier) else {
            throw SnapshotReaderError.unsupportedType
        }
        guard CapturePolicy.decision(
            typeIdentifiers: allTypeIdentifiers,
            sourceApp: nil,
            isCaptureEnabled: true,
            isPaused: false,
            excludedSourceApps: []
        ) == .capture else {
            throw SnapshotReaderError.privacyRestricted
        }

        var totalBytes = 0
        var capturedItems: [CapturedPasteboardItem] = []
        capturedItems.reserveCapacity(pasteboardItems.count)

        for (itemIndex, pasteboardItem) in pasteboardItems.enumerated() {
            let capturedTypes = pasteboardItem.types.filter {
                $0.rawValue != OwnWriteToken.typeIdentifier
            }
            guard !capturedTypes.isEmpty else {
                throw SnapshotReaderError.emptyPasteboard
            }

            var representations: [CapturedRepresentation] = []
            representations.reserveCapacity(capturedTypes.count)
            for type in capturedTypes {
                guard let bytes = pasteboardItem.data(forType: type) else {
                    let currentChangeCount = pasteboard.changeCount
                    if currentChangeCount != initialChangeCount {
                        throw SnapshotReaderError.changedDuringRead(
                            expected: initialChangeCount,
                            actual: currentChangeCount
                        )
                    }
                    throw SnapshotReaderError.incompleteRepresentation(
                        itemIndex: itemIndex,
                        typeIdentifier: type.rawValue
                    )
                }
                guard bytes.count <= Self.maximumPayloadBytes - totalBytes else {
                    throw SnapshotReaderError.payloadTooLarge(maximumBytes: Self.maximumPayloadBytes)
                }
                totalBytes += bytes.count
                representations.append(CapturedRepresentation(typeIdentifier: type.rawValue, bytes: bytes))
            }
            capturedItems.append(CapturedPasteboardItem(representations: representations))
        }

        let finalChangeCount = pasteboard.changeCount
        guard finalChangeCount == initialChangeCount else {
            throw SnapshotReaderError.changedDuringRead(
                expected: initialChangeCount,
                actual: finalChangeCount
            )
        }

        return CaptureSnapshotValue(
            items: capturedItems,
            changeCount: finalChangeCount,
            sourceApp: sourceApp
        )
    }
}
